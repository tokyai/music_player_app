import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/ai_assistant.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/ai_service.dart';
import '../services/ai_punctuation_service.dart';
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
  static const _speechErrorRestartDelay = Duration(milliseconds: 600);
  static const _zipformerSpeechCommitDelay = Duration(milliseconds: 350);
  static const _systemSpeechCommitDelay = Duration(milliseconds: 550);
  static const _doubaoSpeechCommitDelay = Duration(milliseconds: 120);
  static const _punctuationTimeout = Duration(milliseconds: 900);
  // Keep the visible transcript bounded during long in-car sessions. The
  // request context is already limited separately in _contextMessages().
  static const _maxStoredMessages = 100;
  // A gateway response is bounded at the HTTP layer, but a multi-megabyte
  // reply retained in every message would still exhaust a car's heap after
  // a few turns. Normal replies are far below this limit.
  static const _maxMessageChars = 32 * 1024;
  static const _maxContextChars = 64 * 1024;
  // A recognizer can emit many final fragments before the pause timer gets a
  // chance to submit them. Keep that transient speech buffer bounded too.
  static const _maxSpeechChars = 32 * 1024;
  // TTS engines may copy the complete input into native buffers. Keep an
  // unusually long gateway reply from creating another large memory peak.
  static const _maxTtsChars = 8 * 1024;

  final PlayerProvider player;
  final AiConfigController configController;
  final AiChatGateway gateway;
  final AiSongPlaybackResolver songResolver;
  final AiSpeechEngine speech;
  final AiPunctuationService punctuation;
  final AiTextToSpeechEngine textToSpeech;
  final Duration? speechCommitDelay;
  final Duration punctuationTimeout;

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
  Future<void>? _resourceDisposeFuture;
  AiVoiceModelKind? _sessionVoiceModel;
  AiBargeInMode? _sessionBargeInMode;
  Future<bool>? _ttsInitialization;
  bool _ttsReady = false;
  int _ttsInitializationGeneration = 0;
  Future<void>? _bargeInTask;
  int _bargeInToken = 0;

  AiAssistantController({
    required this.player,
    required this.configController,
    AiChatGateway? gateway,
    AiSongPlaybackResolver? songResolver,
    AiSpeechEngine? speech,
    AiPunctuationService? punctuation,
    AiTextToSpeechEngine? textToSpeech,
    this.speechCommitDelay,
    this.punctuationTimeout = _punctuationTimeout,
  }) : gateway = gateway ?? AiAssistantService(),
       songResolver = songResolver ?? const AiSongResolver(),
       speech = speech ?? PlatformAiSpeechEngine(),
       punctuation = punctuation ?? defaultAiPunctuationService(),
       textToSpeech = textToSpeech ?? PlatformAiTextToSpeechEngine();

  AiSessionState get state => _state;
  bool get isActive => _active;
  bool get isListening => _state == AiSessionState.listening;
  String get transcript => _transcript;
  String? get error => _error;
  List<AiConversationMessage> get messages => List.unmodifiable(_messages);

  void configureVoicePreloading({required bool enabled}) {
    if (_disposed) return;
    final warmup = speech is AiSpeechModelWarmup
        ? speech as AiSpeechModelWarmup
        : null;
    warmup?.setRetainIdleModel(enabled);
  }

  Future<bool> preloadVoiceModel() async {
    await configController.ready;
    if (_disposed ||
        configController.voiceModel != AiVoiceModelKind.zipformerChinese) {
      return false;
    }
    final warmup = speech is AiSpeechModelWarmup
        ? speech as AiSpeechModelWarmup
        : null;
    if (warmup == null) return false;
    return warmup.preloadModel(configController.voiceModel);
  }

  Future<void> releasePreloadedVoiceModel() async {
    if (_disposed || _active) return;
    final warmup = speech is AiSpeechModelWarmup
        ? speech as AiSpeechModelWarmup
        : null;
    if (warmup == null) return;
    try {
      await warmup.releasePreloadedModel();
    } catch (error, stackTrace) {
      // Low-memory and shutdown cleanup must remain best effort, but keep the
      // native release failure diagnosable from device logs.
      debugPrint('释放预加载语音模型失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

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
    if (_disposed || _active) return;
    await configController.ready;
    if (_disposed || _active) return;
    if (!configController.config.isComplete) {
      _setState(AiSessionState.error, error: '请先在设置中配置 AI URL、Key 和模型');
      return;
    }
    _active = true;
    _sessionVoiceModel = configController.voiceModel;
    _sessionBargeInMode = configController.bargeInMode;
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
    if (_disposed) return;
    _setState(AiSessionState.initializing);

    var speechReady = false;
    try {
      final modelSelector = speech;
      if (modelSelector is AiVoiceModelSelector) {
        (modelSelector as AiVoiceModelSelector).setVoiceModel(
          configController.voiceModel,
        );
      }
      speechReady = await speech.initialize(
        onError: _handleSpeechError,
        onStatus: _handleSpeechStatus,
      );
    } catch (error) {
      _handleSpeechError(error.toString());
    }
    if (_disposed || !_active) return;
    if (!speechReady) {
      _setState(AiSessionState.textOnly);
      // TTS is optional. Start it in the background so a later text reply can
      // use it without delaying the first recognition attempt.
      unawaited(_ensureTtsInitialized());
      return;
    }
    final listening = _startListening(_generation);
    unawaited(_ensureTtsInitialized());
    await listening;
    if (_disposed || !_active) return;
  }

  Future<void> sendText(String text) async {
    final normalized = text.trim();
    if (_disposed || normalized.isEmpty || !_active) return;
    if (_containsExitPhrase(normalized)) {
      await _finishWithGoodbye();
      return;
    }
    final generation = _generation;
    final turn = ++_turnGeneration;
    final wasSpeaking = _state == AiSessionState.speaking;
    if (wasSpeaking) {
      _invalidateBargeIn();
      await _stopBargeInMonitor();
      await _awaitBargeInTask();
    }
    await _stopRecognition();
    _resetSpeechBuffer();
    if (wasSpeaking) {
      await _stopSpeaking();
    }
    if (!_isCurrentTurn(generation, turn)) return;
    await _sendUserText(normalized, generation, turn);
  }

  Future<void> toggleListening() async {
    if (_disposed) return;
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
      _invalidateBargeIn();
      await _stopBargeInMonitor();
      await _awaitBargeInTask();
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
    if (_disposed) return;
    if (!_active) {
      await startSession();
      return;
    }
    _generation++;
    _turnGeneration++;
    final generation = _generation;
    _ignoreSpeechEvents = true;
    _invalidateBargeIn();
    await _stopBargeInMonitor();
    await _awaitBargeInTask();
    await _stopRecognition();
    if (_disposed || !_active || generation != _generation) return;
    await _stopSpeaking();
    if (_disposed || !_active || generation != _generation) return;
    _messages.clear();
    _resetSpeechBuffer();
    _error = null;
    _notify();
    await _startListening(generation);
  }

  Future<void> stopSession({bool restoreMusic = true}) async {
    if (_disposed || (!_active && _state == AiSessionState.idle)) return;
    _generation++;
    _turnGeneration++;
    final wasActive = _active;
    _active = false;
    _ignoreSpeechEvents = true;
    _invalidateBargeIn();
    _setState(AiSessionState.stopping);
    await _stopBargeInMonitor();
    await _awaitBargeInTask();
    await _stopRecognition();
    await _stopSpeaking();
    await _releaseIdleVoiceResources();
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
    _sessionVoiceModel = null;
    _sessionBargeInMode = null;
    _setState(AiSessionState.idle);
  }

  Future<void> _releaseIdleVoiceResources() async {
    final owner = speech is AiSpeechIdleResourceOwner
        ? speech as AiSpeechIdleResourceOwner
        : null;
    if (owner != null) {
      try {
        await owner.releaseIdleResources();
      } catch (_) {
        // Releasing an optional native model must not block session shutdown.
      }
    }
    try {
      await punctuation.releaseIdleResources();
    } catch (_) {}
  }

  Future<void> _startListening(
    int generation, {
    bool preserveTranscript = false,
  }) async {
    if (_disposed ||
        !_active ||
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

  AiSpeechBargeInSupport? get _bargeInSupport =>
      speech is AiSpeechBargeInSupport
      ? speech as AiSpeechBargeInSupport
      : null;

  bool get _bargeInEnabled =>
      _sessionBargeInMode == AiBargeInMode.voiceActivity &&
      (_bargeInSupport?.supportsBargeIn ?? false);

  void _invalidateBargeIn() {
    _bargeInToken++;
  }

  Future<void> _stopBargeInMonitor({bool preserveForNextListen = false}) async {
    final support = _bargeInSupport;
    if (support == null) return;
    try {
      await support.stopBargeInMonitor(
        preserveForNextListen: preserveForNextListen,
      );
    } catch (error, stackTrace) {
      debugPrint('停止自动打断监听失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _awaitBargeInTask() async {
    final pending = _bargeInTask;
    if (pending == null) return;
    try {
      await pending.timeout(const Duration(seconds: 2));
    } catch (error, stackTrace) {
      debugPrint('等待自动打断收尾超时: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<bool> _startBargeInMonitor(int generation, int turn) async {
    if (!_bargeInEnabled || !_isCurrentTurn(generation, turn)) return false;
    final support = _bargeInSupport;
    if (support == null) return false;
    final token = ++_bargeInToken;
    try {
      final started = await support.startBargeInMonitor(
        onVoiceDetected: () => _handleBargeInDetected(generation, turn, token),
      );
      if (!_isCurrentTurn(generation, turn) || token != _bargeInToken) {
        if (started) await _stopBargeInMonitor();
        return false;
      }
      return started;
    } catch (error, stackTrace) {
      debugPrint('启动自动打断监听失败: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<void> _handleBargeInDetected(
    int generation,
    int turn,
    int token,
  ) async {
    if (!_isCurrentTurn(generation, turn) ||
        token != _bargeInToken ||
        _state != AiSessionState.speaking ||
        !_bargeInEnabled ||
        _bargeInTask != null) {
      return;
    }
    final task = _handleBargeInDetectedInternal(generation, turn, token);
    _bargeInTask = task;
    try {
      await task;
    } finally {
      if (identical(_bargeInTask, task)) _bargeInTask = null;
    }
  }

  Future<void> _handleBargeInDetectedInternal(
    int generation,
    int turn,
    int token,
  ) async {
    if (!_isCurrentTurn(generation, turn) || token != _bargeInToken) return;
    // Invalidate the TTS turn before stopping the native utterance. If the
    // utterance completion callback wins the race, it can no longer reopen a
    // second listening segment or discard the handoff buffer.
    _bargeInToken++;
    final handoffToken = _bargeInToken;
    final nextTurn = ++_turnGeneration;
    await _stopSpeaking();
    if (!_isCurrentGeneration(generation) ||
        !_active ||
        nextTurn != _turnGeneration ||
        handoffToken != _bargeInToken) {
      await _stopBargeInMonitor();
      return;
    }
    // Keep detecting while the native TTS stop is in flight, then snapshot
    // the user's bounded preroll immediately before opening the full ASR.
    await _stopBargeInMonitor(preserveForNextListen: true);
    if (!_isCurrentGeneration(generation) ||
        nextTurn != _turnGeneration ||
        handoffToken != _bargeInToken) {
      await _stopBargeInMonitor();
      return;
    }
    var handedOff = false;
    try {
      await _startListening(generation);
      handedOff = _state == AiSessionState.listening;
    } finally {
      // PlatformAiSpeechEngine.listen() consumes the preroll. If a test/future
      // engine cannot accept it or startup fails, release the monitor here so
      // no microphone/capture remains active.
      if (!handedOff) await _stopBargeInMonitor();
    }
  }

  bool _isCurrentGeneration(int generation) =>
      !_disposed && _active && generation == _generation;

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
    _speechRestartTimer?.cancel();
    _speechRestartTimer = null;
    _currentSpeechText = normalized;
    _transcript = _mergeSpeechText(_finalSpeechText, _currentSpeechText);
    if (isFinal) {
      _finalSpeechText = _mergeSpeechText(_finalSpeechText, normalized);
      _currentSpeechText = '';
      _transcript = _finalSpeechText;
      // Do not start another recognition segment here.  The old code started
      // one after 180 ms and then cancelled it when the commit timer fired,
      // which caused needless microphone/audio-focus/session churn.  The
      // commit path below owns the current recognizer's cleanup and the next
      // segment is opened only after the reply has been spoken.
      _scheduleSpeechCommit(generation);
    }
    _notify();
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
    _setState(AiSessionState.processing);
    var punctuated = normalized;
    try {
      if (_shouldAddPunctuation(normalized)) {
        punctuated = await _addPunctuationWithinBudget(normalized);
      }
    } catch (_) {
      // Optional post-processing must not discard a valid speech command.
    }
    if (!_isCurrentTurn(generation, turn)) return;
    await _sendUserText(punctuated, generation, turn);
  }

  Future<void> _sendUserText(String text, int generation, int turn) async {
    if (!_isCurrentTurn(generation, turn)) return;
    _appendMessage(AiConversationMessage(role: AiMessageRole.user, text: text));
    _transcript = '';
    _setState(AiSessionState.processing);
    try {
      final result = await gateway.sendMessage(
        configController.config,
        _contextMessages(),
      );
      if (!_isCurrentTurn(generation, turn)) return;
      if (result.reply.trim().isNotEmpty) {
        _appendMessage(
          AiConversationMessage(
            role: AiMessageRole.assistant,
            text: result.reply.trim(),
          ),
        );
        _notify();
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
        _appendMessage(
          AiConversationMessage(
            role: AiMessageRole.assistant,
            text: resolution.message,
          ),
        );
        _notify();
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
      _appendMessage(
        AiConversationMessage(role: AiMessageRole.assistant, text: message),
      );
      _setState(AiSessionState.error);
      // 错误状态仍保留文字输入和再次聆听能力。
    }
  }

  Future<bool> _speak(String text, int generation, int turn) async {
    if (!_isCurrentTurn(generation, turn)) return false;
    final normalized = _boundSpeechText(text.trim());
    if (normalized.isEmpty) return true;
    final spoken = normalized.length <= _maxTtsChars
        ? normalized
        : '${normalized.substring(0, _maxTtsChars - 1)}…';
    _setState(AiSessionState.speaking);
    final ttsReady = await _ensureTtsInitialized();
    if (!ttsReady) return _isCurrentTurn(generation, turn);
    if (!_isCurrentTurn(generation, turn)) return false;
    final monitorStarted = await _startBargeInMonitor(generation, turn);
    if (!_isCurrentTurn(generation, turn)) {
      if (monitorStarted) await _stopBargeInMonitor();
      return false;
    }
    try {
      await textToSpeech.speak(spoken);
    } catch (error, stackTrace) {
      debugPrint('AI 语音播报失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    if (!_isCurrentTurn(generation, turn)) {
      // An automatic callback may have invalidated this turn while native TTS
      // was stopping. Let that handoff snapshot the preroll before disposing
      // the monitor; otherwise the first user syllable can be lost.
      await _awaitBargeInTask();
      if (_state == AiSessionState.listening) return false;
      _invalidateBargeIn();
      await _stopBargeInMonitor();
      return false;
    }
    _invalidateBargeIn();
    await _stopBargeInMonitor();
    await _awaitBargeInTask();
    return _isCurrentTurn(generation, turn);
  }

  Future<void> _finishWithGoodbye() async {
    if (!_active) return;
    final generation = _generation;
    final turn = ++_turnGeneration;
    _invalidateBargeIn();
    await _stopBargeInMonitor();
    await _awaitBargeInTask();
    await _stopRecognition();
    await _stopSpeaking();
    if (!_isCurrentTurn(generation, turn)) return;
    const goodbye = '好的，我先退下了。';
    _appendMessage(
      AiConversationMessage(role: AiMessageRole.assistant, text: goodbye),
    );
    _notify();
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

  Future<bool> _ensureTtsInitialized() {
    if (_disposed) return Future<bool>.value(false);
    if (_ttsReady) return Future<bool>.value(true);
    final existing = _ttsInitialization;
    if (existing != null) return existing;
    final generation = _ttsInitializationGeneration;
    late final Future<bool> operation;
    operation = _initializeTtsInternal(generation).whenComplete(() {
      if (identical(_ttsInitialization, operation)) {
        _ttsInitialization = null;
      }
    });
    _ttsInitialization = operation;
    return operation;
  }

  Future<bool> _initializeTtsInternal(int generation) async {
    try {
      await textToSpeech.initialize();
      if (_disposed || generation != _ttsInitializationGeneration) {
        return false;
      }
      _ttsReady = true;
      return true;
    } catch (error, stackTrace) {
      // TTS is optional; preserve text/voice recognition when the system
      // engine is unavailable. Concurrent callers share one initialization
      // future, while a later turn/session can retry a transient platform
      // failure without creating an unbounded initialization storm.
      debugPrint('AI 语音播报初始化失败: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
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
      final hadText =
          _currentSpeechText.isNotEmpty || _finalSpeechText.isNotEmpty;
      if (_currentSpeechText.isNotEmpty) {
        _finalSpeechText = _mergeSpeechText(
          _finalSpeechText,
          _currentSpeechText,
        );
        _currentSpeechText = '';
        _transcript = _finalSpeechText;
        _scheduleSpeechCommit(_generation);
        _notify();
      }
      // A recognizer that ends without a final text can be restarted.  When
      // text exists, _scheduleSpeechCommit owns the transition and starting
      // a second segment would race with _stopRecognition().
      if (!hadText) {
        _scheduleRecognitionRestart(_generation);
      }
    }
  }

  void _handleSpeechError(String message) {
    if (!_active || _ignoreSpeechEvents) return;
    _recognitionActive = false;
    if (!_isUnavailableSpeechError(message)) {
      debugPrint('AI 语音识别短暂异常，正在重试: $message');
      _error = null;
      final hadText =
          _currentSpeechText.isNotEmpty || _finalSpeechText.isNotEmpty;
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
      if (!hadText) {
        _scheduleRecognitionRestart(
          _generation,
          delay: _speechErrorRestartDelay,
          replacePending: true,
        );
      }
      return;
    }
    _cancelSpeechTimers();
    _error = '语音识别不可用：$message';
    _setState(AiSessionState.textOnly);
  }

  void _scheduleSpeechCommit(int generation) {
    _speechCommitTimer?.cancel();
    _speechRestartTimer?.cancel();
    _speechRestartTimer = null;
    _speechCommitTimer = Timer(_effectiveSpeechCommitDelay, () {
      _speechCommitTimer = null;
      unawaited(_commitSpeech(generation));
    });
  }

  Duration get _effectiveSpeechCommitDelay =>
      speechCommitDelay ??
      switch (_sessionVoiceModel ?? configController.voiceModel) {
        AiVoiceModelKind.zipformerChinese => _zipformerSpeechCommitDelay,
        AiVoiceModelKind.systemSpeech => _systemSpeechCommitDelay,
        AiVoiceModelKind.doubaoIme => _doubaoSpeechCommitDelay,
      };

  bool _shouldAddPunctuation(String text) {
    // Doubao's final result already includes its server-side correction and
    // punctuation passes.  Running the local 72 MB punctuation model again
    // only adds latency and memory pressure.
    if ((_sessionVoiceModel ?? configController.voiceModel) ==
        AiVoiceModelKind.doubaoIme) {
      return false;
    }
    // Most assistant voice turns are short commands.  They do not need a
    // second punctuation pass, while longer natural-language speech still
    // benefits from it.
    final command = text
        .replaceAll(RegExp(r'[，。！？,.!?、\s]+'), '')
        .replaceFirst(RegExp(r'^(请|麻烦|帮我)'), '');
    if (RegExp(
      r'^(我想|我要|想要)?(播放|放一首|放|听|暂停|继续|下一首|上一首|收藏|加入收藏|取消收藏|搜索|打开|关闭|调大|调小|音量|快进|快退)',
    ).hasMatch(command)) {
      return false;
    }
    return command.length >= 16;
  }

  Future<String> _addPunctuationWithinBudget(String text) async {
    try {
      return await punctuation.addPunctuation(text).timeout(punctuationTimeout);
    } on TimeoutException {
      // A timed-out optional model must not keep initializing in the
      // background and retain a large native allocation after the raw text
      // has already been submitted.
      unawaited(_releaseTimedOutPunctuation());
      return text;
    }
  }

  Future<void> _releaseTimedOutPunctuation() async {
    try {
      await punctuation.releaseIdleResources();
    } catch (_) {}
  }

  void _scheduleRecognitionRestart(
    int generation, {
    Duration delay = _speechRestartDelay,
    bool replacePending = false,
  }) {
    if (!_active ||
        generation != _generation ||
        _state != AiSessionState.listening) {
      return;
    }
    if (_speechRestartTimer != null && !replacePending) return;
    _speechRestartTimer?.cancel();
    _speechRestartTimer = Timer(delay, () {
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
    final first = _boundSpeechText(existing.trim());
    final second = _boundSpeechText(next.trim());
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
        return _boundSpeechText(
          '${first.substring(0, first.length - length)}$second',
        );
      }
    }
    return _boundSpeechText('$first $second');
  }

  String _boundSpeechText(String value) {
    if (value.length <= _maxSpeechChars) return value;
    return '${value.substring(0, _maxSpeechChars - 1)}…';
  }

  bool _isUnavailableSpeechError(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('error_permission') ||
        normalized.contains('error_audio_focus') ||
        normalized.contains('audio focus') ||
        normalized.contains('permission denied') ||
        normalized.contains('error_language_not_supported') ||
        normalized.contains('error_speech_recognizer_disabled') ||
        normalized.contains('speech_not_supported') ||
        normalized.contains('not supported');
  }

  bool _isCurrentTurn(int generation, int turn) =>
      !_disposed &&
      _active &&
      generation == _generation &&
      turn == _turnGeneration;

  List<AiConversationMessage> _contextMessages() {
    const maxMessages = 24;
    if (_messages.isEmpty) return const [];
    final selected = <AiConversationMessage>[];
    var chars = 0;
    for (
      var index = _messages.length - 1;
      index >= 0 && selected.length < maxMessages;
      index--
    ) {
      final message = _messages[index];
      if (selected.isNotEmpty &&
          chars + message.text.length > _maxContextChars) {
        break;
      }
      selected.add(message);
      chars += message.text.length;
    }
    return selected.reversed.toList(growable: false);
  }

  void _appendMessage(AiConversationMessage message) {
    final text = message.text.length <= _maxMessageChars
        ? message.text
        : '${message.text.substring(0, _maxMessageChars - 1)}…';
    _messages.add(
      identical(text, message.text)
          ? message
          : AiConversationMessage(
              role: message.role,
              text: text,
              createdAt: message.createdAt,
            ),
    );
    if (_messages.length > _maxStoredMessages) {
      _messages.removeRange(0, _messages.length - _maxStoredMessages);
    }
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
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_resourceDisposeFuture != null) return;
    _disposed = true;
    _active = false;
    _ttsInitializationGeneration++;
    _ttsReady = false;
    _sessionVoiceModel = null;
    _sessionBargeInMode = null;
    _invalidateBargeIn();
    _generation++;
    _turnGeneration++;
    _cancelSpeechTimers();
    // Stop exposing listeners synchronously. Microphone/model teardown keeps
    // running through the future returned by disposeResources().
    super.dispose();
    _resourceDisposeFuture = _finishResourceDispose();
  }

  /// Completes after microphone, punctuation and native recognizer resources
  /// have been released. User switching awaits this to avoid overlapping the
  /// next session's model with the previous one.
  Future<void> disposeResources() {
    final existing = _resourceDisposeFuture;
    if (existing != null) return existing;
    dispose();
    return _resourceDisposeFuture!;
  }

  Future<void> _finishResourceDispose() async {
    try {
      await _disposeSpeechResources();
    } catch (error, stackTrace) {
      debugPrint('释放 AI 语音资源失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    try {
      await _stopSpeaking();
    } catch (error, stackTrace) {
      debugPrint('停止 AI 播报失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    try {
      gateway.close();
    } catch (error, stackTrace) {
      debugPrint('关闭 AI 会话失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    _messages.clear();
    _resetSpeechBuffer();
  }

  Future<void> _disposeSpeechResources() async {
    await _stopBargeInMonitor();
    await _awaitBargeInTask();
    try {
      await _stopRecognition();
    } catch (_) {}
    final owner = speech;
    final resourceOwner = owner is AiSpeechResourceOwner
        ? owner as AiSpeechResourceOwner
        : null;
    if (resourceOwner != null) {
      try {
        await resourceOwner.dispose();
      } catch (_) {}
    }
    try {
      await punctuation.dispose();
    } catch (_) {}
  }
}
