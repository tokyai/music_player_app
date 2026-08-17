import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/screens/search_screen.dart';
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
    if (request.url.path != '/api-qq/search') {
      return _jsonResponse(<String, dynamic>{});
    }
    if (request.url.queryParameters['t'] == '2') {
      return _jsonResponse({
        'data': {'list': <Object>[]},
      });
    }
    final keyword = request.url.queryParameters['key'] ?? '';
    suggestionQueries.add(keyword);
    return _jsonResponse({
      'data': {
        'list': [
          {
            'songmid': 'weekend',
            'songname': '周末',
            'singer': [
              {'name': '周杰伦'},
            ],
            'albumname': '测试专辑',
          },
          {
            'songmid': 'sunny',
            'songname': '晴天',
            'singer': [
              {'name': '周深'},
            ],
            'albumname': '测试专辑',
          },
          {
            'songmid': 'unrelated',
            'songname': '不相关',
            'singer': [
              {'name': '其他歌手'},
            ],
            'albumname': '测试专辑',
          },
        ],
      },
    });
  });
}

http.Response _jsonResponse(Map<String, dynamic> body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
