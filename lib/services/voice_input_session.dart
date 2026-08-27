import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/ai_assistant.dart';
import 'ai_voice_service.dart';

/// A bounded, reusable voice capture session over the app-wide speech engine.
///
/// The session owns callbacks and capture state, but not the shared engine or
/// its recognizer. Closing it always releases recording resources and lets the
/// engine's configured idle policy decide whether Zipformer remains loaded.
class VoiceInputSession {
  final AiSpeechEngine _speech;
  final AiVoiceModelKind _voiceModel;

  Future<bool>? _startOperation;
  Future<void>? _closeOperation;
  int _generation = 0;
  bool _listening = false;
  bool _closed = false;

  VoiceInputSession({
    required AiSpeechEngine speech,
    required AiVoiceModelKind voiceModel,
  }) : _speech = speech,
       _voiceModel = voiceModel;

  bool get isListening => _listening;
  bool get isClosed => _closed;

  Future<bool> start({
    required AiSpeechResultCallback onResult,
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) {
    if (_closed) return Future<bool>.value(false);
    if (_listening) return Future<bool>.value(true);
    final pending = _startOperation;
    if (pending != null) return pending;

    late final Future<bool> operation;
    operation =
        _startInternal(
          onResult: onResult,
          onError: onError,
          onStatus: onStatus,
        ).whenComplete(() {
          if (identical(_startOperation, operation)) _startOperation = null;
        });
    _startOperation = operation;
    return operation;
  }

  Future<bool> _startInternal({
    required AiSpeechResultCallback onResult,
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async {
    final generation = ++_generation;
    try {
      final selector = _speech;
      if (selector is AiVoiceModelSelector) {
        (selector as AiVoiceModelSelector).setVoiceModel(_voiceModel);
      }
      final ready = await _speech.initialize(
        onError: (message) {
          if (_isCurrent(generation)) _safeError(onError, message);
        },
        onStatus: (status) {
          if (!_isCurrent(generation)) return;
          if (status == 'done' || status == 'notListening') {
            _listening = false;
          }
          _safeStatus(onStatus, status);
        },
      );
      if (!_isCurrent(generation)) {
        await _cancelSpeech();
        return false;
      }
      if (!ready) return false;

      _listening = true;
      await _speech.listen((text, isFinal) {
        if (_isCurrent(generation)) {
          _safeResult(onResult, text, isFinal);
        }
      });
      if (!_isCurrent(generation)) {
        await _cancelSpeech();
        return false;
      }
      return true;
    } catch (error, stackTrace) {
      _listening = false;
      if (_isCurrent(generation)) {
        _safeError(onError, _messageFor(error));
      }
      debugPrint('启动语音输入失败: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<void> stop() async {
    if (_closed || !_listening) return;
    final generation = _generation;
    try {
      // Keep callbacks current while stop() flushes the recognizer's final
      // text, then invalidate any late native events after it returns.
      await _speech.stop();
    } catch (error, stackTrace) {
      debugPrint('停止语音输入失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (_generation == generation) _generation++;
      _listening = false;
    }
  }

  Future<void> cancel() async {
    if (_closed) return;
    _generation++;
    _listening = false;
    await _cancelSpeech();
  }

  Future<void> close() {
    final pending = _closeOperation;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _closeInternal().whenComplete(() {
      if (identical(_closeOperation, operation)) _closeOperation = null;
    });
    _closeOperation = operation;
    return operation;
  }

  Future<void> _closeInternal() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    _listening = false;
    await _cancelSpeech();

    final starting = _startOperation;
    if (starting != null) {
      try {
        await starting.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    final owner = _speech;
    if (owner is AiSpeechIdleResourceOwner) {
      try {
        await (owner as AiSpeechIdleResourceOwner).releaseIdleResources();
      } catch (error, stackTrace) {
        debugPrint('释放语音输入资源失败: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  bool _isCurrent(int generation) => !_closed && generation == _generation;

  Future<void> _cancelSpeech() async {
    try {
      await _speech.cancel();
    } catch (error, stackTrace) {
      debugPrint('取消语音输入失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _safeResult(AiSpeechResultCallback callback, String text, bool isFinal) {
    try {
      callback(text, isFinal);
    } catch (error, stackTrace) {
      debugPrint('语音输入结果回调失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _safeError(void Function(String message) callback, String message) {
    try {
      callback(message);
    } catch (error, stackTrace) {
      debugPrint('语音输入错误回调失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _safeStatus(void Function(String status) callback, String status) {
    try {
      callback(status);
    } catch (error, stackTrace) {
      debugPrint('语音输入状态回调失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  String _messageFor(Object error) {
    final message = error.toString();
    return message.startsWith('Bad state: ')
        ? message.substring('Bad state: '.length)
        : message;
  }
}
