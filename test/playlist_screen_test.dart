import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/screens/playlist_screen.dart';
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

  for (final size in const [Size(390, 844), Size(640, 360), Size(1280, 800)]) {
    testWidgets(
      'keeps multiple imported playlists and supports long-press deletion at '
      '${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await http.runWithClient(() async {
          final player = PlayerProvider();
          final favorites = FavoriteService();
          await favorites.load();
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            player.dispose();
            favorites.dispose();
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          await _pumpPlaylistScreen(tester, player, favorites, size);
          await _importPlaylist(tester, '10001');
          await _importPlaylist(tester, '10002');

          const firstKey = ValueKey('imported-playlist-qq-10001');
          const secondKey = ValueKey('imported-playlist-qq-10002');
          expect(find.byKey(firstKey), findsOneWidget);
          expect(find.byKey(secondKey), findsOneWidget);
          expect(favorites.favoritePlaylists, hasLength(2));
          expect(tester.takeException(), isNull);

          await tester.longPress(find.byKey(firstKey));
          await tester.pumpAndSettle();
          expect(find.text('删除歌单'), findsOneWidget);
          await tester.tap(find.widgetWithText(FilledButton, '删除'));
          await tester.pumpAndSettle();

          expect(find.byKey(firstKey), findsNothing);
          expect(find.byKey(secondKey), findsOneWidget);
          expect(favorites.favoritePlaylists.single.id, '10002');
          expect(tester.takeException(), isNull);

          final restored = FavoriteService();
          await restored.load();
          expect(restored.favoritePlaylists.single.id, '10002');
          restored.dispose();
        }, _playlistClient);
      },
    );
  }

  testWidgets('rejects an obviously invalid playlist id before requesting it', (
    tester,
  ) async {
    var requests = 0;
    await http.runWithClient(
      () async {
        final player = PlayerProvider();
        final favorites = FavoriteService();
        await favorites.load();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          player.dispose();
          favorites.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await _pumpPlaylistScreen(
          tester,
          player,
          favorites,
          const Size(640, 360),
        );
        await _tapImportButton(tester);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), '1');
        await tester.tap(find.text('导入').last);
        await tester.pumpAndSettle();

        expect(find.text('请输入有效的歌单 ID 或链接'), findsOneWidget);
        expect(find.byType(TextFormField), findsOneWidget);
        expect(requests, 0);
        expect(favorites.favoritePlaylists, isEmpty);
        expect(tester.takeException(), isNull);
      },
      () => MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
  });

  testWidgets('does not save a numeric id when the playlist does not exist', (
    tester,
  ) async {
    var requests = 0;
    await http.runWithClient(
      () async {
        final player = PlayerProvider();
        final favorites = FavoriteService();
        await favorites.load();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          player.dispose();
          favorites.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await _pumpPlaylistScreen(
          tester,
          player,
          favorites,
          const Size(640, 360),
        );
        await _importPlaylist(tester, '99999');

        expect(find.text('未找到歌单，请检查链接或 ID'), findsOneWidget);
        expect(favorites.favoritePlaylists, isEmpty);
        expect(requests, 2);
        expect(tester.takeException(), isNull);
      },
      () => MockClient((request) async {
        requests++;
        if (request.url.host == 'u.y.qq.com') {
          return http.Response(
            jsonEncode({
              'req_0': {'code': 0, 'data': <String, dynamic>{}},
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'data': <String, dynamic>{}}), 200);
      }),
    );
  });
}

Future<void> _pumpPlaylistScreen(
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
      child: MaterialApp(theme: AppTheme.light(), home: const PlaylistScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _importPlaylist(WidgetTester tester, String id) async {
  await _tapImportButton(tester);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField), id);
  await tester.tap(find.text('导入').last);
  await tester.pumpAndSettle();
}

Future<void> _tapImportButton(WidgetTester tester) async {
  final compactButton = find.byTooltip('导入歌单');
  if (compactButton.evaluate().isNotEmpty) {
    await tester.tap(compactButton);
  } else if (find.text('导入歌单').evaluate().isNotEmpty) {
    await tester.tap(find.text('导入歌单').first);
  } else {
    await tester.tap(find.text('导入').first);
  }
}

http.Client _playlistClient() {
  return MockClient((request) async {
    if (request.url.host != 'u.y.qq.com' || request.method != 'POST') {
      return http.Response('{}', 200);
    }
    final payload = jsonDecode(request.body) as Map<String, dynamic>;
    final requestData = payload['req_0'] as Map<String, dynamic>;
    final params = requestData['param'] as Map<String, dynamic>;
    final id = params['disstid'].toString();
    return http.Response(
      jsonEncode({
        'req_0': {
          'code': 0,
          'data': {
            'dirinfo': {
              'id': id,
              'title': '测试歌单 $id',
              'host_nick': '测试用户',
              'songnum': 1,
            },
            'songlist': [
              {
                'mid': 'song-$id',
                'name': '测试歌曲 $id',
                'singer': [
                  {'name': '测试歌手'},
                ],
                'album': {'name': '测试专辑'},
              },
            ],
          },
        },
      }),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  });
}
