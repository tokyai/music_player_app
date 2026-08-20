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
  static const _speechRestartDelay = Duration(milliseconds: 180);

  final PlayerProvider player;
  final AiConfigController configController;
  final AiChatGateway gateway;
  final AiSongPlaybackResolver songResolver;
  final AiSpeechEngine speech;
  final AiTextToSpeechEngine textToSpeech;
  final Duration speechCommitDelay;

  final List<AiConversationMessage> _messages = [];
  AiSessionState _state = AiSessionState.idle;
  String _transcript = '';
  String? _error;
  bool _active = false;
  bool _recognitionActive = false;
  bool _listenStarting = false;
  bool _ignoreSpeechEvents = false;
  int _generation = 0;
  int _turnGeneration = 0;
  String _finalSpeechText = '';
  String _currentSpeechText = '';
  Timer? _speechCommitTimer;
  Timer? _speechRestartTimer;
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
    this.speechCommitDelay = const Duration(milliseconds: 1500),
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
    _turnGeneration++;
    _messages.clear();
    _resetSpeechBuffer();
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
    final generation = _generation;
    final turn = ++_turnGeneration;
    final wasSpeaking = _state == AiSessionState.speaking;
    await _stopRecognition();
    _resetSpeechBuffer();
    if (wasSpeaking) {
      await _stopSpeaking();
    }
    if (!_isCurrentTurn(generation, turn)) return;
    await _sendUserText(normalized, generation, turn);
  }

  Future<void> toggleListening() async {
    if (!_active) {
      await startSession();
      return;
    }
    if (_state == AiSessionState.listening) {
      await _stopRecognition();
      _resetSpeechBuffer();
      _setState(AiSessionState.paused);
      return;
    }
    if (_state == AiSessionState.speaking) {
      final generation = _generation;
      final turn = ++_turnGeneration;
      await _stopSpeaking();
      if (!_isCurrentTurn(generation, turn)) return;
      await _startListening(generation);
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
    _turnGeneration++;
    final generation = _generation;
    _ignoreSpeechEvents = true;
    await _stopRecognition();
    await _stopSpeaking();
    _messages.clear();
    _resetSpeechBuffer();
    _error = null;
    notifyListeners();
    await _startListening(generation);
  }

  Future<void> stopSession({bool restoreMusic = true}) async {
    if (!_active && _state == AiSessionState.idle) return;
    _generation++;
    _turnGeneration++;
    final wasActive = _active;
    _active = false;
    _ignoreSpeechEvents = true;
    _setState(AiSessionState.stopping);
    await _stopRecognition();
    await _stopSpeaking();
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
    _resetSpeechBuffer();
    _setState(AiSessionState.idle);
  }

  Future<void> _startListening(
    int generation, {
    bool preserveTranscript = false,
  }) async {
    if (!_active ||
        generation != _generation ||
        _recognitionActive ||
        _listenStarting) {
      return;
    }
    _speechRestartTimer?.cancel();
    _speechRestartTimer = null;
    if (!preserveTranscript) _resetSpeechBuffer();
    _ignoreSpeechEvents = false;
    _recognitionActive = true;
    _listenStarting = true;
    _setState(AiSessionState.listening);
    try {
      await speech.listen((text, isFinal) {
        _onSpeechResult(generation, text, isFinal);
      });
    } catch (error) {
      _recognitionActive = false;
      _handleSpeechError(error.toString());
    } finally {
      _listenStarting = false;
    }
  }

  void _onSpeechResult(int generation, String text, bool isFinal) {
    if (!_active ||
        generation != _generation ||
        _ignoreSpeechEvents ||
        _state != AiSessionState.listening) {
      return;
    }
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    _speechCommitTimer?.cancel();
    _speechCommitTimer = null;
    _currentSpeechText = normalized;
    _transcript = _mergeSpeechText(_finalSpeechText, _currentSpeechText);
    if (isFinal) {
      _finalSpeechText = _mergeSpeechText(_finalSpeechText, normalized);
      _currentSpeechText = '';
      _transcript = _finalSpeechText;
      _recognitionActive = false;
      _scheduleSpeechCommit(generation);
      _scheduleRecognitionRestart(generation);
    }
    notifyListeners();
  }

  Future<void> _commitSpeech(int generation) async {
    if (!_active ||
        generation != _generation ||
        _state != AiSessionState.listening) {
      return;
    }
    final normalized = _mergeSpeechText(
      _finalSpeechText,
      _currentSpeechText,
    ).trim();
    if (normalized.isEmpty) return;
    final turn = ++_turnGeneration;
    await _stopRecognition();
    _resetSpeechBuffer();
    if (!_isCurrentTurn(generation, turn)) return;
    if (_containsExitPhrase(normalized)) {
      await _finishWithGoodbye();
      return;
    }
    await _sendUserText(normalized, generation, turn);
  }

  Future<void> _sendUserText(String text, int generation, int turn) async {
    if (!_isCurrentTurn(generation, turn)) return;
    _messages.add(AiConversationMessage(role: AiMessageRole.user, text: text));
    _transcript = '';
    _setState(AiSessionState.processing);
    try {
      final result = await gateway.sendMessage(
        configController.config,
        _contextMessages(),
      );
      if (!_isCurrentTurn(generation, turn)) return;
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
        final resolution = await songResolver.resolveAndPlay(
          player,
          result.playRequest!,
        );
        if (!_isCurrentTurn(generation, turn)) return;
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
        notifyListeners();
        if (await _speak(resolution.message, generation, turn)) {
          await _startListening(generation);
        }
        return;
      }
      if (await _speak(result.reply, generation, turn)) {
        await _startListening(generation);
      }
    } catch (error) {
      if (!_isCurrentTurn(generation, turn)) return;
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

  Future<bool> _speak(String text, int generation, int turn) async {
    if (!_isCurrentTurn(generation, turn)) return false;
    if (text.trim().isEmpty) return true;
    _setState(AiSessionState.speaking);
    try {
      await textToSpeech.speak(text);
    } catch (_) {}
    return _isCurrentTurn(generation, turn);
  }

  Future<void> _finishWithGoodbye() async {
    if (!_active) return;
    final generation = _generation;
    final turn = ++_turnGeneration;
    await _stopRecognition();
    await _stopSpeaking();
    if (!_isCurrentTurn(generation, turn)) return;
    const goodbye = '好的，我先退下了。';
    _messages.add(
      AiConversationMessage(role: AiMessageRole.assistant, text: goodbye),
    );
    notifyListeners();
    if (await _speak(goodbye, generation, turn)) {
      await stopSession();
    }
  }

  Future<void> _stopRecognition() async {
    _cancelSpeechTimers();
    _ignoreSpeechEvents = true;
    final shouldCancel = _recognitionActive || _listenStarting;
    _recognitionActive = false;
    if (!shouldCancel) return;
    try {
      await speech.cancel();
    } catch (_) {}
  }

  Future<void> _stopSpeaking() async {
    try {
      await textToSpeech.stop();
    } catch (_) {}
  }

  void _handleSpeechStatus(String status) {
    if (!_active || _ignoreSpeechEvents) return;
    if ((status == 'done' || status == 'notListening') &&
        _state == AiSessionState.listening) {
      _recognitionActive = false;
      if (_currentSpeechText.isNotEmpty) {
        _finalSpeechText = _mergeSpeechText(
          _finalSpeechText,
          _currentSpeechText,
        );
        _currentSpeechText = '';
        _transcript = _finalSpeechText;
        _scheduleSpeechCommit(_generation);
        notifyListeners();
      }
      _scheduleRecognitionRestart(_generation);
    }
  }

  void _handleSpeechError(String message) {
    if (!_active || _ignoreSpeechEvents) return;
    _recognitionActive = false;
    if (_isRecoverableSpeechError(message)) {
      _error = null;
      if (_currentSpeechText.isNotEmpty) {
        _finalSpeechText = _mergeSpeechText(
          _finalSpeechText,
          _currentSpeechText,
        );
        _currentSpeechText = '';
        _transcript = _finalSpeechText;
        _scheduleSpeechCommit(_generation);
      }
      _setState(AiSessionState.listening);
      _scheduleRecognitionRestart(_generation);
      return;
    }
    _cancelSpeechTimers();
    _error = '语音识别不可用：$message';
    _setState(AiSessionState.textOnly);
  }

  void _scheduleSpeechCommit(int generation) {
    _speechCommitTimer?.cancel();
    _speechCommitTimer = Timer(speechCommitDelay, () {
      _speechCommitTimer = null;
      unawaited(_commitSpeech(generation));
    });
  }

  void _scheduleRecognitionRestart(int generation) {
    if (!_active ||
        generation != _generation ||
        _state != AiSessionState.listening) {
      return;
    }
    _speechRestartTimer?.cancel();
    _speechRestartTimer = Timer(_speechRestartDelay, () {
      _speechRestartTimer = null;
      if (!_active ||
          generation != _generation ||
          _state != AiSessionState.listening ||
          _recognitionActive ||
          _listenStarting) {
        return;
      }
      unawaited(_startListening(generation, preserveTranscript: true));
    });
  }

  void _cancelSpeechTimers() {
    _speechCommitTimer?.cancel();
    _speechCommitTimer = null;
    _speechRestartTimer?.cancel();
    _speechRestartTimer = null;
  }

  void _resetSpeechBuffer() {
    _finalSpeechText = '';
    _currentSpeechText = '';
    _transcript = '';
  }

  String _mergeSpeechText(String existing, String next) {
    final first = existing.trim();
    final second = next.trim();
    if (first.isEmpty) return second;
    if (second.isEmpty || first == second || first.endsWith(second)) {
      return first;
    }
    if (second.startsWith(first)) return second;
    final overlapLimit = first.length < second.length
        ? first.length
        : second.length;
    for (var length = overlapLimit; length > 0; length--) {
      if (first.substring(first.length - length) ==
          second.substring(0, length)) {
        return '${first.substring(0, first.length - length)}$second';
      }
    }
    return '$first $second';
  }

  bool _isRecoverableSpeechError(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('error_speech_timeout') ||
        normalized.contains('error_no_match') ||
        normalized.contains('error_busy') ||
        normalized.contains('error_client');
  }

  bool _isCurrentTurn(int generation, int turn) =>
      _active && generation == _generation && turn == _turnGeneration;

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
    _turnGeneration++;
    _cancelSpeechTimers();
    unawaited(_stopRecognition());
    unawaited(textToSpeech.stop());
    gateway.close();
    super.dispose();
  }
}
