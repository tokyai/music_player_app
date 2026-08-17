import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/main.dart' show MainScreen;
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/screens/discover_screen.dart';
import 'package:music_player_app/screens/favorites_screen.dart';
import 'package:music_player_app/screens/player_screen.dart';
import 'package:music_player_app/screens/playlist_detail_screen.dart';
import 'package:music_player_app/screens/playlist_screen.dart';
import 'package:music_player_app/screens/search_screen.dart';
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_layout.dart';
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
        const DiscoverScreen(),
        player,
        theme,
        const Size(1280, 800),
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
        const SearchScreen(),
        player,
        theme,
        const Size(1280, 800),
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

      await tester.tap(find.byTooltip('导入歌单'));
      await tester.pumpAndSettle();
      expect(find.text('导入歌单'), findsOneWidget);
      _expectNoException(tester);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();

      await _pumpScreen(
        tester,
        const PlaylistScreen(),
        player,
        theme,
        const Size(1280, 800),
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

      await _pumpScreen(
        tester,
        PlaylistDetailScreen(
          playlist: PlaylistInfo(
            id: '42-wide',
            name: '宽屏测试歌单',
            creator: '测试用户',
            trackCount: 0,
            tracks: const [],
          ),
          platform: MusicPlatform.qq,
        ),
        player,
        theme,
        const Size(1280, 800),
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

  testWidgets('search results survive player route and shell rotation', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
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
          const Size(390, 844),
        );
        await tester.tap(find.text('搜索').first);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '保留搜索');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.text('保留结果'), findsOneWidget);

        await tester.tap(find.text('保留结果'));
        await tester.pumpAndSettle();
        expect(find.byType(MiniPlayer), findsOneWidget);
        await tester.tap(find.byType(MiniPlayer));
        await tester.pumpAndSettle();
        expect(find.byType(PlayerScreen), findsOneWidget);

        _setViewSize(tester, const Size(640, 360));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('player-back')).hitTestable(),
        );
        await tester.pumpAndSettle();

        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          '保留搜索',
        );
        expect(find.text('保留结果'), findsWidgets);
        _expectNoException(tester);
      },
      () => MockClient((request) async {
        final params = _qqSearchParams(request);
        if (params == null) return http.Response('{}', 200);
        return _qqSearchResponse(
          songs: params['search_type'] == 0
              ? [
                  {
                    'songmid': 'preserved-song',
                    'songname': '保留结果',
                    'singer': [
                      {'name': '测试歌手'},
                    ],
                    'albumname': '测试专辑',
                  },
                ]
              : const [],
        );
      }),
    );
  });

  testWidgets('clearing the query keeps the current search results', (
    tester,
  ) async {
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
          const Size(640, 360),
        );
        await tester.enterText(find.byType(TextField), '保留搜索');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.text('保留结果'), findsOneWidget);

        await tester.tap(find.byIcon(Icons.clear));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          isEmpty,
        );
        expect(find.text('保留结果'), findsOneWidget);
        _expectNoException(tester);
      },
      () => MockClient((request) async {
        final params = _qqSearchParams(request);
        if (params == null) return http.Response('{}', 200);
        return _qqSearchResponse(
          songs: params['search_type'] == 0
              ? [
                  {
                    'songmid': 'clear-result',
                    'songname': '保留结果',
                    'singer': [
                      {'name': '测试歌手'},
                    ],
                    'albumname': '测试专辑',
                  },
                ]
              : const [],
        );
      }),
    );
  });

  testWidgets('landscape player opens song, artist and album searches', (
    tester,
  ) async {
    final requestedKeywords = <String>[];
    await http.runWithClient(
      () async {
        final player = _ControllablePlayer()..showSong();
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
        await tester.tap(find.byType(MiniPlayer));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('player-song-search')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('player-artist-search')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('player-album-search')).hitTestable(),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const ValueKey('player-song-search')).hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SearchScreen), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          '首次播放测试歌曲',
        );
        expect(find.text('首次播放测试歌曲 (Live)'), findsOneWidget);
        expect(find.text('不相关曲目'), findsNothing);

        await tester.tap(find.byType(MiniPlayer));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('player-artist-search')).hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SearchScreen), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          '测试歌手',
        );

        await tester.tap(find.byType(MiniPlayer));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('player-album-search')).hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          '测试专辑',
        );
        expect(find.text('专辑曲目一'), findsOneWidget);
        expect(find.text('专辑曲目二'), findsOneWidget);
        expect(find.text('其他专辑曲目'), findsNothing);
        expect(
          requestedKeywords,
          containsAllInOrder(['首次播放测试歌曲', '测试歌手', '测试专辑']),
        );
        _expectNoException(tester);
      },
      () => MockClient((request) async {
        final params = _qqSearchParams(request);
        final keyword = params?['query']?.toString();
        if (params != null && params['search_type'] == 0 && keyword != null) {
          requestedKeywords.add(keyword);
          final songs = keyword == '首次播放测试歌曲'
              ? [
                  {
                    'songmid': 'title-track-1',
                    'songname': '首次播放测试歌曲',
                    'singer': [
                      {'name': '测试歌手'},
                    ],
                    'albumname': '测试专辑',
                  },
                  {
                    'songmid': 'title-track-2',
                    'songname': '首次播放测试歌曲 (Live)',
                    'singer': [
                      {'name': '测试歌手'},
                    ],
                    'albumname': '现场专辑',
                  },
                  {
                    'songmid': 'unrelated-title',
                    'songname': '不相关曲目',
                    'singer': [
                      {'name': '测试歌手'},
                    ],
                    'albumname': '测试专辑',
                  },
                ]
              : keyword == '测试专辑'
              ? [
                  {
                    'songmid': 'album-track-1',
                    'songname': '专辑曲目一',
                    'singer': [
                      {'name': '测试歌手'},
                    ],
                    'albumname': '测试专辑',
                  },
                  {
                    'songmid': 'album-track-2',
                    'songname': '专辑曲目二',
                    'singer': [
                      {'name': '测试歌手'},
                    ],
                    'albumname': '测试专辑',
                  },
                  {
                    'songmid': 'other-album-track',
                    'songname': '其他专辑曲目',
                    'singer': [
                      {'name': '测试歌手'},
                    ],
                    'albumname': '其他专辑',
                  },
                ]
              : <Map<String, dynamic>>[];
          return _qqSearchResponse(songs: songs);
        }
        return http.Response('{}', 200);
      }),
    );
  });

  testWidgets(
    'landscape MV action resolves and opens the current platform MV',
    (tester) async {
      const channel = MethodChannel('music_player/external_media');
      String? openedUrl;
      final requestedUrls = <Uri>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'playVideo');
        openedUrl = (call.arguments as Map)['url']?.toString();
        return true;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });

      await http.runWithClient(
        () async {
          final player = _ControllablePlayer()..showSong();
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
          expect(find.text('MV').hitTestable(), findsOneWidget);
          await tester.tap(find.text('MV').hitTestable());
          await tester.pumpAndSettle();

          expect(
            requestedUrls.map((url) => url.host),
            containsAllInOrder(['161.118.252.183', 'u.y.qq.com']),
          );
          expect(openedUrl, 'https://video.test/current-song.mp4');
          _expectNoException(tester);
        },
        () => MockClient((request) async {
          requestedUrls.add(request.url);
          if (request.url.path == '/api-qq/search') {
            return http.Response(
              jsonEncode({
                'data': {
                  'list': [
                    {
                      'songmid': 'first-song',
                      'songname': '首次播放测试歌曲',
                      'singer': [
                        {'name': '测试歌手'},
                      ],
                      'vid': 'current-vid',
                    },
                  ],
                },
              }),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }
          if (request.url.host == 'u.y.qq.com') {
            return http.Response(
              jsonEncode({
                'getMvUrl': {
                  'data': {
                    'current-vid': {
                      'mp4': [
                        {
                          'freeflow_url': [
                            'https://video.test/current-song.mp4',
                          ],
                        },
                      ],
                    },
                  },
                },
              }),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }
          return http.Response('{}', 200);
        }),
      );
      expect(
        requestedUrls.map((url) => url.host),
        containsAllInOrder(['161.118.252.183', 'u.y.qq.com']),
      );
    },
  );

  testWidgets('home favorites is a landscape carousel and opens its page', (
    tester,
  ) async {
    final favorites = [
      SongSearchResult(
        platform: MusicPlatform.qq,
        id: 'favorite-1',
        name: '收藏歌曲一',
        artist: '收藏歌手一',
        album: '收藏专辑',
      ),
      SongSearchResult(
        platform: MusicPlatform.netease,
        id: 'favorite-2',
        name: '收藏歌曲二',
        artist: '收藏歌手二',
        album: '收藏专辑',
      ),
    ];
    final favoritePlaylist = FavoritePlaylist(
      platform: MusicPlatform.qq,
      playlist: PlaylistInfo(
        id: 'favorite-playlist-1',
        name: '收藏歌单一',
        coverUrl: 'https://example.com/playlist.jpg',
        creator: '歌单作者',
        trackCount: 12,
        tracks: const [],
      ),
    );
    SharedPreferences.setMockInitialValues({
      'favorites': jsonEncode(favorites.map((song) => song.toJson()).toList()),
      'favorite_playlists': jsonEncode([favoritePlaylist.toJson()]),
    });

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

      final carousel = tester.widget<ListView>(
        find.byKey(const ValueKey('home-favorites-carousel')),
      );
      expect(carousel.scrollDirection, Axis.horizontal);
      expect(find.text('收藏歌曲一'), findsOneWidget);
      expect(find.text('收藏歌手一'), findsOneWidget);
      expect(find.text('收藏歌单'), findsOneWidget);
      expect(find.text('收藏歌单一'), findsOneWidget);
      expect(find.text('QQ音乐推荐歌单'), findsNothing);
      expect(find.text('网易云热门歌单'), findsNothing);
      expect(find.text('酷狗新歌速递'), findsNothing);
      expect(
        tester
            .widget<ListView>(
              find.byKey(const ValueKey('home-favorite-playlists-carousel')),
            )
            .scrollDirection,
        Axis.horizontal,
      );
      expect(
        find.byKey(const ValueKey('home-favorites-header')).hitTestable(),
        findsOneWidget,
      );
      _expectNoException(tester);

      await tester.tap(
        find.byKey(const ValueKey('home-favorites-header')).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FavoritesScreen), findsOneWidget);
      _expectNoException(tester);
    }, _mockClient);
  });

  testWidgets('playlist details can save a playlist to the favorites section', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    final theme = ThemeController();
    final favorites = FavoriteService();
    final playlist = PlaylistInfo(
      id: 'detail-favorite-playlist',
      name: '详情收藏歌单',
      creator: '歌单作者',
      trackCount: 8,
      tracks: const [],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      theme.dispose();
      favorites.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await http.runWithClient(() async {
      _setViewSize(tester, const Size(640, 360));
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<ThemeController>.value(value: theme),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: PlaylistDetailScreen(
              playlist: playlist,
              platform: MusicPlatform.qq,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('playlist-favorite-button')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('playlist-favorite-button')).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(favorites.favoritePlaylists, hasLength(1));

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<ThemeController>.value(value: theme),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const FavoritesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(VerticalDivider), findsOneWidget);
      expect(
        find.byKey(const ValueKey('favorites-playlists-section')),
        findsOneWidget,
      );
      expect(find.text('详情收藏歌单'), findsOneWidget);
      expect(find.byTooltip('取消收藏歌单'), findsOneWidget);
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
      expect(find.text('收藏').hitTestable(), findsOneWidget);
      expect(find.text('MV').hitTestable(), findsOneWidget);
      expect(find.text('字号'), findsNothing);
      expect(find.byTooltip('歌词字号').hitTestable(), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.byKey(const ValueKey('landscape-player-divider')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.text('第一句歌词')).textAlign,
        TextAlign.center,
      );

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
      final nextRect = tester.getRect(
        find.byKey(const ValueKey('player-next-track')),
      );
      final fontRect = tester.getRect(
        find.byKey(const ValueKey('player-lyric-font-action')),
      );
      final songNameRect = tester.getRect(
        find.byKey(const ValueKey('player-song-search')),
      );
      expect(controlsRect.right, lessThanOrEqualTo(lyricsRect.left));
      expect(songNameRect.center.dx, closeTo(controlsRect.center.dx, 1));
      expect(coverRect.bottom, lessThanOrEqualTo(buttonsRect.top));
      expect(fontRect.left, greaterThanOrEqualTo(nextRect.right - 1));
      _expectNoException(tester);

      await tester.tap(find.byTooltip('歌词字号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('大 · 48').last);
      await tester.pumpAndSettle();
      final enlargedLyric = tester.widget<Text>(find.text('第一句歌词'));
      expect(enlargedLyric.style?.fontSize, 48);

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

  testWidgets('landscape player split resizes and persists safely', (
    tester,
  ) async {
    await http.runWithClient(() async {
      SharedPreferences.setMockInitialValues({
        'player_landscape_split_ratio': 0.5,
      });
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
        const Size(1280, 800),
      );
      final divider = find.byKey(const ValueKey('landscape-player-divider'));
      final controls = find.byKey(const ValueKey('landscape-player-controls'));
      final initialWidth = tester.getSize(controls).width;

      await tester.drag(divider, const Offset(-110, 0));
      await tester.pumpAndSettle();
      final resizedWidth = tester.getSize(controls).width;
      expect(resizedWidth, lessThan(initialWidth - 80));
      expect(
        tester.widget<Text>(find.text('第一句歌词')).textAlign,
        TextAlign.center,
      );
      expect(tester.widget<Text>(find.text('横屏测试歌曲')).maxLines, 1);
      _expectNoException(tester);

      final prefs = await SharedPreferences.getInstance();
      final savedRatio = prefs.getDouble('player_landscape_split_ratio');
      expect(savedRatio, isNotNull);
      expect(savedRatio!, lessThan(0.5));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _pumpScreen(
        tester,
        const PlayerScreen(),
        player,
        theme,
        const Size(1280, 800),
      );
      expect(tester.getSize(controls).width, closeTo(resizedWidth, 1));
      expect(find.text('MV').hitTestable(), findsOneWidget);
      expect(find.byTooltip('歌词字号').hitTestable(), findsOneWidget);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('player-lyric-font-action')))
            .left,
        greaterThanOrEqualTo(
          tester
                  .getRect(find.byKey(const ValueKey('player-next-track')))
                  .right -
              1,
        ),
      );

      _setViewSize(tester, const Size(640, 360));
      await tester.pumpAndSettle();
      expect(divider.hitTestable(), findsOneWidget);
      expect(tester.widget<Text>(find.text('第一句歌词')).maxLines, 1);
      expect(
        tester.widget<Text>(find.text('第一句歌词')).textAlign,
        TextAlign.center,
      );
      _expectNoException(tester);
    }, _mockClient);
  });

  testWidgets('lyric font size persists for every song and player screen', (
    tester,
  ) async {
    await http.runWithClient(() async {
      SharedPreferences.setMockInitialValues({});
      final firstPlayer = _PlayerWithLyrics();
      final secondPlayer = _SecondPlayerWithLyrics();
      final theme = ThemeController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        firstPlayer.dispose();
        secondPlayer.dispose();
        theme.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await _pumpScreen(
        tester,
        const PlayerScreen(),
        firstPlayer,
        theme,
        const Size(1280, 800),
      );
      await tester.tap(find.byTooltip('歌词字号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最大 · 60').last);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('第一句歌词')).style?.fontSize, 60);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_font_size'), 60);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _pumpScreen(
        tester,
        const PlayerScreen(),
        secondPlayer,
        theme,
        const Size(640, 360),
      );
      expect(find.text('另一首横屏测试歌曲'), findsOneWidget);
      expect(tester.widget<Text>(find.text('第一句歌词')).style?.fontSize, 60);
      expect(find.text('收藏').hitTestable(), findsOneWidget);
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

  testWidgets('search loads official platforms on demand', (tester) async {
    final requestedUrls = <Uri>[];
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
          requestedUrls.where((url) => url.host == 'u.y.qq.com').length,
          2,
        );
        expect(
          requestedUrls.any((url) => url.host == 'interface.music.163.com'),
          isFalse,
        );
        expect(
          requestedUrls.any((url) => url.host == 'mobilecdn.kugou.com'),
          isFalse,
        );

        await tester.tap(find.text('网易云').first);
        await tester.pumpAndSettle();

        expect(
          requestedUrls
              .where((url) => url.host == 'interface.music.163.com')
              .length,
          2,
        );
        expect(
          requestedUrls.any((url) => url.host == 'mobilecdn.kugou.com'),
          isFalse,
        );
        _expectNoException(tester);
      },
      () {
        return MockClient((request) async {
          requestedUrls.add(request.url);
          final qqParams = _qqSearchParams(request);
          if (qqParams != null) return _qqSearchResponse();
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
      expect(rail.minWidth, 96);
      expect(rail.labelType, NavigationRailLabelType.all);
      expect(
        find.byKey(const ValueKey('landscape-navigation')),
        findsOneWidget,
      );
      _expectNoException(tester);
    }, _mockClient);
  });

  testWidgets('per-platform playback sources persist in both landscapes', (
    tester,
  ) async {
    await http.runWithClient(() async {
      SharedPreferences.setMockInitialValues({
        'playback_source_qq': PlaybackSource.qingMusic.value,
      });
      final player = PlayerProvider();
      final theme = ThemeController();
      await player.settingsReady;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        theme.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      expect(
        player.playbackSourceFor(MusicPlatform.qq),
        PlaybackSource.qingMusic,
      );
      expect(
        player.playbackSourceFor(MusicPlatform.netease),
        PlaybackSource.chksz,
      );

      await _pumpScreen(
        tester,
        const SettingsScreen(),
        player,
        theme,
        const Size(640, 360),
      );
      final qqSource = find.byKey(const ValueKey('playback-source-qq'));
      await tester.ensureVisible(qqSource);
      await tester.pumpAndSettle();
      expect(qqSource.hitTestable(), findsOneWidget);
      expect(tester.widget<Text>(find.text('QQ音乐播放源')).maxLines, 1);
      await tester.tap(qqSource);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('playback-source-qq-chksz')));
      await tester.pumpAndSettle();
      expect(player.playbackSourceFor(MusicPlatform.qq), PlaybackSource.chksz);
      _expectNoException(tester);

      await _pumpScreen(
        tester,
        const SettingsScreen(),
        player,
        theme,
        const Size(1280, 800),
      );
      final neteaseSource = find.byKey(const ValueKey('playback-source-163'));
      await tester.ensureVisible(neteaseSource);
      await tester.tap(neteaseSource);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('playback-source-163-qing_music')),
      );
      await tester.pumpAndSettle();
      expect(
        player.playbackSourceFor(MusicPlatform.netease),
        PlaybackSource.qingMusic,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('playback_source_qq'), 'chksz');
      expect(prefs.getString('playback_source_netease'), 'qing_music');
      expect(prefs.getString('playback_source_kugou'), isNull);
      _expectNoException(tester);
    }, _mockClient);
  });

  testWidgets(
    'global font scale is live, persistent, and usable in landscape',
    (tester) async {
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
          const SettingsScreen(),
          player,
          theme,
          const Size(390, 844),
        );
        final initialScale = MediaQuery.textScalerOf(
          tester.element(find.byType(SettingsScreen)),
        ).scale(16);
        expect(theme.fontScale, ThemeController.defaultFontScale);
        expect(find.text('100%'), findsOneWidget);

        final sliderFinder = find.byKey(const ValueKey('font-scale-slider'));
        final sliderRect = tester.getRect(sliderFinder);
        await tester.tapAt(Offset(sliderRect.right - 8, sliderRect.center.dy));
        await tester.pumpAndSettle();

        expect(theme.fontScale, ThemeController.maxFontScale);
        expect(find.text('130%'), findsAtLeastNWidgets(2));
        expect(
          MediaQuery.textScalerOf(
            tester.element(find.byType(SettingsScreen)),
          ).scale(16),
          closeTo(initialScale * ThemeController.maxFontScale, 0.01),
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getDouble('font_scale'), ThemeController.maxFontScale);
        _expectNoException(tester);

        for (final size in const [Size(640, 360), Size(1280, 800)]) {
          _setViewSize(tester, size);
          await tester.pumpAndSettle();
          final sliderFinder = find.byKey(const ValueKey('font-scale-slider'));
          await tester.ensureVisible(sliderFinder);
          await tester.pumpAndSettle();
          expect(sliderFinder.hitTestable(), findsOneWidget);
          expect(
            find.byKey(const ValueKey('font-scale-value')),
            findsOneWidget,
          );
          _expectNoException(tester);
        }

        final restoredTheme = ThemeController();
        addTearDown(restoredTheme.dispose);
        await _pumpScreen(
          tester,
          const SettingsScreen(),
          player,
          restoredTheme,
          const Size(1280, 800),
        );
        expect(restoredTheme.fontScale, ThemeController.maxFontScale);
        expect(
          tester
              .widget<Slider>(find.byKey(const ValueKey('font-scale-slider')))
              .value,
          ThemeController.maxFontScale,
        );

        final reset = find.byTooltip('恢复默认字号');
        await tester.ensureVisible(reset);
        await tester.tap(reset);
        await tester.pumpAndSettle();
        expect(restoredTheme.fontScale, ThemeController.defaultFontScale);
        expect(prefs.getDouble('font_scale'), ThemeController.defaultFontScale);
        _expectNoException(tester);
      }, _mockClient);
    },
  );

  testWidgets('1920x1080 car display keeps wide panes and readable controls', (
    tester,
  ) async {
    await http.runWithClient(() async {
      SharedPreferences.setMockInitialValues({
        'favorites': jsonEncode([
          SongSearchResult(
            platform: MusicPlatform.qq,
            id: 'car-favorite',
            name: '车机收藏歌曲',
            artist: '测试歌手',
            album: '测试专辑',
          ).toJson(),
        ]),
      });
      final player = _PlayerWithLyrics();
      final theme = ThemeController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        theme.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const carSize = Size(1920, 1080);
      await _pumpScreen(tester, const MainScreen(), player, theme, carSize);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(LandscapeMiniPlayer), findsOneWidget);
      final rail = tester.widget<NavigationRail>(
        find.byKey(const ValueKey('landscape-navigation')),
      );
      expect(rail.minWidth, 132);
      final sidePlayer = tester.getRect(find.byType(LandscapeMiniPlayer));
      expect(sidePlayer.width, closeTo(296, 0.1));
      expect(sidePlayer.height, closeTo(1080, 0.1));
      _expectNoException(tester);

      for (final screen in <Widget>[
        const DiscoverScreen(),
        const SearchScreen(),
        const PlaylistScreen(),
        PlaylistDetailScreen(
          playlist: PlaylistInfo(
            id: 'car-playlist',
            name: '车机歌单',
            creator: '测试用户',
            trackCount: 0,
            tracks: const [],
          ),
          platform: MusicPlatform.qq,
        ),
        const FavoritesScreen(),
        const SettingsScreen(),
      ]) {
        await _pumpScreen(tester, screen, player, theme, carSize);
        expect(find.byType(VerticalDivider), findsOneWidget);
        _expectNoException(tester);
      }

      await _pumpScreen(tester, const PlayerScreen(), player, theme, carSize);
      final controlsRect = tester.getRect(
        find.byKey(const ValueKey('landscape-player-controls')),
      );
      final lyricsRect = tester.getRect(
        find.byKey(const ValueKey('landscape-player-lyrics')),
      );
      final coverRect = tester.getRect(
        find.byKey(const ValueKey('landscape-player-cover')),
      );
      final songNameRect = tester.getRect(
        find.byKey(const ValueKey('player-song-search')),
      );
      expect(controlsRect.right, lessThanOrEqualTo(lyricsRect.left));
      expect(songNameRect.center.dx, closeTo(controlsRect.center.dx, 1));
      expect(coverRect.width, greaterThanOrEqualTo(300));
      expect(find.text('第一句歌词'), findsOneWidget);
      final lyric = tester.widget<Text>(find.text('第一句歌词'));
      expect(lyric.style?.fontSize, 42);
      expect(lyric.style?.height, 1.25);
      final firstLyricRect = tester.getRect(find.text('第一句歌词'));
      final secondLyricRect = tester.getRect(find.text('第二句歌词'));
      expect(
        secondLyricRect.top - firstLyricRect.top,
        greaterThanOrEqualTo(64),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('player-song-search'))).height,
        greaterThanOrEqualTo(52),
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('player-artist-search')))
            .height,
        greaterThanOrEqualTo(52),
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('player-album-search')))
            .height,
        greaterThanOrEqualTo(48),
      );
      final artistText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('player-artist-search')),
          matching: find.text('测试歌手'),
        ),
      );
      final albumText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('player-album-search')),
          matching: find.text('测试专辑'),
        ),
      );
      expect(artistText.style?.fontSize, 20);
      expect(albumText.style?.fontSize, 20);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('player-lyric-font-action')))
            .left,
        lessThan(lyricsRect.left),
      );
      expect(find.text('收藏').hitTestable(), findsOneWidget);
      expect(find.text('MV').hitTestable(), findsOneWidget);
      expect(find.text('字号'), findsNothing);
      expect(find.byTooltip('歌词字号').hitTestable(), findsOneWidget);
      expect(find.text('歌词').hitTestable(), findsNothing);
      _expectNoException(tester);
    }, _mockClient);
  });

  testWidgets('1920x1080 physical display remains usable at 2x density', (
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
        const MainScreen(),
        player,
        theme,
        const Size(1920, 1080),
        devicePixelRatio: 2,
      );
      final mediaQuery = tester.widget<MediaQuery>(
        find.byType(MediaQuery).first,
      );
      expect(mediaQuery.data.size, const Size(960, 540));
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(MainScreen)),
        ).scale(16),
        closeTo(18.88, 0.1),
      );
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(find.text('发现'), findsWidgets);
      _expectNoException(tester);

      await _pumpScreen(
        tester,
        const PlayerScreen(),
        player,
        theme,
        const Size(1920, 1080),
        devicePixelRatio: 2,
      );
      final playerLayout = AppLayout.fromContext(
        tester.element(find.byType(PlayerScreen)),
      );
      expect(playerLayout.isHighDensityCarDisplay, isTrue);
      expect(playerLayout.usesLargeTypography, isTrue);
      expect(find.text('第一句歌词'), findsOneWidget);
      expect(find.text('收藏').hitTestable(), findsOneWidget);
      expect(find.text('MV').hitTestable(), findsOneWidget);
      expect(find.byTooltip('歌词字号').hitTestable(), findsOneWidget);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('player-lyric-font-action')))
            .height,
        greaterThanOrEqualTo(54),
      );
      final carFirstLyric = tester.getRect(find.text('第一句歌词'));
      final carSecondLyric = tester.getRect(find.text('第二句歌词'));
      expect(carSecondLyric.top - carFirstLyric.top, greaterThanOrEqualTo(64));
      expect(
        tester
            .getRect(find.byKey(const ValueKey('landscape-player-controls')))
            .right,
        lessThanOrEqualTo(
          tester
              .getRect(find.byKey(const ValueKey('landscape-player-lyrics')))
              .left,
        ),
      );
      _expectNoException(tester);
    }, _mockClient);
  });

  testWidgets('wide landscape custom surfaces follow live theme changes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final player = _PlayerWithLyrics();
    final theme = ThemeController();
    await theme.setMode(ThemeMode.light);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      theme.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    _setViewSize(tester, const Size(1920, 1080));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider(create: (_) => SearchSession()),
          ChangeNotifierProvider<ThemeController>.value(value: theme),
          ChangeNotifierProvider(create: (_) => FavoriteService()),
        ],
        child: Consumer<ThemeController>(
          builder: (context, controller, _) {
            return MaterialApp(
              theme: AppTheme.light(),
              darkTheme: AppTheme.dark(),
              themeMode: controller.mode,
              builder: (context, child) {
                AppColors.isDark =
                    Theme.of(context).brightness == Brightness.dark;
                return child!;
              },
              home: const MainScreen(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').hitTestable());
    await tester.pumpAndSettle();

    expect(
      _decoratedSurfaceCount(tester, const Color(0xFFFFFFFF)),
      greaterThan(0),
    );
    expect(
      _playerSurfaceCount(tester, const Color(0xFFFFFFFF)),
      greaterThan(0),
    );

    await theme.setMode(ThemeMode.dark);
    await tester.pumpAndSettle();

    expect(
      Theme.of(tester.element(find.byType(SettingsScreen))).brightness,
      Brightness.dark,
    );
    expect(
      _decoratedSurfaceCount(tester, const Color(0xFF181B20)),
      greaterThan(0),
    );
    expect(_decoratedSurfaceCount(tester, const Color(0xFFFFFFFF)), 0);
    expect(
      _playerSurfaceCount(tester, const Color(0xFF181B20)),
      greaterThan(0),
    );
    expect(_playerSurfaceCount(tester, const Color(0xFFFFFFFF)), 0);
    _expectNoException(tester);
  });

  testWidgets('portrait custom surfaces follow live theme changes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final player = _PlayerWithLyrics();
    final theme = ThemeController();
    await theme.setMode(ThemeMode.light);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      theme.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    _setViewSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider(create: (_) => SearchSession()),
          ChangeNotifierProvider<ThemeController>.value(value: theme),
          ChangeNotifierProvider(create: (_) => FavoriteService()),
        ],
        child: Consumer<ThemeController>(
          builder: (context, controller, _) => MaterialApp(
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: controller.mode,
            builder: (context, child) {
              AppColors.syncWithTheme(context);
              return child!;
            },
            home: const MainScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').hitTestable());
    await tester.pumpAndSettle();
    expect(
      _decoratedSurfaceCount(tester, const Color(0xFFFFFFFF)),
      greaterThan(0),
    );

    await theme.setMode(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(
      _decoratedSurfaceCount(tester, const Color(0xFF181B20)),
      greaterThan(0),
    );
    expect(_decoratedSurfaceCount(tester, const Color(0xFFFFFFFF)), 0);

    await theme.setMode(ThemeMode.light);
    await tester.pumpAndSettle();
    expect(
      _decoratedSurfaceCount(tester, const Color(0xFFFFFFFF)),
      greaterThan(0),
    );
    expect(_decoratedSurfaceCount(tester, const Color(0xFF181B20)), 0);
    _expectNoException(tester);
  });

  testWidgets('playlist detail requests and appends twenty-song pages', (
    tester,
  ) async {
    final offsets = <int>[];
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
          PlaylistDetailScreen(
            playlist: PlaylistInfo(
              id: 'paged-playlist',
              name: '分页歌单',
              trackCount: 45,
              tracks: const [],
            ),
            platform: MusicPlatform.netease,
          ),
          player,
          theme,
          const Size(640, 360),
        );
        expect(offsets, [0]);
        final listFinder = find.byKey(
          const PageStorageKey('playlist-detail-tracks'),
        );
        expect(listFinder, findsOneWidget);
        var list = tester.widget<ListView>(listFinder);
        expect(
          (list.childrenDelegate as SliverChildBuilderDelegate).childCount,
          21,
        );

        await tester.fling(listFinder, const Offset(0, -1800), 2600);
        await tester.pumpAndSettle();
        expect(offsets, contains(20));
        list = tester.widget<ListView>(listFinder);
        final loadedCount =
            (list.childrenDelegate as SliverChildBuilderDelegate).childCount!;
        expect(loadedCount, greaterThan(21));
        _expectNoException(tester);
      },
      () => MockClient((request) async {
        if (request.url.path == '/api/v6/playlist/detail') {
          return http.Response(
            jsonEncode({
              'code': 200,
              'playlist': {
                'trackCount': 45,
                'trackIds': List.generate(45, (index) => {'id': index + 1}),
              },
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path != '/api/song/detail') {
          return http.Response('{}', 200);
        }
        final ids = (jsonDecode(request.url.queryParameters['ids']!) as List)
            .map((id) => int.parse(id.toString()))
            .toList();
        final offset = ids.first - 1;
        offsets.add(offset);
        final songs = ids
            .map(
              (id) => {
                'id': id,
                'name': '分页歌曲 $id',
                'ar': [
                  {'name': '分页歌手'},
                ],
                'al': {'name': '分页专辑'},
              },
            )
            .toList();
        return http.Response(
          jsonEncode({'code': 200, 'songs': songs}),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
  });

  testWidgets('player keeps readable foreground colors in both themes', (
    tester,
  ) async {
    final player = _PlayerWithLyrics();
    final favorites = FavoriteService();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      favorites.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    Future<void> pumpTheme(ThemeData theme) async {
      _setViewSize(tester, const Size(640, 360));
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
          ],
          child: MaterialApp(theme: theme, home: const PlayerScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpTheme(AppTheme.dark());
    final darkLyric = tester.widget<Text>(find.text('第一句歌词'));
    expect(darkLyric.style?.color, Colors.white);
    final darkScrim = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('player-background-scrim')),
    );
    final darkGradient =
        (darkScrim.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(darkGradient.colors.first.computeLuminance(), lessThan(0.1));

    await pumpTheme(AppTheme.light());
    final lightLyric = tester.widget<Text>(find.text('第一句歌词'));
    expect(lightLyric.style?.color, const Color(0xFF171A1F));
    final lightScrim = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('player-background-scrim')),
    );
    final lightGradient =
        (lightScrim.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(lightGradient.colors.first.computeLuminance(), greaterThan(0.5));
    _expectNoException(tester);
  });
}

int _decoratedSurfaceCount(WidgetTester tester, Color color) {
  return tester.widgetList<Container>(find.byType(Container)).where((
    container,
  ) {
    final decoration = container.decoration;
    return decoration is BoxDecoration && decoration.color == color;
  }).length;
}

int _playerSurfaceCount(WidgetTester tester, Color color) {
  return tester
      .widgetList<Material>(
        find.descendant(
          of: find.byType(LandscapeMiniPlayer),
          matching: find.byType(Material),
        ),
      )
      .where((material) => material.color == color)
      .length;
}

Future<void> _pumpScreen(
  WidgetTester tester,
  Widget screen,
  PlayerProvider player,
  ThemeController theme,
  Size size, {
  double devicePixelRatio = 1,
}) async {
  _setViewSize(tester, size, devicePixelRatio: devicePixelRatio);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
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
          home: screen,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _setViewSize(
  WidgetTester tester,
  Size size, {
  double devicePixelRatio = 1,
}) {
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.physicalSize = size;
}

Map<String, dynamic>? _qqSearchParams(http.Request request) {
  if (request.url.host != 'u.y.qq.com' || request.method != 'POST') {
    return null;
  }
  final payload = jsonDecode(request.body) as Map<String, dynamic>;
  final rawRequest = payload['req_1'];
  if (rawRequest is! Map) return null;
  final rawParams = rawRequest['param'];
  return rawParams is Map ? Map<String, dynamic>.from(rawParams) : null;
}

http.Response _qqSearchResponse({
  List<Map<String, dynamic>> songs = const [],
  List<Map<String, dynamic>> playlists = const [],
}) {
  return http.Response(
    jsonEncode({
      'req_1': {
        'code': 0,
        'data': {
          'body': {
            'song': {'list': songs},
            'songlist': {'list': playlists},
          },
        },
      },
    }),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
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

class _SecondPlayerWithLyrics extends _PlayerWithLyrics {
  final PlayQueueItem _secondSong = PlayQueueItem(
    platform: MusicPlatform.qq,
    id: 'second-song',
    name: '另一首横屏测试歌曲',
    artist: '另一位歌手',
    album: '另一张专辑',
  );

  @override
  PlayQueueItem? get currentSong => _secondSong;

  @override
  List<PlayQueueItem> get queue => [_secondSong];
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
  Future<void> playSingle(SongSearchResult result) async {
    _currentSong = PlayQueueItem.fromSearchResult(result);
    notifyListeners();
  }

  @override
  PlayQueueItem? get currentSong => _currentSong;

  @override
  List<PlayQueueItem> get queue => [if (_currentSong != null) _currentSong!];

  @override
  int get currentIndex => _currentSong == null ? -1 : 0;
}
