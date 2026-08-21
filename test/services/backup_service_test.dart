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
    'backup round-trips all AI profiles, relays, keys and pet settings',
    () async {
      final player = PlayerProvider();
      addTearDown(player.dispose);
      await player.settingsReady;
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
          voiceModel: AiVoiceModelKind.paraformerBilingual,
        ),
      );
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
      final exportedAi = exported['aiAssistant'] as Map<String, dynamic>;
      expect(exportedAi['config'], containsPair('apiKey', 'ai-secret'));
      expect(
        exportedAi['config'],
        containsPair('voiceModel', AiVoiceModelKind.paraformerBilingual.value),
      );
      expect(exportedAi['activeProfileId'], primaryId);
      final profiles = exportedAi['profiles'] as List<dynamic>;
      expect(profiles, hasLength(2));
      expect(
        profiles
            .map((item) => (item as Map<String, dynamic>)['config'])
            .map((item) => (item as Map<String, dynamic>)['apiKey']),
        containsAll(['ai-secret', 'backup-secret']),
      );

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
      expect(restored.config.voiceModel, AiVoiceModelKind.paraformerBilingual);
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
}
