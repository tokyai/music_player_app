import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/ai_assistant.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/ai_config_controller.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/services/backup_service.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'restore applies the API Key together with songs and playlists',
    () async {
      final player = PlayerProvider();
      addTearDown(player.dispose);
      await player.settingsReady;
      await player.setApiKey('old-key');

      final favorites = FavoriteService();
      final backup = jsonEncode({
        'format': FavoriteService.exportFormat,
        'version': FavoriteService.exportVersion,
        'songs': [
          SongSearchResult(
            platform: MusicPlatform.qq,
            id: 'song-1',
            name: 'Song One',
            artist: 'Singer',
            album: 'Album',
          ).toJson(),
        ],
        'bilibili': [
          SongSearchResult(
            platform: MusicPlatform.bilibili,
            id: 'BV1backup',
            name: 'Backup Video',
            artist: 'UP',
            album: 'Backup Video',
          ).toJson(),
        ],
        'playlists': [
          FavoritePlaylist(
            platform: MusicPlatform.netease,
            playlist: PlaylistInfo(
              id: 'playlist-1',
              name: 'Playlist One',
              trackCount: 20,
              tracks: const [],
            ),
          ).toJson(),
        ],
        'apiKey': 'restored-key',
      });

      final result = await BackupService.importJson(
        raw: backup,
        favorites: favorites,
        player: player,
        mode: FavoriteImportMode.replace,
      );

      expect(player.apiKey, 'restored-key');
      expect(favorites.favorites.single.id, 'song-1');
      expect(favorites.bilibiliFavorites.single.id, 'BV1backup');
      expect(favorites.favoritePlaylists.single.id, 'playlist-1');
      expect(result.apiKeyRestored, isTrue);
      expect(result.bilibiliAdded, 1);
    },
  );

  test(
    'backup round-trips AI profiles but excludes device voice settings',
    () async {
      final player = PlayerProvider();
      addTearDown(player.dispose);
      await player.settingsReady;
      await player.setApiKey('music-secret');
      final favorites = FavoriteService();
      final source = AiConfigController(secretStore: MemoryAiSecretStore());
      addTearDown(source.dispose);
      await source.ready;
      await source.save(
        const AiAssistantConfig(
          provider: AiProviderKind.mimo,
          protocol: AiRequestProtocol.openAiChatCompletions,
          baseUrl: 'https://example.test/v1',
          apiKey: 'ai-secret',
          model: 'mimo-test',
          reasoningEffort: AiReasoningEffort.high,
          webSearchMode: AiWebSearchMode.always,
        ),
      );
      await source.setVoiceModel(AiVoiceModelKind.doubaoIme);
      await source.setVoiceLoadMode(AiVoiceLoadMode.startupPreload);
      final primaryId = source.activeProfileId;
      await source.renameProfile(primaryId, '主力模型');
      final backupProfile = await source.createProfile(
        name: '备用中转站',
        config: const AiAssistantConfig(
          provider: AiProviderKind.custom,
          protocol: AiRequestProtocol.openAiChatCompletions,
          baseUrl: 'https://backup.example/v1',
          apiKey: 'backup-secret',
          model: 'backup-model',
          reasoningEffort: AiReasoningEffort.medium,
          webSearchMode: AiWebSearchMode.disabled,
        ),
      );
      await source.selectProfile(primaryId);
      await source.setShowAssistantOnAllPages(false);
      await source.setShowPetOnPlayerPage(false);
      await source.setPetScale(1.6);
      await source.setPetPosition(const AiPetPosition(x: 0.25, y: 0.75));

      final raw = BackupService.exportJson(
        favorites: favorites,
        player: player,
        aiConfig: source,
      );
      final exported = jsonDecode(raw) as Map<String, dynamic>;
      expect(exported['apiKey'], 'music-secret');
      final exportedAi = exported['aiAssistant'] as Map<String, dynamic>;
      expect(exportedAi['config'], containsPair('apiKey', 'ai-secret'));
      expect(exportedAi['config'], isNot(contains('voiceModel')));
      expect(raw, isNot(contains(AiVoiceModelKind.doubaoIme.value)));
      expect(raw, isNot(contains(AiVoiceLoadMode.startupPreload.value)));
      expect(exportedAi['activeProfileId'], primaryId);
      final profiles = exportedAi['profiles'] as List<dynamic>;
      expect(profiles, hasLength(2));
      expect(
        profiles
            .map((item) => (item as Map<String, dynamic>)['config'])
            .map((item) => (item as Map<String, dynamic>)['apiKey']),
        containsAll(['ai-secret', 'backup-secret']),
      );

      await source.setVoiceModel(AiVoiceModelKind.systemSpeech);
      await source.setVoiceLoadMode(AiVoiceLoadMode.onDemand);
      final restored = AiConfigController(secretStore: MemoryAiSecretStore());
      addTearDown(restored.dispose);
      await restored.ready;
      final result = await BackupService.importJson(
        raw: raw,
        favorites: FavoriteService(),
        player: player,
        aiConfig: restored,
        mode: FavoriteImportMode.replace,
      );

      expect(result.aiConfigRestored, isTrue);
      expect(restored.config.provider, AiProviderKind.mimo);
      expect(restored.config.apiKey, 'ai-secret');
      expect(restored.config.model, 'mimo-test');
      expect(restored.config.reasoningEffort, AiReasoningEffort.high);
      expect(restored.config.webSearchMode, AiWebSearchMode.always);
      expect(restored.voiceModel, AiVoiceModelKind.systemSpeech);
      expect(restored.voiceLoadMode, AiVoiceLoadMode.onDemand);
      expect(restored.profiles.map((profile) => profile.name), [
        '主力模型',
        '备用中转站',
      ]);
      expect(restored.activeProfileId, primaryId);
      await restored.selectProfile(backupProfile.id);
      expect(restored.config.baseUrl, 'https://backup.example/v1');
      expect(restored.config.apiKey, 'backup-secret');
      expect(restored.config.model, 'backup-model');
      expect(restored.showAssistantOnAllPages, isFalse);
      expect(restored.showPetOnPlayerPage, isFalse);
      expect(restored.petScale, closeTo(1.6, 0.001));
      expect(restored.petPosition.x, closeTo(0.25, 0.001));
      expect(restored.petPosition.y, closeTo(0.75, 0.001));
    },
  );

  test('restores an API key from a legacy single AI config backup', () async {
    final player = PlayerProvider();
    addTearDown(player.dispose);
    await player.settingsReady;
    final aiConfig = AiConfigController(secretStore: MemoryAiSecretStore());
    addTearDown(aiConfig.dispose);
    await aiConfig.ready;
    await aiConfig.setVoiceModel(AiVoiceModelKind.systemSpeech);
    await aiConfig.setVoiceLoadMode(AiVoiceLoadMode.startupPreload);

    final result = await BackupService.importJson(
      raw: jsonEncode({
        'format': FavoriteService.exportFormat,
        'version': 3,
        'songs': <dynamic>[],
        'apiKey': 'legacy-music-key',
        'aiAssistant': {
          'config': {
            'provider': 'custom',
            'protocol': 'openai_chat',
            'baseUrl': 'https://legacy.example/v1',
            'model': 'legacy-model',
            'apiKey': 'legacy-ai-key',
            'voiceModel': AiVoiceModelKind.doubaoIme.value,
            'voiceLoadMode': AiVoiceLoadMode.onDemand.value,
          },
        },
      }),
      favorites: FavoriteService(),
      player: player,
      aiConfig: aiConfig,
      mode: FavoriteImportMode.replace,
    );

    expect(result.apiKeyRestored, isTrue);
    expect(result.aiConfigRestored, isTrue);
    expect(player.apiKey, 'legacy-music-key');
    expect(aiConfig.config.baseUrl, 'https://legacy.example/v1');
    expect(aiConfig.config.model, 'legacy-model');
    expect(aiConfig.config.apiKey, 'legacy-ai-key');
    expect(aiConfig.voiceModel, AiVoiceModelKind.systemSpeech);
    expect(aiConfig.voiceLoadMode, AiVoiceLoadMode.startupPreload);
  });

  test('backup round-trips playback sources and player preferences', () async {
    final source = PlayerProvider();
    addTearDown(source.dispose);
    await source.settingsReady;
    await source.setNeteaseLevel(NeteaseLevel.lossless);
    await source.setCommonLevel(CommonLevel.master);
    await source.setPlaybackSource(MusicPlatform.qq, PlaybackSource.qingMusic);
    await source.setPlaybackSource(
      MusicPlatform.kugou,
      PlaybackSource.qingMusic,
    );
    await source.setBilibiliAudioQuality(30232);
    await source.setBilibiliVideoQuality(64);
    await source.setBilibiliLyricPlatformOrder([
      MusicPlatform.kugou,
      MusicPlatform.qq,
      MusicPlatform.netease,
    ]);
    await source.setLyricOffsetStep(const Duration(milliseconds: 800));
    await source.setVideoPlayerMode(VideoPlayerMode.mpv);

    final raw = BackupService.exportJson(
      favorites: FavoriteService(),
      player: source,
    );
    final exported = jsonDecode(raw) as Map<String, dynamic>;
    final playerSettings = exported['playerSettings'] as Map<String, dynamic>;
    expect(playerSettings['neteaseLevel'], NeteaseLevel.lossless.value);
    expect(playerSettings['commonLevel'], CommonLevel.master.value);
    expect(
      (playerSettings['playbackSources']
          as Map<String, dynamic>)[MusicPlatform.qq.code],
      PlaybackSource.qingMusic.value,
    );
    expect(playerSettings['videoPlayerMode'], VideoPlayerMode.mpv.value);

    // Start the destination from clean defaults so the import, rather than
    // SharedPreferences left by the source player, applies every value.
    SharedPreferences.setMockInitialValues({});
    final restored = PlayerProvider();
    addTearDown(restored.dispose);
    await restored.settingsReady;
    final result = await BackupService.importJson(
      raw: raw,
      favorites: FavoriteService(),
      player: restored,
      mode: FavoriteImportMode.replace,
    );

    expect(result.playerSettingsRestored, isTrue);
    expect(restored.neteaseLevel, NeteaseLevel.lossless);
    expect(restored.commonLevel, CommonLevel.master);
    expect(
      restored.playbackSourceFor(MusicPlatform.qq),
      PlaybackSource.qingMusic,
    );
    expect(
      restored.playbackSourceFor(MusicPlatform.kugou),
      PlaybackSource.qingMusic,
    );
    expect(restored.bilibiliAudioQuality, 30232);
    expect(restored.bilibiliVideoQuality, 64);
    expect(restored.bilibiliLyricPlatformOrder, [
      MusicPlatform.kugou,
      MusicPlatform.qq,
      MusicPlatform.netease,
    ]);
    expect(restored.lyricOffsetStep, const Duration(milliseconds: 800));
    expect(restored.videoPlayerMode, VideoPlayerMode.mpv);
  });

  test('partial restore changes only the selected sections', () async {
    final oldSong = _song(MusicPlatform.qq, 'old-song', '旧歌曲');
    final oldVideo = _song(MusicPlatform.bilibili, 'old-video', '旧视频');
    final oldPlaylist = FavoritePlaylist(
      platform: MusicPlatform.qq,
      playlist: PlaylistInfo(
        id: 'old-playlist',
        name: '旧歌单',
        trackCount: 1,
        tracks: const [],
      ),
    );
    final newSong = _song(MusicPlatform.netease, 'new-song', '新歌曲');
    final newVideo = _song(MusicPlatform.bilibili, 'new-video', '新视频');
    final newPlaylist = FavoritePlaylist(
      platform: MusicPlatform.netease,
      playlist: PlaylistInfo(
        id: 'new-playlist',
        name: '新歌单',
        trackCount: 2,
        tracks: const [],
      ),
    );

    final raw = jsonEncode({
      'format': FavoriteService.exportFormat,
      'version': FavoriteService.exportVersion,
      'songs': [newSong.toJson()],
      'bilibili': [newVideo.toJson()],
      'playlists': [newPlaylist.toJson()],
      'apiKey': 'new-key',
      'aiAssistant': <String, dynamic>{'config': <String, dynamic>{}},
      'playerSettings': <String, dynamic>{
        'neteaseLevel': NeteaseLevel.lossless.value,
      },
    });
    final contents = BackupService.inspect(raw);
    expect(
      contents.availableSections,
      containsAll(BackupRestoreSection.values),
    );

    SharedPreferences.setMockInitialValues({});
    final favorites = FavoriteService();
    await favorites.toggle(oldSong);
    await favorites.toggle(oldVideo);
    await favorites.togglePlaylist(oldPlaylist.platform, oldPlaylist.playlist);
    final player = PlayerProvider();
    addTearDown(player.dispose);
    await player.settingsReady;
    await player.setApiKey('old-key');

    final result = await BackupService.importJson(
      raw: raw,
      favorites: favorites,
      player: player,
      mode: FavoriteImportMode.replace,
      sections: const {BackupRestoreSection.songs},
    );

    expect(favorites.favorites.map((song) => song.id), ['new-song']);
    expect(favorites.bilibiliFavorites.map((song) => song.id), ['old-video']);
    expect(favorites.favoritePlaylists.map((item) => item.id), [
      'old-playlist',
    ]);
    expect(player.apiKey, 'old-key');
    expect(player.neteaseLevel, isNot(NeteaseLevel.lossless));
    expect(result.apiKeyRestored, isFalse);
    expect(result.playerSettingsRestored, isFalse);
    expect(result.aiConfigRestored, isFalse);
    expect(result.bilibiliAdded, 0);
    expect(result.playlistsAdded, 0);
  });

  test('rejects oversized backup text before JSON decoding', () {
    final oversized = 'x' * (BackupService.maxBackupBytes + 1);
    expect(
      () => BackupService.inspect(oversized),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects an invalid AI API key before changing existing data', () async {
    final oldSong = _song(MusicPlatform.qq, 'old-song', '旧歌曲');
    final newSong = _song(MusicPlatform.qq, 'new-song', '新歌曲');
    final favorites = FavoriteService();
    await favorites.toggle(oldSong);
    final player = PlayerProvider();
    addTearDown(player.dispose);
    await player.settingsReady;
    await player.setApiKey('old-music-key');
    final aiConfig = AiConfigController(secretStore: MemoryAiSecretStore());
    addTearDown(aiConfig.dispose);
    await aiConfig.ready;
    await aiConfig.save(
      _config(
        url: 'https://old.example/v1',
        key: 'old-ai-key',
        model: 'old-model',
      ),
    );

    final malformed = jsonEncode({
      'format': FavoriteService.exportFormat,
      'version': FavoriteService.exportVersion,
      'songs': [newSong.toJson()],
      'apiKey': 'new-music-key',
      'aiAssistant': {
        'profiles': [
          {
            'id': 'invalid-profile',
            'name': '无效配置',
            'config': {
              'provider': 'custom',
              'protocol': 'openai_chat',
              'baseUrl': 'https://new.example/v1',
              'model': 'new-model',
              'apiKey': 123,
            },
          },
        ],
      },
    });

    await expectLater(
      BackupService.importJson(
        raw: malformed,
        favorites: favorites,
        player: player,
        aiConfig: aiConfig,
        mode: FavoriteImportMode.replace,
      ),
      throwsA(isA<FormatException>()),
    );

    expect(favorites.favorites.map((song) => song.id), ['old-song']);
    expect(player.apiKey, 'old-music-key');
    expect(aiConfig.config.baseUrl, 'https://old.example/v1');
    expect(aiConfig.config.model, 'old-model');
    expect(aiConfig.config.apiKey, 'old-ai-key');
  });
}

SongSearchResult _song(MusicPlatform platform, String id, String name) {
  return SongSearchResult(
    platform: platform,
    id: id,
    name: name,
    artist: '测试歌手',
    album: '测试专辑',
  );
}

AiAssistantConfig _config({
  required String url,
  required String key,
  required String model,
}) => AiAssistantConfig(
  provider: AiProviderKind.custom,
  protocol: AiRequestProtocol.openAiChatCompletions,
  baseUrl: url,
  apiKey: key,
  model: model,
  reasoningEffort: AiReasoningEffort.platformDefault,
  webSearchMode: AiWebSearchMode.disabled,
);
