import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/screens/backup_restore_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('backup page supports compact and wide landscape layouts', (
    tester,
  ) async {
    for (final size in const [Size(640, 360), Size(1280, 800)]) {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      final player = PlayerProvider();
      final favorites = FavoriteService();
      await Future.wait([player.settingsReady, favorites.load()]);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const BackupRestoreScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('backup-file-export')), findsOneWidget);
      expect(find.byKey(const ValueKey('backup-lan-start')), findsOneWidget);
      expect(find.byKey(const ValueKey('backup-webdav-url')), findsOneWidget);
      expect(
        find.byKey(
          ValueKey(
            size.width >= 760
                ? 'backup-responsive-wide'
                : 'backup-responsive-compact',
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      favorites.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
