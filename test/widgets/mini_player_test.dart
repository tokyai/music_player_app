import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:music_player_app/widgets/mini_player.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final size in const [
    Size(640, 360),
    Size(1280, 800),
    Size(390, 844),
    Size(320, 640),
  ]) {
    testWidgets('mini player exposes previous and next controls at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      SharedPreferences.setMockInitialValues({});
      final player = _MiniPlayerTestProvider();
      final favorites = FavoriteService();
      final wide = size == const Size(1280, 800);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        favorites.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<PlayerProvider>.value(value: player),
              ChangeNotifierProvider<FavoriteService>.value(value: favorites),
            ],
            child: Scaffold(
              body: wide
                  ? const Align(
                      alignment: Alignment.centerRight,
                      child: SizedBox(width: 296, child: LandscapeMiniPlayer()),
                    )
                  : null,
              bottomNavigationBar: wide
                  ? null
                  : Align(
                      alignment: Alignment.centerRight,
                      heightFactor: 1,
                      child: SizedBox(
                        width: size.width == 640 ? 543 : size.width,
                        child: const MiniPlayer(),
                      ),
                    ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('上一首').hitTestable(), findsOneWidget);
      expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
      expect(find.byTooltip('下一首').hitTestable(), findsOneWidget);
      expect(
        tester.getRect(find.byTooltip('上一首')).width,
        greaterThanOrEqualTo(48),
      );

      await tester.tap(find.byTooltip('上一首'));
      await tester.tap(find.byTooltip('下一首'));
      expect(player.previousCalls, 1);
      expect(player.nextCalls, 1);
      final previousRect = tester.getRect(find.byTooltip('上一首'));
      final nextRect = tester.getRect(find.byTooltip('下一首'));
      final titleRect = tester.getRect(find.text('迷你播放器测试歌曲'));
      player.setLoading(true);
      await tester.pump();
      expect(
        find.byKey(
          ValueKey(wide ? 'landscape-mini-loading' : 'mini-player-loading'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('播放'), findsNothing);
      expect(tester.getRect(find.byTooltip('上一首')), previousRect);
      expect(tester.getRect(find.byTooltip('下一首')), nextRect);
      expect(tester.getRect(find.text('迷你播放器测试歌曲')), titleRect);
      await tester.tap(find.byTooltip('下一首'));
      expect(player.nextCalls, 2);
      player.setLoading(false);
      await tester.pumpAndSettle();
      expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

class _MiniPlayerTestProvider extends PlayerProvider {
  final PlayQueueItem _song = PlayQueueItem(
    platform: MusicPlatform.qq,
    id: 'mini-player-test-song',
    name: '迷你播放器测试歌曲',
    artist: '测试歌手',
    album: '测试专辑',
  );
  int previousCalls = 0;
  int nextCalls = 0;
  bool _loading = false;

  void setLoading(bool value) {
    _loading = value;
    notifyListeners();
  }

  @override
  PlayQueueItem? get currentSong => _song;

  @override
  bool get isPlaying => false;

  @override
  bool get isLoading => _loading;

  @override
  Future<void> playPrevious() async => previousCalls++;

  @override
  Future<void> playNext() async => nextCalls++;
}
