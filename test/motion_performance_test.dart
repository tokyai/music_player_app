import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/screens/player_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_motion.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:music_player_app/utils/lyric_parser.dart';
import 'package:music_player_app/widgets/song_tile.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppColors.isDark = false;
  });

  testWidgets('playing song rows do not keep a continuous animation', (
    tester,
  ) async {
    final player = _MotionTestPlayer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      _resetView(tester);
    });

    for (final size in const [Size(640, 360), Size(1280, 800)]) {
      _setViewSize(tester, size);
      await tester.pumpWidget(
        ChangeNotifierProvider<PlayerProvider>.value(
          value: player,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: SongTile(song: player.song, onTap: () {}),
            ),
          ),
        ),
      );
      // A repeating playing indicator would keep scheduling frames and make
      // this settle call time out.
      await tester.pumpAndSettle(
        const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );

      expect(
        find.byKey(const ValueKey('song-playing-indicator')),
        findsOneWidget,
      );
      expect(find.byType(AnimatedContainer), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('large state switches remove the outgoing subtree immediately', (
    tester,
  ) async {
    late StateSetter update;
    var showFirst = true;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AppMotionSwitcher(
              child: showFirst
                  ? ListView.builder(
                      key: const ValueKey('outgoing-large-list'),
                      itemCount: 200,
                      itemBuilder: (_, index) => Text('旧项目 $index'),
                    )
                  : ListView.builder(
                      key: const ValueKey('incoming-large-list'),
                      itemCount: 200,
                      itemBuilder: (_, index) => Text('新项目 $index'),
                    ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    update(() => showFirst = false);
    await tester.pump();

    expect(find.byKey(const ValueKey('outgoing-large-list')), findsNothing);
    expect(find.byKey(const ValueKey('incoming-large-list')), findsOneWidget);
  });

  testWidgets('player isolates frequent paints on narrow and wide landscape', (
    tester,
  ) async {
    final player = _MotionTestPlayer();
    final favorites = FavoriteService();
    final search = SearchSession();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      favorites.dispose();
      search.dispose();
      _resetView(tester);
    });

    for (final size in const [Size(640, 360), Size(1280, 800)]) {
      _setViewSize(tester, size);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
            ChangeNotifierProvider<SearchSession>.value(value: search),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const PlayerScreen(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(const ValueKey('player-lyric-repaint-boundary')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('player-progress-repaint-boundary')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('nonessential motion follows the system reduce-motion flag', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: AppMotionSwitcher(
            child: Container(key: const ValueKey('reduced-motion-child')),
          ),
        ),
      ),
    );

    final switcher = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher),
    );
    expect(switcher.duration, Duration.zero);
    expect(switcher.reverseDuration, Duration.zero);
  });
}

class _MotionTestPlayer extends PlayerProvider {
  final SongSearchResult song = SongSearchResult(
    platform: MusicPlatform.qq,
    id: 'motion-song',
    name: '低负载动效测试歌曲',
    artist: '测试歌手',
    album: '测试专辑',
  );

  late final PlayQueueItem _queueSong = PlayQueueItem.fromSearchResult(song);

  @override
  PlayQueueItem get currentSong => _queueSong;

  @override
  List<PlayQueueItem> get queue => [_queueSong];

  @override
  int get currentIndex => 0;

  @override
  bool get isPlaying => true;

  @override
  Duration get position => const Duration(seconds: 4);

  @override
  Duration get duration => const Duration(seconds: 20);

  @override
  int get currentLyricIndex => 0;

  @override
  List<LyricLine> get lyrics => const [
    LyricLine(Duration.zero, '低负载歌词显示测试'),
    LyricLine(Duration(seconds: 10), '第二行歌词'),
  ];
}

void _setViewSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
}

void _resetView(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}
