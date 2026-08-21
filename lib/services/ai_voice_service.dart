import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

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

/// Adapter around speech_to_text so the permission/focus lifecycle can be
/// tested without constructing the platform recognizer in widget tests.
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

class PlatformAiSpeechEngine implements AiSpeechEngine {
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
  }) : _speech = speech ?? _SpeechToTextRecognizer(),
       _microphonePermission =
           microphonePermission ?? PlatformAiMicrophonePermission(),
       _audioFocus = audioFocus ?? PlatformAiAudioFocusCoordinator();

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
