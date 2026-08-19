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
import 'package:music_player_app/screens/discover_screen.dart';
import 'package:music_player_app/screens/playlist_screen.dart';
import 'package:music_player_app/screens/search_screen.dart';
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/services/update_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:music_player_app/widgets/remote_focusable.dart';
import 'package:music_player_app/widgets/update_dialog.dart';
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
    testWidgets('D-pad leaves a focused text field vertically at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      final controller = TextEditingController(text: 'remote input');
      final fieldFocus = FocusNode();
      final downFocus = FocusNode();
      addTearDown(() {
        controller.dispose();
        fieldFocus.dispose();
        downFocus.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 280,
                    child: RemoteTextFieldTraversal(
                      controller: controller,
                      child: TextField(
                        focusNode: fieldFocus,
                        controller: controller,
                        autofocus: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    focusNode: downFocus,
                    onPressed: () {},
                    child: const Text('下方'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(fieldFocus.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(fieldFocus.hasFocus, isFalse);
      expect(downFocus.hasFocus, isTrue);
    });

    for (final direction in const [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
    ]) {
      testWidgets('D-pad leaves a text boundary with $direction at $size', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        final controller = TextEditingController(text: 'remote input');
        final fieldFocus = FocusNode();
        final buttonFocus = FocusNode();
        addTearDown(() {
          controller.dispose();
          fieldFocus.dispose();
          buttonFocus.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final exitsLeft = direction == LogicalKeyboardKey.arrowLeft;
        final button = FilledButton(
          focusNode: buttonFocus,
          onPressed: () {},
          child: Text(exitsLeft ? '左侧' : '右侧'),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (exitsLeft) ...[button, const SizedBox(width: 12)],
                    SizedBox(
                      width: 280,
                      child: RemoteTextFieldTraversal(
                        controller: controller,
                        child: TextField(
                          focusNode: fieldFocus,
                          controller: controller,
                          autofocus: true,
                        ),
                      ),
                    ),
                    if (!exitsLeft) ...[const SizedBox(width: 12), button],
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(fieldFocus.hasFocus, isTrue);
        controller.selection = TextSelection.collapsed(
          offset: exitsLeft ? 0 : controller.text.length,
        );

        await tester.sendKeyEvent(direction);
        await tester.pump();
        expect(fieldFocus.hasFocus, isFalse);
        expect(buttonFocus.hasFocus, isTrue);
      });
    }

    testWidgets('D-pad leaves selectable text horizontally at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      final selectableFocus = FocusNode();
      final buttonFocus = FocusNode();
      addTearDown(() {
        selectableFocus.dispose();
        buttonFocus.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RemoteTextFieldTraversal(
                    child: SelectableText(
                      'https://example.com/backup',
                      focusNode: selectableFocus,
                      autofocus: true,
                    ),
                  ),
                  const SizedBox(width: 16),
                  FilledButton(
                    focusNode: buttonFocus,
                    onPressed: () {},
                    child: const Text('复制'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(selectableFocus.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(selectableFocus.hasFocus, isFalse);
      expect(buttonFocus.hasFocus, isTrue);
    });
  }

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

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        final initialFocus = find.byKey(
          const ValueKey('landscape-navigation-initial-focus'),
        );
        final focusDecoration = tester
            .widget<AnimatedContainer>(
              find.descendant(
                of: initialFocus,
                matching: find.byType(AnimatedContainer),
              ),
            )
            .foregroundDecoration;
        expect(initialFocus, findsOneWidget);
        expect((focusDecoration! as BoxDecoration).border, isNotNull);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(SearchScreen), findsOneWidget);
        expect(
          tester
              .widget<NavigationRail>(find.byType(NavigationRail))
              .selectedIndex,
          1,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(PlaylistScreen), findsOneWidget);
        expect(
          tester
              .widget<NavigationRail>(find.byType(NavigationRail))
              .selectedIndex,
          2,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(SettingsScreen), findsOneWidget);
        expect(
          tester
              .widget<NavigationRail>(find.byType(NavigationRail))
              .selectedIndex,
          3,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(DiscoverScreen), findsOneWidget);
        expect(
          tester
              .widget<NavigationRail>(find.byType(NavigationRail))
              .selectedIndex,
          0,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(MainScreen), findsOneWidget);
        expect(find.byType(DiscoverScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, _emptyClient);
    });
  }

  testWidgets('remote back key pops the current route', (tester) async {
    final player = _RemoteTestPlayer();
    final navigatorKey = GlobalKey<NavigatorState>();
    final editorFocus = FocusNode();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      editorFocus.dispose();
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
        builder: (_) => Scaffold(
          body: TextField(
            focusNode: editorFocus,
            autofocus: true,
            key: const ValueKey('remote-detail'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-detail')), findsOneWidget);
    expect(editorFocus.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-detail')), findsOneWidget);
    expect(editorFocus.hasFocus, isFalse);

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

  for (final size in const [Size(640, 360), Size(1280, 800)]) {
    testWidgets('update notes scroll with the D-pad at $size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final info = UpdateInfo(
        versionName: '9.9.9',
        versionCode: 999,
        apkUrl: 'https://example.com/app.apk',
        apkSize: 1,
        md5: '',
        sha256: '',
        forceUpdate: false,
        updateLog: List.generate(
          80,
          (index) => '第 ${index + 1} 项电视遥控器更新内容',
        ).join('\n'),
        publishTime: '',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showUpdateDialog(context, info),
                child: const Text('检查更新'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();

      final scrollable = find.descendant(
        of: find.byKey(const ValueKey('update-log-scroll')),
        matching: find.byType(Scrollable),
      );
      final scrollState = tester.state<ScrollableState>(scrollable);
      expect(scrollState.position.maxScrollExtent, greaterThan(0));
      expect(scrollState.position.pixels, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(scrollState.position.pixels, greaterThan(0));
    });
  }
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
