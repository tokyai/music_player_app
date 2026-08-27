import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/ai_assistant.dart';
import 'package:music_player_app/models/app_user.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/ai_config_controller.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/providers/user_controller.dart';
import 'package:music_player_app/services/backup_service.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/services/playback_history_service.dart';
import 'package:music_player_app/services/playback_state_service.dart';
import 'package:music_player_app/services/user_avatar_storage.dart';
import 'package:music_player_app/services/user_data_scope.dart';
import 'package:music_player_app/services/webdav_backup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_avatar_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    const secureStorageChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, null);
    });
  });

  test(
    'full backup exported from a secondary user restores every user without mixing data',
    () async {
      final fixture = await _FullBackupFixture.create();
      addTearDown(fixture.dispose);

      final decoded = jsonDecode(fixture.raw) as Map<String, dynamic>;
      expect(decoded['format'], BackupService.fullSnapshotFormat);
      expect(decoded['activeUserId'], fixture.secondUserId);
      final exportedUsers = (decoded['users'] as List).cast<Map>();
      expect(exportedUsers, hasLength(2));
      expect(
        exportedUsers.map((item) => (item['profile'] as Map)['name']),
        containsAll(['默认驾驶员', '副驾驶']),
      );
      final exportedSecond = exportedUsers.firstWhere(
        (item) => (item['profile'] as Map)['id'] == fixture.secondUserId,
      );
      expect(exportedSecond['avatarJpegBase64'], isNotEmpty);

      final third = await fixture.users.createUser(
        name: '临时用户',
        avatarId: 'person',
        avatarColorIndex: 3,
      );
      final thirdScope = UserDataScope(third.id);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        thirdScope.preferenceKey('favorites'),
        jsonEncode([_song(MusicPlatform.qq, 'third-song', '临时歌曲').toJson()]),
      );
      await fixture.users.updateUser(
        fixture.secondUserId,
        name: '已修改副驾驶',
        avatarId: AppUserProfile.customAvatarId,
        avatarColorIndex: 7,
      );
      await fixture.users.updateUser(
        AppUserProfile.defaultUserId,
        name: '已修改默认用户',
        avatarId: 'star',
        avatarColorIndex: 6,
      );
      await _replaceUserData(
        fixture.defaultScope,
        song: _song(MusicPlatform.qq, 'wrong-default', '错误默认歌曲'),
        search: '错误默认搜索',
        history: _song(MusicPlatform.qq, 'wrong-default-history', '错误默认历史'),
        queue: _song(MusicPlatform.qq, 'wrong-default-queue', '错误默认队列'),
      );
      await _replaceUserData(
        fixture.secondScope,
        song: _song(MusicPlatform.qq, 'wrong-second', '错误副驾驶歌曲'),
        search: '错误副驾驶搜索',
        history: _song(MusicPlatform.qq, 'wrong-second-history', '错误副驾驶历史'),
        queue: _song(MusicPlatform.qq, 'wrong-second-queue', '错误副驾驶队列'),
      );
      await const WebDavConfig(
        url: 'https://changed.example/dav',
        username: 'changed-default',
        password: 'changed',
        certificateSha256: '',
      ).save();
      await WebDavConfig(
        url: 'https://changed.example/dav',
        username: 'changed-second',
        password: 'changed',
        certificateSha256: '',
        dataScope: fixture.secondScope,
      ).save();
      await prefs.setString('test_global_config', 'changed');
      await prefs.setString('extra_global_config', 'remove-me');
      await fixture.player.setApiKey('changed-music-key');
      await fixture.player.setCommonLevel(CommonLevel.k128);
      await fixture.theme.setMode(ThemeMode.light);
      await fixture.ai.updateProfile(
        fixture.ai.activeProfileId,
        config: fixture.ai.config.copyWith(
          baseUrl: 'https://changed.example/v1',
          apiKey: 'changed-ai-key',
          model: 'changed-model',
        ),
      );
      await fixture.ai.setVoiceModel(AiVoiceModelKind.systemSpeech);

      final result = await BackupService.importJson(
        raw: fixture.raw,
        favorites: fixture.activeFavorites,
        player: fixture.player,
        aiConfig: fixture.ai,
        theme: fixture.theme,
        search: fixture.activeSearch,
        users: fixture.users,
      );

      expect(result.fullSnapshotRestored, isTrue);
      expect(fixture.users.activeUserId, fixture.secondUserId);
      expect(fixture.users.users, hasLength(2));
      expect(
        fixture.users.userById(AppUserProfile.defaultUserId).name,
        '默认驾驶员',
      );
      final restoredSecond = fixture.users.userById(fixture.secondUserId);
      expect(restoredSecond.name, '副驾驶');
      expect(restoredSecond.hasCustomAvatar, isTrue);
      expect(
        await fixture.users.avatarStorage.read(restoredSecond.avatarFileName),
        testAvatarJpeg,
      );
      expect(prefs.getString(thirdScope.preferenceKey('favorites')), isNull);

      final defaultFavorites = FavoriteService(dataScope: fixture.defaultScope);
      final secondFavorites = FavoriteService(dataScope: fixture.secondScope);
      final defaultSearch = SearchSession(dataScope: fixture.defaultScope);
      final secondSearch = SearchSession(dataScope: fixture.secondScope);
      addTearDown(() {
        defaultFavorites.dispose();
        secondFavorites.dispose();
        defaultSearch.dispose();
        secondSearch.dispose();
      });
      await Future.wait([
        defaultFavorites.load(),
        secondFavorites.load(),
        defaultSearch.historyReady,
        secondSearch.historyReady,
      ]);

      expect(defaultFavorites.favorites.map((song) => song.id), [
        'default-song',
      ]);
      expect(defaultFavorites.favoritePlaylists.map((item) => item.id), [
        'default-playlist',
      ]);
      expect(secondFavorites.favorites.map((song) => song.id), ['second-song']);
      expect(secondFavorites.bilibiliFavorites.map((song) => song.id), [
        'second-video',
      ]);
      expect(secondFavorites.favoritePlaylists.map((item) => item.id), [
        'second-playlist',
      ]);
      expect(defaultSearch.searchHistory, ['默认搜索']);
      expect(secondSearch.searchHistory, ['副驾驶搜索']);
      expect(
        (await PlaybackHistoryService.load(
          scope: fixture.defaultScope,
        )).single.song.id,
        'default-history',
      );
      expect(
        (await PlaybackHistoryService.load(
          scope: fixture.secondScope,
        )).single.song.id,
        'second-history',
      );
      expect(
        (await PlaybackStateService.load(
          scope: fixture.defaultScope,
        ))!.queue.single.id,
        'default-queue',
      );
      expect(
        (await PlaybackStateService.load(
          scope: fixture.secondScope,
        ))!.queue.single.id,
        'second-queue',
      );
      expect((await WebDavConfig.load()).username, 'default-webdav');
      expect(
        (await WebDavConfig.load(dataScope: fixture.secondScope)).username,
        'second-webdav',
      );
      expect(prefs.getString('test_global_config'), 'snapshot-global');
      expect(prefs.getString('extra_global_config'), isNull);
      expect(fixture.player.apiKey, 'snapshot-music-key');
      expect(fixture.player.commonLevel, CommonLevel.master);
      expect(fixture.theme.mode, ThemeMode.dark);
      expect(fixture.ai.config.baseUrl, 'https://snapshot.example/v1');
      expect(fixture.ai.config.apiKey, 'snapshot-ai-key');
      expect(fixture.ai.config.model, 'snapshot-model');
      expect(fixture.ai.voiceModel, AiVoiceModelKind.doubaoIme);
      expect(fixture.ai.voiceLoadMode, AiVoiceLoadMode.startupPreload);
    },
  );

  test(
    'invalid full snapshots are rejected before preferences or users change',
    () async {
      final fixture = await _FullBackupFixture.create();
      addTearDown(fixture.dispose);
      final prefs = await SharedPreferences.getInstance();
      final beforePreferences = {
        for (final key in prefs.getKeys()) key: prefs.get(key),
      };
      final beforeUsers = fixture.users.users
          .map((user) => user.toJson())
          .toList();

      Future<void> expectRejected(
        void Function(Map<String, dynamic> backup) corrupt,
      ) async {
        final backup = jsonDecode(fixture.raw) as Map<String, dynamic>;
        corrupt(backup);
        await expectLater(
          BackupService.importJson(
            raw: jsonEncode(backup),
            favorites: fixture.activeFavorites,
            player: fixture.player,
            aiConfig: fixture.ai,
            theme: fixture.theme,
            search: fixture.activeSearch,
            users: fixture.users,
          ),
          throwsA(isA<FormatException>()),
        );
        expect({
          for (final key in prefs.getKeys()) key: prefs.get(key),
        }, beforePreferences);
        expect(
          fixture.users.users.map((user) => user.toJson()).toList(),
          beforeUsers,
        );
      }

      await expectRejected((backup) {
        final users = backup['users'] as List;
        (users[1]['profile'] as Map)['id'] = AppUserProfile.defaultUserId;
      });
      await expectRejected((backup) {
        final users = backup['users'] as List;
        users[1]['avatarJpegBase64'] = 'not-valid-base64';
      });
      await expectRejected((backup) {
        final users = backup['users'] as List;
        (users[0]['data'] as Map)['playbackHistory'] = {
          'version': 1,
          'items': [
            {'broken': true},
          ],
        };
      });
      await expectRejected((backup) {
        final users = backup['users'] as List;
        (users[0]['data'] as Map)['playbackState'] = {
          'version': 1,
          'queue': [
            {'broken': true},
          ],
          'currentIndex': 0,
          'positionMs': 0,
          'isPlaying': false,
          'playMode': 'sequence',
        };
      });
    },
  );

  test(
    'failed session rebuild rolls data back before the final session reload',
    () async {
      final fixture = await _FullBackupFixture.create();
      addTearDown(fixture.dispose);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('test_global_config', 'before-restore');
      await fixture.users.updateUser(
        fixture.secondUserId,
        name: '还原前副驾驶',
        avatarId: AppUserProfile.customAvatarId,
        avatarColorIndex: 6,
      );
      final observedGlobalValues = <String?>[];
      fixture.users.attachSessionReloader(() async {
        observedGlobalValues.add(prefs.getString('test_global_config'));
        if (observedGlobalValues.length == 1) {
          throw StateError('simulated session rebuild failure');
        }
      });

      await expectLater(
        BackupService.importJson(
          raw: fixture.raw,
          favorites: fixture.activeFavorites,
          player: fixture.player,
          aiConfig: fixture.ai,
          theme: fixture.theme,
          search: fixture.activeSearch,
          users: fixture.users,
        ),
        throwsA(isA<StateError>()),
      );

      expect(observedGlobalValues, [
        'snapshot-global',
        'snapshot-global',
        'before-restore',
      ]);
      expect(prefs.getString('test_global_config'), 'before-restore');
      expect(fixture.users.activeUserId, fixture.secondUserId);
      expect(fixture.users.userById(fixture.secondUserId).name, '还原前副驾驶');
    },
  );

  test(
    'AI secret persistence failure aborts and rolls the snapshot back',
    () async {
      final secretStore = _ControllableAiSecretStore();
      final fixture = await _FullBackupFixture.create(secretStore: secretStore);
      addTearDown(fixture.dispose);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('test_global_config', 'before-secret-failure');
      await fixture.ai.updateProfile(
        fixture.ai.activeProfileId,
        config: fixture.ai.config.copyWith(
          baseUrl: 'https://before.example/v1',
          apiKey: 'before-key',
          model: 'before-model',
        ),
      );
      secretStore.failNextWrite = true;

      await expectLater(
        BackupService.importJson(
          raw: fixture.raw,
          favorites: fixture.activeFavorites,
          player: fixture.player,
          aiConfig: fixture.ai,
          theme: fixture.theme,
          search: fixture.activeSearch,
          users: fixture.users,
        ),
        throwsA(isA<StateError>()),
      );

      expect(prefs.getString('test_global_config'), 'before-secret-failure');
      expect(fixture.ai.config.baseUrl, 'https://before.example/v1');
      expect(fixture.ai.config.apiKey, 'before-key');
      expect(fixture.ai.config.model, 'before-model');
      expect(
        jsonDecode(secretStore.value!) as Map<String, dynamic>,
        containsValue('before-key'),
      );
    },
  );

  test(
    'failed restore preserves a queue update still inside its debounce',
    () async {
      final fixture = await _FullBackupFixture.create();
      addTearDown(fixture.dispose);
      final latest = _song(MusicPlatform.qq, 'latest-queue-item', '刚加入队列');
      fixture.player.addToQueue(latest);
      fixture.users.attachSessionReloader(() async {
        throw StateError('simulated session rebuild failure');
      });

      await expectLater(
        BackupService.importJson(
          raw: fixture.raw,
          favorites: fixture.activeFavorites,
          player: fixture.player,
          aiConfig: fixture.ai,
          theme: fixture.theme,
          search: fixture.activeSearch,
          users: fixture.users,
        ),
        throwsA(isA<StateError>()),
      );

      final restoredState = await PlaybackStateService.load(
        scope: fixture.secondScope,
      );
      expect(restoredState, isNotNull);
      expect(restoredState!.queue.map((song) => song.id), contains(latest.id));
    },
  );
}

class _FullBackupFixture {
  final Directory root;
  final UserController users;
  final String secondUserId;
  final FavoriteService defaultFavorites;
  final FavoriteService activeFavorites;
  final PlayerProvider player;
  final SearchSession activeSearch;
  final AiConfigController ai;
  final ThemeController theme;
  final String raw;

  const _FullBackupFixture({
    required this.root,
    required this.users,
    required this.secondUserId,
    required this.defaultFavorites,
    required this.activeFavorites,
    required this.player,
    required this.activeSearch,
    required this.ai,
    required this.theme,
    required this.raw,
  });

  UserDataScope get defaultScope => UserDataScope.defaultScope;
  UserDataScope get secondScope => UserDataScope(secondUserId);

  static Future<_FullBackupFixture> create({AiSecretStore? secretStore}) async {
    final root = await Directory.systemTemp.createTemp('kuzai-full-backup-');
    final users = UserController(
      avatarStorage: UserAvatarStorage(rootDirectory: root),
    );
    await users.ready;
    await users.updateUser(
      AppUserProfile.defaultUserId,
      name: '默认驾驶员',
      avatarId: 'car',
      avatarColorIndex: 2,
    );
    final second = await users.createUser(
      name: '副驾驶',
      avatarId: 'person',
      avatarColorIndex: 4,
      customAvatarBytes: testAvatarJpeg,
    );
    await users.switchUser(second.id);
    final secondScope = UserDataScope(second.id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('search_history', ['默认搜索']);
    await prefs.setStringList(secondScope.preferenceKey('search_history'), [
      '副驾驶搜索',
    ]);
    await prefs.setString('test_global_config', 'snapshot-global');
    await PlaybackHistoryService.save([
      _history(_song(MusicPlatform.qq, 'default-history', '默认历史')),
    ]);
    await PlaybackStateService.save(
      _snapshot(_song(MusicPlatform.qq, 'default-queue', '默认队列')),
    );
    await PlaybackHistoryService.save([
      _history(_song(MusicPlatform.qq, 'second-history', '副驾驶历史')),
    ], scope: secondScope);
    await PlaybackStateService.save(
      _snapshot(_song(MusicPlatform.qq, 'second-queue', '副驾驶队列')),
      scope: secondScope,
    );

    final defaultFavorites = FavoriteService();
    final activeFavorites = FavoriteService(dataScope: secondScope);
    final player = PlayerProvider(
      dataScope: secondScope,
      activateRestoredSession: false,
    );
    final activeSearch = SearchSession(dataScope: secondScope);
    final ai = AiConfigController(
      secretStore: secretStore ?? MemoryAiSecretStore(),
    );
    final theme = ThemeController();
    await Future.wait([
      defaultFavorites.load(),
      activeFavorites.load(),
      player.settingsReady,
      player.historyReady,
      player.playbackStateReady,
      activeSearch.historyReady,
      ai.ready,
      theme.ready,
    ]);

    await defaultFavorites.toggle(
      _song(MusicPlatform.qq, 'default-song', '默认歌曲'),
    );
    await defaultFavorites.togglePlaylist(
      MusicPlatform.netease,
      _playlist('default-playlist', '默认歌单'),
    );
    await activeFavorites.toggle(
      _song(MusicPlatform.qq, 'second-song', '副驾驶歌曲'),
    );
    await activeFavorites.toggle(
      _song(MusicPlatform.bilibili, 'second-video', '副驾驶视频'),
    );
    await activeFavorites.togglePlaylist(
      MusicPlatform.qq,
      _playlist('second-playlist', '副驾驶歌单'),
    );
    await const WebDavConfig(
      url: 'https://default.example/dav',
      username: 'default-webdav',
      password: 'default-password',
      certificateSha256: '',
    ).save();
    await WebDavConfig(
      url: 'https://second.example/dav',
      username: 'second-webdav',
      password: 'second-password',
      certificateSha256: '',
      dataScope: secondScope,
    ).save();
    await player.setApiKey('snapshot-music-key');
    await player.setCommonLevel(CommonLevel.master);
    await theme.setMode(ThemeMode.dark);
    await theme.setFontScale(1.2);
    await ai.updateProfile(
      ai.activeProfileId,
      config: ai.config.copyWith(
        baseUrl: 'https://snapshot.example/v1',
        apiKey: 'snapshot-ai-key',
        model: 'snapshot-model',
      ),
    );
    await ai.setVoiceModel(AiVoiceModelKind.doubaoIme);
    await ai.setVoiceLoadMode(AiVoiceLoadMode.startupPreload);
    await ai.setBargeInMode(AiBargeInMode.voiceActivity);
    await ai.setAssistantPlaybackMode(AiAssistantPlaybackMode.duck);
    await ai.setDuckingReductionPercent(60);

    final raw = await BackupService.exportFullJson(
      users: users,
      favorites: activeFavorites,
      player: player,
      aiConfig: ai,
      theme: theme,
      search: activeSearch,
    );
    return _FullBackupFixture(
      root: root,
      users: users,
      secondUserId: second.id,
      defaultFavorites: defaultFavorites,
      activeFavorites: activeFavorites,
      player: player,
      activeSearch: activeSearch,
      ai: ai,
      theme: theme,
      raw: raw,
    );
  }

  Future<void> dispose() async {
    defaultFavorites.dispose();
    activeFavorites.dispose();
    player.dispose();
    activeSearch.dispose();
    ai.dispose();
    theme.dispose();
    users.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

Future<void> _replaceUserData(
  UserDataScope scope, {
  required SongSearchResult song,
  required String search,
  required SongSearchResult history,
  required SongSearchResult queue,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    scope.preferenceKey('favorites'),
    jsonEncode([song.toJson()]),
  );
  await prefs.setString(
    scope.preferenceKey('favorite_playlists'),
    jsonEncode(<dynamic>[]),
  );
  await prefs.setStringList(scope.preferenceKey('search_history'), [search]);
  await PlaybackHistoryService.save([_history(history)], scope: scope);
  await PlaybackStateService.save(_snapshot(queue), scope: scope);
}

PlaybackHistoryEntry _history(SongSearchResult song) => PlaybackHistoryEntry(
  song: song,
  position: const Duration(seconds: 12),
  playedAt: DateTime.utc(2026, 8, 27, 10),
);

PlaybackSessionSnapshot _snapshot(SongSearchResult song) =>
    PlaybackSessionSnapshot(
      queue: [song],
      currentIndex: 0,
      position: const Duration(seconds: 7),
      isPlaying: false,
      playMode: 'repeat',
    );

SongSearchResult _song(MusicPlatform platform, String id, String name) =>
    SongSearchResult(
      platform: platform,
      id: id,
      name: name,
      artist: '测试歌手',
      album: '测试专辑',
    );

PlaylistInfo _playlist(String id, String name) => PlaylistInfo(
  id: id,
  name: name,
  creator: '测试用户',
  trackCount: 3,
  tracks: const [],
);

class _ControllableAiSecretStore implements AiSecretStore {
  String? value;
  bool failNextWrite = false;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('simulated secure storage failure');
    }
    this.value = value;
  }
}
