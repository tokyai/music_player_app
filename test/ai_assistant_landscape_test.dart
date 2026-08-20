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
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/services/ai_service.dart';
import 'package:music_player_app/services/ai_voice_service.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_layout.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:music_player_app/widgets/ai_assistant_overlay.dart';
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
            find.byKey(const ValueKey('ai-assistant-text-field')).hitTestable(),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('ai-assistant-send')).hitTestable(),
            findsOneWidget,
          );
          expect(find.text('正在听，请说话'), findsOneWidget);
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

  static Future<_MainFixture> create() async {
    final player = _LandscapePlayer();
    final theme = ThemeController();
    final config = AiConfigController(secretStore: MemoryAiSecretStore());
    await config.ready;
    await config.save(_completeConfig());
    final assistant = AiAssistantController(
      player: player,
      configController: config,
      gateway: _SilentGateway(),
      speech: _ReadySpeech(),
      textToSpeech: _SilentTts(),
    );
    return _MainFixture._(
      player: player,
      theme: theme,
      config: config,
      assistant: assistant,
    );
  }

  Widget app() => MultiProvider(
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
        home: const MainScreen(),
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

class _SilentTts implements AiTextToSpeechEngine {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}
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
