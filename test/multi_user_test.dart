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
import 'package:music_player_app/services/user_data_scope.dart';
import 'package:music_player_app/services/webdav_backup_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('favorites history settings and AI profiles stay isolated', () async {
    const scopeA = UserDataScope('isolation-a');
    const scopeB = UserDataScope('isolation-b');
    final favoritesA = FavoriteService(dataScope: scopeA);
    final favoritesB = FavoriteService(dataScope: scopeB);
    final themeA = ThemeController(dataScope: scopeA);
    final themeB = ThemeController(dataScope: scopeB);
    final secretA = MemoryAiSecretStore();
    final secretB = MemoryAiSecretStore();
    final aiA = AiConfigController(dataScope: scopeA, secretStore: secretA);
    final aiB = AiConfigController(dataScope: scopeB, secretStore: secretB);
    addTearDown(() {
      favoritesA.dispose();
      favoritesB.dispose();
      themeA.dispose();
      themeB.dispose();
      aiA.dispose();
      aiB.dispose();
    });
    await Future.wait([
      favoritesA.load(),
      favoritesB.load(),
      themeA.ready,
      themeB.ready,
      aiA.ready,
      aiB.ready,
    ]);

    await favoritesA.toggle(_song('only-a', '只属于A'));
    await PlaybackHistoryService.save([
      PlaybackHistoryEntry(
        song: _song('history-a', 'A的历史'),
        position: const Duration(seconds: 12),
        playedAt: DateTime(2026, 8, 23),
      ),
    ], scope: scopeA);
    await themeA.setMode(ThemeMode.dark);
    await aiA.updateProfile(
      aiA.activeProfileId,
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
    expect(themeA.mode, ThemeMode.dark);
    expect(themeB.mode, ThemeMode.system);
    expect(aiA.config.apiKey, 'test-key-a');
    expect(aiB.config.apiKey, isEmpty);
  });

  test('search queue and service configuration stay isolated', () async {
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
    final queueA = await PlaybackStateService.load(scope: scopeA);
    final queueB = await PlaybackStateService.load(scope: scopeB);
    expect(queueA!.queue.single.id, 'queue-a');
    expect(queueA.playMode, 'shuffle');
    expect(queueB!.queue.single.id, 'queue-b');
    expect(queueB.playMode, 'repeat');
    expect((await WebDavConfig.load(dataScope: scopeA)).username, 'a');
    expect((await WebDavConfig.load(dataScope: scopeB)).username, 'b');
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(scopeA.preferenceKey(FloatingCapsuleService.preferenceKey)),
      isTrue,
    );
    expect(
      prefs.getBool(scopeB.preferenceKey(FloatingCapsuleService.preferenceKey)),
      isFalse,
    );
  });

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

  test('version 3 backup restores to default instead of active user', () async {
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
      sections: const [BackupRestoreSection.songs, BackupRestoreSection.apiKey],
    );

    expect(result.restoredToDefaultUser, isTrue);
    expect(activeFavorites.allFavorites, isEmpty);
    expect(activePlayer.apiKey, 'active-key');
    final defaultFavorites = FavoriteService();
    final defaultPlayer = PlayerProvider(activateRestoredSession: false);
    addTearDown(() {
      defaultFavorites.dispose();
      defaultPlayer.dispose();
    });
    await Future.wait([defaultFavorites.load(), defaultPlayer.settingsReady]);
    expect(defaultFavorites.allFavorites.single.id, 'legacy-default');
    expect(defaultPlayer.apiKey, 'legacy-default-key');
  });

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

    await users.switchUser(second.id);
    await tester.pumpAndSettle();

    mainContext = tester.element(find.byType(MainScreen));
    final switchedPlayer = mainContext.read<PlayerProvider>();
    expect(users.activeUserId, second.id);
    expect(switchedPlayer, isNot(same(initialPlayer)));
    expect(switchedPlayer.dataScope.userId, second.id);
    expect(mainContext.read<FavoriteService>().dataScope.userId, second.id);
    expect(mainContext.read<SearchSession>().dataScope.userId, second.id);
    expect(mainContext.read<ThemeController>().dataScope.userId, second.id);
    expect(mainContext.read<AiConfigController>().dataScope.userId, second.id);
    expect(systemPlayer, same(switchedPlayer));
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
      expect(find.byKey(const ValueKey('user-switch-dialog')), findsOneWidget);
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
