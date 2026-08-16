import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/screens/favorites_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppColors.isDark = false;
    SharedPreferences.setMockInitialValues({
      'favorites': jsonEncode([
        _song(MusicPlatform.qq, 'qq-1', 'Favorite One').toJson(),
        _song(MusicPlatform.netease, '163-2', 'Favorite Two').toJson(),
      ]),
    });
  });

  testWidgets('landscape favorites supports management and batch selection', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 360);
    final player = PlayerProvider();
    final favorites = FavoriteService();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      favorites.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
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
    expect(find.text('2 首歌曲'), findsOneWidget);
    expect(find.text('Favorite One'), findsOneWidget);
    expect(find.text('Favorite Two'), findsOneWidget);
    expect(find.byTooltip('取消收藏'), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    expect(find.byType(VerticalDivider), findsOneWidget);
    expect(find.text('导入'), findsOneWidget);
    expect(find.text('导出'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(800, 360);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('收藏管理'));
    await tester.pumpAndSettle();
    expect(find.text('导入收藏'), findsOneWidget);
    expect(find.text('导出收藏'), findsOneWidget);
    await tester.tapAt(const Offset(20, 200));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Favorite One'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(find.text('已选 1 首'), findsOneWidget);
    expect(find.text('换源'), findsOneWidget);

    await tester.tap(find.text('换源'));
    await tester.pumpAndSettle();
    expect(find.text('切换到'), findsOneWidget);
    expect(find.text('QQ音乐'), findsOneWidget);
    expect(find.text('网易云'), findsOneWidget);
    expect(find.text('酷狗'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

SongSearchResult _song(MusicPlatform platform, String id, String name) {
  return SongSearchResult(
    platform: platform,
    id: id,
    name: name,
    artist: 'Singer',
    album: 'Album',
    duration: 200,
  );
}
