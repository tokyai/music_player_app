import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/screens/playlist_detail_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppColors.isDark = false;
  });

  for (final size in const [Size(640, 360), Size(1280, 800)]) {
    testWidgets(
      'play all starts the first page and appends later pages at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        final secondPage = Completer<http.Response>();
        final offsets = <int>[];

        await http.runWithClient(() async {
          final player = PlayerProvider();
          final favorites = FavoriteService();
          try {
            await _pumpPlaylist(tester, player, favorites, size);
            expect(offsets, [0]);

            await tester.tap(find.text('播放全部').hitTestable());
            await tester.pump();

            expect(player.queue, hasLength(20));
            expect(player.queue.first.id, '1');
            expect(offsets, [0, 20]);
            expect(find.text('加载中 20/45'), findsOneWidget);

            secondPage.complete(_playlistPage(offset: 20, total: 45));
            await tester.pumpAndSettle();

            expect(offsets, [0, 20, 40]);
            expect(player.queue, hasLength(45));
            expect(player.queue[20].id, '21');
            expect(player.queue.last.id, '45');
            expect(find.text('播放全部'), findsOneWidget);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            player.dispose();
            favorites.dispose();
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          }
        }, () => _playlistClient(offsets, delayedPage: secondPage));
      },
    );
  }

  testWidgets('a stale playlist loader cannot append to a replacement queue', (
    tester,
  ) async {
    final secondPage = Completer<http.Response>();
    final offsets = <int>[];

    await http.runWithClient(() async {
      final player = PlayerProvider();
      final favorites = FavoriteService();
      try {
        await _pumpPlaylist(tester, player, favorites, const Size(1280, 800));
        await tester.tap(find.text('播放全部').hitTestable());
        await tester.pump();
        expect(player.queue, hasLength(20));
        expect(offsets, [0, 20]);

        final replacement = SongSearchResult(
          platform: MusicPlatform.qq,
          id: 'replacement',
          name: '新播放队列',
          artist: '测试歌手',
          album: '测试专辑',
        );
        unawaited(player.playFromPlaylist([replacement], 0));
        await tester.pump();
        expect(player.queue.single.id, 'replacement');

        secondPage.complete(_playlistPage(offset: 20, total: 45));
        await tester.pumpAndSettle();

        expect(offsets, [0, 20]);
        expect(player.queue, hasLength(1));
        expect(player.queue.single.id, 'replacement');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        favorites.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    }, () => _playlistClient(offsets, delayedPage: secondPage));
  });
}

Future<void> _pumpPlaylist(
  WidgetTester tester,
  PlayerProvider player,
  FavoriteService favorites,
  Size size,
) async {
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
        home: PlaylistDetailScreen(
          playlist: PlaylistInfo(
            id: 'progressive-playlist',
            name: '渐进加载歌单',
            trackCount: 45,
            tracks: const [],
          ),
          platform: MusicPlatform.netease,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

http.Client _playlistClient(
  List<int> offsets, {
  required Completer<http.Response> delayedPage,
}) {
  return MockClient((request) async {
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
    if (offset == 20) return delayedPage.future;
    return _playlistPage(offset: offset, total: 45);
  });
}

http.Response _playlistPage({required int offset, required int total}) {
  final count = (total - offset).clamp(0, 20).toInt();
  final songs = List.generate(
    count,
    (index) => {
      'id': offset + index + 1,
      'name': '分页歌曲 ${offset + index + 1}',
      'ar': [
        {'name': '分页歌手'},
      ],
      'al': {'name': '分页专辑'},
    },
  );
  return http.Response(
    jsonEncode({'code': 200, 'songs': songs}),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
