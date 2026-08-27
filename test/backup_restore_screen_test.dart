import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/providers/ai_config_controller.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/providers/user_controller.dart';
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
      final users = UserController();
      final ai = AiConfigController(secretStore: MemoryAiSecretStore());
      final theme = ThemeController();
      final search = SearchSession();
      await Future.wait([
        player.settingsReady,
        favorites.load(),
        users.ready,
        ai.ready,
        theme.ready,
        search.historyReady,
      ]);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
            ChangeNotifierProvider<UserController>.value(value: users),
            ChangeNotifierProvider<AiConfigController>.value(value: ai),
            ChangeNotifierProvider<ThemeController>.value(value: theme),
            ChangeNotifierProvider<SearchSession>.value(value: search),
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
      users.dispose();
      ai.dispose();
      theme.dispose();
      search.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('restore scope defaults to all and supports individual choices', (
    tester,
  ) async {
    const contents = BackupRestoreContents(
      songs: true,
      bilibili: true,
      playlists: true,
      searchHistory: true,
      appearance: true,
      lyricDisplay: true,
      bilibiliAccount: true,
      apiKey: true,
      globalVoice: true,
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

  testWidgets('full snapshot restore only offers complete replacement', (
    tester,
  ) async {
    const contents = BackupRestoreContents(
      songs: true,
      bilibili: true,
      playlists: true,
      searchHistory: true,
      appearance: true,
      lyricDisplay: true,
      bilibiliAccount: true,
      apiKey: true,
      globalVoice: true,
      aiAssistant: true,
      playerSettings: true,
      fullSnapshot: true,
    );

    for (final size in const [Size(640, 360), Size(1280, 800)]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      BackupRestoreSelection? selection;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                key: const ValueKey('open-full-restore-dialog'),
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
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-full-restore-dialog')));
      await tester.pumpAndSettle();

      expect(find.text('恢复全部用户'), findsOneWidget);
      expect(find.textContaining('默认用户只会被覆盖，不会删除'), findsOneWidget);
      expect(find.byKey(const ValueKey('backup-restore-merge')), findsNothing);
      expect(
        find.byKey(const ValueKey('backup-restore-replace')),
        findsNothing,
      );
      final replace = find.byKey(const ValueKey('backup-restore-full-replace'));
      expect(replace, findsOneWidget);
      expect(replace.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(replace);
      await tester.pumpAndSettle();
      expect(selection?.mode, FavoriteImportMode.replace);
      expect(selection?.sections, containsAll(BackupRestoreSection.values));
      expect(
        selection?.sections,
        hasLength(BackupRestoreSection.values.length),
      );
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
