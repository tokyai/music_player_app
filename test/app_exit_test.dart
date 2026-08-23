import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/main.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/services/app_exit_service.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/services/floating_capsule_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const lifecycleChannel = MethodChannel(AppExitService.channelName);
  const floatingChannel = MethodChannel(FloatingCapsuleService.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppColors.isDark = false;
    AppExitService.resetForTesting();
    calls = [];
    messenger.setMockMethodCallHandler(lifecycleChannel, (call) async {
      calls.add('lifecycle:${call.method}');
      return true;
    });
    messenger.setMockMethodCallHandler(floatingChannel, (call) async {
      calls.add('floating:${call.method}');
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(lifecycleChannel, null);
    messenger.setMockMethodCallHandler(floatingChannel, null);
  });

  for (final size in const [Size(640, 360), Size(1280, 800)]) {
    testWidgets('landscape complete exit is usable at $size', (tester) async {
      final player = _ExitTestPlayer();
      final theme = ThemeController();
      final search = SearchSession();
      final favorites = FavoriteService();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        theme.dispose();
        search.dispose();
        favorites.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await _pumpApp(
        tester,
        const MainScreen(),
        player: player,
        theme: theme,
        search: search,
        favorites: favorites,
        size: size,
      );

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).scrollable,
        size.height < 480,
      );
      expect(
        find.byKey(const ValueKey('landscape-complete-exit')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      for (var step = 0; step < 4; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('complete-exit-dialog')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('complete-exit-cancel')));
      await tester.pumpAndSettle();
      expect(player.exitPreparations, 0);
      expect(calls, isEmpty);

      await tester.tap(find.byKey(const ValueKey('landscape-complete-exit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('complete-exit-confirm')));
      await tester.pumpAndSettle();

      expect(player.exitPreparations, 1);
      expect(calls, ['floating:hide', 'lifecycle:exit']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('portrait settings contains the complete exit action', (
    tester,
  ) async {
    final player = _ExitTestPlayer();
    final theme = ThemeController();
    final search = SearchSession();
    final favorites = FavoriteService();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      theme.dispose();
      search.dispose();
      favorites.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await _pumpApp(
      tester,
      const SettingsScreen(),
      player: player,
      theme: theme,
      search: search,
      favorites: favorites,
      size: const Size(390, 844),
    );

    final exitAction = find.byKey(const ValueKey('portrait-complete-exit'));
    await tester.scrollUntilVisible(
      exitAction,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(exitAction, findsOneWidget);
    await tester.tap(exitAction);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('complete-exit-confirm')));
    await tester.pumpAndSettle();

    expect(player.exitPreparations, 1);
    expect(calls, ['floating:hide', 'lifecycle:exit']);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpApp(
  WidgetTester tester,
  Widget home, {
  required PlayerProvider player,
  required ThemeController theme,
  required SearchSession search,
  required FavoriteService favorites,
  required Size size,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<SearchSession>.value(value: search),
        ChangeNotifierProvider<FavoriteService>.value(value: favorites),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: home),
    ),
  );
  await tester.pumpAndSettle();
}

class _ExitTestPlayer extends PlayerProvider {
  int exitPreparations = 0;

  @override
  Future<void> prepareForAppExit() async {
    exitPreparations++;
  }
}
