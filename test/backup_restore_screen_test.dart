import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/screens/backup_restore_screen.dart';
import 'package:music_player_app/services/backup_service.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:music_player_app/widgets/backup_restore_options_dialog.dart';
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
      expect(find.byKey(const ValueKey('backup-copy-json')), findsOneWidget);
      expect(find.byKey(const ValueKey('backup-paste-json')), findsOneWidget);
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

  testWidgets('restore scope defaults to all and supports individual choices', (
    tester,
  ) async {
    final contents = const BackupRestoreContents(
      songs: true,
      bilibili: true,
      playlists: true,
      apiKey: true,
      aiAssistant: true,
      playerSettings: true,
    );
    BackupRestoreSelection? selection;

    for (final size in const [Size(640, 360), Size(1280, 800)]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      selection = null;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => FilledButton(
                  key: const ValueKey('open-restore-scope-dialog'),
                  onPressed: () async {
                    selection = await showBackupRestoreSelectionDialog(
                      context,
                      contents,
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-restore-scope-dialog')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('backup-restore-options-dialog')),
        findsOneWidget,
      );
      for (final section in BackupRestoreSection.values) {
        final checkbox = tester.widget<Checkbox>(
          find.descendant(
            of: find.byKey(ValueKey('backup-restore-section-${section.name}')),
            matching: find.byType(Checkbox),
          ),
        );
        expect(checkbox.value, isTrue);
      }

      final aiTile = find.byKey(
        const ValueKey('backup-restore-section-aiAssistant'),
      );
      await tester.ensureVisible(aiTile);
      await tester.tap(aiTile);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('backup-restore-merge')).hitTestable(),
      );
      await tester.pumpAndSettle();

      expect(selection?.mode, FavoriteImportMode.merge);
      expect(
        selection?.sections,
        isNot(contains(BackupRestoreSection.aiAssistant)),
      );
      expect(
        selection?.sections,
        containsAll(
          BackupRestoreSection.values.where(
            (section) => section != BackupRestoreSection.aiAssistant,
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('backup-restore-options-dialog')),
        findsNothing,
      );
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
