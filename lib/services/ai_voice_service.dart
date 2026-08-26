import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:speech_to_text/speech_to_text.dart';

import '../models/ai_assistant.dart';
import 'ai_barge_in.dart';
import 'doubao_ime_asr_client.dart';
import 'sherpa_audio_utils.dart';

typedef AiSpeechResultCallback = void Function(String text, bool isFinal);

const _aiSpeechSampleRate = 16000;

abstract class AiSpeechEngine {
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  });

  Future<void> listen(AiSpeechResultCallback onResult);
  Future<void> stop();
  Future<void> cancel();
}

/// Optional full-duplex control used while TTS is speaking. Implementations
/// must run only lightweight voice detection and must not start a second full
/// recognizer until [onVoiceDetected] asks the controller to stop TTS.
abstract class AiSpeechBargeInSupport {
  bool get supportsBargeIn;
  Future<bool> startBargeInMonitor({
    required Future<void> Function() onVoiceDetected,
  });

  /// Stops the lightweight monitor. Only the automatic-detection path may
  /// preserve its bounded PCM for the immediately following
  /// [AiSpeechEngine.listen]. Normal completion, manual interruption and
  /// teardown must leave [preserveForNextListen] false so assistant audio is
  /// never replayed into the recognizer.
  Future<void> stopBargeInMonitor({bool preserveForNextListen = false});
}

/// A recognizer that can accept the mono PCM retained by the barge-in monitor.
abstract class AiSpeechPrerollRecognizer {
  void setNextPreroll(Uint8List pcm16Mono);
}

abstract class AiVoiceModelSelector {
  void setVoiceModel(AiVoiceModelKind model);
}

/// Optional control surface for keeping the bundled offline recognizer warm.
/// Preloading never requests microphone permission or audio focus.
abstract class AiSpeechModelWarmup {
  void setRetainIdleModel(bool retain);
  Future<bool> preloadModel(AiVoiceModelKind model);
  Future<void> releasePreloadedModel();
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
  return isAndroid ? AiSpeechRecognizerRouter() : _SpeechToTextRecognizer();
}

typedef AiSpeechRecognizerFactory = AiSpeechRecognizer Function();

/// Keeps the persisted engine choice independent from the AI provider/model.
class AiSpeechRecognizerRouter
    implements
        AiSpeechRecognizer,
        AiVoiceModelSelector,
        AiSpeechResourceOwner,
        AiSpeechIdleResourceOwner,
        AiSpeechPrerollRecognizer {
  final AiSpeechRecognizerFactory _zipformerFactory;
  final AiSpeechRecognizerFactory _systemFactory;
  final AiSpeechRecognizerFactory _doubaoFactory;

  AiVoiceModelKind _selectedModel = AiVoiceModelKind.zipformerChinese;
  AiVoiceModelKind? _activeModel;
  AiSpeechRecognizer? _active;
  Future<bool>? _initializing;
  AiVoiceModelKind? _initializingModel;
  void Function(String message)? _onError;
  void Function(String status)? _onStatus;
  Future<void>? _disposeOperation;
  bool _disposed = false;

  AiSpeechRecognizerRouter({
    AiSpeechRecognizerFactory? zipformerFactory,
    AiSpeechRecognizerFactory? systemFactory,
    AiSpeechRecognizerFactory? doubaoFactory,
  }) : _zipformerFactory = zipformerFactory ?? _SherpaOnnxRecognizer.new,
       _systemFactory = systemFactory ?? _SpeechToTextRecognizer.new,
       _doubaoFactory = doubaoFactory ?? DoubaoImeSpeechRecognizer.new;

  @override
  void setVoiceModel(AiVoiceModelKind model) {
    if (_disposed) return;
    _selectedModel = model;
  }

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) {
    if (_disposed) return Future<bool>.value(false);
    _onError = onError;
    _onStatus = onStatus;
    final pending = _initializing;
    if (pending != null) {
      if (_initializingModel == _selectedModel) return pending;
      return pending.then((_) {
        if (_disposed) return false;
        return initialize(onError: onError, onStatus: onStatus);
      });
    }
    final requestedModel = _selectedModel;
    late final Future<bool> operation;
    operation = _initializeInternal(onError: onError, onStatus: onStatus)
        .whenComplete(() {
          if (identical(_initializing, operation)) {
            _initializing = null;
            _initializingModel = null;
          }
        });
    _initializingModel = requestedModel;
    _initializing = operation;
    return operation;
  }

  Future<bool> _initializeInternal({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async {
    final requestedModel = _selectedModel;
    if (_activeModel != requestedModel || _active == null) {
      await _disposeActive();
      if (_disposed || requestedModel != _selectedModel) return false;
      _active = switch (requestedModel) {
        AiVoiceModelKind.zipformerChinese => _zipformerFactory(),
        AiVoiceModelKind.systemSpeech => _systemFactory(),
        AiVoiceModelKind.doubaoIme => _doubaoFactory(),
      };
      _activeModel = requestedModel;
    }
    final active = _active!;
    final ready = await active.initialize(
      onError: (message) {
        if (!_disposed && requestedModel == _selectedModel) {
          _onError?.call(message);
        }
      },
      onStatus: (status) {
        if (!_disposed && requestedModel == _selectedModel) {
          _onStatus?.call(status);
        }
      },
    );
    if (_disposed ||
        requestedModel != _selectedModel ||
        !identical(active, _active)) {
      if (identical(active, _active)) await _disposeActive();
      return false;
    }
    return ready;
  }

  @override
  Future<void> listen(AiSpeechResultCallback onResult) async {
    if (_disposed) throw StateError('语音识别路由已释放');
    final active = _active;
    if (active == null || _activeModel != _selectedModel) {
      throw StateError('语音输入引擎尚未初始化');
    }
    await active.listen(onResult);
  }

  @override
  Future<void> stop() async {
    await _active?.stop();
  }

  @override
  Future<void> cancel() async {
    await _active?.cancel();
  }

  @override
  void setNextPreroll(Uint8List pcm16Mono) {
    final active = _active;
    if (active is AiSpeechPrerollRecognizer) {
      (active as AiSpeechPrerollRecognizer).setNextPreroll(pcm16Mono);
    }
  }

  @override
  Future<void> releaseIdleResources() async {
    if (_disposed) return;
    final active = _active;
    try {
      await active?.cancel();
    } catch (_) {}
    final idleOwner = active is AiSpeechIdleResourceOwner
        ? active as AiSpeechIdleResourceOwner
        : null;
    if (idleOwner != null) {
      try {
        await idleOwner.releaseIdleResources();
      } catch (_) {}
    }
  }

  Future<void> _disposeActive() async {
    final active = _active;
    _active = null;
    _activeModel = null;
    if (active == null) return;
    try {
      await active.cancel();
    } catch (_) {}
    final resourceOwner = active is AiSpeechResourceOwner
        ? active as AiSpeechResourceOwner
        : null;
    if (resourceOwner != null) {
      try {
        await resourceOwner.dispose();
      } catch (_) {}
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
    final initializing = _initializing;
    if (initializing != null) {
      try {
        await initializing.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    await _disposeActive();
    _onError = null;
    _onStatus = null;
  }
}

abstract class AiAudioCapture {
  Stream<Uint8List> get audioStream;
  int get channelCount;
  int get mixDivisor;
  String get description;
  Future<void> stop();
  Future<void> cancel();
  Future<void> dispose();
}

class _RecordAudioCapture implements AiAudioCapture {
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

class _CarArrayAudioCapture implements AiAudioCapture {
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

Future<AiAudioCapture> _startAiAudioCapture({
  required void Function(String message) log,
  required void Function(String context, Object error, StackTrace stackTrace)
  logError,
}) async {
  try {
    final carCapture = await _CarArrayAudioCapture.tryStart();
    if (carCapture != null) {
      log('capture source ready: ${carCapture.description}');
      return carCapture;
    }
  } on MissingPluginException {
    log('car-array capture channel unavailable; using standard microphone');
  } catch (error, stackTrace) {
    logError(
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
      log(
        'opening capture source: ${profile.source.name} '
        'channels=${profile.channelCount}',
      );
      final stream = await recorder
          .startStream(
            RecordConfig(
              encoder: AudioEncoder.pcm16bits,
              sampleRate: _aiSpeechSampleRate,
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
          )
          .timeout(const Duration(seconds: 5));
      final description =
          'standard(source=${profile.source.name}, '
          'channels=${profile.channelCount})';
      log('capture source ready: $description');
      return _RecordAudioCapture(
        recorder: recorder,
        audioStream: stream,
        description: description,
        channelCount: profile.channelCount,
        mixDivisor: profile.channelCount,
      );
    } catch (error, stackTrace) {
      logError(
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

/// Barge-in capture intentionally uses the communication source instead of
/// the car-array stream. Android can attach its hardware AEC/NS path to this
/// source while TTS is playing; falling back to voice-recognition keeps the
/// feature usable on older head units without opening a second car-array
/// session that would be prone to speaker echo.
Future<AiAudioCapture> _startBargeInAudioCapture() async {
  Object? firstError;
  for (final source in const [
    AndroidAudioSource.voiceCommunication,
    AndroidAudioSource.voiceRecognition,
    AndroidAudioSource.mic,
  ]) {
    final recorder = AudioRecorder();
    try {
      final stream = await recorder
          .startStream(
            RecordConfig(
              encoder: AudioEncoder.pcm16bits,
              sampleRate: _aiSpeechSampleRate,
              numChannels: 1,
              echoCancel: true,
              noiseSuppress: true,
              audioInterruption: AudioInterruptionMode.none,
              streamBufferSize: 3200,
              androidConfig: AndroidRecordConfig(
                audioSource: source,
                speakerphone: false,
                audioManagerMode: AudioManagerMode.modeInCommunication,
                manageBluetooth: true,
              ),
            ),
          )
          .timeout(const Duration(seconds: 5));
      return _RecordAudioCapture(
        recorder: recorder,
        audioStream: stream,
        description: 'barge-in(source=${source.name}, aec=preferred)',
        channelCount: 1,
        mixDivisor: 1,
      );
    } catch (error, stackTrace) {
      firstError ??= error;
      debugPrint('[AiBargeIn] source ${source.name} failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      try {
        await recorder.dispose();
      } catch (_) {}
    }
  }
  throw StateError('无法打开自动打断麦克风：$firstError');
}

/// Monitors the microphone only while TTS is active. It converts to mono once,
/// keeps a bounded preroll, and uses a lightweight energy gate instead of a
/// second ASR model/WebSocket. The capture is handed off by stopping it before
/// the selected recognizer opens its normal session.
class AiBargeInMonitor {
  AiBargeInMonitor({
    AiAudioCaptureStarter? captureStarter,
    AiBargeInVoiceGate? gate,
  }) : _captureStarter = captureStarter,
       _gate = gate ?? AiBargeInVoiceGate();

  final AiAudioCaptureStarter? _captureStarter;
  final AiBargeInVoiceGate _gate;
  final Pcm16MonoStreamConverter _converter = Pcm16MonoStreamConverter();
  final Pcm16StreamDecoder _decoder = Pcm16StreamDecoder();
  final AiPcmRingBuffer _preroll = AiPcmRingBuffer();
  AiAudioCapture? _capture;
  StreamSubscription<Uint8List>? _subscription;
  Future<void> _lifecycleTail = Future<void>.value();
  Future<void> Function()? _onVoiceDetected;
  bool _triggering = false;
  bool _disposed = false;
  int _generation = 0;

  bool get active => _capture != null || _subscription != null;

  Future<bool> start(Future<void> Function() onVoiceDetected) {
    final generation = ++_generation;
    return _enqueue(() => _startInternal(generation, onVoiceDetected));
  }

  Future<bool> _startInternal(
    int generation,
    Future<void> Function() onVoiceDetected,
  ) async {
    await _stopCurrent();
    if (_disposed || generation != _generation) return false;
    _converter.reset();
    _decoder.reset();
    _preroll.clear();
    _gate.reset();
    _triggering = false;
    AiAudioCapture? capture;
    late final Future<AiAudioCapture> pendingCapture;
    try {
      pendingCapture = Future<AiAudioCapture>.sync(
        () => _captureStarter?.call() ?? _startBargeInAudioCapture(),
      );
      try {
        capture = await pendingCapture.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // Future cancellation is not available for every recorder/plugin.
        // Keep the late result attached and release it as soon as it arrives,
        // while allowing TTS and the assistant state machine to continue.
        unawaited(
          pendingCapture.then<void>(
            _releaseCapture,
            onError: (Object _, StackTrace __) {},
          ),
        );
        return false;
      }
      if (_disposed || generation != _generation) {
        await _releaseCapture(capture);
        return false;
      }
      _capture = capture;
      _onVoiceDetected = onVoiceDetected;
      final channelCount = capture.channelCount;
      final mixDivisor = capture.mixDivisor;
      _subscription = capture.audioStream.listen(
        (bytes) => _process(bytes, channelCount, mixDivisor),
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('[AiBargeIn] capture failed: $error');
          debugPrintStack(stackTrace: stackTrace);
          unawaited(stop());
        },
        onDone: () => unawaited(stop()),
        cancelOnError: false,
      );
      return true;
    } catch (error, stackTrace) {
      debugPrint('[AiBargeIn] unavailable: $error');
      debugPrintStack(stackTrace: stackTrace);
      await _releaseCapture(capture);
      return false;
    }
  }

  void _process(Uint8List bytes, int channelCount, int mixDivisor) {
    if (_disposed || !active) return;
    try {
      final mono = _converter.convert(
        bytes,
        channelCount: channelCount,
        mixDivisor: mixDivisor,
      );
      if (mono.isEmpty) return;
      _preroll.add(mono);
      final samples = _decoder.decode(mono);
      final detected = _gate.accept(samples);
      if (!detected || _triggering) return;
      _triggering = true;
      final callback = _onVoiceDetected;
      if (callback != null) {
        unawaited(
          callback().catchError((Object error, StackTrace stackTrace) {
            debugPrint('[AiBargeIn] detection callback failed: $error');
            debugPrintStack(stackTrace: stackTrace);
          }),
        );
      }
    } catch (error, stackTrace) {
      debugPrint('[AiBargeIn] PCM detection failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      unawaited(stop());
    }
  }

  Future<Uint8List> stop() {
    _generation++;
    return _enqueue(_stopCurrent);
  }

  Future<Uint8List> _stopCurrent() async {
    final subscription = _subscription;
    final capture = _capture;
    _subscription = null;
    _capture = null;
    _onVoiceDetected = null;
    try {
      await subscription?.cancel().timeout(const Duration(seconds: 2));
    } catch (_) {}
    // StreamSubscription.cancel waits for an in-flight synchronous callback,
    // so snapshot after cancellation to retain the last user packet that
    // arrived just before automatic detection.
    final preroll = _preroll.snapshot();
    try {
      await capture?.cancel().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await capture?.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _converter.reset();
    _decoder.reset();
    _preroll.clear();
    _gate.reset();
    _triggering = false;
    return preroll;
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final previous = _lifecycleTail;
    final operation = previous.catchError((_) {}).then((_) => action());
    _lifecycleTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> _releaseCapture(AiAudioCapture? capture) async {
    if (capture == null) return;
    try {
      await capture.cancel().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await capture.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
  }
}

class _SherpaOnnxRecognizer
    implements
        AiSpeechRecognizer,
        AiVoiceModelSelector,
        AiSpeechResourceOwner,
        AiSpeechIdleResourceOwner,
        AiSpeechPrerollRecognizer {
  static const _sampleRate = _aiSpeechSampleRate;
  static const _modelChannel = MethodChannel('music_player/ai_model');
  static const _homophoneModelId = 'homophone-replacer-zh';
  static bool _bindingsInitialized = false;

  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _stream;
  AiAudioCapture? _capture;
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
  Uint8List _nextPreroll = Uint8List(0);

  @override
  void setNextPreroll(Uint8List pcm16Mono) {
    if (_disposed) return;
    _nextPreroll = pcm16Mono.length <= 32 * 1024
        ? Uint8List.fromList(pcm16Mono)
        : Uint8List.fromList(pcm16Mono.sublist(pcm16Mono.length - 32 * 1024));
  }

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
      final modelPath = paths?['model'];
      final tokens = paths?['tokens'];
      if (modelPath == null || tokens == null) {
        throw StateError('离线语音模型路径不完整');
      }
      if (!_bindingsInitialized) {
        sherpa.initBindings();
        _bindingsInitialized = true;
      }
      final model = sherpa.OnlineModelConfig(
        zipformer2Ctc: sherpa.OnlineZipformer2CtcModelConfig(model: modelPath),
        tokens: tokens,
        numThreads: 2,
        provider: 'cpu',
        debug: false,
      );
      final homophoneConfig = await _prepareHomophoneConfig();
      if (!_canContinueModelInitialization(requestedModel, requestGeneration)) {
        return false;
      }
      late final sherpa.OnlineRecognizer nextRecognizer;
      try {
        nextRecognizer = sherpa.OnlineRecognizer(
          sherpa.OnlineRecognizerConfig(model: model, hr: homophoneConfig),
        );
      } catch (error, stackTrace) {
        if (homophoneConfig.lexicon.isEmpty) rethrow;
        _logError(
          'homophone initialization failed; using original recognizer',
          error,
          stackTrace,
        );
        nextRecognizer = sherpa.OnlineRecognizer(
          sherpa.OnlineRecognizerConfig(model: model),
        );
      }
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

  Future<sherpa.HomophoneReplacerConfig> _prepareHomophoneConfig() async {
    try {
      final rawPaths = await _modelChannel
          .invokeMapMethod<Object?, Object?>('prepare', {
            'model': _homophoneModelId,
          })
          .timeout(const Duration(seconds: 30));
      return aiHomophoneConfigFromPaths(
        rawPaths?.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        ),
      );
    } catch (error, stackTrace) {
      _logError('homophone resources unavailable', error, stackTrace);
      return const sherpa.HomophoneReplacerConfig();
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
      final capture = await _startAiAudioCapture(
        log: _log,
        logError: _logError,
      );
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
      final preroll = _nextPreroll;
      _nextPreroll = Uint8List(0);
      if (preroll.isNotEmpty) {
        _processAudio(generation, preroll);
      }
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
      _nextPreroll = Uint8List(0);
      rethrow;
    }
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
    _nextPreroll = Uint8List(0);
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

typedef AiAudioCaptureStarter = Future<AiAudioCapture> Function();

class DoubaoImeSpeechRecognizer
    implements
        AiSpeechRecognizer,
        AiSpeechResourceOwner,
        AiSpeechIdleResourceOwner,
        AiSpeechPrerollRecognizer {
  static const _frameDurationMilliseconds = 20;
  static const _frameBytes =
      _aiSpeechSampleRate * _frameDurationMilliseconds ~/ 1000 * 2;
  static const _maxAudioFrames = 60 * 1000 ~/ _frameDurationMilliseconds;
  static const _sessionFinishTimeout = Duration(seconds: 8);

  final DoubaoImeAsrGateway _client;
  final AiAudioCaptureStarter? _captureStarter;
  final Pcm16MonoStreamConverter _pcmConverter = Pcm16MonoStreamConverter();
  final Pcm16FrameBuffer _frameBuffer = Pcm16FrameBuffer(
    frameBytes: _frameBytes,
  );

  AiAudioCapture? _capture;
  StreamSubscription<Uint8List>? _audioSubscription;
  DoubaoImeAsrConnection? _session;
  Future<void>? _responseTask;
  Future<void> _cleanupFuture = Future<void>.value();
  Future<bool>? _initializing;
  Future<void>? _disposeOperation;
  Future<void>? _finishInputOperation;
  void Function(String message)? _onError;
  void Function(String status)? _onStatus;
  AiSpeechResultCallback? _onResult;
  int _captureChannelCount = 1;
  int _captureMixDivisor = 1;
  int _frameIndex = 0;
  int _startedAtMilliseconds = 0;
  int _generation = 0;
  bool _listening = false;
  bool _listenStarting = false;
  bool _finishing = false;
  bool _finishRequested = false;
  bool _sessionRetryUsed = false;
  bool _terminalFrameSent = false;
  bool _finalResultEmitted = false;
  String _latestSpeechText = '';
  String _pendingFinalText = '';
  Completer<void>? _sessionCompletion;
  bool _disposed = false;
  Uint8List _nextPreroll = Uint8List(0);

  @override
  void setNextPreroll(Uint8List pcm16Mono) {
    if (_disposed) return;
    _nextPreroll = pcm16Mono.length <= 32 * 1024
        ? Uint8List.fromList(pcm16Mono)
        : Uint8List.fromList(pcm16Mono.sublist(pcm16Mono.length - 32 * 1024));
  }

  DoubaoImeSpeechRecognizer({
    DoubaoImeAsrGateway? client,
    AiAudioCaptureStarter? captureStarter,
  }) : _client = client ?? DoubaoImeAsrClient(),
       _captureStarter = captureStarter;

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
      _emitError(onError, 'speech_not_supported: 豆包语音服务已释放');
      return false;
    }
    _onError = onError;
    _onStatus = onStatus;
    try {
      await _client.prepare().timeout(const Duration(seconds: 30));
      return !_disposed;
    } catch (error, stackTrace) {
      _logError('initialization failed', error, stackTrace);
      if (!_disposed) {
        _emitError(onError, 'speech_not_supported: 豆包语音初始化失败：$error');
      }
      return false;
    }
  }

  @override
  Future<void> listen(AiSpeechResultCallback onResult) async {
    if (_disposed) throw StateError('豆包语音服务已释放');
    if (_listenStarting) return;
    _listenStarting = true;
    try {
      await _listenInternal(onResult);
    } finally {
      _listenStarting = false;
    }
  }

  Future<void> _listenInternal(AiSpeechResultCallback onResult) async {
    if (_disposed) throw StateError('豆包语音服务已释放');
    final generation = ++_generation;
    // The assistant schedules its next listening segment as soon as it
    // receives a final result. That result can arrive before the provider has
    // sent SessionFinished, so wait for the in-flight finish handshake before
    // opening a new socket. Otherwise a new session could overwrite the old
    // session's completion future and make cleanup race with recognition.
    while (!_disposed) {
      final pendingFinish = _finishInputOperation;
      if (pendingFinish != null) {
        try {
          await pendingFinish;
        } catch (_) {
          // Finish is best-effort; the operation itself performs bounded
          // cleanup and the next session may still be attempted.
        }
        continue;
      }
      final cleanup = _cleanupFuture;
      await cleanup;
      if (_finishing || !identical(cleanup, _cleanupFuture)) continue;
      break;
    }
    if (_disposed) throw StateError('豆包语音服务已释放');
    if (!_isCurrent(generation) || _listening || _finishing) return;

    _resetAudioState();
    _sessionRetryUsed = false;
    _finishRequested = false;
    _terminalFrameSent = false;
    _finalResultEmitted = false;
    _latestSpeechText = '';
    _pendingFinalText = '';
    _onResult = onResult;
    DoubaoImeAsrConnection? session;
    AiAudioCapture? capture;
    try {
      session = await _client.openSession();
      if (!_isCurrent(generation)) {
        await _closeSession(session);
        return;
      }
      capture =
          await (_captureStarter?.call() ??
              _startAiAudioCapture(log: _log, logError: _logError));
      if (!_isCurrent(generation)) {
        await capture.cancel();
        await capture.dispose();
        await _closeSession(session);
        return;
      }
      _session = session;
      _capture = capture;
      _captureChannelCount = capture.channelCount;
      _captureMixDivisor = capture.mixDivisor;
      _sessionCompletion = Completer<void>();
      _listening = true;
      _responseTask = _readResponses(generation);
      _audioSubscription = capture.audioStream.listen(
        (bytes) => _processAudio(generation, bytes),
        onError: (Object error, StackTrace stackTrace) =>
            _handleCaptureError(generation, error),
        onDone: () => _handleCaptureDone(generation),
        cancelOnError: false,
      );
      final preroll = _nextPreroll;
      _nextPreroll = Uint8List(0);
      if (preroll.isNotEmpty) {
        _frameBuffer.add(preroll, _sendAudioFrame);
      }
      _log('capture listening: generation=$generation ${capture.description}');
      _emitStatus('listening');
    } catch (error, stackTrace) {
      _logError('capture startup failed', error, stackTrace);
      try {
        await capture?.cancel();
      } catch (_) {}
      try {
        await capture?.dispose();
      } catch (_) {}
      try {
        if (session != null) await _closeSession(session);
      } catch (_) {}
      if (_isCurrent(generation)) {
        _onResult = null;
        _nextPreroll = Uint8List(0);
        _resetAudioState();
      }
      rethrow;
    }
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _processAudio(int generation, Uint8List bytes) {
    if (!_isCurrent(generation) || !_listening || _finishing) {
      return;
    }
    try {
      final mono = _pcmConverter.convert(
        bytes,
        channelCount: _captureChannelCount,
        mixDivisor: _captureMixDivisor,
      );
      _frameBuffer.add(mono, _sendAudioFrame);
    } catch (error, stackTrace) {
      _logError('audio processing failed', error, stackTrace);
      _handleCaptureError(generation, error);
    }
  }

  void _sendAudioFrame(Uint8List frame) {
    final session = _session;
    if (session == null) return;
    if (_frameIndex >= _maxAudioFrames) {
      throw StateError('豆包语音单次聆听超过 60 秒');
    }
    session.sendAudio(
      frame,
      frameState: _frameIndex == 0
          ? DoubaoImeAudioFrameState.first
          : DoubaoImeAudioFrameState.middle,
      timestampMilliseconds:
          _startedAtMilliseconds + _frameIndex * _frameDurationMilliseconds,
    );
    _frameIndex++;
    if (_frameIndex == 1 || _frameIndex % 250 == 0) {
      _log('audio sent: frames=$_frameIndex');
    }
  }

  Future<void> _readResponses(int generation) async {
    try {
      while (_isCurrent(generation) &&
          _session != null &&
          (_listening || _finishRequested)) {
        final session = _session;
        if (session == null) return;
        final response = await session.nextResponse();
        if (!_isCurrent(generation) ||
            (!_listening && !_finishRequested) ||
            !identical(session, _session)) {
          return;
        }
        if (response == null) {
          if (_finishRequested) {
            _emitFinalResultIfNeeded();
            _completeSessionCompletion();
          } else {
            await _finishCapture(fromResponseLoop: true, emitStatus: true);
          }
          return;
        }
        switch (response.kind) {
          case DoubaoImeAsrResponseKind.interim:
            final text = response.text.trim();
            if (text.isNotEmpty) {
              _latestSpeechText = text;
              _emitResult(text, false);
            }
            break;
          case DoubaoImeAsrResponseKind.finalResult:
            final text = response.text.trim();
            if (text.isNotEmpty) _pendingFinalText = text;
            // The provider can emit its two/three-pass final result as soon
            // as VAD detects a pause, while the platform microphone stream
            // remains open. Stop feeding audio and ask the provider to finish
            // the session, but keep the response loop alive so a later
            // SessionFinished (and any last correction) is still consumed.
            // Calling this unawaited is intentional: awaiting it here would
            // deadlock waiting for the same response loop to receive
            // SessionFinished.
            if (!_finishRequested && !_finishing) {
              unawaited(_finishInput());
            }
            break;
          case DoubaoImeAsrResponseKind.sessionFinished:
            _emitFinalResultIfNeeded();
            if (_finishRequested) {
              _completeSessionCompletion();
            } else {
              await _finishCapture(fromResponseLoop: true, emitStatus: true);
            }
            return;
          case DoubaoImeAsrResponseKind.error:
            _log(
              'provider failure: type=${response.messageType.isEmpty ? 'unknown' : response.messageType} '
              'status=${response.statusCode} '
              'message=${response.statusMessage.isEmpty ? response.error : response.statusMessage}',
            );
            if (!_sessionRetryUsed &&
                isDoubaoImeCredentialRoutingError(
                  response.error,
                  statusCode: response.statusCode,
                )) {
              _sessionRetryUsed = true;
              if (await _replaceRejectedSession(generation, session)) {
                continue;
              }
              if (!_isCurrent(generation) || _finishing) return;
            }
            final status = response.statusCode == 0
                ? ''
                : ' [${response.messageType.isEmpty ? 'provider' : response.messageType} '
                      'status=${response.statusCode}]';
            _emitError(
              null,
              'error_network: 豆包语音识别失败：${response.error}$status',
            );
            if (_finishRequested) {
              _emitFinalResultIfNeeded();
              _completeSessionCompletion();
            } else {
              await _finishCapture(fromResponseLoop: true);
            }
            return;
          case DoubaoImeAsrResponseKind.taskStarted:
          case DoubaoImeAsrResponseKind.sessionStarted:
          case DoubaoImeAsrResponseKind.vadStarted:
          case DoubaoImeAsrResponseKind.heartbeat:
          case DoubaoImeAsrResponseKind.unknown:
            break;
        }
      }
    } catch (error, stackTrace) {
      if (!_isCurrent(generation)) return;
      if (_finishRequested) {
        _logError('response stream failed while finishing', error, stackTrace);
        _emitFinalResultIfNeeded();
        _completeSessionCompletion();
        return;
      }
      if (_finishing) return;
      _logError('response stream failed', error, stackTrace);
      _emitError(null, 'error_network: 豆包语音连接异常：$error');
      await _finishCapture(fromResponseLoop: true);
    }
  }

  Future<bool> _replaceRejectedSession(
    int generation,
    DoubaoImeAsrConnection rejected,
  ) async {
    if (!_isCurrent(generation) ||
        !_listening ||
        _finishRequested ||
        !identical(rejected, _session)) {
      return false;
    }
    _session = null;
    try {
      await _closeSession(rejected);
      if (!_isCurrent(generation) ||
          !_listening ||
          _finishRequested ||
          _finishing) {
        return false;
      }
      try {
        await _client.refreshToken();
      } catch (error, stackTrace) {
        // A transient settings-endpoint failure should not prevent a new
        // provider session from recovering with the current credential.
        _logError(
          'credential refresh during recovery failed',
          error,
          stackTrace,
        );
      }
      if (!_isCurrent(generation) ||
          !_listening ||
          _finishRequested ||
          _finishing) {
        return false;
      }
      final replacement = await _client.openSession();
      if (!_isCurrent(generation) ||
          !_listening ||
          _finishRequested ||
          _finishing) {
        await _closeSession(replacement);
        return false;
      }
      _session = replacement;
      _resetAudioState();
      _log('reconnected after provider rejection');
      return true;
    } catch (error, stackTrace) {
      _logError('session recovery failed', error, stackTrace);
      return false;
    }
  }

  void _handleCaptureDone(int generation) {
    if (!_isCurrent(generation) || _finishing) return;
    unawaited(_finishInput());
  }

  void _handleCaptureError(int generation, Object error) {
    if (!_isCurrent(generation) || _finishing) return;
    _emitError(null, 'error_audio: 麦克风音频流异常：$error');
    unawaited(_finishCapture());
  }

  @override
  Future<void> stop() {
    _invalidatePendingListen();
    return _finishInput();
  }

  @override
  Future<void> cancel() {
    _invalidatePendingListen();
    return _finishCapture();
  }

  void _invalidatePendingListen() {
    if (_listenStarting &&
        !_listening &&
        _audioSubscription == null &&
        _capture == null &&
        _session == null) {
      _generation++;
    }
  }

  Future<void> _finishInput() {
    final pending = _finishInputOperation;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _finishInputInternal().whenComplete(() {
      if (identical(_finishInputOperation, operation)) {
        _finishInputOperation = null;
      }
    });
    _finishInputOperation = operation;
    return operation;
  }

  Future<void> _finishInputInternal() async {
    if (_disposed) return;
    _invalidatePendingListen();
    if (_finishing) {
      await _cleanupFuture;
      return;
    }
    final session = _session;
    if (!_listening &&
        _audioSubscription == null &&
        _capture == null &&
        session == null) {
      return;
    }
    _finishRequested = true;
    _listening = false;
    final subscription = _audioSubscription;
    final capture = _capture;
    _audioSubscription = null;
    _capture = null;
    try {
      await subscription?.cancel().timeout(const Duration(seconds: 2));
    } catch (error, stackTrace) {
      _logError('audio subscription cancel failed', error, stackTrace);
    }
    try {
      await capture?.stop().timeout(const Duration(seconds: 2));
    } catch (error, stackTrace) {
      _logError('audio capture stop failed', error, stackTrace);
    }
    try {
      await capture?.dispose().timeout(const Duration(seconds: 2));
    } catch (error, stackTrace) {
      _logError('audio capture dispose failed', error, stackTrace);
    }
    if (session == null) {
      await _finishCapture(emitStatus: true, fromFinishInput: true);
      return;
    }
    if (!_terminalFrameSent) {
      try {
        _sendTerminalFrame(session);
        session.finish();
        _terminalFrameSent = true;
      } catch (error, stackTrace) {
        _logError('final audio send failed', error, stackTrace);
      }
    }
    try {
      await (_sessionCompletion ??= Completer<void>()).future.timeout(
        _sessionFinishTimeout,
      );
    } catch (_) {
      // A dead provider must not hold the microphone/session indefinitely.
      _emitFinalResultIfNeeded();
    }
    await _finishCapture(emitStatus: true, fromFinishInput: true);
  }

  Future<void> _finishCapture({
    bool finalizeInput = false,
    bool emitStatus = false,
    bool fromResponseLoop = false,
    bool fromFinishInput = false,
  }) async {
    _invalidatePendingListen();
    if (!fromFinishInput) {
      final pendingInput = _finishInputOperation;
      if (pendingInput != null) {
        if (!fromResponseLoop) {
          try {
            await pendingInput.timeout(_sessionFinishTimeout);
          } catch (_) {}
        }
        return;
      }
    }
    if (_finishing) {
      if (!fromResponseLoop) await _cleanupFuture;
      return;
    }
    if (!_listening &&
        _audioSubscription == null &&
        _capture == null &&
        _session == null &&
        !(fromFinishInput && _finishRequested)) {
      return;
    }
    _finishing = true;
    _listening = false;
    _finishRequested = false;
    _generation++;
    final subscription = _audioSubscription;
    final capture = _capture;
    final session = _session;
    final responseTask = _responseTask;
    _audioSubscription = null;
    _capture = null;
    _session = null;
    _responseTask = null;

    final cleanup = () async {
      try {
        try {
          await subscription?.cancel();
        } catch (error, stackTrace) {
          _logError('audio subscription cancel failed', error, stackTrace);
        }
        try {
          if (finalizeInput) {
            await capture?.stop();
          } else {
            await capture?.cancel();
          }
        } catch (error, stackTrace) {
          _logError('audio capture stop failed', error, stackTrace);
        }
        if (finalizeInput && session != null && !_terminalFrameSent) {
          try {
            _sendTerminalFrame(session);
            session.finish();
          } catch (error, stackTrace) {
            _logError('final audio send failed', error, stackTrace);
          }
        }
        try {
          if (session != null) await _closeSession(session);
        } catch (_) {}
        // _finishInput may be initiated by _readResponses after an endpoint
        // final. Waiting on that same response future would wait on itself.
        if (!fromResponseLoop && !fromFinishInput && responseTask != null) {
          try {
            await responseTask.timeout(const Duration(seconds: 2));
          } catch (_) {}
        }
      } finally {
        try {
          await capture?.dispose();
        } catch (_) {}
        _onResult = null;
        _resetAudioState();
        _terminalFrameSent = false;
        _finalResultEmitted = false;
        _latestSpeechText = '';
        _pendingFinalText = '';
        _sessionRetryUsed = false;
        _sessionCompletion = null;
        _finishing = false;
        if (emitStatus) _emitStatus('done');
      }
    }();
    _cleanupFuture = cleanup;
    await cleanup;
  }

  void _completeSessionCompletion() {
    final completion = _sessionCompletion;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  void _emitFinalResultIfNeeded() {
    if (_finalResultEmitted) return;
    final text = _pendingFinalText.isNotEmpty
        ? _pendingFinalText
        : _latestSpeechText;
    if (text.isEmpty) return;
    _finalResultEmitted = true;
    _emitResult(text, true);
  }

  Future<void> _closeSession(DoubaoImeAsrConnection session) async {
    try {
      await session.close().timeout(const Duration(seconds: 2));
    } catch (error, stackTrace) {
      _logError('session close failed', error, stackTrace);
    }
  }

  void _sendTerminalFrame(DoubaoImeAsrConnection session) {
    final pending = _frameBuffer.takePaddedFrame();
    if (pending.isEmpty && _frameIndex == 0) return;
    session.sendAudio(
      pending.isEmpty ? Uint8List(_frameBytes) : pending,
      frameState: DoubaoImeAudioFrameState.last,
      timestampMilliseconds:
          _startedAtMilliseconds + _frameIndex * _frameDurationMilliseconds,
    );
    _frameIndex++;
  }

  void _resetAudioState() {
    _pcmConverter.reset();
    _frameBuffer.reset();
    _frameIndex = 0;
    _startedAtMilliseconds = DateTime.now().millisecondsSinceEpoch;
  }

  @override
  Future<void> releaseIdleResources() async {
    if (_disposed) return;
    await _finishCapture();
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
    _generation++;
    await _finishCapture();
    final initializing = _initializing;
    if (initializing != null) {
      try {
        await initializing.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    try {
      await _client.dispose();
    } catch (_) {}
    _onResult = null;
    _nextPreroll = Uint8List(0);
    _onError = null;
    _onStatus = null;
  }

  void _emitResult(String text, bool isFinal) {
    final callback = _onResult;
    if (callback == null || _disposed) return;
    try {
      callback(text, isFinal);
    } catch (error, stackTrace) {
      _logError('result callback failed', error, stackTrace);
    }
  }

  void _emitError(void Function(String message)? callback, String message) {
    final target = callback ?? _onError;
    if (target == null || _disposed) return;
    try {
      target(message);
    } catch (error, stackTrace) {
      _logError('error callback failed', error, stackTrace);
    }
  }

  void _emitStatus(String status) {
    final callback = _onStatus;
    if (callback == null || _disposed) return;
    try {
      callback(status);
    } catch (error, stackTrace) {
      _logError('status callback failed', error, stackTrace);
    }
  }

  void _log(String message) => debugPrint('[DoubaoImeAsr] $message');

  void _logError(String context, Object error, StackTrace stackTrace) {
    _log('$context: $error');
    debugPrintStack(label: '[DoubaoImeAsr] $context', stackTrace: stackTrace);
  }
}

@visibleForTesting
sherpa.HomophoneReplacerConfig aiHomophoneConfigFromPaths(
  Map<String, String>? paths,
) {
  final lexicon = paths?['lexicon']?.trim() ?? '';
  final rules = paths?['rules']?.trim() ?? '';
  if (lexicon.isEmpty || rules.isEmpty) {
    return const sherpa.HomophoneReplacerConfig();
  }
  return sherpa.HomophoneReplacerConfig(lexicon: lexicon, ruleFsts: rules);
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
        AiSpeechModelWarmup,
        AiSpeechResourceOwner,
        AiSpeechIdleResourceOwner,
        AiSpeechBargeInSupport {
  final AiSpeechRecognizer _speech;
  final AiMicrophonePermission _microphonePermission;
  final AiAudioFocusCoordinator _audioFocus;
  late final AiBargeInMonitor _bargeInMonitor;
  bool _initialized = false;
  bool _focusHeld = false;
  bool _retainIdleModel = false;
  AiVoiceModelKind _voiceModel = AiVoiceModelKind.zipformerChinese;
  bool _disposed = false;
  Future<void> _focusReleaseFuture = Future<void>.value();
  Future<bool>? _initializeOperation;
  Future<void>? _disposeOperation;
  Uint8List _pendingBargeInPreroll = Uint8List(0);

  PlatformAiSpeechEngine({
    AiSpeechRecognizer? speech,
    AiMicrophonePermission? microphonePermission,
    AiAudioFocusCoordinator? audioFocus,
    AiBargeInMonitor? bargeInMonitor,
  }) : _speech = speech ?? _defaultSpeechRecognizer(),
       _microphonePermission =
           microphonePermission ?? PlatformAiMicrophonePermission(),
       _audioFocus = audioFocus ?? PlatformAiAudioFocusCoordinator() {
    _bargeInMonitor =
        bargeInMonitor ??
        AiBargeInMonitor(captureStarter: _startBargeInAudioCapture);
  }

  @override
  bool get supportsBargeIn =>
      !_disposed &&
      (_voiceModel == AiVoiceModelKind.zipformerChinese ||
          _voiceModel == AiVoiceModelKind.doubaoIme);

  @override
  void setVoiceModel(AiVoiceModelKind model) {
    if (_disposed) return;
    _voiceModel = model;
    _initialized = false;
    final speech = _speech;
    if (speech is AiVoiceModelSelector) {
      (speech as AiVoiceModelSelector).setVoiceModel(model);
    }
  }

  @override
  void setRetainIdleModel(bool retain) {
    if (_disposed) return;
    _retainIdleModel = retain;
  }

  @override
  Future<bool> preloadModel(AiVoiceModelKind model) async {
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    if (_disposed || !isAndroid || model != AiVoiceModelKind.zipformerChinese) {
      return false;
    }
    setVoiceModel(model);
    try {
      return await _speech.initialize(
        onError: (message) => debugPrint('[AiVoice] preload failed: $message'),
        onStatus: (_) {},
      );
    } catch (error, stackTrace) {
      debugPrint('[AiVoice] preload failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  @override
  Future<void> releasePreloadedModel() async {
    if (_disposed) return;
    try {
      await _speech.cancel();
    } catch (error, stackTrace) {
      debugPrint('[AiVoice] cancel before preload release failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    await _releaseFocus();
    final speech = _speech;
    final owner = speech is AiSpeechIdleResourceOwner
        ? speech as AiSpeechIdleResourceOwner
        : null;
    if (owner != null) {
      try {
        await owner.releaseIdleResources();
      } catch (error, stackTrace) {
        debugPrint('[AiVoice] preload release failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
    _initialized = false;
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
    // A normal/manual listen must never inherit the tail of the assistant's
    // own TTS. Automatic detection explicitly stages a bounded handoff below.
    await _bargeInMonitor.stop();
    final preroll = _pendingBargeInPreroll;
    _pendingBargeInPreroll = Uint8List(0);
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
    final speech = _speech;
    final prerollRecognizer = speech is AiSpeechPrerollRecognizer
        ? speech as AiSpeechPrerollRecognizer
        : null;
    prerollRecognizer?.setNextPreroll(preroll);
    try {
      await _speech.listen(onResult);
    } catch (_) {
      prerollRecognizer?.setNextPreroll(Uint8List(0));
      await _releaseFocus();
      rethrow;
    }
  }

  @override
  Future<bool> startBargeInMonitor({
    required Future<void> Function() onVoiceDetected,
  }) async {
    if (!supportsBargeIn || !_initialized) return false;
    if (!await _microphonePermission.ensureGranted()) return false;
    _pendingBargeInPreroll = Uint8List(0);
    return _bargeInMonitor.start(onVoiceDetected);
  }

  @override
  Future<void> stopBargeInMonitor({bool preserveForNextListen = false}) async {
    final preroll = await _bargeInMonitor.stop();
    if (preserveForNextListen && supportsBargeIn && !_disposed) {
      _pendingBargeInPreroll = preroll;
    } else {
      _pendingBargeInPreroll = Uint8List(0);
    }
  }

  @override
  Future<void> stop() async {
    _pendingBargeInPreroll = Uint8List(0);
    await _bargeInMonitor.stop();
    try {
      await _speech.stop();
    } finally {
      await _releaseFocus();
    }
  }

  @override
  Future<void> cancel() async {
    _pendingBargeInPreroll = Uint8List(0);
    await _bargeInMonitor.stop();
    try {
      await _speech.cancel();
    } finally {
      await _releaseFocus();
    }
  }

  @override
  Future<void> releaseIdleResources() async {
    if (_disposed) return;
    _pendingBargeInPreroll = Uint8List(0);
    await _bargeInMonitor.stop();
    try {
      await _speech.cancel();
    } catch (_) {}
    await _releaseFocus();
    final speech = _speech;
    final owner = speech is AiSpeechIdleResourceOwner
        ? speech as AiSpeechIdleResourceOwner
        : null;
    final keepOfflineModel =
        _retainIdleModel && _voiceModel == AiVoiceModelKind.zipformerChinese;
    if (owner != null && !keepOfflineModel) {
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
    _pendingBargeInPreroll = Uint8List(0);
    await _bargeInMonitor.dispose();
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
