import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/main.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/screens/search_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:music_player_app/widgets/remote_focusable.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppColors.isDark = false;
  });

  testWidgets('remote focusable exposes a visible focus and select action', (
    tester,
  ) async {
    var activated = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Center(
          child: RemoteFocusable(
            key: const ValueKey('remote-control'),
            autofocus: true,
            onPressed: () => activated++,
            child: const SizedBox(width: 160, height: 80),
          ),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.byKey(const ValueKey('remote-control')), findsOneWidget);
    final animated = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byKey(const ValueKey('remote-control')),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(animated.foregroundDecoration, isA<BoxDecoration>());
    expect((animated.foregroundDecoration! as BoxDecoration).border, isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(activated, 1);
  });

  for (final size in const [Size(640, 360), Size(1280, 800)]) {
    testWidgets('main shell switches pages with a TV remote at $size', (
      tester,
    ) async {
      await http.runWithClient(() async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        final player = _RemoteTestPlayer()..showSong();
        final session = SearchSession();
        final theme = ThemeController();
        final favorites = FavoriteService();
        await favorites.load();
        final navigatorKey = GlobalKey<NavigatorState>();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          player.dispose();
          session.dispose();
          theme.dispose();
          favorites.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<PlayerProvider>.value(value: player),
              ChangeNotifierProvider<SearchSession>.value(value: session),
              ChangeNotifierProvider<ThemeController>.value(value: theme),
              ChangeNotifierProvider<FavoriteService>.value(value: favorites),
            ],
            child: MaterialApp(
              navigatorKey: navigatorKey,
              theme: AppTheme.light(),
              home: TvRemoteScope(
                navigatorKey: navigatorKey,
                child: const MainScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(SearchScreen), findsOneWidget);
        expect(find.byType(NavigationRail), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(MainScreen), findsOneWidget);
        expect(find.byType(SearchScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, _emptyClient);
    });
  }

  testWidgets('remote back key pops the current route', (tester) async {
    final player = _RemoteTestPlayer();
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<PlayerProvider>.value(
        value: player,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          builder: (context, child) =>
              TvRemoteScope(navigatorKey: navigatorKey, child: child!),
          home: const SizedBox(key: ValueKey('remote-home')),
        ),
      ),
    );
    final routeResult = navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
          body: Focus(
            autofocus: true,
            child: SizedBox(key: ValueKey('remote-detail')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-detail')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-detail')), findsNothing);
    expect(find.byKey(const ValueKey('remote-home')), findsOneWidget);
    await routeResult;
  });

  testWidgets('media remote keys reach the player provider', (tester) async {
    final player = _RemoteTestPlayer()..showSong();
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: TvRemoteScope(
            navigatorKey: navigatorKey,
            child: const Focus(
              autofocus: true,
              child: SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackNext);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackPrevious);
    expect(player.playPauseCalls, 1);
    expect(player.nextCalls, 1);
    expect(player.previousCalls, 1);
  });
}

http.Client _emptyClient() => MockClient((_) async => http.Response('{}', 200));

class _RemoteTestPlayer extends PlayerProvider {
  PlayQueueItem? _song;
  int playPauseCalls = 0;
  int nextCalls = 0;
  int previousCalls = 0;

  void showSong() {
    _song = PlayQueueItem(
      platform: MusicPlatform.qq,
      id: 'remote-song',
      name: '遥控器测试歌曲',
      artist: '测试歌手',
      album: '测试专辑',
    );
    notifyListeners();
  }

  @override
  PlayQueueItem? get currentSong => _song;

  @override
  List<PlayQueueItem> get queue => [if (_song != null) _song!];

  @override
  int get currentIndex => _song == null ? -1 : 0;

  @override
  Future<void> playPause() async => playPauseCalls++;

  @override
  Future<void> playNext() async => nextCalls++;

  @override
  Future<void> playPrevious() async => previousCalls++;
}
