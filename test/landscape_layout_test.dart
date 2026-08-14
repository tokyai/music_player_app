import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/main.dart' show MainScreen;
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/screens/discover_screen.dart';
import 'package:music_player_app/screens/player_screen.dart';
import 'package:music_player_app/screens/playlist_detail_screen.dart';
import 'package:music_player_app/screens/playlist_screen.dart';
import 'package:music_player_app/screens/search_screen.dart';
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:music_player_app/utils/lyric_parser.dart';
import 'package:music_player_app/widgets/mini_player.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppColors.isDark = false;
  });

  testWidgets('landscape pages use two panes without layout exceptions', (
    tester,
  ) async {
    await http.runWithClient(() async {
      final player = PlayerProvider();
      final theme = ThemeController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        theme.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await _pumpScreen(
        tester,
        const DiscoverScreen(),
        player,
        theme,
        const Size(640, 360),
      );
      expect(find.byType(VerticalDivider), findsOneWidget);
      _expectNoException(tester);

      await _pumpScreen(
        tester,
        const SearchScreen(),
        player,
        theme,
        const Size(800, 360),
      );
      expect(find.byType(VerticalDivider), findsOneWidget);
      _expectNoException(tester);

      await _pumpScreen(
        tester,
        const PlaylistScreen(),
        player,
        theme,
        const Size(640, 360),
      );
      expect(find.byType(VerticalDivider), findsOneWidget);
      _expectNoException(tester);

      await _pumpScreen(
        tester,
        PlaylistDetailScreen(
          playlist: PlaylistInfo(
            id: '42',
            name: '横屏测试歌单',
            creator: '测试用户',
            trackCount: 0,
            tracks: const [],
          ),
          platform: MusicPlatform.kugou,
        ),
        player,
        theme,
        const Size(640, 360),
      );
      expect(find.byType(VerticalDivider), findsOneWidget);
      _expectNoException(tester);

      for (final size in const [
        Size(640, 360),
        Size(800, 360),
        Size(1280, 800),
      ]) {
        await _pumpScreen(tester, const SettingsScreen(), player, theme, size);
        expect(find.byType(VerticalDivider), findsOneWidget);
        _expectNoException(tester);
      }
    }, _mockClient);
  });

  testWidgets('search state survives portrait to landscape rotation', (
    tester,
  ) async {
    await http.runWithClient(() async {
      final player = PlayerProvider();
      final theme = ThemeController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        theme.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await _pumpScreen(
        tester,
        const SearchScreen(),
        player,
        theme,
        const Size(390, 844),
      );
      await tester.enterText(find.byType(TextField), '周杰伦');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      final initialTabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect((initialTabBar.tabs.first as Tab).text, 'QQ音乐');
      await tester.tap(find.text('网易云').first);
      await tester.pumpAndSettle();

      _setViewSize(tester, const Size(640, 360));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(field.controller?.text, '周杰伦');
      expect(tabBar.controller?.index, 1);
      expect(find.byType(VerticalDivider), findsOneWidget);
      _expectNoException(tester);
    }, _mockClient);
  });

  testWidgets('player fits short landscape and opens a side queue', (
    tester,
  ) async {
    await http.runWithClient(() async {
      final player = _PlayerWithLyrics();
      final theme = ThemeController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        theme.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await _pumpScreen(
        tester,
        const PlayerScreen(),
        player,
        theme,
        const Size(640, 360),
      );
      expect(find.text('正在播放'), findsOneWidget);
      expect(find.text('第一句歌词'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      final controlsRect = tester.getRect(
        find.byKey(const ValueKey('landscape-player-controls')),
      );
      final lyricsRect = tester.getRect(
        find.byKey(const ValueKey('landscape-player-lyrics')),
      );
      final coverRect = tester.getRect(
        find.byKey(const ValueKey('landscape-player-cover')),
      );
      final buttonsRect = tester.getRect(
        find.byKey(const ValueKey('landscape-player-buttons')),
      );
      expect(controlsRect.right, lessThanOrEqualTo(lyricsRect.left));
      expect(coverRect.bottom, lessThanOrEqualTo(buttonsRect.top));
      _expectNoException(tester);

      await tester.tap(find.byTooltip('歌词字号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('大').last);
      await tester.pumpAndSettle();
      final enlargedLyric = tester.widget<Text>(find.text('第一句歌词'));
      expect(enlargedLyric.style?.fontSize, 20);

      _setViewSize(tester, const Size(1125, 651));
      await tester.pumpAndSettle();
      expect(find.text('第一句歌词'), findsOneWidget);
      _expectNoException(tester);

      await tester.tap(find.byTooltip('播放队列'));
      await tester.pumpAndSettle();
      expect(find.text('播放队列 (1)'), findsOneWidget);
      _expectNoException(tester);
    }, _mockClient);
  });

  testWidgets('main shell switches navigation and player placement', (
    tester,
  ) async {
    await http.runWithClient(() async {
      final player = PlayerProvider();
      final theme = ThemeController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        theme.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await player.playSingle(
        SongSearchResult(
          platform: MusicPlatform.netease,
          id: '2',
          name: '主界面测试歌曲',
          artist: '测试歌手',
          album: '测试专辑',
        ),
      );
      await _pumpScreen(
        tester,
        const MainScreen(),
        player,
        theme,
        const Size(1280, 800),
      );
      expect(find.byType(NavigationRail), findsOneWidget);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.labelType, NavigationRailLabelType.all);
      expect(find.text('库仔音乐'), findsOneWidget);
      expect(find.text('发现'), findsWidgets);
      expect(find.text('搜索'), findsWidgets);
      expect(find.text('歌单'), findsWidgets);
      expect(find.text('设置'), findsWidgets);
      expect(find.text('检查更新'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(LandscapeMiniPlayer), findsOneWidget);
      _expectNoException(tester);

      _setViewSize(tester, const Size(390, 844));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(LandscapeMiniPlayer), findsNothing);
      expect(find.byType(MiniPlayer), findsOneWidget);
      _expectNoException(tester);
    }, _mockClient);
  });

  testWidgets('first landscape player pane preserves search state', (
    tester,
  ) async {
    await http.runWithClient(() async {
      final player = _ControllablePlayer();
      final theme = ThemeController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        theme.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await _pumpScreen(
        tester,
        const MainScreen(),
        player,
        theme,
        const Size(1280, 800),
      );
      await tester.tap(find.text('搜索').first);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '周杰伦');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '周杰伦',
      );

      player.showSong();
      await tester.pumpAndSettle();

      expect(find.byType(LandscapeMiniPlayer), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '周杰伦',
      );
      expect(find.text('没有找到结果'), findsOneWidget);
      _expectNoException(tester);
    }, _mockClient);
  });

  testWidgets('search loads platforms on demand', (tester) async {
    final requestedPaths = <String>[];
    await http.runWithClient(
      () async {
        final player = PlayerProvider();
        final theme = ThemeController();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          player.dispose();
          theme.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await _pumpScreen(
          tester,
          const SearchScreen(),
          player,
          theme,
          const Size(800, 360),
        );
        await tester.enterText(find.byType(TextField), '周杰伦');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        expect(
          requestedPaths.where((path) => path.startsWith('/api-qq/')).length,
          2,
        );
        expect(
          requestedPaths.any((path) => path.startsWith('/api-netease/')),
          isFalse,
        );
        expect(
          requestedPaths.any((path) => path.startsWith('/api-kugou-search/')),
          isFalse,
        );

        await tester.tap(find.text('网易云').first);
        await tester.pumpAndSettle();

        expect(
          requestedPaths
              .where((path) => path.startsWith('/api-netease/'))
              .length,
          2,
        );
        expect(
          requestedPaths.any((path) => path.startsWith('/api-kugou-search/')),
          isFalse,
        );
        _expectNoException(tester);
      },
      () {
        return MockClient((request) async {
          requestedPaths.add(request.url.path);
          return http.Response(
            '{}',
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        });
      },
    );
  });

  testWidgets('compact landscape navigation fits without crowding', (
    tester,
  ) async {
    await http.runWithClient(() async {
      final player = PlayerProvider();
      final theme = ThemeController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        theme.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await _pumpScreen(
        tester,
        const MainScreen(),
        player,
        theme,
        const Size(640, 360),
      );

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.minWidth, 88);
      expect(rail.labelType, NavigationRailLabelType.all);
      expect(
        find.byKey(const ValueKey('landscape-navigation')),
        findsOneWidget,
      );
      _expectNoException(tester);
    }, _mockClient);
  });
}

Future<void> _pumpScreen(
  WidgetTester tester,
  Widget screen,
  PlayerProvider player,
  ThemeController theme,
  Size size,
) async {
  _setViewSize(tester, size);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider(create: (_) => FavoriteService()),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: screen),
    ),
  );
  await tester.pumpAndSettle();
}

void _setViewSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
}

http.Client _mockClient() {
  return MockClient((request) async {
    return http.Response(
      '{}',
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  });
}

void _expectNoException(WidgetTester tester) {
  expect(tester.takeException(), isNull);
}

class _PlayerWithLyrics extends PlayerProvider {
  final PlayQueueItem _song = PlayQueueItem(
    platform: MusicPlatform.netease,
    id: '1',
    name: '横屏测试歌曲',
    artist: '测试歌手',
    album: '测试专辑',
  );

  late final List<LyricLine> _testLyrics = [
    LyricLine(Duration.zero, '第一句歌词'),
    LyricLine(const Duration(seconds: 10), '第二句歌词'),
  ];

  @override
  PlayQueueItem? get currentSong => _song;

  @override
  List<PlayQueueItem> get queue => [_song];

  @override
  int get currentIndex => 0;

  @override
  List<LyricLine> get lyrics => _testLyrics;
}

class _ControllablePlayer extends PlayerProvider {
  PlayQueueItem? _currentSong;

  void showSong() {
    _currentSong = PlayQueueItem(
      platform: MusicPlatform.qq,
      id: 'first-song',
      name: '首次播放测试歌曲',
      artist: '测试歌手',
      album: '测试专辑',
    );
    notifyListeners();
  }

  @override
  PlayQueueItem? get currentSong => _currentSong;

  @override
  List<PlayQueueItem> get queue => [if (_currentSong != null) _currentSong!];

  @override
  int get currentIndex => _currentSong == null ? -1 : 0;
}
