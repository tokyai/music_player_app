import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/main.dart' show MainScreen;
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/ai_config_controller.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('portrait home can scroll back after reaching the bottom', (
    tester,
  ) async {
    final songs = List.generate(
      12,
      (index) => SongSearchResult(
        platform: MusicPlatform.qq,
        id: 'scroll-$index',
        name: '滚动测试歌曲 $index',
        artist: '测试歌手',
        album: '测试专辑',
      ).toJson(),
    );
    SharedPreferences.setMockInitialValues({'favorites': jsonEncode(songs)});
    final player = PlayerProvider();
    final favorites = FavoriteService();
    final theme = ThemeController();
    final aiConfig = AiConfigController(secretStore: MemoryAiSecretStore());
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      favorites.dispose();
      theme.dispose();
      aiConfig.dispose();
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
            ChangeNotifierProvider<ThemeController>.value(value: theme),
            ChangeNotifierProvider<AiConfigController>.value(value: aiConfig),
            ChangeNotifierProvider(create: (_) => SearchSession()),
          ],
          child: MaterialApp(theme: AppTheme.light(), home: const MainScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final scrollable = find
          .descendant(
            of: find.byType(MainScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      final state = tester.state<ScrollableState>(scrollable);
      expect(
        tester
            .widget<ListView>(
              find
                  .descendant(
                    of: find.byType(MainScreen),
                    matching: find.byType(ListView),
                  )
                  .first,
            )
            .primary,
        isFalse,
      );
      expect(state.position.maxScrollExtent, greaterThan(0));

      await tester.drag(scrollable, const Offset(0, -2000));
      await tester.pumpAndSettle();
      final bottom = state.position.pixels;
      expect(bottom, closeTo(state.position.maxScrollExtent, 1));

      final viewport = tester.getRect(scrollable);
      await tester.dragFrom(
        Offset(viewport.center.dx, viewport.bottom - 18),
        const Offset(0, 500),
      );
      await tester.pumpAndSettle();
      expect(state.position.pixels, lessThan(bottom - 1));

      // Building another shell page attaches another primary scroll position.
      // Returning home must still allow the original list to move.
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('发现').last);
      await tester.pumpAndSettle();
      final returned = find
          .descendant(
            of: find.byType(MainScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      final returnedState = tester.state<ScrollableState>(returned);
      returnedState.position.jumpTo(returnedState.position.maxScrollExtent);
      await tester.pump();
      final returnedBottom = returnedState.position.pixels;
      final returnedViewport = tester.getRect(returned);
      await tester.dragFrom(
        Offset(returnedViewport.center.dx, returnedViewport.bottom - 18),
        const Offset(0, 500),
      );
      await tester.pumpAndSettle();
      expect(returnedState.position.pixels, lessThan(returnedBottom - 1));
    }, () => MockClient((request) async => http.Response('{}', 200)));
  });

  testWidgets(
    'portrait home remains recoverable when sections finish loading',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final player = PlayerProvider();
      final favorites = FavoriteService();
      final theme = ThemeController();
      final aiConfig = AiConfigController(secretStore: MemoryAiSecretStore());
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        favorites.dispose();
        theme.dispose();
        aiConfig.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await http.runWithClient(
        () async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(390, 844);
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<PlayerProvider>.value(value: player),
                ChangeNotifierProvider<FavoriteService>.value(value: favorites),
                ChangeNotifierProvider<ThemeController>.value(value: theme),
                ChangeNotifierProvider<AiConfigController>.value(
                  value: aiConfig,
                ),
                ChangeNotifierProvider(create: (_) => SearchSession()),
              ],
              child: MaterialApp(
                theme: AppTheme.light(),
                home: const MainScreen(),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 50));
          final scrollable = find
              .descendant(
                of: find.byType(MainScreen),
                matching: find.byType(Scrollable),
              )
              .first;
          final state = tester.state<ScrollableState>(scrollable);
          await tester.drag(scrollable, const Offset(0, -1600));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 1200));
          await tester.pumpAndSettle();
          final bottom = state.position.pixels;
          final viewport = tester.getRect(scrollable);
          await tester.dragFrom(
            Offset(viewport.center.dx, viewport.bottom - 18),
            const Offset(0, 500),
          );
          await tester.pumpAndSettle();
          expect(state.position.pixels, lessThan(bottom - 1));
        },
        () => MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.Response('{}', 200);
        }),
      );
    },
  );
}
