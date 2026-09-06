import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:music_player_app/widgets/song_tile.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final size in const [Size(640, 360), Size(1280, 800)]) {
    for (final width in const [110.0, 170.0]) {
      testWidgets(
        'compact song tiles retain favorite and queue actions at $size/$width',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          final song = SongSearchResult(
            platform: MusicPlatform.qq,
            id: 'compact-song',
            name: '窄布局歌曲',
            artist: '测试歌手',
            album: '测试专辑',
          );
          var played = 0;
          var queued = 0;
          final favorites = FavoriteService();
          final player = PlayerProvider(activateRestoredSession: false);
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            favorites.dispose();
            player.dispose();
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.light(),
              home: MultiProvider(
                providers: [
                  ChangeNotifierProvider<PlayerProvider>.value(value: player),
                  ChangeNotifierProvider<FavoriteService>.value(
                    value: favorites,
                  ),
                ],
                child: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: width,
                      child: SongTile(
                        song: song,
                        onTap: () => played++,
                        onAddToQueue: () => queued++,
                        showFavorite: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.byTooltip('收藏').hitTestable(), findsOneWidget);
          expect(
            find.byType(PopupMenuButton<String>).hitTestable(),
            findsOneWidget,
          );
          await tester.tap(find.byTooltip('收藏'));
          await tester.pumpAndSettle();
          expect(favorites.isFavorite(song.platform, song.id), isTrue);
          await tester.tap(find.byType(PopupMenuButton<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('添加到队列'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('窄布局歌曲'));
          expect(queued, 1);
          expect(played, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
