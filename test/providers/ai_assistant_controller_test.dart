import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/ai_assistant.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/ai_assistant_controller.dart';
import 'package:music_player_app/providers/ai_config_controller.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/services/ai_punctuation_service.dart';
import 'package:music_player_app/services/ai_service.dart';
import 'package:music_player_app/services/ai_song_resolver.dart';
import 'package:music_player_app/services/ai_voice_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('continues listening and a new session clears prior context', () async {
    final fixture = await _Fixture.create(
      gatewayResults: const [
        AiChatResult(reply: '我推荐《夜曲》。'),
        AiChatResult(reply: '这是一次全新对话。'),
      ],
    );
    addTearDown(fixture.dispose);

    await fixture.controller.startSession();
    expect(fixture.controller.state, AiSessionState.listening);
    expect(fixture.speech.listenCalls, 1);

    fixture.speech.emit('周杰伦表达感情有哪些歌曲', isFinal: true);
    await _waitFor(() => fixture.gateway.requests.length == 1);
    await _waitFor(() => fixture.controller.state == AiSessionState.listening);
    expect(fixture.tts.spoken, ['我推荐《夜曲》。']);
    expect(fixture.gateway.requests.first, hasLength(1));
    expect(fixture.gateway.requests.first.single.text, '周杰伦表达感情有哪些歌曲');
    expect(fixture.controller.messages, hasLength(2));

    await fixture.controller.newSession();
    expect(fixture.controller.messages, isEmpty);
    expect(fixture.controller.state, AiSessionState.listening);

    fixture.speech.emit('你还记得刚才的问题吗', isFinal: true);
    await _waitFor(() => fixture.gateway.requests.length == 2);
    await _waitFor(() => fixture.controller.state == AiSessionState.listening);
    expect(fixture.gateway.requests.last, hasLength(1));
    expect(fixture.gateway.requests.last.single.text, '你还记得刚才的问题吗');
    expect(fixture.speech.listenCalls, greaterThanOrEqualTo(4));
  });

  test('bounds unusually large messages and request context', () async {
    final fixture = await _Fixture.create(
      gatewayResults: [AiChatResult(reply: '回复' * 40000)],
    );
    addTearDown(fixture.dispose);

    await fixture.controller.startSession();
    await fixture.controller.sendText('问题' * 40000);

    expect(fixture.controller.messages, hasLength(2));
    expect(
      fixture.controller.messages.every(
        (message) => message.text.length <= 32769,
      ),
      isTrue,
    );
    expect(
      fixture.gateway.requests.single.single.text.length,
      lessThanOrEqualTo(32768),
    );
    expect(fixture.tts.spoken.single.length, lessThanOrEqualTo(8192));
  });

  test('bounds a long continuous speech transcript', () async {
    final fixture = await _Fixture.create(
      speechCommitDelay: const Duration(hours: 1),
    );
    addTearDown(fixture.dispose);

    await fixture.controller.startSession();
    fixture.speech.emit('语音' * 40000, isFinal: true);

    expect(fixture.controller.transcript.length, lessThanOrEqualTo(32768));
  });

  test('uses the configured voice engine for a new session', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.config.save(
      fixture.config.config.copyWith(voiceModel: AiVoiceModelKind.doubaoIme),
    );

    await fixture.controller.startSession();

    expect(fixture.speech.voiceModel, AiVoiceModelKind.doubaoIme);
  });

  test('waits for continued speech and sends combined text once', () async {
    String? punctuationInput;
    final punctuation = MemoryAiPunctuationService(
      transform: (text) {
        punctuationInput = text;
        return '$text！';
      },
    );
    final fixture = await _Fixture.create(
      speechCommitDelay: const Duration(milliseconds: 80),
      gatewayResults: const [AiChatResult(reply: '收到完整问题。')],
      punctuation: punctuation,
    );
    addTearDown(fixture.dispose);

    await fixture.controller.startSession();
    fixture.speech.emit('我想听周杰伦的', isFinal: true);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(fixture.gateway.requests, isEmpty);
    fixture.speech.emit('夜曲', isFinal: false);
    fixture.speech.emit('夜曲', isFinal: true);

    await _waitFor(() => fixture.gateway.requests.length == 1);
    expect(punctuationInput, '我想听周杰伦的 夜曲');
    expect(fixture.gateway.requests.single.single.text, '我想听周杰伦的 夜曲！');
    expect(punctuation.calls, 1);
  });

  test('keyboard input bypasses speech punctuation', () async {
    final punctuation = MemoryAiPunctuationService(
      transform: (text) => '$text！',
    );
    final fixture = await _Fixture.create(punctuation: punctuation);
    addTearDown(fixture.dispose);

    await fixture.controller.startSession();
    await fixture.controller.sendText('键盘输入');

    expect(fixture.gateway.requests.single.single.text, '键盘输入');
    expect(punctuation.calls, 0);
  });

  test('punctuation failure falls back to the recognized text', () async {
    final punctuation = MemoryAiPunctuationService(
      transform: (_) => throw StateError('模型不可用'),
    );
    final fixture = await _Fixture.create(punctuation: punctuation);
    addTearDown(fixture.dispose);

    await fixture.controller.startSession();
    fixture.speech.emit('播放周杰伦', isFinal: true);

    await _waitFor(() => fixture.gateway.requests.length == 1);
    expect(fixture.gateway.requests.single.single.text, '播放周杰伦');
  });

  test('stopping and disposing release punctuation resources', () async {
    final punctuation = MemoryAiPunctuationService();
    final fixture = await _Fixture.create(punctuation: punctuation);

    await fixture.controller.startSession();
    await fixture.controller.stopSession();
    expect(punctuation.releaseCalls, 1);

    await fixture.dispose();
    await _waitFor(() => punctuation.disposeCalls == 1);
  });

  test(
    'retries transient speech errors but keeps unavailable errors visible',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);

      await fixture.controller.startSession();
      fixture.speech.emitError('error_speech_timeout');
      await _waitFor(() => fixture.speech.listenCalls >= 2);

      expect(fixture.controller.state, AiSessionState.listening);

      fixture.speech.emitError('error_network');
      await _waitFor(() => fixture.speech.listenCalls >= 3);

      expect(fixture.controller.state, AiSessionState.listening);
      expect(fixture.controller.error, isNull);

      fixture.speech.emitError('error_server_disconnected');
      await _waitFor(() => fixture.speech.listenCalls >= 4);

      expect(fixture.controller.state, AiSessionState.listening);
      expect(fixture.controller.error, isNull);

      fixture.speech.emitError('error_permission');
      expect(fixture.controller.state, AiSessionState.textOnly);
      expect(fixture.controller.error, contains('error_permission'));
    },
  );

  test('interrupting speech keeps the current conversation context', () async {
    final fixture = await _Fixture.create(
      blockedSpeakCount: 1,
      gatewayResults: const [
        AiChatResult(reply: '第一轮回答。'),
        AiChatResult(reply: '结合刚才内容继续回答。'),
      ],
    );
    addTearDown(fixture.dispose);

    await fixture.controller.startSession();
    fixture.speech.emit('第一轮问题', isFinal: true);
    await _waitFor(() => fixture.controller.state == AiSessionState.speaking);

    await fixture.controller.toggleListening();
    expect(fixture.controller.state, AiSessionState.listening);
    fixture.speech.emit('继续刚才的话题', isFinal: true);
    await _waitFor(() => fixture.gateway.requests.length == 2);
    await _waitFor(() => fixture.controller.state == AiSessionState.listening);

    expect(fixture.tts.stopCalls, greaterThanOrEqualTo(1));
    expect(fixture.gateway.requests, hasLength(2));
    expect(fixture.gateway.requests.last.map((message) => message.text), [
      '第一轮问题',
      '第一轮回答。',
      '继续刚才的话题',
    ]);
    expect(fixture.controller.messages, hasLength(4));
    expect(fixture.controller.state, AiSessionState.listening);
  });

  test('exit keyword ends the session and restores paused music', () async {
    final oldSong = _queueItem(id: 'old-song', name: '原来播放的歌');
    final fixture = await _Fixture.create(
      player: _TestPlayer(song: oldSong, playing: true),
    );
    addTearDown(fixture.dispose);

    await fixture.controller.startSession();
    expect(fixture.player.pauseCalls, 1);
    expect(fixture.player.isPlaying, isFalse);

    await fixture.controller.sendText('结束');

    expect(fixture.controller.isActive, isFalse);
    expect(fixture.controller.state, AiSessionState.idle);
    expect(fixture.gateway.requests, isEmpty);
    expect(fixture.tts.spoken.last, '好的，我先退下了。');
    expect(fixture.player.playPauseCalls, 1);
    expect(fixture.player.isPlaying, isTrue);
  });

  test(
    'successful song playback exits without restoring the old song',
    () async {
      final oldSong = _queueItem(id: 'old-song', name: '原来播放的歌');
      final resolver = _TestResolver(
        AiSongResolution(
          song: SongSearchResult(
            platform: MusicPlatform.qq,
            id: 'night-song',
            name: '夜曲',
            artist: '周杰伦',
            album: '十一月的萧邦',
          ),
          message: '正在播放《夜曲》',
        ),
      );
      final fixture = await _Fixture.create(
        player: _TestPlayer(song: oldSong, playing: true),
        resolver: resolver,
        blockedSpeakCount: 1,
        gatewayResults: const [
          AiChatResult(
            reply: '好的，我来播放《夜曲》。',
            playRequest: AiPlaySongRequest(title: '夜曲', artist: '周杰伦'),
          ),
        ],
      );
      addTearDown(fixture.dispose);

      await fixture.controller.startSession();
      await fixture.controller.sendText('播放周杰伦的夜曲');

      expect(resolver.requests, hasLength(1));
      expect(resolver.requests.single.artist, '周杰伦');
      expect(resolver.requests.single.title, '夜曲');
      expect(fixture.controller.isActive, isFalse);
      expect(fixture.controller.state, AiSessionState.idle);
      expect(fixture.player.pauseCalls, 1);
      expect(fixture.player.playPauseCalls, 0);
      expect(fixture.tts.spoken, isEmpty);
    },
  );

  test('failed song playback keeps the current conversation open', () async {
    final fixture = await _Fixture.create(
      gatewayResults: const [
        AiChatResult(
          reply: '我来找找《夜曲》。',
          playRequest: AiPlaySongRequest(title: '夜曲', artist: '周杰伦'),
        ),
      ],
    );
    addTearDown(fixture.dispose);

    await fixture.controller.startSession();
    await fixture.controller.sendText('播放周杰伦的夜曲');

    expect(fixture.controller.isActive, isTrue);
    expect(fixture.controller.state, AiSessionState.listening);
    expect(fixture.controller.messages.map((message) => message.text), [
      '播放周杰伦的夜曲',
      '我来找找《夜曲》。',
      '没有找到歌曲',
    ]);
    expect(fixture.tts.spoken, ['没有找到歌曲']);
  });

  test(
    'closing a chat without playback restores only the same old song',
    () async {
      final oldSong = _queueItem(id: 'old-song', name: '原来播放的歌');
      final player = _TestPlayer(song: oldSong, playing: true);
      final fixture = await _Fixture.create(player: player);
      addTearDown(fixture.dispose);

      await fixture.controller.startSession();
      player.song = _queueItem(id: 'different-song', name: '另一首歌');
      await fixture.controller.stopSession();

      expect(player.playPauseCalls, 0);
      expect(fixture.controller.state, AiSessionState.idle);
    },
  );
}

class _Fixture {
  final _TestPlayer player;
  final AiConfigController config;
  final _TestGateway gateway;
  final _TestSpeech speech;
  final AiPunctuationService punctuation;
  final _TestTts tts;
  final AiAssistantController controller;

  _Fixture._({
    required this.player,
    required this.config,
    required this.gateway,
    required this.speech,
    required this.punctuation,
    required this.tts,
    required this.controller,
  });

  static Future<_Fixture> create({
    _TestPlayer? player,
    _TestResolver? resolver,
    List<AiChatResult> gatewayResults = const [],
    int blockedSpeakCount = 0,
    Duration speechCommitDelay = const Duration(milliseconds: 10),
    AiPunctuationService? punctuation,
  }) async {
    final actualPlayer = player ?? _TestPlayer();
    final config = AiConfigController(secretStore: MemoryAiSecretStore());
    await config.ready;
    await config.save(_completeConfig());
    final gateway = _TestGateway(gatewayResults);
    final speech = _TestSpeech();
    final actualPunctuation = punctuation ?? MemoryAiPunctuationService();
    final tts = _TestTts(blockedSpeakCount: blockedSpeakCount);
    final controller = AiAssistantController(
      player: actualPlayer,
      configController: config,
      gateway: gateway,
      songResolver: resolver ?? _TestResolver.notFound(),
      speech: speech,
      punctuation: actualPunctuation,
      textToSpeech: tts,
      speechCommitDelay: speechCommitDelay,
    );
    return _Fixture._(
      player: actualPlayer,
      config: config,
      gateway: gateway,
      speech: speech,
      punctuation: actualPunctuation,
      tts: tts,
      controller: controller,
    );
  }

  Future<void> dispose() async {
    controller.dispose();
    config.dispose();
    player.dispose();
    await Future<void>.delayed(Duration.zero);
  }
}

class _TestGateway implements AiChatGateway {
  final List<AiChatResult> _results;
  final List<List<AiConversationMessage>> requests = [];
  bool closed = false;

  _TestGateway(List<AiChatResult> results) : _results = List.of(results);

  @override
  Future<AiChatResult> sendMessage(
    AiAssistantConfig config,
    List<AiConversationMessage> messages, {
    bool connectionCheck = false,
  }) async {
    requests.add(List.of(messages));
    if (_results.isEmpty) return const AiChatResult(reply: '收到');
    return _results.removeAt(0);
  }

  @override
  Future<AiConnectionCheck> checkConnection(
    AiAssistantConfig config, {
    bool checkSearch = false,
  }) async => const AiConnectionCheck(
    success: true,
    webSearchObserved: false,
    message: '连接成功',
  );

  @override
  void close() => closed = true;
}

class _TestSpeech implements AiSpeechEngine, AiVoiceModelSelector {
  AiSpeechResultCallback? _resultCallback;
  void Function(String)? _errorCallback;
  void Function(String)? _statusCallback;
  bool listening = false;
  int listenCalls = 0;
  AiVoiceModelKind? voiceModel;

  @override
  void setVoiceModel(AiVoiceModelKind model) => voiceModel = model;

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async {
    _errorCallback = onError;
    _statusCallback = onStatus;
    return true;
  }

  @override
  Future<void> listen(AiSpeechResultCallback onResult) async {
    _resultCallback = onResult;
    listening = true;
    listenCalls++;
  }

  void emit(String text, {bool isFinal = true}) {
    _resultCallback?.call(text, isFinal);
  }

  void emitError(String message) => _errorCallback?.call(message);

  void emitStatus(String status) => _statusCallback?.call(status);

  @override
  Future<void> stop() async => listening = false;

  @override
  Future<void> cancel() async => listening = false;
}

class _TestTts implements AiTextToSpeechEngine {
  final List<String> spoken = [];
  int blockedSpeakCount;
  int stopCalls = 0;
  Completer<void>? _pendingSpeak;

  _TestTts({this.blockedSpeakCount = 0});

  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    if (blockedSpeakCount <= 0) return;
    blockedSpeakCount--;
    final pending = Completer<void>();
    _pendingSpeak = pending;
    await pending.future;
    if (identical(_pendingSpeak, pending)) _pendingSpeak = null;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    final pending = _pendingSpeak;
    if (pending != null && !pending.isCompleted) pending.complete();
  }
}

class _TestResolver implements AiSongPlaybackResolver {
  final AiSongResolution result;
  final List<AiPlaySongRequest> requests = [];

  _TestResolver(this.result);

  factory _TestResolver.notFound() =>
      _TestResolver(const AiSongResolution(song: null, message: '没有找到歌曲'));

  @override
  Future<AiSongResolution> resolveAndPlay(
    PlayerProvider player,
    AiPlaySongRequest request,
  ) async {
    requests.add(request);
    return result;
  }
}

class _TestPlayer extends PlayerProvider {
  PlayQueueItem? song;
  bool playing;
  int pauseCalls = 0;
  int playPauseCalls = 0;

  _TestPlayer({this.song, this.playing = false});

  @override
  PlayQueueItem? get currentSong => song;

  @override
  bool get isPlaying => playing;

  @override
  List<PlayQueueItem> get queue => [if (song != null) song!];

  @override
  int get currentIndex => song == null ? -1 : 0;

  @override
  Future<void> pause() async {
    pauseCalls++;
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> playPause() async {
    playPauseCalls++;
    playing = !playing;
    notifyListeners();
  }
}

AiAssistantConfig _completeConfig() => const AiAssistantConfig(
  provider: AiProviderKind.openAi,
  protocol: AiRequestProtocol.openAiResponses,
  baseUrl: 'https://example.test/v1',
  apiKey: 'test-key',
  model: 'test-model',
  reasoningEffort: AiReasoningEffort.platformDefault,
  webSearchMode: AiWebSearchMode.disabled,
);

PlayQueueItem _queueItem({required String id, required String name}) =>
    PlayQueueItem(
      platform: MusicPlatform.qq,
      id: id,
      name: name,
      artist: '测试歌手',
      album: '测试专辑',
    );

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('等待异步状态超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
