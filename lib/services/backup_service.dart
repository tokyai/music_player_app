import 'dart:convert';

import '../models/song.dart';
import '../providers/ai_config_controller.dart';
import '../providers/player_provider.dart';
import '../services/favorite_service.dart';

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
  const BackupService._();

  static BackupRestoreContents inspect(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('备份文件不是有效的 JSON');
    }

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
    final aiAssistant = _readAiBackup(raw);
    final playerSettings = _readPlayerBackup(raw);
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
    final decoded = jsonDecode(favorites.exportJson(apiKey: player.apiKey));
    if (decoded is! Map) {
      throw const FormatException('收藏备份生成失败');
    }
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
    final selectedSections = sections == null
        ? BackupRestoreSection.values.toSet()
        : sections.toSet();
    final aiBackup = selectedSections.contains(BackupRestoreSection.aiAssistant)
        ? _readAiBackup(raw)
        : null;
    final playerBackup =
        selectedSections.contains(BackupRestoreSection.playerSettings)
        ? _readPlayerBackup(raw)
        : null;
    final result = await favorites.importJson(
      raw,
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

  static Map<String, dynamic>? _readAiBackup(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // FavoriteService owns the user-facing JSON error for malformed files.
      return null;
    }
    if (decoded is! Map || !decoded.containsKey('aiAssistant')) return null;
    final value = decoded['aiAssistant'];
    if (value is! Map) {
      throw const FormatException('备份文件中的 AI 助理数据格式错误');
    }
    return Map<String, dynamic>.from(value);
  }

  static Map<String, dynamic>? _readPlayerBackup(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
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
  });
}
