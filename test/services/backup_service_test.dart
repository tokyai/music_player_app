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
    'backup round-trips the complete AI configuration and visibility',
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
          voiceModel: AiVoiceModelKind.zipformerChinese,
        ),
      );
      await source.setShowAssistantOnAllPages(false);
      await source.setShowPetOnPlayerPage(false);

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
        containsPair('voiceModel', AiVoiceModelKind.zipformerChinese.value),
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
      expect(restored.config.voiceModel, AiVoiceModelKind.zipformerChinese);
      expect(restored.showAssistantOnAllPages, isFalse);
      expect(restored.showPetOnPlayerPage, isFalse);
    },
  );
}
