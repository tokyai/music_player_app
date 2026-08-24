import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppColors.isDark = false;
  });

  testWidgets('disposing settings stops the active favorite import server', (
    tester,
  ) async {
    final player = PlayerProvider();
    final theme = ThemeController();
    final favorites = FavoriteService();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(640, 360);
    try {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<ThemeController>.value(value: theme),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final import = find.byKey(const ValueKey('batch-favorite-import'));
      final preferencesScroll = find
          .descendant(
            of: find.byKey(
              const PageStorageKey<String>('settings-landscape-preferences'),
            ),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        import,
        160,
        scrollable: preferencesScroll,
      );
      await tester.tap(import);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final qrCode = find.byKey(const ValueKey('favorite-import-qr-code'));
      expect(tester.widget<QrImageView>(qrCode).size, 146);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      player.dispose();
      theme.dispose();
      favorites.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}
