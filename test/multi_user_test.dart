import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/main.dart';
import 'package:music_player_app/models/ai_assistant.dart';
import 'package:music_player_app/models/app_user.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/ai_config_controller.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/providers/user_controller.dart';
import 'package:music_player_app/screens/discover_screen.dart';
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/services/backup_service.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/services/floating_capsule_service.dart';
import 'package:music_player_app/services/playback_history_service.dart';
import 'package:music_player_app/services/playback_state_service.dart';
import 'package:music_player_app/services/user_avatar_storage.dart';
import 'package:music_player_app/services/user_data_scope.dart';
import 'package:music_player_app/services/webdav_backup_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:music_player_app/widgets/app_user_avatar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_avatar_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppColors.isDark = false;
  });

  test('default keeps legacy keys while other users use isolated keys', () {
    const defaultScope = UserDataScope.defaultScope;
    const userScope = UserDataScope('user-a');

    expect(defaultScope.preferenceKey('favorites'), 'favorites');
    expect(defaultScope.secureStorageKey('secret'), 'secret');
    expect(userScope.preferenceKey('favorites'), contains('user-a'));
    expect(userScope.preferenceKey('favorites'), isNot('favorites'));
    expect(userScope.secureStorageKey('secret'), contains('user-a'));
    expect(userScope.audioCacheRelativePath, contains('user-a'));
  });

  test(
    'user controller migrates the legacy installation to default user',
    () async {
      SharedPreferences.setMockInitialValues({
        'favorites': jsonEncode([_song('legacy-song', '旧版歌曲').toJson()]),
        'api_key': 'legacy-key',
      });
      final users = UserController();
      addTearDown(users.dispose);
      await users.ready;

      expect(users.users, hasLength(1));
      expect(users.activeUser, AppUserProfile.defaultUser);
      expect(users.activeUser.isDefault, isTrue);

      final favorites = FavoriteService(dataScope: users.activeScope);
      addTearDown(favorites.dispose);
      await favorites.load();
      expect(favorites.allFavorites.single.id, 'legacy-song');

      final player = PlayerProvider(dataScope: users.activeScope);
      addTearDown(player.dispose);
      await player.settingsReady;
      expect(player.apiKey, 'legacy-key');
    },
  );

  test(
    'user data stays isolated while appearance and AI settings are global',
    () async {
      const scopeA = UserDataScope('isolation-a');
      const scopeB = UserDataScope('isolation-b');
      final favoritesA = FavoriteService(dataScope: scopeA);
      final favoritesB = FavoriteService(dataScope: scopeB);
      final theme = ThemeController();
      final secret = MemoryAiSecretStore();
      final ai = AiConfigController(secretStore: secret);
      addTearDown(() {
        favoritesA.dispose();
        favoritesB.dispose();
        theme.dispose();
        ai.dispose();
      });
      await Future.wait([
        favoritesA.load(),
        favoritesB.load(),
        theme.ready,
        ai.ready,
      ]);

      await favoritesA.toggle(_song('only-a', '只属于A'));
      await PlaybackHistoryService.save([
        PlaybackHistoryEntry(
          song: _song('history-a', 'A的历史'),
          position: const Duration(seconds: 12),
          playedAt: DateTime(2026, 8, 23),
        ),
      ], scope: scopeA);
      await theme.setMode(ThemeMode.dark);
      await ai.updateProfile(
        ai.activeProfileId,
        config: AiAssistantConfig.defaults().copyWith(
          baseUrl: 'https://a.example/v1',
          apiKey: 'test-key-a',
          model: 'model-a',
        ),
      );

      expect(favoritesA.allFavorites.single.id, 'only-a');
      expect(favoritesB.allFavorites, isEmpty);
      expect(
        (await PlaybackHistoryService.load(scope: scopeA)).single.song.id,
        'history-a',
      );
      expect(await PlaybackHistoryService.load(scope: scopeB), isEmpty);
      expect(theme.mode, ThemeMode.dark);
      expect(ai.config.apiKey, 'test-key-a');

      // A newly created session reads the same global settings regardless of
      // which user owns its isolated music data.
      final themeForB = ThemeController(dataScope: scopeB);
      final aiForB = AiConfigController(dataScope: scopeB, secretStore: secret);
      addTearDown(() {
        themeForB.dispose();
        aiForB.dispose();
      });
      await Future.wait([themeForB.ready, aiForB.ready]);
      expect(themeForB.mode, ThemeMode.dark);
      expect(aiForB.config.apiKey, 'test-key-a');
    },
  );

  test(
    'search and playback state stay isolated while global player settings are shared',
    () async {
      const scopeA = UserDataScope('settings-a');
      const scopeB = UserDataScope('settings-b');
      SharedPreferences.setMockInitialValues({
        scopeA.preferenceKey('search_history'): ['只属于A'],
        scopeB.preferenceKey('search_history'): ['只属于B'],
      });
      final searchA = SearchSession(dataScope: scopeA);
      final searchB = SearchSession(dataScope: scopeB);
      final playerA = PlayerProvider(
        dataScope: scopeA,
        activateRestoredSession: false,
      );
      final playerB = PlayerProvider(
        dataScope: scopeB,
        activateRestoredSession: false,
      );
      addTearDown(() {
        searchA.dispose();
        searchB.dispose();
        playerA.dispose();
        playerB.dispose();
      });
      await Future.wait([
        searchA.historyReady,
        searchB.historyReady,
        playerA.settingsReady,
        playerB.settingsReady,
      ]);

      await playerA.setApiKey('music-key-a');
      await playerB.setApiKey('music-key-b');
      await playerA.setCommonLevel(CommonLevel.master);
      await playerB.setCommonLevel(CommonLevel.flac);
      await PlaybackStateService.save(
        PlaybackSessionSnapshot(
          queue: [_song('queue-a', 'A的队列')],
          currentIndex: 0,
          position: const Duration(seconds: 23),
          isPlaying: true,
          playMode: 'shuffle',
        ),
        scope: scopeA,
      );
      await PlaybackStateService.save(
        PlaybackSessionSnapshot(
          queue: [_song('queue-b', 'B的队列')],
          currentIndex: 0,
          position: const Duration(seconds: 7),
          isPlaying: false,
          playMode: 'repeat',
        ),
        scope: scopeB,
      );
      await const WebDavConfig(
        url: 'https://a.example/dav',
        username: 'a',
        password: 'password-a',
        certificateSha256: '',
        dataScope: scopeA,
      ).save();
      await const WebDavConfig(
        url: 'https://b.example/dav',
        username: 'b',
        password: 'password-b',
        certificateSha256: '',
        dataScope: scopeB,
      ).save();
      await FloatingCapsuleService.persistEnabled(true, scope: scopeA);
      await FloatingCapsuleService.persistEnabled(false, scope: scopeB);

      expect(searchA.searchHistory, ['只属于A']);
      expect(searchB.searchHistory, ['只属于B']);
      expect(playerA.apiKey, 'music-key-a');
      expect(playerB.apiKey, 'music-key-b');
      expect(playerA.commonLevel, CommonLevel.master);
      expect(playerB.commonLevel, CommonLevel.flac);
      final reloadedPlayer = PlayerProvider(
        dataScope: UserDataScope('settings-reloaded'),
        activateRestoredSession: false,
      );
      addTearDown(reloadedPlayer.dispose);
      await reloadedPlayer.settingsReady;
      expect(reloadedPlayer.apiKey, 'music-key-b');
      expect(reloadedPlayer.commonLevel, CommonLevel.flac);
      final queueA = await PlaybackStateService.load(scope: scopeA);
      final queueB = await PlaybackStateService.load(scope: scopeB);
      expect(queueA!.queue.single.id, 'queue-a');
      expect(queueA.playMode, 'shuffle');
      expect(queueB!.queue.single.id, 'queue-b');
      expect(queueB.playMode, 'repeat');
      expect((await WebDavConfig.load(dataScope: scopeA)).username, 'a');
      expect((await WebDavConfig.load(dataScope: scopeB)).username, 'b');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(FloatingCapsuleService.preferenceKey), isFalse);
      expect(
        prefs.getBool(
          scopeA.preferenceKey(FloatingCapsuleService.preferenceKey),
        ),
        isNull,
      );
    },
  );

  test('deleting a user clears scoped data and blocks stale writes', () async {
    const secureStorageChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (_) async => null);
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    final temporaryRoot = await Directory.systemTemp.createTemp(
      'kuzai-user-delete-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => temporaryRoot.path,
        );
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      if (await temporaryRoot.exists()) {
        await temporaryRoot.delete(recursive: true);
      }
    });
    final users = UserController();
    final staleFavorites = <FavoriteService>[];
    addTearDown(() {
      for (final service in staleFavorites) {
        service.dispose();
      }
      users.dispose();
    });
    await users.ready;
    final victim = await users.createUser(
      name: '待删除用户',
      avatarId: 'person',
      avatarColorIndex: 1,
    );
    final scope = UserDataScope(victim.id);
    final userCache = Directory(
      '${temporaryRoot.path}/${scope.audioCacheRelativePath}',
    );
    await userCache.create(recursive: true);
    await File('${userCache.path}/cached-song.mp3').writeAsString('cached');
    final favorites = FavoriteService(dataScope: scope);
    staleFavorites.add(favorites);
    await favorites.load();
    await favorites.toggle(_song('before-delete', '删除前'));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(scope.preferenceKey('api_key'), 'temporary-key');

    await users.deleteUser(victim.id);

    expect(scope.isDeleted, isTrue);
    expect(users.users.any((user) => user.id == victim.id), isFalse);
    expect(prefs.getKeys().where(scope.ownsPreferenceKey), isEmpty);
    expect(await userCache.exists(), isFalse);
    await favorites.toggle(_song('after-delete', '删除后'));
    expect(prefs.getKeys().where(scope.ownsPreferenceKey), isEmpty);

    await users.updateUser(
      AppUserProfile.defaultUserId,
      name: '我的账号',
      avatarId: 'music',
      avatarColorIndex: 3,
    );
    expect(users.userById(AppUserProfile.defaultUserId).name, '我的账号');
    await expectLater(
      users.deleteUser(AppUserProfile.defaultUserId),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'restoring profiles reloads the current session without switching users',
    () async {
      final users = UserController();
      addTearDown(users.dispose);
      await users.ready;
      var reloads = 0;
      var switches = 0;
      users.attachSessionReloader(() async => reloads++);
      users.attachSessionSwitcher((_) async => switches++);

      await users.restoreBackupProfiles(const [
        AppUserProfile(
          id: AppUserProfile.defaultUserId,
          name: '恢复后的默认用户',
          avatarId: 'music',
          avatarColorIndex: 2,
        ),
      ], backupActiveUserId: AppUserProfile.defaultUserId);

      expect(users.activeUserId, AppUserProfile.defaultUserId);
      expect(users.activeUser.name, '恢复后的默认用户');
      expect(reloads, 1);
      expect(switches, 0);
    },
  );

  test('restoring profiles switches to the backup active user', () async {
    final users = UserController();
    addTearDown(users.dispose);
    await users.ready;
    const restoredUser = AppUserProfile(
      id: 'restored-passenger',
      name: '恢复的副驾驶',
      avatarId: 'person',
      avatarColorIndex: 1,
    );
    final switched = <String>[];
    users.attachSessionSwitcher((userId) async {
      switched.add(userId);
      await users.activatePreparedUser(userId);
    });

    await users.restoreBackupProfiles(const [
      AppUserProfile.defaultUser,
      restoredUser,
    ], backupActiveUserId: restoredUser.id);

    expect(switched, [restoredUser.id]);
    expect(users.activeUserId, restoredUser.id);
    expect(users.activeUser, restoredUser);
  });

  test(
    'failed restored-session reload rolls profiles and active user back',
    () async {
      final users = UserController();
      addTearDown(users.dispose);
      await users.ready;
      final previousUsers = users.users;
      final previousActiveUserId = users.activeUserId;
      var reloads = 0;
      users.attachSessionReloader(() async {
        reloads++;
        throw StateError('reload failed');
      });

      await expectLater(
        users.restoreBackupProfiles(const [
          AppUserProfile(
            id: AppUserProfile.defaultUserId,
            name: '不应保留的名称',
            avatarId: 'star',
            avatarColorIndex: 4,
          ),
        ], backupActiveUserId: AppUserProfile.defaultUserId),
        throwsA(isA<StateError>()),
      );

      expect(reloads, 2);
      expect(users.users, previousUsers);
      expect(users.activeUserId, previousActiveUserId);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('kuzai_active_user_v1'), previousActiveUserId);
    },
  );

  test(
    'custom avatars persist, replace, clear, and delete with users',
    () async {
      const secureStorageChannel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      final temporaryRoot = await Directory.systemTemp.createTemp(
        'kuzai-user-avatar-',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, (_) async => null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProviderChannel,
            (_) async => temporaryRoot.path,
          );
      final users = UserController(
        avatarStorage: UserAvatarStorage(rootDirectory: temporaryRoot),
      );
      addTearDown(() async {
        users.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(secureStorageChannel, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null);
        if (await temporaryRoot.exists()) {
          await temporaryRoot.delete(recursive: true);
        }
      });
      await users.ready;

      final created = await users.createUser(
        name: '头像用户',
        avatarId: 'person',
        avatarColorIndex: 2,
        customAvatarBytes: testAvatarJpeg,
      );
      expect(created.hasCustomAvatar, isTrue);
      final firstFile = File(
        '${temporaryRoot.path}${Platform.pathSeparator}user_avatars'
        '${Platform.pathSeparator}${created.avatarFileName}',
      );
      expect(await firstFile.exists(), isTrue);

      await users.updateUser(
        created.id,
        name: '头像用户改名',
        avatarId: AppUserProfile.customAvatarId,
        avatarColorIndex: 3,
      );
      expect(users.userById(created.id).avatarFileName, created.avatarFileName);
      expect(await firstFile.exists(), isTrue);

      await users.updateUser(
        created.id,
        name: '头像用户改名',
        avatarId: AppUserProfile.customAvatarId,
        avatarColorIndex: 3,
        customAvatarBytes: testAvatarJpeg,
      );
      final replacement = users.userById(created.id);
      expect(replacement.avatarFileName, isNot(created.avatarFileName));
      expect(await firstFile.exists(), isFalse);
      final replacementFile = File(
        '${temporaryRoot.path}${Platform.pathSeparator}user_avatars'
        '${Platform.pathSeparator}${replacement.avatarFileName}',
      );
      expect(await replacementFile.exists(), isTrue);

      await users.updateUser(
        created.id,
        name: '头像用户改名',
        avatarId: 'music',
        avatarColorIndex: 3,
      );
      expect(users.userById(created.id).hasCustomAvatar, isFalse);
      expect(await replacementFile.exists(), isFalse);

      await users.updateUser(
        created.id,
        name: '头像用户改名',
        avatarId: 'music',
        avatarColorIndex: 3,
        customAvatarBytes: testAvatarJpeg,
      );
      final deletedAvatarName = users.userById(created.id).avatarFileName;
      await users.deleteUser(created.id);
      expect(
        await File(
          '${temporaryRoot.path}${Platform.pathSeparator}user_avatars'
          '${Platform.pathSeparator}$deletedAvatarName',
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'old user JSON remains compatible and unsafe avatar paths are ignored',
    () {
      final legacy = AppUserProfile.fromJson({
        'id': 'legacy',
        'name': '旧用户',
        'avatarId': 'music',
        'avatarColorIndex': 2,
      });
      expect(legacy.avatarId, 'music');
      expect(legacy.avatarFileName, isNull);

      final unsafe = AppUserProfile.fromJson({
        'id': 'unsafe',
        'name': '异常头像',
        'avatarId': AppUserProfile.customAvatarId,
        'avatarColorIndex': 0,
        'avatarFileName': '../outside.jpg',
      });
      expect(unsafe.avatarId, 'person');
      expect(unsafe.avatarFileName, isNull);
    },
  );

  testWidgets(
    'custom avatar widget resolves private files for repeated views',
    (tester) async {
      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      late final Directory temporaryRoot;
      const fileName = 'avatar_test_user_0123456789abcdef.jpg';
      await tester.runAsync(() async {
        temporaryRoot = await Directory.systemTemp.createTemp(
          'kuzai-avatar-widget-',
        );
        final avatarDirectory = Directory(
          '${temporaryRoot.path}${Platform.pathSeparator}user_avatars',
        );
        await avatarDirectory.create(recursive: true);
        await File(
          '${avatarDirectory.path}${Platform.pathSeparator}$fileName',
        ).writeAsBytes(testAvatarJpeg);
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProviderChannel,
        (_) async => temporaryRoot.path,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if (await temporaryRoot.exists()) {
            await temporaryRoot.delete(recursive: true);
          }
        });
        PaintingBinding.instance.imageCache.clear();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          pathProviderChannel,
          null,
        );
      });
      const user = AppUserProfile(
        id: 'test_user',
        name: '头像用户',
        avatarId: AppUserProfile.customAvatarId,
        avatarColorIndex: 0,
        avatarFileName: fileName,
      );
      final resolved = await tester.runAsync(
        () => UserAvatarStorage.shared.resolve(fileName),
      );
      expect(resolved, isNotNull);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Row(
              children: [
                AppUserAvatar(user: user, size: 44),
                AppUserAvatar(user: user, size: 52),
                AppUserAvatar(user: user, size: 72),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      for (var attempt = 0; attempt < 3; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }

      expect(
        find.byKey(const ValueKey('user-custom-avatar-test_user')),
        findsNWidgets(3),
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'legacy backup restores user data to the current user without global sections',
    () async {
      const activeScope = UserDataScope('backup-active-user');
      final activeFavorites = FavoriteService(dataScope: activeScope);
      final activePlayer = PlayerProvider(
        dataScope: activeScope,
        activateRestoredSession: false,
      );
      addTearDown(() {
        activeFavorites.dispose();
        activePlayer.dispose();
      });
      await Future.wait([activeFavorites.load(), activePlayer.settingsReady]);
      await activePlayer.setApiKey('active-key');

      final result = await BackupService.importJson(
        raw: jsonEncode({
          'format': FavoriteService.exportFormat,
          'version': 3,
          'songs': [_song('legacy-default', '还原到默认').toJson()],
          'bilibili': <dynamic>[],
          'playlists': <dynamic>[],
          'apiKey': 'legacy-default-key',
        }),
        favorites: activeFavorites,
        player: activePlayer,
        sections: const [
          BackupRestoreSection.songs,
          BackupRestoreSection.apiKey,
        ],
      );

      expect(result.restoredToDefaultUser, isFalse);
      expect(activeFavorites.allFavorites.single.id, 'legacy-default');
      expect(activePlayer.apiKey, 'active-key');
      final defaultFavorites = FavoriteService();
      final defaultPlayer = PlayerProvider(activateRestoredSession: false);
      addTearDown(() {
        defaultFavorites.dispose();
        defaultPlayer.dispose();
      });
      await Future.wait([defaultFavorites.load(), defaultPlayer.settingsReady]);
      expect(defaultFavorites.allFavorites, isEmpty);
      expect(defaultPlayer.apiKey, 'active-key');
    },
  );

  test('version 4 backup restores only to the active user', () async {
    const activeScope = UserDataScope('backup-v4-user');
    final favorites = FavoriteService(dataScope: activeScope);
    final player = PlayerProvider(
      dataScope: activeScope,
      activateRestoredSession: false,
    );
    addTearDown(() {
      favorites.dispose();
      player.dispose();
    });
    await Future.wait([favorites.load(), player.settingsReady]);

    final result = await BackupService.importJson(
      raw: jsonEncode({
        'format': FavoriteService.exportFormat,
        'version': 4,
        'userDataVersion': 1,
        'songs': [_song('active-only', '当前用户').toJson()],
        'bilibili': <dynamic>[],
        'playlists': <dynamic>[],
      }),
      favorites: favorites,
      player: player,
      sections: const [BackupRestoreSection.songs],
    );

    expect(result.restoredToDefaultUser, isFalse);
    expect(favorites.allFavorites.single.id, 'active-only');
    final defaultFavorites = FavoriteService();
    addTearDown(defaultFavorites.dispose);
    await defaultFavorites.load();
    expect(defaultFavorites.allFavorites, isEmpty);
  });

  testWidgets('app replaces every session provider when switching users', (
    tester,
  ) async {
    const floatingChannel = MethodChannel(FloatingCapsuleService.channelName);
    const secureStorageChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      floatingChannel,
      (call) async => call.method == 'hasPermission' ? true : null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      secureStorageChannel,
      (_) async => null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        floatingChannel,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        secureStorageChannel,
        null,
      );
    });
    final users = UserController();
    await users.ready;
    final second = await users.createUser(
      name: '副驾驶',
      avatarId: 'headphones',
      avatarColorIndex: 4,
    );
    final initialPlayer = PlayerProvider(
      dataScope: users.activeScope,
      activateRestoredSession: false,
    );
    PlayerProvider? systemPlayer;

    await tester.pumpWidget(
      MusicPlayerApp(
        player: initialPlayer,
        users: users,
        bindSystemPlayer: (player) => systemPlayer = player,
      ),
    );
    await tester.pump();
    var mainContext = tester.element(find.byType(MainScreen));
    expect(mainContext.read<PlayerProvider>().dataScope.isDefault, isTrue);
    expect(mainContext.read<FavoriteService>().dataScope.isDefault, isTrue);
    final sharedTheme = mainContext.read<ThemeController>();
    final sharedAiConfig = mainContext.read<AiConfigController>();

    await users.switchUser(second.id);
    // The discover page starts a network refresh on every new session. It is
    // intentionally not settled here because a real car may keep that
    // spinner active while the network is unavailable.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    mainContext = tester.element(find.byType(MainScreen));
    final switchedPlayer = mainContext.read<PlayerProvider>();
    final switchedFavorites = mainContext.read<FavoriteService>();
    final switchedSearch = mainContext.read<SearchSession>();
    expect(users.activeUserId, second.id);
    expect(switchedPlayer, isNot(same(initialPlayer)));
    expect(switchedPlayer.dataScope.userId, second.id);
    expect(switchedFavorites.dataScope.userId, second.id);
    expect(switchedSearch.dataScope.userId, second.id);
    expect(mainContext.read<ThemeController>(), same(sharedTheme));
    expect(mainContext.read<ThemeController>().dataScope.isDefault, isTrue);
    expect(mainContext.read<AiConfigController>(), same(sharedAiConfig));
    expect(mainContext.read<AiConfigController>().dataScope.isDefault, isTrue);
    expect(systemPlayer, same(switchedPlayer));
    expect(tester.takeException(), isNull);

    await users.reloadActiveSession();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    mainContext = tester.element(find.byType(MainScreen));
    final reloadedPlayer = mainContext.read<PlayerProvider>();
    expect(users.activeUserId, second.id);
    expect(reloadedPlayer, isNot(same(switchedPlayer)));
    expect(reloadedPlayer.dataScope.userId, second.id);
    expect(mainContext.read<FavoriteService>(), isNot(same(switchedFavorites)));
    expect(mainContext.read<SearchSession>(), isNot(same(switchedSearch)));
    expect(mainContext.read<ThemeController>(), same(sharedTheme));
    expect(mainContext.read<AiConfigController>(), same(sharedAiConfig));
    expect(systemPlayer, same(reloadedPlayer));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final size in const [Size(640, 360), Size(1280, 800)]) {
    testWidgets('user header and settings management fit at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      final users = UserController();
      await users.ready;
      final second = await users.createUser(
        name: '驾驶员B',
        avatarId: 'car',
        avatarColorIndex: 2,
      );
      final player = PlayerProvider();
      final theme = ThemeController();
      final search = SearchSession();
      final favorites = FavoriteService();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        users.dispose();
        player.dispose();
        theme.dispose();
        search.dispose();
        favorites.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<UserController>.value(value: users),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<ThemeController>.value(value: theme),
            ChangeNotifierProvider<SearchSession>.value(value: search),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const DiscoverScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-user-avatar')), findsOneWidget);
      expect(find.textContaining('默认用户'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('home-user-avatar')));
      await tester.pumpAndSettle();
      final switchDialog = find.byKey(const ValueKey('user-switch-dialog'));
      expect(switchDialog, findsOneWidget);
      final switchDialogRect = tester.getRect(switchDialog);
      expect(switchDialogRect.left, greaterThanOrEqualTo(0));
      expect(switchDialogRect.right, lessThanOrEqualTo(size.width));
      expect(switchDialogRect.top, greaterThanOrEqualTo(0));
      expect(switchDialogRect.bottom, lessThanOrEqualTo(size.height));
      expect(switchDialogRect.width, greaterThan(560));
      expect(
        tester.getSize(find.byKey(const ValueKey('user-switch-list'))).width,
        greaterThan(0),
      );
      await tester.tap(find.byKey(ValueKey('user-switch-${second.id}')));
      await tester.pumpAndSettle();
      expect(find.textContaining('驾驶员B'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<UserController>.value(value: users),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<ThemeController>.value(value: theme),
            ChangeNotifierProvider<SearchSession>.value(value: search),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('user-add')), findsOneWidget);
      expect(find.byKey(const ValueKey('user-edit-default')), findsOneWidget);
      expect(find.byKey(const ValueKey('user-delete-default')), findsNothing);
      expect(find.byKey(ValueKey('user-delete-${second.id}')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('user-add')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('user-profile-editor-dialog')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('user-profile-save')), findsOneWidget);
      final scan = find.byKey(const ValueKey('user-profile-scan'));
      await tester.ensureVisible(scan);
      expect(scan.hitTestable(), findsOneWidget);
      expect(tester.getRect(scan).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
      final editor = find.byKey(const ValueKey('user-profile-editor-dialog'));
      await tester.tap(find.descendant(of: editor, matching: find.text('取消')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

SongSearchResult _song(String id, String name) => SongSearchResult(
  platform: MusicPlatform.qq,
  id: id,
  name: name,
  artist: '测试歌手',
  album: '测试专辑',
);
