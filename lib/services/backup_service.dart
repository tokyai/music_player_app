import 'dart:convert';

import '../providers/ai_config_controller.dart';
import '../providers/player_provider.dart';
import '../services/favorite_service.dart';

/// 收藏数据与播放器设置之间的备份协调层。
///
/// FavoriteService 只负责收藏数据本身，播放器 API Key 由这里统一编排，
/// 因此文件、WebDAV 和局域网三种入口都会得到完全一致的行为。
class BackupService {
  const BackupService._();

  static String exportJson({
    required FavoriteService favorites,
    required PlayerProvider player,
    AiConfigController? aiConfig,
  }) {
    final decoded = jsonDecode(favorites.exportJson(apiKey: player.apiKey));
    if (decoded is! Map) {
      throw const FormatException('收藏备份生成失败');
    }
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
  }) async {
    final aiBackup = _readAiBackup(raw);
    final result = await favorites.importJson(raw, mode: mode);
    var apiKeyRestored = false;
    if (result.apiKeyPresent) {
      await player.setApiKey(result.apiKey ?? '');
      apiKeyRestored = true;
    }
    var aiConfigRestored = false;
    if (aiBackup != null && aiConfig != null) {
      await aiConfig.restoreBackupJson(aiBackup);
      aiConfigRestored = true;
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
  });
}
