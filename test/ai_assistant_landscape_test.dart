import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/main.dart' show MainScreen;
import 'package:music_player_app/models/ai_assistant.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/ai_assistant_controller.dart';
import 'package:music_player_app/providers/ai_config_controller.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/screens/player_screen.dart';
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/services/ai_service.dart';
import 'package:music_player_app/services/ai_song_resolver.dart';
import 'package:music_player_app/services/ai_voice_service.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_layout.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:music_player_app/widgets/ai_assistant_overlay.dart';
import 'package:music_player_app/widgets/kuzai_pet.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppColors.isDark = false;
  });

  testWidgets('AI startup services stay lazy until the assistant is opened', (
    tester,
  ) async {
    var configCreateCount = 0;
    var assistantCreateCount = 0;
    final player = _LandscapePlayer();
    _setViewSize(tester, const Size(640, 360));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider<AiConfigController>(
            create: (_) {
              configCreateCount++;
              return AiConfigController(secretStore: MemoryAiSecretStore());
            },
          ),
          ChangeNotifierProvider<AiAssistantController>(
            create: (context) {
              assistantCreateCount++;
              return AiAssistantController(
                player: player,
                configController: context.read<AiConfigController>(),
                gateway: _SilentGateway(),
                speech: _ReadySpeech(),
                textToSpeech: _SilentTts(),
              );
            },
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            floatingActionButton: AiAssistantFloatingButton(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(configCreateCount, 0);
    expect(assistantCreateCount, 0);

    await tester.tap(find.byKey(const ValueKey('ai-assistant-fab')));
    await tester.pumpAndSettle();

    expect(configCreateCount, 1);
    expect(assistantCreateCount, 1);
    expect(find.textContaining('请先到“设置 > AI 音乐助理”'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    player.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('Kuzai pet waves on tap and reacts to long press', (
    tester,
  ) async {
    var tapCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: KuzaiPet(
              key: const ValueKey('test-kuzai-pet'),
              size: 88,
              mode: KuzaiPetMode.idle,
              onTap: () => tapCount++,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('test-kuzai-pet')));
    await tester.pump();
    expect(tapCount, 1);
    expect(find.byKey(const ValueKey('kuzai-pet-wave-active')), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('kuzai-pet-wave-active')), findsNothing);

    await tester.longPress(find.byKey(const ValueKey('test-kuzai-pet')));
    await tester.pump();
    expect(tapCount, 1);
    expect(
      find.byKey(const ValueKey('kuzai-pet-petting-active')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'AI assistant remains usable without hiding playback paths in both landscapes',
    (tester) async {
      await http.runWithClient(() async {
        for (final size in const [Size(640, 360), Size(1280, 800)]) {
          SharedPreferences.setMockInitialValues({});
          final fixture = await _MainFixture.create();
          _setViewSize(tester, size);
          await tester.pumpWidget(fixture.app());
          await _pumpFrames(tester);

          final fab = find.byKey(const ValueKey('ai-assistant-fab'));
          expect(fab.hitTestable(), findsOneWidget);
          expect(
            tester.getSize(fab).height,
            size == const Size(640, 360) ? 68 : 88,
          );
          if (size == const Size(640, 360)) {
            final miniControls = find.byKey(
              const ValueKey('mini-player-controls'),
            );
            expect(miniControls, findsOneWidget);
            expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
            expect(
              tester.getRect(fab).overlaps(tester.getRect(miniControls)),
              isFalse,
            );
          } else {
            final playerPane = find.byKey(
              const ValueKey('landscape-mini-player-qq:landscape-song'),
            );
            expect(playerPane, findsOneWidget);
            expect(
              find
                  .byKey(const ValueKey('landscape-mini-play-control'))
                  .hitTestable(),
              findsOneWidget,
            );
            expect(find.byTooltip('收藏').hitTestable(), findsOneWidget);
            expect(find.byTooltip('播放队列').hitTestable(), findsOneWidget);
            expect(
              tester.getRect(fab).overlaps(tester.getRect(playerPane)),
              isFalse,
            );
          }

          await tester.tap(fab);
          await _pumpFrames(tester);

          expect(
            find.byKey(const ValueKey('ai-assistant-dialog')),
            findsOneWidget,
          );
          expect(
            find
                .byKey(const ValueKey('ai-assistant-new-session'))
                .hitTestable(),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('ai-assistant-close')).hitTestable(),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('ai-assistant-microphone')).hitTestable(),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('ai-assistant-text-field')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('ai-assistant-send')), findsNothing);
          expect(find.text('正在听，请说话'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('kuzai-pet-mode-listening')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);

          await tester.tap(
            find.byKey(const ValueKey('ai-assistant-close')).hitTestable(),
          );
          await _pumpFrames(tester);
          expect(
            find.byKey(const ValueKey('ai-assistant-dialog')),
            findsNothing,
          );

          if (size == const Size(640, 360)) {
            await tester.tap(
              find.byKey(const ValueKey('mini-player-qq:landscape-song')),
            );
            await _pumpFrames(tester);
            expect(
              find.byKey(const ValueKey('player-queue-action')).hitTestable(),
              findsOneWidget,
            );
            expect(find.text('收藏').hitTestable(), findsOneWidget);
            expect(find.byTooltip('播放').hitTestable(), findsWidgets);
          }
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          fixture.dispose();
        }
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }, _mockClient);
    },
  );

  testWidgets(
    'successful voice playback closes the dialog in both landscapes',
    (tester) async {
      await http.runWithClient(() async {
        for (final size in const [Size(640, 360), Size(1280, 800)]) {
          SharedPreferences.setMockInitialValues({});
          final resolver = _FoundSongResolver();
          final fixture = await _MainFixture.create(
            gateway: _PlaySongGateway(),
            songResolver: resolver,
          );
          _setViewSize(tester, size);
          await tester.pumpWidget(fixture.app());
          await _pumpFrames(tester);

          await tester.tap(find.byKey(const ValueKey('ai-assistant-fab')));
          await _pumpFrames(tester);
          expect(
            find.byKey(const ValueKey('ai-assistant-dialog')),
            findsOneWidget,
          );

          await fixture.assistant.sendText('播放周杰伦的夜曲');
          await _pumpFrames(tester);

          expect(resolver.requests, hasLength(1));
          expect(
            find.byKey(const ValueKey('ai-assistant-dialog')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          fixture.dispose();
        }
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }, _mockClient);
    },
  );

  testWidgets('landscape microphone can interrupt an answer in both sizes', (
    tester,
  ) async {
    await http.runWithClient(() async {
      for (final size in const [Size(640, 360), Size(1280, 800)]) {
        SharedPreferences.setMockInitialValues({});
        final tts = _BlockingTts();
        final fixture = await _MainFixture.create(
          gateway: _AnswerGateway(),
          textToSpeech: tts,
        );
        _setViewSize(tester, size);
        await tester.pumpWidget(fixture.app());
        await _pumpFrames(tester);

        await tester.tap(find.byKey(const ValueKey('ai-assistant-fab')));
        await _pumpFrames(tester);
        final response = fixture.assistant.sendText('第一轮问题');
        await _pumpFrames(tester);

        expect(fixture.assistant.state, AiSessionState.speaking);
        expect(
          find.byKey(const ValueKey('ai-assistant-microphone')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('ai-assistant-text-field')),
          findsNothing,
        );

        await tester.tap(
          find.byKey(const ValueKey('ai-assistant-microphone')).hitTestable(),
        );
        await _pumpFrames(tester);
        await response;

        expect(tts.stopCalls, greaterThanOrEqualTo(1));
        expect(fixture.assistant.state, AiSessionState.listening);
        expect(fixture.assistant.messages, hasLength(2));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        fixture.dispose();
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }, _mockClient);
  });

  testWidgets('close dismisses before speech cleanup in every orientation', (
    tester,
  ) async {
    await http.runWithClient(() async {
      for (final size in const [
        Size(390, 844),
        Size(640, 360),
        Size(1280, 800),
      ]) {
        SharedPreferences.setMockInitialValues({});
        final speech = _BlockingCancelSpeech();
        final fixture = await _MainFixture.create(speech: speech);
        _setViewSize(tester, size);
        await tester.pumpWidget(fixture.app());
        await _pumpFrames(tester);

        await tester.tap(find.byKey(const ValueKey('ai-assistant-fab')));
        await _pumpFrames(tester);
        expect(
          find.byKey(const ValueKey('ai-assistant-close')).hitTestable(),
          findsOneWidget,
        );
        if (size.width > size.height) {
          expect(
            find.byKey(const ValueKey('ai-assistant-dialog')),
            findsOneWidget,
          );
        }

        await tester.tap(
          find.byKey(const ValueKey('ai-assistant-close')).hitTestable(),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(speech.cancelCalls, 1);
        expect(speech.cancelCompleted, isFalse);
        expect(find.byKey(const ValueKey('ai-assistant-close')), findsNothing);
        expect(find.byKey(const ValueKey('ai-assistant-dialog')), findsNothing);

        speech.completeCancel();
        await _pumpFrames(tester);
        expect(fixture.assistant.state, AiSessionState.idle);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        fixture.dispose();
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }, _mockClient);
  });

  testWidgets(
    'player page AI pet follows its setting across portrait and landscapes',
    (tester) async {
      await http.runWithClient(() async {
        for (final size in const [
          Size(390, 844),
          Size(640, 360),
          Size(1280, 800),
        ]) {
          SharedPreferences.setMockInitialValues({});
          final fixture = await _MainFixture.create();
          _setViewSize(tester, size);
          await tester.pumpWidget(fixture.app(home: const PlayerScreen()));
          await _pumpFrames(tester);

          final pet = find.byKey(const ValueKey('ai-assistant-fab'));
          expect(pet.hitTestable(), findsOneWidget);
          expect(
            tester
                .getRect(pet)
                .overlaps(
                  tester.getRect(
                    find.byKey(const ValueKey('player-next-track')),
                  ),
                ),
            isFalse,
          );
          if (size.width > size.height) {
            expect(
              tester
                  .getRect(pet)
                  .overlaps(
                    tester.getRect(
                      find.byKey(const ValueKey('player-lyric-bottom-toolbar')),
                    ),
                  ),
              isFalse,
            );
          } else {
            expect(
              tester
                  .getRect(pet)
                  .overlaps(
                    tester.getRect(
                      find.byKey(const ValueKey('player-mv-action')),
                    ),
                  ),
              isFalse,
            );
          }

          await tester.tap(pet);
          await _pumpFrames(tester);
          final close = find.byKey(const ValueKey('ai-assistant-close'));
          expect(close.hitTestable(), findsOneWidget);
          await tester.tap(close);
          await _pumpFrames(tester);

          await fixture.config.setShowPetOnPlayerPage(false);
          await tester.pump();
          expect(pet, findsNothing);
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          fixture.dispose();
        }
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }, _mockClient);
    },
  );

  testWidgets(
    'AI settings and QR close path are reachable in both landscapes',
    (tester) async {
      for (final size in const [Size(640, 360), Size(1280, 800)]) {
        SharedPreferences.setMockInitialValues({});
        final player = _LandscapePlayer();
        final theme = ThemeController();
        final config = AiConfigController(secretStore: MemoryAiSecretStore());
        await config.ready;
        await config.save(_completeConfig());
        _setViewSize(tester, size);
        await tester.pumpWidget(
          _settingsApp(player: player, theme: theme, config: config),
        );
        await tester.pumpAndSettle();

        final systemScroll = find
            .descendant(
              of: find.byKey(
                const PageStorageKey<String>('settings-landscape-system'),
              ),
              matching: find.byType(Scrollable),
            )
            .first;
        final urlField = find.byKey(const ValueKey('ai-base-url-field'));
        final playerPetToggle = find.byKey(
          const ValueKey('ai-player-page-pet-toggle'),
        );
        final allPagesToggle = find.byKey(
          const ValueKey('ai-all-pages-toggle'),
        );
        await tester.scrollUntilVisible(
          allPagesToggle,
          160,
          scrollable: systemScroll,
        );
        expect(allPagesToggle.hitTestable(), findsOneWidget);
        expect(tester.widget<SwitchListTile>(allPagesToggle).value, isTrue);
        await tester.tap(allPagesToggle);
        await tester.pumpAndSettle();
        expect(config.showAssistantOnAllPages, isFalse);
        expect(
          (await SharedPreferences.getInstance()).getBool(
            AiConfigController.showAssistantOnAllPagesPreferenceKey,
          ),
          isFalse,
        );
        await tester.scrollUntilVisible(
          playerPetToggle,
          160,
          scrollable: systemScroll,
        );
        expect(playerPetToggle.hitTestable(), findsOneWidget);
        expect(tester.widget<SwitchListTile>(playerPetToggle).value, isTrue);
        await tester.tap(playerPetToggle);
        await tester.pumpAndSettle();
        expect(config.showPetOnPlayerPage, isFalse);
        expect(
          (await SharedPreferences.getInstance()).getBool(
            AiConfigController.showPetOnPlayerPagePreferenceKey,
          ),
          isFalse,
        );

        await tester.scrollUntilVisible(
          urlField,
          220,
          scrollable: systemScroll,
        );
        expect(urlField.hitTestable(), findsOneWidget);
        expect(
          tester.widget<TextField>(urlField).controller?.text,
          'https://example.test/v1',
        );

        for (final key in const [
          ValueKey('ai-config-save'),
          ValueKey('ai-config-test'),
          ValueKey('ai-config-qr-input'),
        ]) {
          final action = find.byKey(key);
          await tester.scrollUntilVisible(
            action,
            160,
            scrollable: systemScroll,
          );
          expect(action.hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);

        final qrInput = find.byKey(const ValueKey('ai-config-qr-input'));
        await tester.tap(qrInput);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();

        final qrCode = find.byKey(const ValueKey('ai-config-qr-code'));
        final close = find.byKey(const ValueKey('ai-config-qr-close'));
        expect(qrCode, findsOneWidget);
        expect(
          tester.widget<QrImageView>(qrCode).size,
          size == const Size(640, 360) ? 146 : 205,
        );
        expect(close.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(qrCode, findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        config.dispose();
        player.dispose();
        theme.dispose();
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}

class _MainFixture {
  final _LandscapePlayer player;
  final ThemeController theme;
  final AiConfigController config;
  final AiAssistantController assistant;

  _MainFixture._({
    required this.player,
    required this.theme,
    required this.config,
    required this.assistant,
  });

  static Future<_MainFixture> create({
    AiChatGateway? gateway,
    AiSongPlaybackResolver? songResolver,
    AiSpeechEngine? speech,
    AiTextToSpeechEngine? textToSpeech,
  }) async {
    final player = _LandscapePlayer();
    final theme = ThemeController();
    final config = AiConfigController(secretStore: MemoryAiSecretStore());
    await config.ready;
    await config.save(_completeConfig());
    final assistant = AiAssistantController(
      player: player,
      configController: config,
      gateway: gateway ?? _SilentGateway(),
      songResolver: songResolver,
      speech: speech ?? _ReadySpeech(),
      textToSpeech: textToSpeech ?? _SilentTts(),
    );
    return _MainFixture._(
      player: player,
      theme: theme,
      config: config,
      assistant: assistant,
    );
  }

  Widget app({Widget home = const MainScreen()}) => MultiProvider(
    providers: [
      ChangeNotifierProvider<PlayerProvider>.value(value: player),
      ChangeNotifierProvider<AiConfigController>.value(value: config),
      ChangeNotifierProvider<AiAssistantController>.value(value: assistant),
      ChangeNotifierProvider(create: (_) => SearchSession()),
      ChangeNotifierProvider<ThemeController>.value(value: theme),
      ChangeNotifierProvider(create: (_) => FavoriteService()),
    ],
    child: Consumer<ThemeController>(
      builder: (context, controller, _) => MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: AppLayout.adaptiveMediaQueryOf(
            context,
            fontScale: controller.fontScale,
          ),
          child: child!,
        ),
        home: home,
      ),
    ),
  );

  void dispose() {
    assistant.dispose();
    config.dispose();
    player.dispose();
    theme.dispose();
  }
}

Widget _settingsApp({
  required PlayerProvider player,
  required ThemeController theme,
  required AiConfigController config,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<PlayerProvider>.value(value: player),
    ChangeNotifierProvider<ThemeController>.value(value: theme),
    ChangeNotifierProvider<AiConfigController>.value(value: config),
    ChangeNotifierProvider(create: (_) => FavoriteService()),
  ],
  child: MaterialApp(theme: AppTheme.light(), home: const SettingsScreen()),
);

class _LandscapePlayer extends PlayerProvider {
  final PlayQueueItem _song = PlayQueueItem(
    platform: MusicPlatform.qq,
    id: 'landscape-song',
    name: '横屏测试歌曲',
    artist: '测试歌手',
    album: '测试专辑',
  );

  @override
  PlayQueueItem? get currentSong => _song;

  @override
  List<PlayQueueItem> get queue => [_song];

  @override
  int get currentIndex => 0;

  @override
  bool get isPlaying => false;
}

class _SilentGateway implements AiChatGateway {
  @override
  Future<AiChatResult> sendMessage(
    AiAssistantConfig config,
    List<AiConversationMessage> messages, {
    bool connectionCheck = false,
  }) async => const AiChatResult(reply: '收到');

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
  void close() {}
}

class _PlaySongGateway implements AiChatGateway {
  @override
  Future<AiChatResult> sendMessage(
    AiAssistantConfig config,
    List<AiConversationMessage> messages, {
    bool connectionCheck = false,
  }) async => const AiChatResult(
    reply: '好的，我来播放《夜曲》。',
    playRequest: AiPlaySongRequest(title: '夜曲', artist: '周杰伦'),
  );

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
  void close() {}
}

class _AnswerGateway implements AiChatGateway {
  @override
  Future<AiChatResult> sendMessage(
    AiAssistantConfig config,
    List<AiConversationMessage> messages, {
    bool connectionCheck = false,
  }) async => const AiChatResult(reply: '第一轮回答。');

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
  void close() {}
}

class _FoundSongResolver implements AiSongPlaybackResolver {
  final List<AiPlaySongRequest> requests = [];

  @override
  Future<AiSongResolution> resolveAndPlay(
    PlayerProvider player,
    AiPlaySongRequest request,
  ) async {
    requests.add(request);
    return AiSongResolution(
      song: SongSearchResult(
        platform: MusicPlatform.qq,
        id: 'night-song',
        name: '夜曲',
        artist: '周杰伦',
        album: '十一月的萧邦',
      ),
      message: '正在播放《夜曲》',
    );
  }
}

class _ReadySpeech implements AiSpeechEngine {
  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async => true;

  @override
  Future<void> listen(AiSpeechResultCallback onResult) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}
}

class _BlockingCancelSpeech extends _ReadySpeech {
  final Completer<void> _cancel = Completer<void>();
  int cancelCalls = 0;

  bool get cancelCompleted => _cancel.isCompleted;

  @override
  Future<void> cancel() {
    cancelCalls++;
    return _cancel.future;
  }

  void completeCancel() {
    if (!_cancel.isCompleted) _cancel.complete();
  }
}

class _SilentTts implements AiTextToSpeechEngine {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}
}

class _BlockingTts implements AiTextToSpeechEngine {
  Completer<void>? _pending;
  int stopCalls = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String text) async {
    final pending = Completer<void>();
    _pending = pending;
    await pending.future;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete();
    _pending = null;
  }
}

AiAssistantConfig _completeConfig() => const AiAssistantConfig(
  provider: AiProviderKind.openAi,
  protocol: AiRequestProtocol.openAiResponses,
  baseUrl: 'https://example.test/v1',
  apiKey: 'test-key',
  model: 'test-model',
  reasoningEffort: AiReasoningEffort.platformDefault,
  webSearchMode: AiWebSearchMode.automatic,
);

void _setViewSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump(const Duration(milliseconds: 500));
}

http.Client _mockClient() => MockClient((request) async {
  return http.Response(
    jsonEncode(<String, dynamic>{}),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
});
