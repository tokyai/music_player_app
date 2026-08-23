import 'dart:convert';

import '../models/song.dart';
import '../providers/ai_config_controller.dart';
import '../providers/player_provider.dart';
import '../services/favorite_service.dart';
import '../services/user_data_scope.dart';

/// A user-selectable portion of an exported backup.
enum BackupRestoreSection {
  songs,
  bilibili,
  playlists,
  apiKey,
  aiAssistant,
  playerSettings,
}

/// The import mode and the portions the user wants to restore.
class BackupRestoreSelection {
  final FavoriteImportMode mode;
  final Set<BackupRestoreSection> sections;

  BackupRestoreSelection({
    required this.mode,
    required Iterable<BackupRestoreSection> sections,
  }) : sections = Set.unmodifiable(sections);
}

/// Describes which optional sections are present in a backup payload.
class BackupRestoreContents {
  final bool songs;
  final bool bilibili;
  final bool playlists;
  final bool apiKey;
  final bool aiAssistant;
  final bool playerSettings;

  const BackupRestoreContents({
    required this.songs,
    required this.bilibili,
    required this.playlists,
    required this.apiKey,
    required this.aiAssistant,
    required this.playerSettings,
  });

  bool contains(BackupRestoreSection section) => switch (section) {
    BackupRestoreSection.songs => songs,
    BackupRestoreSection.bilibili => bilibili,
    BackupRestoreSection.playlists => playlists,
    BackupRestoreSection.apiKey => apiKey,
    BackupRestoreSection.aiAssistant => aiAssistant,
    BackupRestoreSection.playerSettings => playerSettings,
  };

  Set<BackupRestoreSection> get availableSections =>
      BackupRestoreSection.values.where(contains).toSet();
}

/// 收藏数据与播放器设置之间的备份协调层。
///
/// FavoriteService 只负责收藏数据本身，播放器 API Key 由这里统一编排，
/// 因此文件、WebDAV 和局域网三种入口都会得到完全一致的行为。
class BackupService {
  static const maxBackupBytes = 5 * 1024 * 1024;

  const BackupService._();

  static BackupRestoreContents inspect(String raw) {
    final decoded = _decodeJson(raw);

    if (decoded is List) {
      return BackupRestoreContents(
        songs: true,
        bilibili: _containsBilibili(decoded),
        playlists: false,
        apiKey: false,
        aiAssistant: false,
        playerSettings: false,
      );
    }
    if (decoded is! Map) {
      throw const FormatException('备份文件格式不受支持');
    }
    final format = decoded['format'];
    if (format != null && format != FavoriteService.exportFormat) {
      throw const FormatException('不是库仔音乐收藏备份');
    }
    final songs = decoded['songs'];
    if (songs is! List) {
      throw const FormatException('备份文件缺少歌曲列表');
    }
    final bilibili = decoded['bilibili'];
    if (bilibili != null && bilibili is! List) {
      throw const FormatException('备份文件中的 B站收藏格式错误');
    }
    final playlists = decoded['playlists'];
    if (playlists != null && playlists is! List) {
      throw const FormatException('备份文件中的歌单列表格式错误');
    }
    final rawApiKey = decoded['apiKey'];
    if (decoded.containsKey('apiKey') &&
        rawApiKey != null &&
        rawApiKey is! String) {
      throw const FormatException('备份文件中的 API Key 格式错误');
    }
    // The payload has already been decoded and validated above. Reuse this
    // tree instead of decoding the complete backup once per optional section.
    final aiAssistant = _readAiBackupValue(decoded);
    final playerSettings = _readPlayerBackupValue(decoded);
    return BackupRestoreContents(
      songs: true,
      bilibili: bilibili is List ? true : _containsBilibili(songs),
      playlists: playlists is List,
      apiKey: decoded.containsKey('apiKey'),
      aiAssistant: aiAssistant != null,
      playerSettings: playerSettings != null,
    );
  }

  static String exportJson({
    required FavoriteService favorites,
    required PlayerProvider player,
    AiConfigController? aiConfig,
  }) {
    final decoded = favorites.exportData(apiKey: player.apiKey);
    decoded['playerSettings'] = player.toBackupJson();
    if (aiConfig != null) {
      decoded['aiAssistant'] = aiConfig.toBackupJson();
    }
    return const JsonEncoder.withIndent('  ').convert(decoded);
  }

  static Future<BackupRestoreResult> importJson({
    required String raw,
    required FavoriteService favorites,
    required PlayerProvider player,
    AiConfigController? aiConfig,
    FavoriteImportMode mode = FavoriteImportMode.merge,
    Iterable<BackupRestoreSection>? sections,
  }) async {
    final decoded = _decodeJson(raw);
    final selectedSections = sections == null
        ? BackupRestoreSection.values.toSet()
        : sections.toSet();
    if (_isLegacyBackup(decoded) && !player.dataScope.isDefault) {
      const scope = UserDataScope.defaultScope;
      final defaultFavorites = FavoriteService(dataScope: scope);
      final defaultPlayer = PlayerProvider(
        dataScope: scope,
        activateRestoredSession: false,
      );
      final defaultAiConfig = aiConfig == null
          ? null
          : AiConfigController(dataScope: scope);
      try {
        await Future.wait<void>([
          defaultFavorites.load(),
          defaultPlayer.settingsReady,
          defaultPlayer.historyReady,
          defaultPlayer.playbackStateReady,
          if (defaultAiConfig != null) defaultAiConfig.ready,
        ]);
        final result = await _importDecoded(
          decoded: decoded,
          favorites: defaultFavorites,
          player: defaultPlayer,
          aiConfig: defaultAiConfig,
          mode: mode,
          selectedSections: selectedSections,
        );
        return result.copyWith(restoredToDefaultUser: true);
      } finally {
        defaultAiConfig?.dispose();
        defaultFavorites.dispose();
        defaultPlayer.dispose();
      }
    }
    return _importDecoded(
      decoded: decoded,
      favorites: favorites,
      player: player,
      aiConfig: aiConfig,
      mode: mode,
      selectedSections: selectedSections,
    );
  }

  static Future<BackupRestoreResult> _importDecoded({
    required dynamic decoded,
    required FavoriteService favorites,
    required PlayerProvider player,
    required AiConfigController? aiConfig,
    required FavoriteImportMode mode,
    required Set<BackupRestoreSection> selectedSections,
  }) async {
    final aiBackup = selectedSections.contains(BackupRestoreSection.aiAssistant)
        ? _readAiBackupValue(decoded)
        : null;
    final playerBackup =
        selectedSections.contains(BackupRestoreSection.playerSettings)
        ? _readPlayerBackupValue(decoded)
        : null;
    // Validate portable AI credentials before FavoriteService writes any
    // selected collection. A malformed key must not leave a half-restored
    // backup with new favorites but old settings.
    if (aiBackup != null && aiConfig != null) {
      await aiConfig.validateBackupJson(aiBackup);
    }
    final result = await favorites.importDecoded(
      decoded,
      mode: mode,
      importSongs: selectedSections.contains(BackupRestoreSection.songs),
      importBilibili: selectedSections.contains(BackupRestoreSection.bilibili),
      importPlaylists: selectedSections.contains(
        BackupRestoreSection.playlists,
      ),
      importApiKey: selectedSections.contains(BackupRestoreSection.apiKey),
    );
    var apiKeyRestored = false;
    if (selectedSections.contains(BackupRestoreSection.apiKey) &&
        result.apiKeyPresent) {
      await player.setApiKey(result.apiKey ?? '');
      apiKeyRestored = true;
    }
    var aiConfigRestored = false;
    if (selectedSections.contains(BackupRestoreSection.aiAssistant) &&
        aiBackup != null &&
        aiConfig != null) {
      await aiConfig.restoreBackupJson(aiBackup);
      aiConfigRestored = true;
    }
    var playerSettingsRestored = false;
    if (selectedSections.contains(BackupRestoreSection.playerSettings) &&
        playerBackup != null) {
      await player.restoreBackupJson(playerBackup);
      playerSettingsRestored = true;
    }
    return BackupRestoreResult(
      songsAdded: result.added,
      songsSkipped: result.skipped,
      songsTotal: result.total,
      bilibiliAdded: result.bilibiliAdded,
      bilibiliSkipped: result.bilibiliSkipped,
      bilibiliTotal: result.bilibiliTotal,
      playlistsAdded: result.playlistsAdded,
      playlistsSkipped: result.playlistsSkipped,
      apiKeyRestored: apiKeyRestored,
      aiConfigRestored: aiConfigRestored,
      playerSettingsRestored: playerSettingsRestored,
    );
  }

  static dynamic _decodeJson(String raw) {
    var byteLength = 0;
    for (var index = 0; index < raw.length; index++) {
      final codeUnit = raw.codeUnitAt(index);
      if (codeUnit <= 0x7f) {
        byteLength += 1;
      } else if (codeUnit <= 0x7ff) {
        byteLength += 2;
      } else if (codeUnit >= 0xd800 &&
          codeUnit <= 0xdbff &&
          index + 1 < raw.length &&
          raw.codeUnitAt(index + 1) >= 0xdc00 &&
          raw.codeUnitAt(index + 1) <= 0xdfff) {
        byteLength += 4;
        index++;
      } else {
        byteLength += 3;
      }
      if (byteLength > maxBackupBytes) {
        throw const FormatException('备份文件不能超过 5 MB');
      }
    }
    try {
      return jsonDecode(raw);
    } on FormatException {
      throw const FormatException('备份文件不是有效的 JSON');
    }
  }

  static bool _isLegacyBackup(dynamic decoded) {
    if (decoded is List) return true;
    if (decoded is! Map) return false;
    final version = decoded['version'];
    if (version is num) return version.toInt() <= 3;
    return decoded['userDataVersion'] != 1;
  }

  static Map<String, dynamic>? _readAiBackupValue(dynamic decoded) {
    if (decoded is! Map || !decoded.containsKey('aiAssistant')) return null;
    final value = decoded['aiAssistant'];
    if (value is! Map) {
      throw const FormatException('备份文件中的 AI 助理数据格式错误');
    }
    return Map<String, dynamic>.from(value);
  }

  static Map<String, dynamic>? _readPlayerBackupValue(dynamic decoded) {
    if (decoded is! Map || !decoded.containsKey('playerSettings')) return null;
    final value = decoded['playerSettings'];
    if (value is! Map) {
      throw const FormatException('备份文件中的播放器设置格式错误');
    }
    return Map<String, dynamic>.from(value);
  }

  static bool _containsBilibili(List<dynamic> entries) {
    return entries.any((entry) {
      if (entry is! Map) return false;
      return entry['platform']?.toString() == MusicPlatform.bilibili.code;
    });
  }
}

class BackupRestoreResult {
  final int songsAdded;
  final int songsSkipped;
  final int songsTotal;
  final int bilibiliAdded;
  final int bilibiliSkipped;
  final int bilibiliTotal;
  final int playlistsAdded;
  final int playlistsSkipped;
  final bool apiKeyRestored;
  final bool aiConfigRestored;
  final bool playerSettingsRestored;
  final bool restoredToDefaultUser;

  const BackupRestoreResult({
    required this.songsAdded,
    required this.songsSkipped,
    required this.songsTotal,
    this.bilibiliAdded = 0,
    this.bilibiliSkipped = 0,
    this.bilibiliTotal = 0,
    required this.playlistsAdded,
    required this.playlistsSkipped,
    required this.apiKeyRestored,
    this.aiConfigRestored = false,
    this.playerSettingsRestored = false,
    this.restoredToDefaultUser = false,
  });

  BackupRestoreResult copyWith({bool? restoredToDefaultUser}) {
    return BackupRestoreResult(
      songsAdded: songsAdded,
      songsSkipped: songsSkipped,
      songsTotal: songsTotal,
      bilibiliAdded: bilibiliAdded,
      bilibiliSkipped: bilibiliSkipped,
      bilibiliTotal: bilibiliTotal,
      playlistsAdded: playlistsAdded,
      playlistsSkipped: playlistsSkipped,
      apiKeyRestored: apiKeyRestored,
      aiConfigRestored: aiConfigRestored,
      playerSettingsRestored: playerSettingsRestored,
      restoredToDefaultUser:
          restoredToDefaultUser ?? this.restoredToDefaultUser,
    );
  }
}
