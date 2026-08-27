import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Adds punctuation to a complete speech transcript.
///
/// Implementations must return the original text when punctuation is not
/// available. This keeps speech commands usable on devices that cannot load
/// the optional punctuation model.
abstract class AiPunctuationService {
  Future<String> addPunctuation(String text);

  Future<void> releaseIdleResources();

  Future<void> dispose();
}

/// Platform default. Android uses the local Sherpa model; other platforms
/// keep their existing speech recognizer without loading an extra model.
AiPunctuationService defaultAiPunctuationService() {
  final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  return isAndroid
      ? PlatformAiPunctuationService()
      : const NoopAiPunctuationService();
}

class NoopAiPunctuationService implements AiPunctuationService {
  const NoopAiPunctuationService();

  @override
  Future<String> addPunctuation(String text) async => text.trim();

  @override
  Future<void> releaseIdleResources() async {}

  @override
  Future<void> dispose() async {}
}

/// Android punctuation wrapper.
///
/// The native method channel copies the asset to an application file. The
/// actual ONNX object lives in a worker isolate because addPunct() is a
/// synchronous FFI call and can otherwise block Flutter's UI isolate.
class PlatformAiPunctuationService implements AiPunctuationService {
  static const _modelChannel = MethodChannel('music_player/ai_model');
  static const _modelId =
      'punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8';
  static const _workerReadyTimeout = Duration(seconds: 20);
  static const _requestTimeout = Duration(seconds: 8);

  Isolate? _isolate;
  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _receiveSubscription;
  SendPort? _sendPort;
  Completer<void>? _workerReady;
  Completer<void>? _disposeAck;
  Future<void>? _initializing;
  Future<void>? _shutdownOperation;
  final Map<int, Completer<String>> _pending = <int, Completer<String>>{};
  int _nextRequestId = 0;
  int _lifecycleGeneration = 0;
  bool _workerInitialized = false;
  bool _disposed = false;

  @override
  Future<String> addPunctuation(String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty || _disposed) return normalized;

    try {
      final sendPort = await _ensureWorker();
      final requestId = ++_nextRequestId;
      final completer = Completer<String>();
      _pending[requestId] = completer;
      sendPort.send(<String, Object?>{
        'type': 'punctuate',
        'id': requestId,
        'text': normalized,
      });
      try {
        final result = await completer.future.timeout(_requestTimeout);
        final punctuated = result.trim();
        return punctuated.isEmpty ? normalized : punctuated;
      } finally {
        _pending.remove(requestId);
      }
    } catch (error) {
      debugPrint('[AiPunctuation] punctuation unavailable: $error');
      return normalized;
    }
  }

  Future<SendPort> _ensureWorker() async {
    if (_disposed) throw StateError('标点服务已释放');
    final shutdown = _shutdownOperation;
    if (shutdown != null) await shutdown;
    final existing = _sendPort;
    if (_workerInitialized && existing != null) return existing;
    final pendingInitialization = _initializing;
    if (pendingInitialization != null) {
      await pendingInitialization;
      final ready = _sendPort;
      if (!_workerInitialized || ready == null) {
        throw StateError('标点服务未就绪');
      }
      return ready;
    }

    final generation = _lifecycleGeneration;
    late final Future<void> initialization;
    initialization = _initializeWorker(generation).whenComplete(() {
      if (identical(_initializing, initialization)) _initializing = null;
    });
    _initializing = initialization;
    await initialization;
    final ready = _sendPort;
    if (!_workerInitialized || ready == null) {
      throw StateError('标点服务未就绪');
    }
    return ready;
  }

  Future<void> _initializeWorker(int generation) async {
    if (!_canInitialize(generation)) throw StateError('标点服务已停止');
    final rawPaths = await _modelChannel
        .invokeMapMethod<Object?, Object?>('prepare', {'model': _modelId})
        .timeout(const Duration(minutes: 3));
    if (!_canInitialize(generation)) throw StateError('标点服务已停止');
    final paths = rawPaths?.map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
    final modelPath = paths?['model'];
    if (modelPath == null || modelPath.isEmpty) {
      throw StateError('标点模型路径不完整');
    }

    final receivePort = ReceivePort();
    final ready = Completer<void>();
    _modelPathForWorker = modelPath;
    _receivePort = receivePort;
    _workerReady = ready;
    _receiveSubscription = receivePort.listen(_handleWorkerMessage);
    Isolate? spawnedIsolate;
    try {
      spawnedIsolate = await Isolate.spawn(
        _workerEntry,
        receivePort.sendPort,
        debugName: 'sherpa-punctuation',
      );
      if (!_canInitialize(generation)) {
        spawnedIsolate.kill(priority: Isolate.immediate);
        spawnedIsolate = null;
        throw StateError('标点服务已停止');
      }
      _isolate = spawnedIsolate;
      await ready.future.timeout(_workerReadyTimeout);
      if (!_canInitialize(generation)) throw StateError('标点服务已停止');
      _workerInitialized = true;
    } catch (_) {
      if (!identical(_isolate, spawnedIsolate)) {
        spawnedIsolate?.kill(priority: Isolate.immediate);
      }
      await _shutdownWorker();
      rethrow;
    } finally {
      if (identical(_workerReady, ready)) _workerReady = null;
    }
  }

  bool _canInitialize(int generation) =>
      !_disposed && generation == _lifecycleGeneration;

  void _handleWorkerMessage(dynamic message) {
    if (message is SendPort) {
      _sendPort = message;
      final modelPath = _modelPathForWorker;
      if (modelPath != null) {
        message.send(<String, Object?>{'type': 'init', 'model': modelPath});
      }
      return;
    }
    if (message is! Map) return;
    final type = message['type']?.toString();
    if (type == 'ready') {
      final ready = _workerReady;
      if (ready != null && !ready.isCompleted) ready.complete();
      return;
    }
    if (type == 'disposeAck') {
      final ack = _disposeAck;
      if (ack != null && !ack.isCompleted) ack.complete();
      return;
    }
    if (type == 'error') {
      final error = StateError(message['message']?.toString() ?? '标点服务异常');
      final ready = _workerReady;
      if (ready != null && !ready.isCompleted) {
        ready.completeError(error);
      }
      final requestId = (message['id'] as num?)?.toInt();
      if (requestId != null) _completeRequestWithError(requestId, error);
      return;
    }
    if (type == 'result') {
      final requestId = (message['id'] as num?)?.toInt();
      if (requestId == null) return;
      final completer = _pending.remove(requestId);
      if (completer == null || completer.isCompleted) return;
      completer.complete(message['text']?.toString() ?? '');
    }
  }

  // Stored separately so the initial SendPort message can arrive before the
  // async initialization method has finished assigning local variables.
  String? _modelPathForWorker;

  void _completeRequestWithError(int requestId, Object error) {
    final completer = _pending.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    completer.completeError(error);
  }

  Future<void> _shutdownWorker() {
    final existing = _shutdownOperation;
    if (existing != null) return existing;
    late final Future<void> operation;
    operation = _shutdownWorkerInternal().whenComplete(() {
      if (identical(_shutdownOperation, operation)) _shutdownOperation = null;
    });
    _shutdownOperation = operation;
    return operation;
  }

  Future<void> _shutdownWorkerInternal() async {
    _workerInitialized = false;
    final sendPort = _sendPort;
    final isolate = _isolate;
    if (sendPort != null) {
      final ack = Completer<void>();
      _disposeAck = ack;
      try {
        sendPort.send(<String, Object?>{'type': 'dispose'});
        await ack.future.timeout(const Duration(seconds: 2));
      } catch (_) {
        // Killing the isolate below still releases its native resources.
      } finally {
        _disposeAck = null;
      }
    }
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('标点服务已停止'));
      }
    }
    _pending.clear();
    final ready = _workerReady;
    if (ready != null && !ready.isCompleted) {
      // Wake initialization normally; its lifecycle check reports cancellation.
      ready.complete();
    }
    await _receiveSubscription?.cancel();
    _receiveSubscription = null;
    _receivePort?.close();
    _receivePort = null;
    isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    _modelPathForWorker = null;
  }

  @override
  Future<void> releaseIdleResources() async {
    _lifecycleGeneration++;
    _workerInitialized = false;
    final initializing = _initializing;
    if (initializing != null) {
      try {
        await initializing.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    await _shutdownWorker();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _lifecycleGeneration++;
    _workerInitialized = false;
    final initializing = _initializing;
    if (initializing != null) {
      try {
        await initializing.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    await _shutdownWorker();
  }

  static void _workerEntry(SendPort mainPort) {
    final receivePort = ReceivePort();
    mainPort.send(receivePort.sendPort);
    sherpa.OfflinePunctuation? punctuation;

    receivePort.listen((dynamic message) {
      if (message is! Map) return;
      final type = message['type']?.toString();
      if (type == 'init') {
        try {
          sherpa.initBindings();
          punctuation = sherpa.OfflinePunctuation(
            config: sherpa.OfflinePunctuationConfig(
              model: sherpa.OfflinePunctuationModelConfig(
                ctTransformer: message['model']?.toString() ?? '',
                numThreads: 1,
                provider: 'cpu',
                debug: false,
              ),
            ),
          );
          mainPort.send(<String, Object?>{'type': 'ready'});
        } catch (error) {
          mainPort.send(<String, Object?>{
            'type': 'error',
            'message': '$error',
          });
        }
        return;
      }
      if (type == 'punctuate') {
        final requestId = (message['id'] as num?)?.toInt();
        if (requestId == null) return;
        try {
          final result =
              punctuation?.addPunct(message['text']?.toString() ?? '') ?? '';
          mainPort.send(<String, Object?>{
            'type': 'result',
            'id': requestId,
            'text': result,
          });
        } catch (error) {
          mainPort.send(<String, Object?>{
            'type': 'error',
            'id': requestId,
            'message': '$error',
          });
        }
        return;
      }
      if (type == 'dispose') {
        try {
          punctuation?.free();
        } catch (_) {}
        punctuation = null;
        mainPort.send(<String, Object?>{'type': 'disposeAck'});
        receivePort.close();
      }
    });
  }
}

/// Lightweight implementation used by tests and non-Android platforms.
class MemoryAiPunctuationService implements AiPunctuationService {
  final String Function(String text)? transform;
  int calls = 0;
  int releaseCalls = 0;
  int disposeCalls = 0;

  MemoryAiPunctuationService({this.transform});

  @override
  Future<String> addPunctuation(String text) async {
    calls++;
    return transform?.call(text) ?? text.trim();
  }

  @override
  Future<void> releaseIdleResources() async {
    releaseCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}
