import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/remote_playback.dart';
import 'package:music_player_app/models/playback_source_config.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/screens/playback_source_config_screen.dart';
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'legacy personal credentials survive unchanged save in both landscapes',
    (tester) async {
      final legacyConfig = PlaybackSourceConfig.defaults().copyWith(
        hywCardKey: 'legacy-personal-hyw-key',
        xinghaiLicenseKey: 'legacy-personal-xinghai-license',
      );
      SharedPreferences.setMockInitialValues({
        PlaybackSourceConfig.preferenceKey: jsonEncode(legacyConfig.toJson()),
      });
      final player = await _pumpConfig(
        tester,
        const Size(640, 360),
        _LegacyCredentialPlayer(),
      );
      expect(player.playbackSourceConfig.remoteCredentials, isEmpty);
      final expectedValues = {
        'source-credential-hyw-hywCardKey': 'legacy-personal-hyw-key',
        'source-credential-xinghai-xinghaiLicenseKey':
            'legacy-personal-xinghai-license',
      };
      for (final size in const [Size(640, 360), Size(1280, 800)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        for (final entry in expectedValues.entries) {
          final field = find.byKey(ValueKey(entry.key));
          await tester.ensureVisible(field);
          expect(field.hitTestable(), findsOneWidget);
          expect(tester.widget<TextField>(field).controller!.text, entry.value);
          expect(tester.widget<TextField>(field).obscureText, isTrue);
        }
        expect(tester.takeException(), isNull);
      }
      final toggle = find.byKey(const ValueKey('source-enabled-server_added'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('保存配置'));
      await tester.pumpAndSettle();
      expect(
        player.playbackSourceConfig.remoteCredentials['hyw']?['hywCardKey'],
        'legacy-personal-hyw-key',
      );
      expect(
        player
            .playbackSourceConfig
            .remoteCredentials['xinghai']?['xinghaiLicenseKey'],
        'legacy-personal-xinghai-license',
      );
      expect(
        player.playbackSourceConfig.disabledSourceIds,
        contains('server_added'),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new server source and credential survive landscape rotation', (
    tester,
  ) async {
    final player = await _pumpConfig(tester, const Size(640, 360));
    final field = find.byKey(
      const ValueKey('source-credential-server_added-accessToken'),
    );
    await tester.ensureVisible(field);
    await tester.enterText(field, 'draft-token');
    for (final size in const [
      Size(1280, 800),
      Size(390, 844),
      Size(640, 360),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      await tester.ensureVisible(field);
      expect(field.hitTestable(), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, 'draft-token');
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      expect(find.byTooltip('保存配置').hitTestable(), findsOneWidget);
      expect(find.byTooltip('刷新音源列表').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    final toggle = find.byKey(const ValueKey('source-enabled-server_added'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('保存配置'));
    await tester.pumpAndSettle();
    expect(player.playbackSourceConfig.remoteCredentials['server_added'], {
      'accessToken': 'draft-token',
    });
    expect(
      player.playbackSourceConfig.disabledRemoteSources,
      contains('server_added'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate saves are blocked and failed save retains draft', (
    tester,
  ) async {
    final player = await _pumpConfig(tester, const Size(1280, 800));
    final field = find.byKey(
      const ValueKey('source-credential-server_added-accessToken'),
    );
    await tester.ensureVisible(field);
    await tester.enterText(field, 'retry-token');
    player.saveGate = Completer<void>();
    final save = tester
        .widget<IconButton>(
          find.byKey(const ValueKey('save-playback-source-config')),
        )
        .onPressed!;
    save();
    save();
    await tester.pump();
    expect(player.saveCalls, 1);
    expect(tester.widget<TextField>(field).enabled, isFalse);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('save-playback-source-config')),
          )
          .onPressed,
      isNull,
    );
    player.saveGate!.completeError(StateError('storage unavailable'));
    await tester.pumpAndSettle();
    expect(find.textContaining('storage unavailable'), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'retry-token');
    expect(
      player.playbackSourceConfig.remoteCredentials['server_added'],
      isNull,
    );
    player.saveGate = null;
    await tester.tap(find.byTooltip('保存配置'));
    await tester.pumpAndSettle();
    expect(player.saveCalls, 2);
    expect(
      player
          .playbackSourceConfig
          .remoteCredentials['server_added']?['accessToken'],
      'retry-token',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh and save completion do not update disposed page', (
    tester,
  ) async {
    final player = await _pumpConfig(tester, const Size(640, 360));
    player.refreshGate = Completer<void>();
    await tester.tap(find.byTooltip('刷新音源列表'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    player.refreshGate!.completeError(StateError('server unavailable'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh retains credential draft and displays retry feedback', (
    tester,
  ) async {
    final player = await _pumpConfig(tester, const Size(640, 360));
    final field = find.byKey(
      const ValueKey('source-credential-server_added-accessToken'),
    );
    await tester.ensureVisible(field);
    await tester.enterText(field, 'unsaved-token');
    player.refreshError = '音源服务暂时不可用';
    await tester.tap(find.byTooltip('刷新音源列表'));
    await tester.pumpAndSettle();
    expect(find.text('音源服务暂时不可用'), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'unsaved-token');
    expect(
      player.playbackSourceConfig.remoteCredentials['server_added'],
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(640, 360), Size(1280, 800)]) {
    testWidgets('local package and update failure stay usable at $size', (
      tester,
    ) async {
      final player = _RemotePlayer()..packageUpdateError = '解析包更新失败，继续使用本地版本';
      await _pumpConfig(tester, size, player);
      for (final text in [
        '使用本地解析包。后台更新不可用时继续使用当前版本，不影响播放。',
        '当前解析包：7',
        '解析包更新失败，继续使用本地版本',
      ]) {
        final feedback = find.text(text);
        await tester.ensureVisible(feedback);
        expect(feedback.hitTestable(), findsOneWidget);
      }
      expect(find.byTooltip('刷新音源列表').hitTestable(), findsOneWidget);
      expect(find.byTooltip('保存配置').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
      final toggle = find.byKey(const ValueKey('source-enabled-server_added'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final refreshCalls = player.refreshCalls;
      await tester.tap(find.byTooltip('刷新音源列表'));
      await tester.pumpAndSettle();
      expect(player.refreshCalls, refreshCalls + 1);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await tester.tap(find.byTooltip('保存配置'));
      await tester.pumpAndSettle();
      expect(
        player.playbackSourceConfig.disabledSourceIds,
        contains('server_added'),
      );
      expect(find.byType(PlaybackSourceConfigScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('new source can be selected in settings at $size', (
      tester,
    ) async {
      final player = _RemotePlayer();
      final theme = ThemeController();
      await player.settingsReady;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await player.disposeResources();
        theme.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<ThemeController>.value(value: theme),
            ChangeNotifierProvider(create: (_) => FavoriteService()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final platform = find.byKey(const ValueKey('playback-source-qq'));
      await tester.ensureVisible(platform);
      await tester.tap(platform);
      await tester.pumpAndSettle();
      final choice = find.byKey(
        const ValueKey('playback-source-qq-server_added'),
      );
      await tester.ensureVisible(choice);
      expect(choice.hitTestable(), findsOneWidget);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(
        player.playbackSourceFor(MusicPlatform.qq),
        _RemotePlayer.addedSource,
      );
      expect(
        (await SharedPreferences.getInstance()).getString('playback_source_qq'),
        'server_added',
      );
      expect(tester.takeException(), isNull);
    });
  }
}

Future<_RemotePlayer> _pumpConfig(
  WidgetTester tester,
  Size size, [
  _RemotePlayer? existingPlayer,
]) async {
  final player = existingPlayer ?? _RemotePlayer();
  await player.settingsReady;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() async {
    if (player.refreshGate != null && !player.refreshGate!.isCompleted) {
      player.refreshGate!.complete();
    }
    if (player.saveGate != null && !player.saveGate!.isCompleted) {
      player.saveGate!.complete();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await player.disposeResources();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<PlayerProvider>.value(
      value: player,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    ),
  );
  final context = tester.element(find.byType(Scaffold));
  unawaited(
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const PlaybackSourceConfigScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return player;
}

class _RemotePlayer extends PlayerProvider {
  static final addedSource = PlaybackSource.fromId(
    'server_added',
    label: '服务端新增音源',
  );
  static final descriptors = [
    RemotePlaybackSource(
      source: addedSource,
      description: '新的音源由服务端维护',
      platforms: const ['qq', '163', 'kugou'],
      credentials: const [
        PlaybackCredentialField(
          key: 'accessToken',
          label: '访问令牌',
          requiredPlatforms: ['qq'],
        ),
      ],
    ),
  ];
  Completer<void>? saveGate;
  Completer<void>? refreshGate;
  String? refreshError;
  String? packageUpdateError;
  int saveCalls = 0;
  int refreshCalls = 0;

  @override
  List<RemotePlaybackSource> get remotePlaybackSources => descriptors;

  @override
  String? get playbackSourcesError => refreshError;

  @override
  bool get playbackSourcesLoading => false;

  @override
  int? get playbackPackageVersion => 7;

  @override
  String? get playbackPackageUpdateError => packageUpdateError;

  @override
  List<PlaybackSource> playbackSourceOptions(MusicPlatform platform) => [
    PlaybackSource.automatic,
    addedSource,
  ];

  @override
  RemotePlaybackSource? descriptorFor(PlaybackSource source) =>
      source == addedSource ? descriptors.first : null;

  @override
  Future<void> refreshPlaybackSources() async {
    refreshCalls++;
    await refreshGate?.future;
    notifyListeners();
  }

  @override
  Future<void> setRemotePlaybackSourceSettings({
    required List<String> disabledSources,
    required Map<String, Map<String, String>> credentials,
  }) async {
    saveCalls++;
    await saveGate?.future;
    await super.setRemotePlaybackSourceSettings(
      disabledSources: disabledSources,
      credentials: credentials,
    );
  }
}

class _LegacyCredentialPlayer extends _RemotePlayer {
  @override
  List<RemotePlaybackSource> get remotePlaybackSources => [
    const RemotePlaybackSource(
      source: PlaybackSource.hyw,
      description: '个人 HYW 卡密',
      platforms: ['163', 'qq'],
      credentials: [
        PlaybackCredentialField(
          key: 'hywCardKey',
          label: 'HYW Card Key',
          requiredPlatforms: [],
        ),
      ],
    ),
    const RemotePlaybackSource(
      source: PlaybackSource.xinghai,
      description: '个人星海授权',
      platforms: ['163', 'qq', 'kugou'],
      credentials: [
        PlaybackCredentialField(
          key: 'xinghaiLicenseKey',
          label: '星海授权卡密',
          requiredPlatforms: ['qq'],
        ),
      ],
    ),
    ..._RemotePlayer.descriptors,
  ];
}
