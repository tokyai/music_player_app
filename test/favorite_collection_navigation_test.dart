import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/screens/discover_screen.dart';
import 'package:music_player_app/screens/favorites_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home arrows open the matching vertical collection page', (
    tester,
  ) async {
    final song = _song(MusicPlatform.qq, 'song-1', '首页收藏歌曲');
    final bilibili = _song(MusicPlatform.bilibili, 'video-1', '首页 B 站收藏');
    final playlist = FavoritePlaylist(
      platform: MusicPlatform.netease,
      playlist: PlaylistInfo(
        id: 'playlist-1',
        name: '首页收藏歌单',
        creator: '测试作者',
        trackCount: 8,
        tracks: const [],
      ),
    );
    SharedPreferences.setMockInitialValues({
      'favorites': jsonEncode([song.toJson(), bilibili.toJson()]),
      'favorite_playlists': jsonEncode([playlist.toJson()]),
    });

    final player = PlayerProvider();
    final favorites = FavoriteService();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      favorites.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await http.runWithClient(() async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const DiscoverScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<ListView>(
              find.byKey(const ValueKey('home-favorites-carousel')),
            )
            .scrollDirection,
        Axis.horizontal,
      );
      await tester.tap(find.text('收藏歌曲').first);
      await tester.pumpAndSettle();
      expect(find.byType(FavoriteSongsScreen), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('home-favorites-header')).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FavoriteSongsScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('favorite-songs-page-list')),
        findsOneWidget,
      );
      expect(find.text('首页收藏歌曲'), findsOneWidget);
      expect(
        tester
            .widget<ListView>(
              find.byKey(const ValueKey('favorite-songs-page-list')),
            )
            .scrollDirection,
        Axis.vertical,
      );
      expect(find.text('导入收藏'), findsNothing);
      expect(find.text('导出收藏'), findsNothing);
      expect(find.text('备份与还原'), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      final homeScroll = find
          .descendant(
            of: find.byKey(const PageStorageKey('discover-portrait-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      final playlistHeader = find.byKey(
        const ValueKey('home-favorite-playlists-header'),
      );
      await tester.scrollUntilVisible(
        playlistHeader,
        220,
        scrollable: homeScroll,
      );
      await tester.tap(playlistHeader.hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(FavoritePlaylistsScreen), findsOneWidget);
      expect(
        tester
            .widget<ListView>(
              find.byKey(const ValueKey('favorite-playlists-page-list')),
            )
            .scrollDirection,
        Axis.vertical,
      );
      expect(find.text('首页收藏歌单'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      final bilibiliHeader = find.byKey(
        const ValueKey('home-bilibili-favorites-header'),
      );
      await tester.scrollUntilVisible(
        bilibiliHeader,
        220,
        scrollable: homeScroll,
      );
      await tester.tap(bilibiliHeader.hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(BilibiliFavoritesScreen), findsOneWidget);
      expect(
        tester
            .widget<ListView>(
              find.byKey(const ValueKey('bilibili-favorites-page-list')),
            )
            .scrollDirection,
        Axis.vertical,
      );
      expect(find.text('首页 B 站收藏'), findsOneWidget);
    }, () => MockClient((_) async => http.Response('{}', 200)));
  });

  testWidgets('collection pages keep vertical lists in both landscape sizes', (
    tester,
  ) async {
    final song = _song(MusicPlatform.qq, 'landscape-song', '横屏收藏歌曲');
    final song2 = _song(MusicPlatform.netease, 'landscape-song-2', '第二首收藏歌曲');
    final bilibili = _song(
      MusicPlatform.bilibili,
      'landscape-video',
      '横屏 B 站收藏',
    );
    final bilibili2 = _song(
      MusicPlatform.bilibili,
      'landscape-video-2',
      '第二个 B 站收藏',
    );
    final playlist = FavoritePlaylist(
      platform: MusicPlatform.qq,
      playlist: PlaylistInfo(
        id: 'landscape-playlist',
        name: '横屏收藏歌单',
        creator: '作者',
        trackCount: 3,
        tracks: const [],
      ),
    );
    final playlist2 = FavoritePlaylist(
      platform: MusicPlatform.netease,
      playlist: PlaylistInfo(
        id: 'landscape-playlist-2',
        name: '第二个收藏歌单',
        creator: '作者二',
        trackCount: 5,
        tracks: const [],
      ),
    );
    SharedPreferences.setMockInitialValues({
      'favorites': jsonEncode([
        song.toJson(),
        song2.toJson(),
        bilibili.toJson(),
        bilibili2.toJson(),
      ]),
      'favorite_playlists': jsonEncode([playlist.toJson(), playlist2.toJson()]),
    });
    final player = PlayerProvider();
    final favorites = FavoriteService();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      favorites.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    for (final size in const [Size(640, 360), Size(1280, 800)]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const FavoriteSongsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final songsList = tester.widget<ListView>(
        find.byKey(const ValueKey('favorite-songs-page-list')),
      );
      expect(songsList.scrollDirection, Axis.vertical);
      final songCard = find.byKey(
        const ValueKey('favorite-song-qq-landscape-song'),
      );
      expect(songCard, findsOneWidget);
      expect(
        find.descendant(of: songCard, matching: find.byType(ListTile)),
        findsOneWidget,
      );
      final songTile = tester.widget<ListTile>(
        find.descendant(of: songCard, matching: find.byType(ListTile)),
      );
      expect(
        find
            .descendant(of: songCard, matching: find.byTooltip('取消收藏'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(
        find
            .descendant(
              of: songCard,
              matching: find.byType(PopupMenuButton<String>),
            )
            .hitTestable(),
        findsOneWidget,
      );
      expect(find.byType(Divider), findsWidgets);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const FavoritePlaylistsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('favorite-playlists-page-list')),
      );
      expect(list.scrollDirection, Axis.vertical);
      expect(find.text('横屏收藏歌单'), findsOneWidget);
      final playlistCard = find.byKey(
        const ValueKey('favorite-playlist-list-qq-landscape-playlist'),
      );
      expect(playlistCard, findsOneWidget);
      expect(
        find.descendant(of: playlistCard, matching: find.byType(ListTile)),
        findsOneWidget,
      );
      final playlistTile = tester.widget<ListTile>(
        find.descendant(of: playlistCard, matching: find.byType(ListTile)),
      );
      expect(playlistTile.minTileHeight, songTile.minTileHeight);
      expect(playlistTile.contentPadding, songTile.contentPadding);
      expect(
        find
            .descendant(of: playlistCard, matching: find.byTooltip('取消收藏歌单'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(find.byType(Divider), findsWidgets);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const BilibiliFavoritesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bilibiliList = tester.widget<ListView>(
        find.byKey(const ValueKey('bilibili-favorites-page-list')),
      );
      expect(bilibiliList.scrollDirection, Axis.vertical);
      final bilibiliCard = find.byKey(
        const ValueKey('favorite-bilibili-landscape-video'),
      );
      expect(bilibiliCard, findsOneWidget);
      expect(
        find.descendant(of: bilibiliCard, matching: find.byType(ListTile)),
        findsOneWidget,
      );
      final bilibiliTile = tester.widget<ListTile>(
        find.descendant(of: bilibiliCard, matching: find.byType(ListTile)),
      );
      expect(bilibiliTile.minTileHeight, songTile.minTileHeight);
      expect(bilibiliTile.contentPadding, songTile.contentPadding);
      expect(
        find
            .descendant(of: bilibiliCard, matching: find.byTooltip('取消收藏'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(
        find
            .descendant(
              of: bilibiliCard,
              matching: find.byType(PopupMenuButton<String>),
            )
            .hitTestable(),
        findsOneWidget,
      );
      expect(find.byType(Divider), findsWidgets);
      expect(tester.takeException(), isNull);
    }
  });
}

SongSearchResult _song(MusicPlatform platform, String id, String name) {
  return SongSearchResult(
    platform: platform,
    id: id,
    name: name,
    artist: '测试歌手',
    album: '测试专辑',
  );
}
