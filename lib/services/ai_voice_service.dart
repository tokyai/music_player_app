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

  final StreamController<Uint8List> _controller = StreamController<Uint8List>();
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
      await capture.dispose();
      rethrow;
    }
  }

  Future<void> _start(Map<String, Object?> profile) async {
    channelCount = (profile['channelCount'] as num?)?.toInt() ?? 4;
    mixDivisor = (profile['mixDivisor'] as num?)?.toInt() ?? 2;
    description =
        'carArray(source=${profile['audioSource']}, '
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
      if (!_disposed) _controller.add(event);
      return;
    }
    if (event is ByteData) {
      if (!_disposed) _controller.add(event.buffer.asUint8List());
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    if (!_ready.isCompleted) {
      _ready.completeError(error, stackTrace);
    } else if (!_disposed) {
      _controller.addError(error, stackTrace);
    }
  }

  void _handleDone() {
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('车机阵列麦克风在启动前关闭'));
    }
    if (!_disposed) unawaited(_controller.close());
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
    await _stopNative();
    await _controller.close();
  }
}

class _SherpaOnnxRecognizer
    implements AiSpeechRecognizer, AiVoiceModelSelector {
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

  @override
  void setVoiceModel(AiVoiceModelKind model) {
    _voiceModel = model;
  }

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async {
    _onError = onError;
    _onStatus = onStatus;
    if (_recognizer != null && _loadedVoiceModel == _voiceModel) {
      _log('model already loaded: ${_voiceModel.value}');
      return true;
    }

    try {
      _log('preparing model: ${_voiceModel.value}');
      await _cleanupFuture;
      if (_listening || _finishing) {
        throw StateError('语音识别进行中，暂时无法切换模型');
      }
      _recognizer?.free();
      _recognizer = null;
      _loadedVoiceModel = null;
      final rawPaths = await _modelChannel
          .invokeMapMethod<Object?, Object?>('prepare', {
            'model': _voiceModel.value,
          })
          .timeout(const Duration(minutes: 3));
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
      final model = switch (_voiceModel) {
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
      _recognizer = sherpa.OnlineRecognizer(
        sherpa.OnlineRecognizerConfig(model: model),
      );
      _loadedVoiceModel = _voiceModel;
      _log('model ready: ${_voiceModel.value}');
      return true;
    } catch (error, stackTrace) {
      _logError('model initialization failed', error, stackTrace);
      onError('speech_not_supported: 离线语音模型初始化失败：$error');
      return false;
    }
  }

  @override
  Future<void> listen(AiSpeechResultCallback onResult) async {
    final recognizer = _recognizer;
    if (recognizer == null) {
      throw StateError('离线语音识别器尚未初始化');
    }
    await _cleanupFuture;
    if (_listening || _finishing) return;

    final generation = ++_generation;
    _pcmDecoder.reset();
    _lastText = '';
    _audioChunkCount = 0;
    _audioSampleCount = 0;
    _maxObservedPeak = 0;
    _onResult = onResult;
    _stream = recognizer.createStream();
    try {
      final capture = await _startCapture();
      if (generation != _generation) {
        await capture.cancel();
        await capture.dispose();
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
      _onStatus?.call('listening');
    } catch (error, stackTrace) {
      _logError('capture startup failed', error, stackTrace);
      _stream?.free();
      _stream = null;
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
    if (generation != _generation || !_listening || _finishing) return;
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
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }
      final text = recognizer.getResult(stream).text.trim();
      if (text.isNotEmpty && text != _lastText) {
        _lastText = text;
        _log('partial result: chars=${text.length}');
        _onResult?.call(text, false);
      }
      if (recognizer.isEndpoint(stream)) {
        _log('endpoint: resultChars=${text.length}');
        if (text.isNotEmpty) _onResult?.call(text, true);
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
    _onError?.call('error_audio: 麦克风音频流异常：$error');
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
        await subscription?.cancel();
        try {
          await capture?.stop();
        } catch (_) {}
        if (finalizeInput && stream != null && recognizer != null) {
          stream.inputFinished();
          while (recognizer.isReady(stream)) {
            recognizer.decode(stream);
          }
          final text = recognizer.getResult(stream).text.trim();
          _log('final result: chars=${text.length}');
          if (text.isNotEmpty) _onResult?.call(text, true);
        }
      } finally {
        try {
          await capture?.dispose();
        } catch (_) {}
        stream?.free();
        _pcmDecoder.reset();
        _onResult = null;
        _lastText = '';
        _finishing = false;
        _log(
          'capture finished: chunks=$_audioChunkCount '
          'samples=$_audioSampleCount '
          'maxPeak=${_maxObservedPeak.toStringAsFixed(4)}',
        );
        if (emitStatus) _onStatus?.call('done');
      }
    }();
    _cleanupFuture = cleanup;
    await cleanup;
  }

  void _log(String message) => debugPrint('[AiVoice] $message');

  void _logError(String context, Object error, StackTrace stackTrace) {
    _log('$context: $error');
    debugPrintStack(label: '[AiVoice] $context', stackTrace: stackTrace);
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
          _onFocusLost?.call();
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

class PlatformAiSpeechEngine implements AiSpeechEngine, AiVoiceModelSelector {
  final AiSpeechRecognizer _speech;
  final AiMicrophonePermission _microphonePermission;
  final AiAudioFocusCoordinator _audioFocus;
  bool _initialized = false;
  bool _focusHeld = false;
  Future<void> _focusReleaseFuture = Future<void>.value();

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
    final speech = _speech;
    if (speech is AiVoiceModelSelector) {
      (speech as AiVoiceModelSelector).setVoiceModel(model);
    }
  }

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async {
    _audioFocus.setOnFocusLost(() {
      unawaited(_handleFocusLost(onError));
    });
    if (!await _microphonePermission.ensureGranted()) {
      onError('麦克风权限未授予');
      return false;
    }
    final ready = await _speech.initialize(
      onError: (message) {
        unawaited(_releaseFocus());
        onError(message);
      },
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          unawaited(_releaseFocus());
        }
        onStatus(status);
      },
    );
    _initialized = ready;
    return ready;
  }

  @override
  Future<void> listen(AiSpeechResultCallback onResult) async {
    if (!_initialized) {
      throw StateError('语音识别服务尚未初始化');
    }
    // A recognizer status callback may release focus asynchronously just as
    // the controller schedules its next listening segment.
    await _focusReleaseFuture;
    final granted = await _audioFocus.request();
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
    onError('error_audio_focus_lost: 车机语音焦点已被其他应用占用');
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
