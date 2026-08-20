import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/ai_assistant.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/ai_service.dart';
import '../services/ai_song_resolver.dart';
import '../services/ai_voice_service.dart';
import 'ai_config_controller.dart';

enum AiSessionState {
  idle,
  initializing,
  listening,
  processing,
  speaking,
  textOnly,
  paused,
  stopping,
  error,
}

class AiAssistantController extends ChangeNotifier {
  final PlayerProvider player;
  final AiConfigController configController;
  final AiChatGateway gateway;
  final AiSongPlaybackResolver songResolver;
  final AiSpeechEngine speech;
  final AiTextToSpeechEngine textToSpeech;

  final List<AiConversationMessage> _messages = [];
  AiSessionState _state = AiSessionState.idle;
  String _transcript = '';
  String? _error;
  bool _active = false;
  bool _recognitionActive = false;
  bool _ignoreSpeechEvents = false;
  int _generation = 0;
  bool _wasPlayingBeforeSession = false;
  bool _startedMusic = false;
  ({MusicPlatform platform, String id})? _songBeforeSession;
  bool _disposed = false;

  AiAssistantController({
    required this.player,
    required this.configController,
    AiChatGateway? gateway,
    AiSongPlaybackResolver? songResolver,
    AiSpeechEngine? speech,
    AiTextToSpeechEngine? textToSpeech,
  }) : gateway = gateway ?? AiAssistantService(),
       songResolver = songResolver ?? const AiSongResolver(),
       speech = speech ?? PlatformAiSpeechEngine(),
       textToSpeech = textToSpeech ?? PlatformAiTextToSpeechEngine();

  AiSessionState get state => _state;
  bool get isActive => _active;
  bool get isListening => _state == AiSessionState.listening;
  String get transcript => _transcript;
  String? get error => _error;
  List<AiConversationMessage> get messages => List.unmodifiable(_messages);

  String get statusLabel => switch (_state) {
    AiSessionState.idle => '点击麦克风开始对话',
    AiSessionState.initializing => '正在准备语音服务…',
    AiSessionState.listening => '正在听，请说话',
    AiSessionState.processing => '正在思考…',
    AiSessionState.speaking => '正在回答…',
    AiSessionState.textOnly => '语音不可用，可使用文字输入',
    AiSessionState.paused => '已暂停聆听',
    AiSessionState.stopping => '正在结束对话…',
    AiSessionState.error => _error ?? '发生错误',
  };

  Future<void> startSession() async {
    if (_active) return;
    await configController.ready;
    if (!configController.config.isComplete) {
      _setState(AiSessionState.error, error: '请先在设置中配置 AI URL、Key 和模型');
      return;
    }
    _active = true;
    _generation++;
    _messages.clear();
    _transcript = '';
    _error = null;
    _startedMusic = false;
    _wasPlayingBeforeSession = player.isPlaying;
    final before = player.currentSong;
    _songBeforeSession = before == null
        ? null
        : (platform: before.platform, id: before.id);
    if (_wasPlayingBeforeSession) {
      await player.pause();
    }
    _setState(AiSessionState.initializing);

    var speechReady = false;
    try {
      speechReady = await speech.initialize(
        onError: _handleSpeechError,
        onStatus: _handleSpeechStatus,
      );
    } catch (error) {
      _handleSpeechError(error.toString());
    }
    try {
      await textToSpeech.initialize();
    } catch (_) {
      // 语音播报不可用时仍可继续识别和文字对话。
    }
    if (!_active) return;
    if (!speechReady) {
      _setState(AiSessionState.textOnly);
      return;
    }
    await _startListening(_generation);
  }

  Future<void> sendText(String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty || !_active) return;
    if (_containsExitPhrase(normalized)) {
      await _finishWithGoodbye();
      return;
    }
    await _stopRecognition();
    await _sendUserText(normalized, _generation);
  }

  Future<void> toggleListening() async {
    if (!_active) {
      await startSession();
      return;
    }
    if (_state == AiSessionState.listening) {
      await _stopRecognition();
      _setState(AiSessionState.paused);
      return;
    }
    if (_state == AiSessionState.paused || _state == AiSessionState.textOnly) {
      await _startListening(_generation);
    } else if (_state == AiSessionState.error) {
      _error = null;
      await _startListening(_generation);
    }
  }

  Future<void> newSession() async {
    if (!_active) {
      await startSession();
      return;
    }
    _generation++;
    final generation = _generation;
    _ignoreSpeechEvents = true;
    await _stopRecognition();
    try {
      await textToSpeech.stop();
    } catch (_) {}
    _messages.clear();
    _transcript = '';
    _error = null;
    notifyListeners();
    await _startListening(generation);
  }

  Future<void> stopSession({bool restoreMusic = true}) async {
    if (!_active && _state == AiSessionState.idle) return;
    _generation++;
    final wasActive = _active;
    _active = false;
    _ignoreSpeechEvents = true;
    _setState(AiSessionState.stopping);
    await _stopRecognition();
    try {
      await textToSpeech.stop();
    } catch (_) {}
    if (restoreMusic &&
        wasActive &&
        _wasPlayingBeforeSession &&
        !_startedMusic) {
      final current = player.currentSong;
      final sameSong =
          current != null &&
          _songBeforeSession?.platform == current.platform &&
          _songBeforeSession?.id == current.id;
      if (sameSong && !player.isPlaying) {
        await player.playPause();
      }
    }
    _transcript = '';
    _setState(AiSessionState.idle);
  }

  Future<void> _startListening(int generation) async {
    if (!_active || generation != _generation) return;
    _ignoreSpeechEvents = false;
    _recognitionActive = true;
    _transcript = '';
    _setState(AiSessionState.listening);
    try {
      await speech.listen((text, isFinal) {
        _onSpeechResult(generation, text, isFinal);
      });
    } catch (error) {
      _recognitionActive = false;
      _handleSpeechError(error.toString());
    }
  }

  void _onSpeechResult(int generation, String text, bool isFinal) {
    if (!_active || generation != _generation || _ignoreSpeechEvents) return;
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    _transcript = normalized;
    notifyListeners();
    if (_containsExitPhrase(normalized)) {
      unawaited(_finishWithGoodbye());
      return;
    }
    if (isFinal) {
      unawaited(
        _stopRecognition().then((_) => _sendUserText(normalized, generation)),
      );
    }
  }

  Future<void> _sendUserText(String text, int generation) async {
    if (!_active || generation != _generation) return;
    _messages.add(AiConversationMessage(role: AiMessageRole.user, text: text));
    _transcript = '';
    _setState(AiSessionState.processing);
    try {
      final result = await gateway.sendMessage(
        configController.config,
        _contextMessages(),
      );
      if (!_active || generation != _generation) return;
      if (result.reply.trim().isNotEmpty) {
        _messages.add(
          AiConversationMessage(
            role: AiMessageRole.assistant,
            text: result.reply.trim(),
          ),
        );
        notifyListeners();
      }
      if (result.playRequest != null) {
        await _speak(result.reply);
        if (!_active || generation != _generation) return;
        final resolution = await songResolver.resolveAndPlay(
          player,
          result.playRequest!,
        );
        if (resolution.found) {
          _startedMusic = true;
          await stopSession(restoreMusic: false);
          return;
        }
        _messages.add(
          AiConversationMessage(
            role: AiMessageRole.assistant,
            text: resolution.message,
          ),
        );
        await _speak(resolution.message);
        await _startListening(generation);
        return;
      }
      await _speak(result.reply);
      await _startListening(generation);
    } catch (error) {
      if (!_active || generation != _generation) return;
      final message = error is AiServiceException
          ? error.message
          : '请求失败：$error';
      _error = message;
      _messages.add(
        AiConversationMessage(role: AiMessageRole.assistant, text: message),
      );
      _setState(AiSessionState.error);
      // 错误状态仍保留文字输入和再次聆听能力。
    }
  }

  Future<void> _speak(String text) async {
    if (!_active || text.trim().isEmpty) return;
    _setState(AiSessionState.speaking);
    try {
      await textToSpeech.speak(text);
    } catch (_) {}
  }

  Future<void> _finishWithGoodbye() async {
    if (!_active) return;
    await _stopRecognition();
    const goodbye = '好的，我先退下了。';
    _messages.add(
      AiConversationMessage(role: AiMessageRole.assistant, text: goodbye),
    );
    notifyListeners();
    await _speak(goodbye);
    await stopSession();
  }

  Future<void> _stopRecognition() async {
    if (!_recognitionActive) return;
    _ignoreSpeechEvents = true;
    _recognitionActive = false;
    try {
      await speech.cancel();
    } catch (_) {}
  }

  void _handleSpeechStatus(String status) {
    if (!_active || _ignoreSpeechEvents) return;
    if ((status == 'done' || status == 'notListening') &&
        _state == AiSessionState.listening) {
      _recognitionActive = false;
      unawaited(_startListening(_generation));
    }
  }

  void _handleSpeechError(String message) {
    if (!_active) return;
    _recognitionActive = false;
    _error = '语音识别不可用：$message';
    _setState(AiSessionState.textOnly);
  }

  List<AiConversationMessage> _contextMessages() {
    const maxMessages = 24;
    if (_messages.length <= maxMessages) return List.of(_messages);
    return _messages.sublist(_messages.length - maxMessages);
  }

  bool _containsExitPhrase(String text) {
    final normalized = text.replaceAll(RegExp(r'[，。！？,.!?\s]+'), '');
    if (normalized == '结束') return true;
    return RegExp(
      r'(退下吧|结束对话|结束聊天|退出助手|退出对话|关闭助手|助手再见|先这样吧)',
    ).hasMatch(normalized);
  }

  void _setState(AiSessionState state, {String? error}) {
    if (_disposed) return;
    _state = state;
    if (error != null) _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _active = false;
    _generation++;
    unawaited(_stopRecognition());
    unawaited(textToSpeech.stop());
    gateway.close();
    super.dispose();
  }
}
