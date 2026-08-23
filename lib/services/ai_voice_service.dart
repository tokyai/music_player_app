import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:speech_to_text/speech_to_text.dart';

import '../models/ai_assistant.dart';
import 'sherpa_audio_utils.dart';

typedef AiSpeechResultCallback = void Function(String text, bool isFinal);

abstract class AiSpeechEngine {
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  });

  Future<void> listen(AiSpeechResultCallback onResult);
  Future<void> stop();
  Future<void> cancel();
}

abstract class AiVoiceModelSelector {
  void setVoiceModel(AiVoiceModelKind model);
}

/// Optional lifecycle hook for recognizers that own native resources.
/// Lightweight test/fallback recognizers do not need to implement it.
abstract class AiSpeechResourceOwner {
  Future<void> dispose();
}

/// Releases a recognizer's heavy native model while keeping the wrapper
/// reusable for the next assistant session.
abstract class AiSpeechIdleResourceOwner {
  Future<void> releaseIdleResources();
}

/// Adapter around the platform recognizer so the permission/focus lifecycle
/// can be tested without constructing native recognition objects.
abstract class AiSpeechRecognizer {
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  });

  Future<void> listen(AiSpeechResultCallback onResult);
  Future<void> stop();
  Future<void> cancel();
}

class _SpeechToTextRecognizer implements AiSpeechRecognizer {
  final SpeechToText _speech = SpeechToText();

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) {
    return _speech.initialize(
      onError: (error) => onError(error.errorMsg),
      onStatus: onStatus,
      debugLogging: false,
    );
  }

  @override
  Future<void> listen(AiSpeechResultCallback onResult) async {
    await _speech.listen(
      onResult: (result) =>
          onResult(result.recognizedWords, result.finalResult),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenFor: const Duration(seconds: 45),
        pauseFor: const Duration(seconds: 3),
        localeId: 'zh_CN',
        listenMode: ListenMode.dictation,
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}

AiSpeechRecognizer _defaultSpeechRecognizer() {
  final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  return isAndroid ? _SherpaOnnxRecognizer() : _SpeechToTextRecognizer();
}

abstract class _AiAudioCapture {
  Stream<Uint8List> get audioStream;
  int get channelCount;
  int get mixDivisor;
  String get description;
  Future<void> stop();
  Future<void> cancel();
  Future<void> dispose();
}

class _RecordAudioCapture implements _AiAudioCapture {
  _RecordAudioCapture({
    required AudioRecorder recorder,
    required this.audioStream,
    required this.description,
    required this.channelCount,
    required this.mixDivisor,
  }) : _recorder = recorder;

  final AudioRecorder _recorder;

  @override
  final Stream<Uint8List> audioStream;

  @override
  final String description;

  @override
  final int channelCount;

  @override
  final int mixDivisor;

  @override
  Future<void> stop() => _recorder.stop();

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  Future<void> dispose() => _recorder.dispose();
}

class _CarArrayAudioCapture implements _AiAudioCapture {
  static const _controlChannel = MethodChannel(
    'music_player/ai_car_audio_control',
  );
  static const _eventChannel = EventChannel('music_player/ai_car_audio_stream');

  // Native capture sends one bounded batch at a time and waits for the ACK
  // issued below. A synchronous controller lets the ACK happen only after
  // the recognizer has consumed the bytes, keeping Flutter's platform queue
  // bounded as well.
  final StreamController<Uint8List> _controller = StreamController<Uint8List>(
    sync: true,
  );
  final Completer<void> _ready = Completer<void>();
  StreamSubscription<Object?>? _nativeSubscription;
  bool _disposed = false;

  @override
  late final int channelCount;

  @override
  late final int mixDivisor;

  @override
  late final String description;

  @override
  Stream<Uint8List> get audioStream => _controller.stream;

  static Future<_CarArrayAudioCapture?> tryStart() async {
    final profile = await _controlChannel
        .invokeMapMethod<String, Object?>('getCaptureProfile')
        .timeout(const Duration(seconds: 2));
    if (profile?['supported'] != true) return null;

    final capture = _CarArrayAudioCapture();
    try {
      await capture._start(profile!);
      return capture;
    } catch (_) {
      try {
        await capture.dispose();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _start(Map<String, Object?> profile) async {
    channelCount = (profile['channelCount'] as num?)?.toInt() ?? 4;
    mixDivisor = (profile['mixDivisor'] as num?)?.toInt() ?? 2;
    final kind = profile['kind']?.toString() == 'standardNative'
        ? 'native'
        : 'carArray';
    description =
        '$kind(source=${profile['audioSource']}, '
        'mask=${profile['channelMask']}, channels=$channelCount, '
        'deviceType=${profile['deviceType']})';
    _nativeSubscription = _eventChannel.receiveBroadcastStream().listen(
      _handleEvent,
      onError: _handleError,
      onDone: _handleDone,
      cancelOnError: false,
    );
    await _ready.future.timeout(const Duration(seconds: 5));
  }

  void _handleEvent(Object? event) {
    if (event is Map && event['event'] == 'started') {
      if (!_ready.isCompleted) _ready.complete();
      return;
    }
    if (event is Uint8List) {
      if (!_disposed) {
        try {
          _controller.add(event);
        } catch (_) {
          // A final platform event can race with StreamController.close().
        } finally {
          unawaited(_acknowledgeNativeBatch());
        }
      }
      return;
    }
    if (event is ByteData) {
      if (!_disposed) {
        try {
          _controller.add(event.buffer.asUint8List());
        } catch (_) {
          // A final platform event can race with StreamController.close().
        } finally {
          unawaited(_acknowledgeNativeBatch());
        }
      }
    }
  }

  Future<void> _acknowledgeNativeBatch() async {
    if (_disposed) return;
    try {
      await _controlChannel
          .invokeMethod<void>('ackCaptureBatch')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Capture teardown or an older host build can remove the channel while
      // the final batch is being delivered.
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    if (!_ready.isCompleted) {
      _ready.completeError(error, stackTrace);
    } else if (!_disposed) {
      try {
        _controller.addError(error, stackTrace);
      } catch (_) {
        // Ignore an error delivered after the event stream has closed.
      }
    }
  }

  void _handleDone() {
    _disposed = true;
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('车机阵列麦克风在启动前关闭'));
    }
    unawaited(_controller.close().catchError((_) {}));
  }

  Future<void> _stopNative() async {
    final subscription = _nativeSubscription;
    _nativeSubscription = null;
    await subscription?.cancel();
  }

  @override
  Future<void> stop() => _stopNative();

  @override
  Future<void> cancel() => _stopNative();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _stopNative();
    } catch (_) {}
    try {
      await _controller.close();
    } catch (_) {}
  }
}

class _SherpaOnnxRecognizer
    implements
        AiSpeechRecognizer,
        AiVoiceModelSelector,
        AiSpeechResourceOwner,
        AiSpeechIdleResourceOwner {
  static const _sampleRate = 16000;
  static const _modelChannel = MethodChannel('music_player/ai_model');
  static bool _bindingsInitialized = false;

  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _stream;
  _AiAudioCapture? _capture;
  StreamSubscription<Uint8List>? _audioSubscription;
  final Pcm16StreamDecoder _pcmDecoder = Pcm16StreamDecoder();
  void Function(String message)? _onError;
  void Function(String status)? _onStatus;
  AiSpeechResultCallback? _onResult;
  AiVoiceModelKind _voiceModel = AiVoiceModelKind.zipformerChinese;
  AiVoiceModelKind? _loadedVoiceModel;
  int _captureChannelCount = 1;
  int _captureMixDivisor = 1;
  String _lastText = '';
  bool _listening = false;
  bool _finishing = false;
  int _audioChunkCount = 0;
  int _audioSampleCount = 0;
  double _maxObservedPeak = 0;
  int _generation = 0;
  Future<void> _cleanupFuture = Future<void>.value();
  Future<bool>? _initializing;
  Future<void>? _disposeOperation;
  int _modelGeneration = 0;
  bool _disposed = false;

  @override
  void setVoiceModel(AiVoiceModelKind model) {
    if (_disposed || _voiceModel == model) return;
    _voiceModel = model;
    _modelGeneration++;
  }

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) {
    final pending = _initializing;
    if (pending != null) return pending;
    late final Future<bool> operation;
    operation = _initializeInternal(onError: onError, onStatus: onStatus)
        .whenComplete(() {
          if (identical(_initializing, operation)) _initializing = null;
        });
    _initializing = operation;
    return operation;
  }

  Future<bool> _initializeInternal({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async {
    if (_disposed) {
      _emitError(onError, 'speech_not_supported: 语音识别服务已释放');
      return false;
    }
    _onError = onError;
    _onStatus = onStatus;
    if (_recognizer != null && _loadedVoiceModel == _voiceModel) {
      _log('model already loaded: ${_voiceModel.value}');
      return true;
    }

    final requestedModel = _voiceModel;
    final requestGeneration = _modelGeneration;
    try {
      _log('preparing model: ${requestedModel.value}');
      await _cleanupFuture;
      if (!_canContinueModelInitialization(requestedModel, requestGeneration)) {
        return false;
      }
      if (_listening ||
          _finishing ||
          _stream != null ||
          _capture != null ||
          _audioSubscription != null) {
        throw StateError('语音识别进行中，暂时无法切换模型');
      }
      _freeRecognizer(_recognizer);
      _recognizer = null;
      _loadedVoiceModel = null;
      final rawPaths = await _modelChannel
          .invokeMapMethod<Object?, Object?>('prepare', {
            'model': requestedModel.value,
          })
          .timeout(const Duration(minutes: 3));
      if (!_canContinueModelInitialization(requestedModel, requestGeneration)) {
        return false;
      }
      final paths = rawPaths?.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
      final encoder = paths?['encoder'];
      final decoder = paths?['decoder'];
      final tokens = paths?['tokens'];
      if (encoder == null || decoder == null || tokens == null) {
        throw StateError('离线语音模型路径不完整');
      }
      if (!_bindingsInitialized) {
        sherpa.initBindings();
        _bindingsInitialized = true;
      }
      final model = switch (requestedModel) {
        AiVoiceModelKind.zipformerChinese => sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: encoder,
            decoder: decoder,
            joiner: paths?['joiner'] ?? (throw StateError('Zipformer 连接器路径缺失')),
          ),
          tokens: tokens,
          numThreads: 2,
          provider: 'cpu',
          debug: false,
        ),
        AiVoiceModelKind.paraformerBilingual => sherpa.OnlineModelConfig(
          paraformer: sherpa.OnlineParaformerModelConfig(
            encoder: encoder,
            decoder: decoder,
          ),
          tokens: tokens,
          numThreads: 2,
          provider: 'cpu',
          debug: false,
        ),
      };
      final nextRecognizer = sherpa.OnlineRecognizer(
        sherpa.OnlineRecognizerConfig(model: model),
      );
      if (!_canContinueModelInitialization(requestedModel, requestGeneration)) {
        _freeRecognizer(nextRecognizer);
        return false;
      }
      _recognizer = nextRecognizer;
      _loadedVoiceModel = requestedModel;
      _log('model ready: ${requestedModel.value}');
      unawaited(_logMemory('model-ready'));
      return true;
    } catch (error, stackTrace) {
      _recognizer = null;
      _loadedVoiceModel = null;
      _logError('model initialization failed', error, stackTrace);
      if (!_disposed) {
        _emitError(onError, 'speech_not_supported: 离线语音模型初始化失败：$error');
      }
      return false;
    }
  }

  bool _canContinueModelInitialization(
    AiVoiceModelKind requestedModel,
    int requestGeneration,
  ) =>
      !_disposed &&
      requestedModel == _voiceModel &&
      requestGeneration == _modelGeneration;

  @override
  Future<void> listen(AiSpeechResultCallback onResult) async {
    if (_disposed) throw StateError('离线语音识别服务已释放');
    final recognizer = _recognizer;
    if (recognizer == null) {
      throw StateError('离线语音识别器尚未初始化');
    }
    await _cleanupFuture;
    if (_disposed || _listening || _finishing) return;
    if (!identical(recognizer, _recognizer) ||
        _loadedVoiceModel != _voiceModel) {
      throw StateError('离线语音识别器正在切换模型');
    }

    final generation = ++_generation;
    _pcmDecoder.reset();
    _lastText = '';
    _audioChunkCount = 0;
    _audioSampleCount = 0;
    _maxObservedPeak = 0;
    _onResult = onResult;
    final stream = recognizer.createStream();
    _stream = stream;
    try {
      final capture = await _startCapture();
      if (generation != _generation) {
        await capture.cancel();
        await capture.dispose();
        _freeStream(stream);
        if (identical(_stream, stream)) _stream = null;
        _onResult = null;
        _pcmDecoder.reset();
        return;
      }
      _capture = capture;
      _captureChannelCount = capture.channelCount;
      _captureMixDivisor = capture.mixDivisor;
      _listening = true;
      _audioSubscription = capture.audioStream.listen(
        (bytes) => _processAudio(generation, bytes),
        onError: (Object error, StackTrace stackTrace) {
          _handleCaptureError(generation, error);
        },
        onDone: () => _handleCaptureDone(generation),
        cancelOnError: false,
      );
      _log('capture listening: generation=$generation ${capture.description}');
      _emitStatus('listening');
    } catch (error, stackTrace) {
      _logError('capture startup failed', error, stackTrace);
      try {
        await _capture?.cancel();
      } catch (_) {}
      try {
        await _capture?.dispose();
      } catch (_) {}
      _capture = null;
      _freeStream(stream);
      if (identical(_stream, stream)) _stream = null;
      _onResult = null;
      rethrow;
    }
  }

  Future<_AiAudioCapture> _startCapture() async {
    try {
      final carCapture = await _CarArrayAudioCapture.tryStart();
      if (carCapture != null) {
        _log('capture source ready: ${carCapture.description}');
        return carCapture;
      }
    } on MissingPluginException {
      _log('car-array capture channel unavailable; using standard microphone');
    } catch (error, stackTrace) {
      _logError(
        'car-array capture failed; using standard microphone',
        error,
        stackTrace,
      );
    }

    Object? firstError;
    for (final profile in const [
      (source: AndroidAudioSource.mic, channelCount: 2),
      (source: AndroidAudioSource.mic, channelCount: 1),
      (source: AndroidAudioSource.voiceRecognition, channelCount: 1),
      (source: AndroidAudioSource.defaultSource, channelCount: 1),
    ]) {
      final recorder = AudioRecorder();
      try {
        _log(
          'opening capture source: ${profile.source.name} '
          'channels=${profile.channelCount}',
        );
        final stream = await recorder.startStream(
          RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: _sampleRate,
            numChannels: profile.channelCount,
            // PlatformAiAudioFocusCoordinator is the single focus owner.
            // record's default focus request would preempt it and cancel us.
            audioInterruption: AudioInterruptionMode.none,
            // Let AudioRecord choose a hardware-safe buffer for Flyme stereo.
            streamBufferSize: profile.channelCount == 1 ? 3200 : null,
            androidConfig: AndroidRecordConfig(
              audioSource: profile.source,
              manageBluetooth: true,
            ),
          ),
        );
        final description =
            'standard(source=${profile.source.name}, '
            'channels=${profile.channelCount})';
        _log('capture source ready: $description');
        return _RecordAudioCapture(
          recorder: recorder,
          audioStream: stream,
          description: description,
          channelCount: profile.channelCount,
          mixDivisor: profile.channelCount,
        );
      } catch (error, stackTrace) {
        _logError(
          'capture source failed: ${profile.source.name} '
          'channels=${profile.channelCount}',
          error,
          stackTrace,
        );
        firstError ??= error;
        try {
          await recorder.dispose();
        } catch (_) {}
      }
    }
    throw StateError('无法打开车机麦克风：$firstError');
  }

  void _processAudio(int generation, Uint8List bytes) {
    if (_disposed || generation != _generation || !_listening || _finishing) {
      return;
    }
    final recognizer = _recognizer;
    final stream = _stream;
    if (recognizer == null || stream == null) return;
    try {
      final samples = _pcmDecoder.decode(
        bytes,
        channelCount: _captureChannelCount,
        mixDivisor: _captureMixDivisor,
      );
      if (samples.isEmpty) return;
      _audioChunkCount++;
      _audioSampleCount += samples.length;
      var chunkPeak = 0.0;
      for (final sample in samples) {
        final magnitude = sample.abs();
        if (magnitude > chunkPeak) chunkPeak = magnitude;
      }
      if (chunkPeak > _maxObservedPeak) _maxObservedPeak = chunkPeak;
      if (_audioChunkCount == 1 || _audioChunkCount % 50 == 0) {
        _log(
          'audio: chunks=$_audioChunkCount samples=$_audioSampleCount '
          'peak=${chunkPeak.toStringAsFixed(4)} '
          'maxPeak=${_maxObservedPeak.toStringAsFixed(4)}',
        );
      }
      stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
      var decoded = false;
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
        decoded = true;
      }
      // getResult() allocates and parses a native JSON result. Calling it for
      // every audio packet is unnecessary when the recognizer did not decode
      // a frame, and creates avoidable Dart/native heap churn on car hardware.
      if (!decoded && !recognizer.isEndpoint(stream)) return;
      final text = recognizer.getResult(stream).text.trim();
      if (text.isNotEmpty && text != _lastText) {
        _lastText = text;
        _log('partial result: chars=${text.length}');
        _emitResult(text, false);
      }
      if (recognizer.isEndpoint(stream)) {
        _log('endpoint: resultChars=${text.length}');
        if (text.isNotEmpty) _emitResult(text, true);
        unawaited(_finishCapture(emitStatus: true));
      }
    } catch (error, stackTrace) {
      _logError('audio processing failed', error, stackTrace);
      _handleCaptureError(generation, error);
    }
  }

  void _handleCaptureDone(int generation) {
    if (generation != _generation || _finishing) return;
    _log('capture stream closed by platform: generation=$generation');
    unawaited(_finishCapture(finalizeInput: true, emitStatus: true));
  }

  void _handleCaptureError(int generation, Object error) {
    if (generation != _generation || _finishing) return;
    _log('capture error: generation=$generation error=$error');
    _emitError(null, 'error_audio: 麦克风音频流异常：$error');
    unawaited(_finishCapture());
  }

  @override
  Future<void> stop() => _finishCapture(finalizeInput: true, emitStatus: true);

  @override
  Future<void> cancel() => _finishCapture();

  Future<void> _finishCapture({
    bool finalizeInput = false,
    bool emitStatus = false,
  }) async {
    if (_finishing) {
      await _cleanupFuture;
      return;
    }
    if (!_listening &&
        _audioSubscription == null &&
        _capture == null &&
        _stream == null) {
      return;
    }
    _finishing = true;
    _listening = false;
    _generation++;
    final subscription = _audioSubscription;
    final capture = _capture;
    final stream = _stream;
    final recognizer = _recognizer;
    _audioSubscription = null;
    _capture = null;
    _stream = null;

    final cleanup = () async {
      try {
        try {
          await subscription?.cancel();
        } catch (error, stackTrace) {
          _logError('audio subscription cancel failed', error, stackTrace);
        }
        try {
          await capture?.stop();
        } catch (error, stackTrace) {
          _logError('audio capture stop failed', error, stackTrace);
        }
        if (finalizeInput && stream != null && recognizer != null) {
          try {
            stream.inputFinished();
            while (recognizer.isReady(stream)) {
              recognizer.decode(stream);
            }
            final text = recognizer.getResult(stream).text.trim();
            _log('final result: chars=${text.length}');
            if (text.isNotEmpty) _emitResult(text, true);
          } catch (error, stackTrace) {
            // Native recognizers may be torn down concurrently with the last
            // audio callback. Finalization is best-effort and must not leak an
            // unhandled error from an unawaited cleanup future.
            _logError('final audio decode failed', error, stackTrace);
          }
        }
      } finally {
        try {
          await capture?.dispose();
        } catch (_) {}
        _freeStream(stream);
        _pcmDecoder.reset();
        _onResult = null;
        _lastText = '';
        _finishing = false;
        _log(
          'capture finished: chunks=$_audioChunkCount '
          'samples=$_audioSampleCount '
          'maxPeak=${_maxObservedPeak.toStringAsFixed(4)}',
        );
        unawaited(_logMemory('capture-finished'));
        if (emitStatus) {
          _emitStatus('done');
        }
      }
    }();
    _cleanupFuture = cleanup;
    await cleanup;
  }

  @override
  Future<void> dispose() {
    final pending = _disposeOperation;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _disposeInternal().whenComplete(() {
      if (identical(_disposeOperation, operation)) _disposeOperation = null;
    });
    _disposeOperation = operation;
    return operation;
  }

  @override
  Future<void> releaseIdleResources() async {
    if (_disposed) return;
    // Invalidate an asset-copy/recognizer build that may still be finishing
    // before releasing the currently loaded native model.
    _modelGeneration++;
    final initializing = _initializing;
    if (initializing != null) {
      try {
        await initializing.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    await _finishCapture();
    _freeRecognizer(_recognizer);
    _recognizer = null;
    _loadedVoiceModel = null;
    _onResult = null;
  }

  Future<void> _disposeInternal() async {
    if (_disposed) return;
    _disposed = true;
    _modelGeneration++;
    _generation++;
    // Do not let an in-flight asset copy/recognizer construction finish and
    // publish a native pointer after disposal. It has explicit disposed
    // checks as well, while this bounded wait keeps normal teardown ordered.
    final initializing = _initializing;
    if (initializing != null) {
      try {
        await initializing.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    await _finishCapture();
    _freeRecognizer(_recognizer);
    _recognizer = null;
    _loadedVoiceModel = null;
    _onResult = null;
    _onError = null;
    _onStatus = null;
  }

  void _log(String message) => debugPrint('[AiVoice] $message');

  Future<void> _logMemory(String stage) async {
    try {
      final snapshot = await _modelChannel
          .invokeMapMethod<Object?, Object?>('memory')
          .timeout(const Duration(seconds: 2));
      if (snapshot == null) return;
      _log(
        'memory[$stage]: pss=${snapshot['totalPssKb']}KB '
        'native=${snapshot['nativeHeapKb']}KB '
        'java=${snapshot['javaHeapKb']}KB '
        'avail=${snapshot['availMemKb']}KB '
        'low=${snapshot['lowMemory']} '
        'limit=${snapshot['memoryClassMb']}MB/'
        '${snapshot['largeMemoryClassMb']}MB',
      );
    } catch (_) {
      // Older host builds do not expose diagnostics; recognition still works.
    }
  }

  void _freeStream(sherpa.OnlineStream? stream) {
    if (stream == null) return;
    try {
      stream.free();
    } catch (error, stackTrace) {
      _logError('recognition stream release failed', error, stackTrace);
    }
  }

  void _freeRecognizer(sherpa.OnlineRecognizer? recognizer) {
    if (recognizer == null) return;
    try {
      recognizer.free();
    } catch (error, stackTrace) {
      _logError('recognizer release failed', error, stackTrace);
    }
  }

  void _logError(String context, Object error, StackTrace stackTrace) {
    _log('$context: $error');
    debugPrintStack(label: '[AiVoice] $context', stackTrace: stackTrace);
  }

  void _emitResult(String text, bool isFinal) {
    final callback = _onResult;
    if (callback == null) return;
    try {
      callback(text, isFinal);
    } catch (error, stackTrace) {
      _logError('recognition result callback failed', error, stackTrace);
    }
  }

  void _emitError(void Function(String message)? callback, String message) {
    final target = callback ?? _onError;
    if (target == null) return;
    try {
      target(message);
    } catch (error, stackTrace) {
      _logError('recognition error callback failed', error, stackTrace);
    }
  }

  void _emitStatus(String status) {
    final callback = _onStatus;
    if (callback == null) return;
    try {
      callback(status);
    } catch (error, stackTrace) {
      _logError('recognition status callback failed', error, stackTrace);
    }
  }
}

abstract class AiMicrophonePermission {
  Future<bool> ensureGranted();
}

class PlatformAiMicrophonePermission implements AiMicrophonePermission {
  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> ensureGranted() async {
    if (!_isAndroid) return true;
    try {
      final current = await Permission.microphone.status;
      if (current.isGranted) return true;
      final requested = await Permission.microphone.request();
      return requested.isGranted;
    } on MissingPluginException {
      // Keep speech_to_text's own permission path on hosts without the
      // optional permission_handler implementation.
      return true;
    } catch (_) {
      return false;
    }
  }
}

abstract class AiAudioFocusCoordinator {
  void setOnFocusLost(void Function()? callback);
  Future<bool> request();
  Future<void> abandon();
}

class PlatformAiAudioFocusCoordinator implements AiAudioFocusCoordinator {
  static const _channel = MethodChannel('music_player/ai_audio');

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool _supported = true;
  bool _held = false;
  bool _handlerInstalled = false;
  void Function()? _onFocusLost;

  @override
  void setOnFocusLost(void Function()? callback) {
    _onFocusLost = callback;
  }

  void _installHandler() {
    if (!_isAndroid || _handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'focusChanged') {
        final change = call.arguments is num
            ? (call.arguments as num).toInt()
            : null;
        if (change == -1 || change == -2) {
          _held = false;
          final callback = _onFocusLost;
          if (callback != null) {
            try {
              callback();
            } catch (error, stackTrace) {
              debugPrint('AI 音频焦点回调失败: $error');
              debugPrintStack(stackTrace: stackTrace);
            }
          }
        }
      }
      return null;
    });
  }

  @override
  Future<bool> request() async {
    if (!_isAndroid || !_supported || _held) return true;
    _installHandler();
    try {
      final granted = await _channel
          .invokeMethod<bool>('requestFocus')
          .timeout(const Duration(seconds: 2));
      _held = granted == true;
      return granted == true;
    } on MissingPluginException {
      // Older host builds do not have this optional channel. The recognizer
      // can still use the platform's normal audio routing in that case.
      _supported = false;
      return true;
    } on PlatformException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<void> abandon() async {
    if (!_isAndroid || !_held) return;
    _held = false;
    if (!_supported) return;
    try {
      await _channel
          .invokeMethod<void>('abandonFocus')
          .timeout(const Duration(seconds: 2));
    } on MissingPluginException {
      _supported = false;
    } catch (_) {
      // Releasing focus must never mask a recognizer stop/cancel failure.
    }
  }
}

abstract class AiTextToSpeechEngine {
  Future<void> initialize();
  Future<void> speak(String text);
  Future<void> stop();
}

class PlatformAiSpeechEngine
    implements
        AiSpeechEngine,
        AiVoiceModelSelector,
        AiSpeechResourceOwner,
        AiSpeechIdleResourceOwner {
  final AiSpeechRecognizer _speech;
  final AiMicrophonePermission _microphonePermission;
  final AiAudioFocusCoordinator _audioFocus;
  bool _initialized = false;
  bool _focusHeld = false;
  bool _disposed = false;
  Future<void> _focusReleaseFuture = Future<void>.value();
  Future<bool>? _initializeOperation;
  Future<void>? _disposeOperation;

  PlatformAiSpeechEngine({
    AiSpeechRecognizer? speech,
    AiMicrophonePermission? microphonePermission,
    AiAudioFocusCoordinator? audioFocus,
  }) : _speech = speech ?? _defaultSpeechRecognizer(),
       _microphonePermission =
           microphonePermission ?? PlatformAiMicrophonePermission(),
       _audioFocus = audioFocus ?? PlatformAiAudioFocusCoordinator();

  @override
  void setVoiceModel(AiVoiceModelKind model) {
    if (_disposed) return;
    final speech = _speech;
    if (speech is AiVoiceModelSelector) {
      (speech as AiVoiceModelSelector).setVoiceModel(model);
    }
  }

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) {
    if (_disposed) return Future<bool>.value(false);
    final pending = _initializeOperation;
    if (pending != null) return pending;
    late final Future<bool> operation;
    operation = _initializeInternal(onError: onError, onStatus: onStatus)
        .whenComplete(() {
          if (identical(_initializeOperation, operation)) {
            _initializeOperation = null;
          }
        });
    _initializeOperation = operation;
    return operation;
  }

  Future<bool> _initializeInternal({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async {
    if (_disposed) return false;
    try {
      _audioFocus.setOnFocusLost(() {
        unawaited(_handleFocusLost(onError));
      });
    } catch (error, stackTrace) {
      debugPrint('AI 音频焦点回调安装失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    if (!await _microphonePermission.ensureGranted()) {
      if (!_disposed) _safeError(onError, '麦克风权限未授予');
      return false;
    }
    if (_disposed) return false;
    final ready = await _speech.initialize(
      onError: (message) {
        if (_disposed) return;
        unawaited(_releaseFocus());
        _safeError(onError, message);
      },
      onStatus: (status) {
        if (_disposed) return;
        if (status == 'done' || status == 'notListening') {
          unawaited(_releaseFocus());
        }
        _safeStatus(onStatus, status);
      },
    );
    if (_disposed) return false;
    _initialized = ready;
    return ready;
  }

  @override
  Future<void> listen(AiSpeechResultCallback onResult) async {
    if (_disposed) throw StateError('语音识别服务已释放');
    if (!_initialized) {
      throw StateError('语音识别服务尚未初始化');
    }
    // A recognizer status callback may release focus asynchronously just as
    // the controller schedules its next listening segment.
    await _focusReleaseFuture;
    if (_disposed) throw StateError('语音识别服务已释放');
    final granted = await _audioFocus.request();
    if (_disposed) {
      if (granted) await _audioFocus.abandon();
      throw StateError('语音识别服务已释放');
    }
    if (!granted) {
      throw StateError('error_audio_focus: 无法获取语音输入音频焦点');
    }
    _focusHeld = true;
    try {
      await _speech.listen(onResult);
    } catch (_) {
      await _releaseFocus();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _speech.stop();
    } finally {
      await _releaseFocus();
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _speech.cancel();
    } finally {
      await _releaseFocus();
    }
  }

  @override
  Future<void> releaseIdleResources() async {
    if (_disposed) return;
    try {
      await _speech.cancel();
    } catch (_) {}
    await _releaseFocus();
    final speech = _speech;
    final owner = speech is AiSpeechIdleResourceOwner
        ? speech as AiSpeechIdleResourceOwner
        : null;
    if (owner != null) {
      try {
        await owner.releaseIdleResources();
      } catch (_) {}
    }
    _initialized = false;
  }

  Future<void> _releaseFocus() async {
    if (!_focusHeld) return;
    _focusHeld = false;
    final release = () async {
      try {
        await _audioFocus.abandon();
      } catch (_) {}
    }();
    _focusReleaseFuture = release;
    await release;
  }

  Future<void> _handleFocusLost(void Function(String message) onError) async {
    try {
      await _speech.cancel();
    } catch (_) {}
    await _releaseFocus();
    if (!_disposed) {
      _safeError(onError, 'error_audio_focus_lost: 车机语音焦点已被其他应用占用');
    }
  }

  void _safeError(void Function(String message) callback, String message) {
    try {
      callback(message);
    } catch (error, stackTrace) {
      debugPrint('AI 语音错误回调失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _safeStatus(void Function(String status) callback, String status) {
    try {
      callback(status);
    } catch (error, stackTrace) {
      debugPrint('AI 语音状态回调失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  Future<void> dispose() {
    final pending = _disposeOperation;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _disposeInternal().whenComplete(() {
      if (identical(_disposeOperation, operation)) _disposeOperation = null;
    });
    _disposeOperation = operation;
    return operation;
  }

  Future<void> _disposeInternal() async {
    if (_disposed) return;
    _disposed = true;
    final initializing = _initializeOperation;
    try {
      await _speech.cancel();
    } catch (_) {}
    await _releaseFocus();
    if (initializing != null) {
      try {
        await initializing.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    final speech = _speech;
    final resourceOwner = speech is AiSpeechResourceOwner
        ? speech as AiSpeechResourceOwner
        : null;
    if (resourceOwner != null) {
      try {
        await resourceOwner.dispose();
      } catch (_) {}
    }
  }
}

class PlatformAiTextToSpeechEngine implements AiTextToSpeechEngine {
  static const _channel = MethodChannel('music_player/ai_tts');

  @override
  Future<void> initialize() async {
    final ready = await _channel
        .invokeMethod<bool>('initialize')
        .timeout(const Duration(seconds: 8));
    if (ready != true) {
      throw StateError('系统文字转语音服务不可用');
    }
  }

  @override
  Future<void> speak(String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    await _channel.invokeMethod<bool>('speak', {'text': normalized});
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}

class MemoryAiSpeechEngine implements AiSpeechEngine {
  bool initialized = false;
  bool listening = false;
  AiSpeechResultCallback? callback;
  void Function(String)? error;

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async {
    error = onError;
    initialized = true;
    return true;
  }

  @override
  Future<void> listen(AiSpeechResultCallback onResult) async {
    listening = true;
    callback = onResult;
  }

  void emit(String text, {bool isFinal = true}) =>
      callback?.call(text, isFinal);

  @override
  Future<void> stop() async => listening = false;

  @override
  Future<void> cancel() async => listening = false;
}

class MemoryAiTextToSpeechEngine implements AiTextToSpeechEngine {
  final List<String> spoken = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async {}
}
