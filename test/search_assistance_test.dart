import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/screens/search_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:music_player_app/widgets/smart_cover.dart';
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
      'deleting the query returns to the initial view at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await http.runWithClient(() async {
          final player = PlayerProvider();
          final session = SearchSession();
          final favorites = FavoriteService();
          try {
            await _pumpSearch(
              tester,
              player: player,
              session: session,
              favorites: favorites,
              size: size,
            );

            final field = find.byKey(const ValueKey('search-field'));
            await tester.enterText(field, '周');
            await tester.testTextInput.receiveAction(TextInputAction.search);
            await tester.pumpAndSettle();

            expect(session.keyword, '周');
            expect(find.text('周末'), findsOneWidget);

            await tester.enterText(field, '');
            await tester.pumpAndSettle();

            expect(session.keyword, isEmpty);
            expect(find.text('周末'), findsNothing);
            expect(
              find.byKey(const PageStorageKey('search-welcome-results')),
              findsOneWidget,
            );
            expect(find.text('热门搜索'), findsOneWidget);
            await tester.scrollUntilVisible(
              find.byKey(const ValueKey('search-history-section')),
              100,
              scrollable: find.descendant(
                of: find.byKey(
                  const PageStorageKey('search-landscape-controls'),
                ),
                matching: find.byType(Scrollable),
              ),
            );
            expect(find.text('搜索历史'), findsOneWidget);
            expect(session.searchHistory, ['周']);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            player.dispose();
            session.dispose();
            favorites.dispose();
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          }
        }, () => _searchClient(<String>[]));
      },
    );

    testWidgets(
      'search suggestions and removable history work at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        final suggestionQueries = <String>[];
        await http.runWithClient(() async {
          final player = PlayerProvider();
          final session = SearchSession();
          final favorites = FavoriteService();
          try {
            await _pumpSearch(
              tester,
              player: player,
              session: session,
              favorites: favorites,
              size: size,
            );

            await tester.enterText(
              find.byKey(const ValueKey('search-field')),
              '周',
            );
            await tester.pump(const Duration(milliseconds: 400));
            await tester.pumpAndSettle();

            expect(suggestionQueries, ['周']);
            expect(
              find.byKey(const ValueKey('search-suggestion-artist-周杰伦')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('search-suggestion-artist-周深')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('search-suggestion-track-周末')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('search-suggestion-track-不相关')),
              findsNothing,
            );

            await tester.tap(
              find.byKey(const ValueKey('search-suggestion-artist-周杰伦')),
            );
            await tester.pumpAndSettle();

            expect(session.keyword, '周杰伦');
            expect(session.searchHistory, ['周杰伦']);
            await tester.scrollUntilVisible(
              find.text('搜索历史'),
              100,
              scrollable: find.descendant(
                of: find.byKey(
                  const PageStorageKey('search-landscape-controls'),
                ),
                matching: find.byType(Scrollable),
              ),
            );
            expect(
              find.byKey(const ValueKey('search-history-section')),
              findsOneWidget,
            );
            final prefs = await SharedPreferences.getInstance();
            expect(prefs.getStringList('search_history'), ['周杰伦']);

            final deleteButton = find.byKey(
              const ValueKey('delete-search-history-周杰伦'),
            );
            await tester.ensureVisible(deleteButton);
            await tester.tap(deleteButton);
            await tester.pumpAndSettle();

            expect(session.searchHistory, isEmpty);
            expect(prefs.getStringList('search_history'), isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            player.dispose();
            session.dispose();
            favorites.dispose();
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          }
        }, () => _searchClient(suggestionQueries));
      },
    );

    testWidgets(
      'related playlist action switches to cached playlists at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        var requestCount = 0;
        await http.runWithClient(
          () async {
            final player = PlayerProvider();
            final session = SearchSession();
            final favorites = FavoriteService();
            try {
              await _pumpSearch(
                tester,
                player: player,
                session: session,
                favorites: favorites,
                size: size,
              );
              await tester.enterText(
                find.byKey(const ValueKey('search-field')),
                '测试',
              );
              await tester.testTextInput.receiveAction(TextInputAction.search);
              await tester.pumpAndSettle();

              final action = find.byKey(
                const ValueKey('search-related-playlists-action'),
              );
              expect(action.hitTestable(), findsOneWidget);
              expect(find.text('相关测试歌单'), findsOneWidget);
              expect(requestCount, 2);

              await tester.tap(action.hitTestable());
              await tester.pumpAndSettle();

              expect(session.playlistMode, isTrue);
              expect(find.text('相关测试歌单'), findsOneWidget);
              expect(requestCount, 2);
              expect(tester.takeException(), isNull);
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              player.dispose();
              session.dispose();
              favorites.dispose();
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
            }
          },
          () {
            return MockClient((request) async {
              requestCount++;
              final payload = jsonDecode(request.body) as Map<String, dynamic>;
              final req = payload['req_1'] as Map<String, dynamic>;
              final params = req['param'] as Map<String, dynamic>;
              final playlistMode = params['search_type'] == 3;
              return _jsonResponse({
                'req_1': {
                  'code': 0,
                  'data': {
                    'body': {
                      'song': {
                        'list': playlistMode
                            ? <Object>[]
                            : [
                                {
                                  'mid': 'related-song',
                                  'name': '相关测试歌曲',
                                  'singer': [
                                    {'name': '测试歌手'},
                                  ],
                                  'album': {'name': '测试专辑'},
                                },
                              ],
                      },
                      'songlist': {
                        'list': playlistMode
                            ? [
                                {
                                  'dissid': 'related-playlist',
                                  'dissname': '相关测试歌单',
                                  'song_count': 30,
                                  'creator': {'name': '测试用户'},
                                },
                              ]
                            : <Object>[],
                      },
                    },
                  },
                },
              });
            });
          },
        );
      },
    );

    testWidgets(
      'Netease official covers reach song rows at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await http.runWithClient(() async {
          final player = PlayerProvider();
          final session = SearchSession();
          final favorites = FavoriteService();
          try {
            await _pumpSearch(
              tester,
              player: player,
              session: session,
              favorites: favorites,
              size: size,
            );

            await session.search(
              player.api,
              '周杰伦',
              preferredPlatform: MusicPlatform.netease,
            );
            await tester.pumpAndSettle();

            expect(find.text('想你就写信 (Live)'), findsOneWidget);
            final covers = tester
                .widgetList<SmartCover>(find.byType(SmartCover))
                .map((cover) => cover.url);
            expect(
              covers,
              contains('https://music.126.net/official-cover.jpg'),
            );
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            player.dispose();
            session.dispose();
            favorites.dispose();
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          }
        }, _neteaseCoverClient);
      },
    );
  }
}

Future<void> _pumpSearch(
  WidgetTester tester, {
  required PlayerProvider player,
  required SearchSession session,
  required FavoriteService favorites,
  required Size size,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<SearchSession>.value(value: session),
        ChangeNotifierProvider<FavoriteService>.value(value: favorites),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const SearchScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

http.Client _searchClient(List<String> suggestionQueries) {
  return MockClient((request) async {
    if (request.url.host != 'u.y.qq.com') {
      return _jsonResponse(<String, dynamic>{});
    }
    final payload = jsonDecode(request.body) as Map<String, dynamic>;
    final req = payload['req_1'] as Map<String, dynamic>;
    final params = req['param'] as Map<String, dynamic>;
    if (params['search_type'] == 3) {
      return _jsonResponse({
        'req_1': {
          'code': 0,
          'data': {
            'body': {
              'songlist': {'list': <Object>[]},
            },
          },
        },
      });
    }
    final keyword = params['query']?.toString() ?? '';
    suggestionQueries.add(keyword);
    return _jsonResponse({
      'req_1': {
        'code': 0,
        'data': {
          'body': {
            'song': {
              'list': [
                {
                  'mid': 'weekend',
                  'name': '周末',
                  'singer': [
                    {'name': '周杰伦'},
                  ],
                  'album': {'name': '测试专辑'},
                },
                {
                  'mid': 'sunny',
                  'name': '晴天',
                  'singer': [
                    {'name': '周深'},
                  ],
                  'album': {'name': '测试专辑'},
                },
                {
                  'mid': 'unrelated',
                  'name': '不相关',
                  'singer': [
                    {'name': '其他歌手'},
                  ],
                  'album': {'name': '测试专辑'},
                },
              ],
            },
          },
        },
      },
    });
  });
}

http.Client _neteaseCoverClient() {
  return MockClient((request) async {
    if (request.url.host != 'interface.music.163.com') {
      return _jsonResponse(<String, dynamic>{});
    }
    if (request.url.path == '/api/search/get/web') {
      if (request.url.queryParameters['type'] == '1000') {
        return _jsonResponse({
          'code': 200,
          'result': {'playlists': <Object>[]},
        });
      }
      return _jsonResponse({
        'code': 200,
        'result': {
          'songs': [
            {
              'id': 509781655,
              'name': '想你就写信 (Live)',
              'artists': [
                {'name': '周杰伦'},
              ],
              'album': {'name': '演唱会'},
              'duration': 240000,
            },
          ],
        },
      });
    }
    if (request.url.path == '/api/song/detail') {
      return _jsonResponse({
        'code': 200,
        'songs': [
          {
            'id': 509781655,
            'name': '想你就写信 (Live)',
            'artists': [
              {'name': '周杰伦'},
            ],
            'album': {
              'name': '演唱会',
              'picUrl': 'http://music.126.net/official-cover.jpg',
            },
          },
        ],
      });
    }
    return http.Response('not found', 404);
  });
}

http.Response _jsonResponse(Map<String, dynamic> body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
