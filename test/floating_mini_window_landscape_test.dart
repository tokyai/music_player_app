import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/services/floating_capsule_service.dart';
import 'package:music_player_app/theme/app_layout.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(FloatingCapsuleService.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FloatingCapsuleService.setEnabled(false);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'hasPermission') return true;
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('car settings expose and persist the always-on-top mini window', (
    tester,
  ) async {
    for (final size in const [Size(640, 360), Size(1280, 800)]) {
      SharedPreferences.setMockInitialValues({});
      FloatingCapsuleService.setEnabled(false);
      final player = PlayerProvider();
      final theme = ThemeController();
      final favorites = FavoriteService();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<ThemeController>.value(value: theme),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
            ChangeNotifierProvider(create: (_) => SearchSession()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: AppLayout.adaptiveMediaQueryOf(context),
              child: child!,
            ),
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final preferencesPane = find.descendant(
        of: find.byKey(const PageStorageKey('settings-landscape-preferences')),
        matching: find.byType(Scrollable),
      );
      final toggle = find.byKey(const ValueKey('floating-mini-window-toggle'));
      await tester.scrollUntilVisible(toggle, 220, scrollable: preferencesPane);
      expect(toggle.hitTestable(), findsOneWidget);
      expect(find.text('车机迷你窗（置顶）'), findsOneWidget);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(FloatingCapsuleService.enabled, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(FloatingCapsuleService.preferenceKey), isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      favorites.dispose();
      theme.dispose();
      player.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('granting overlay permission enables the mini window on return', (
    tester,
  ) async {
    var permissionGranted = false;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'hasPermission' => permissionGranted,
        'openPermissionSettings' => true,
        'show' => true,
        _ => null,
      };
    });
    final player = PlayerProvider();
    final theme = ThemeController();
    final favorites = FavoriteService();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(640, 360);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      favorites.dispose();
      theme.dispose();
      player.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider<ThemeController>.value(value: theme),
          ChangeNotifierProvider<FavoriteService>.value(value: favorites),
          ChangeNotifierProvider(create: (_) => SearchSession()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: AppLayout.adaptiveMediaQueryOf(context),
            child: child!,
          ),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final preferencesPane = find.descendant(
      of: find.byKey(const PageStorageKey('settings-landscape-preferences')),
      matching: find.byType(Scrollable),
    );
    final toggle = find.byKey(const ValueKey('floating-mini-window-toggle'));
    await tester.scrollUntilVisible(toggle, 220, scrollable: preferencesPane);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(FloatingCapsuleService.enabled, isFalse);
    expect(
      calls.map((call) => call.method),
      contains('openPermissionSettings'),
    );
    expect(find.textContaining('返回库仔音乐'), findsOneWidget);

    permissionGranted = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(FloatingCapsuleService.enabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(FloatingCapsuleService.preferenceKey), isTrue);
    expect(calls.where((call) => call.method == 'hasPermission'), hasLength(2));
    expect(tester.takeException(), isNull);
  });
}
