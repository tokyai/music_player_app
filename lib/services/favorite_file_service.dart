import 'package:flutter/services.dart';

enum FavoriteExportResult { saved, copiedToClipboard, cancelled }

class FavoriteFileService {
  static const MethodChannel _channel = MethodChannel(
    'music_player/favorites_file',
  );

  static Future<FavoriteExportResult> exportBackup(String content) async {
    final now = DateTime.now();
    final date =
        '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    try {
      final saved = await _channel.invokeMethod<bool>('exportFavorites', {
        'content': content,
        'fileName': 'kuzai-music-backup-$date.json',
      });
      return saved == true
          ? FavoriteExportResult.saved
          : FavoriteExportResult.cancelled;
    } on MissingPluginException {
      return _copyToClipboard(content);
    } on PlatformException catch (error) {
      if (error.code != 'UNSUPPORTED') rethrow;
      return _copyToClipboard(content);
    }
  }

  static Future<String?> importBackup() async {
    try {
      return await _channel.invokeMethod<String>('importFavorites');
    } on MissingPluginException {
      throw UnsupportedError('当前平台不支持文件选择');
    } on PlatformException catch (error) {
      if (error.code == 'UNSUPPORTED') {
        throw UnsupportedError('当前平台不支持文件选择');
      }
      rethrow;
    }
  }

  static Future<FavoriteExportResult> _copyToClipboard(String content) async {
    await Clipboard.setData(ClipboardData(text: content));
    return FavoriteExportResult.copiedToClipboard;
  }
}
