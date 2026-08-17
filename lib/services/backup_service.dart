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
  }) {
    return favorites.exportJson(apiKey: player.apiKey);
  }

  static Future<BackupRestoreResult> importJson({
    required String raw,
    required FavoriteService favorites,
    required PlayerProvider player,
    FavoriteImportMode mode = FavoriteImportMode.merge,
  }) async {
    final result = await favorites.importJson(raw, mode: mode);
    var apiKeyRestored = false;
    if (result.apiKeyPresent) {
      await player.setApiKey(result.apiKey ?? '');
      apiKeyRestored = true;
    }
    return BackupRestoreResult(
      songsAdded: result.added,
      songsSkipped: result.skipped,
      songsTotal: result.total,
      playlistsAdded: result.playlistsAdded,
      playlistsSkipped: result.playlistsSkipped,
      apiKeyRestored: apiKeyRestored,
    );
  }
}

class BackupRestoreResult {
  final int songsAdded;
  final int songsSkipped;
  final int songsTotal;
  final int playlistsAdded;
  final int playlistsSkipped;
  final bool apiKeyRestored;

  const BackupRestoreResult({
    required this.songsAdded,
    required this.songsSkipped,
    required this.songsTotal,
    required this.playlistsAdded,
    required this.playlistsSkipped,
    required this.apiKeyRestored,
  });
}
