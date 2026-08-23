import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'user_data_scope.dart';

/// 缓存歌曲信息（用于列表展示）
class CachedSongInfo {
  final String platformCode;
  final String songId;
  final String name;
  final String artist;
  final String filePath;
  final int fileSize;

  CachedSongInfo({
    required this.platformCode,
    required this.songId,
    required this.name,
    required this.artist,
    required this.filePath,
    required this.fileSize,
  });
}

/// 音频缓存服务
/// 播放过的歌曲缓存到本地，下次播放不重新联网下载。
///
/// 缓存目录: getApplicationCacheDirectory()/audio_cache/
/// 文件命名: 歌曲名-歌手.ext（特殊字符替换）
/// 元数据索引: audio_cache/_index.json
class AudioCacheService {
  static final Map<String, _AudioCacheContext> _contexts = {};
  // Playback caching runs in the background while settings can clear or
  // remove a cache entry. Serialize filesystem/index mutations so two calls
  // cannot share the same `.tmp` path or write `_index.json` concurrently.
  static _AudioCacheContext _context(UserDataScope scope) =>
      _contexts.putIfAbsent(scope.userId, _AudioCacheContext.new);

  static Future<T> _withCacheLock<T>(
    UserDataScope scope,
    Future<T> Function() operation,
  ) {
    final context = _context(scope);
    final run = context.operationTail.then<T>((_) => operation());
    context.operationTail = run.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return run;
  }

  /// 获取缓存目录（延迟初始化）
  static Future<Directory> _getCacheDir(UserDataScope scope) async {
    final context = _context(scope);
    if (context.cacheDir != null) return context.cacheDir!;
    try {
      final base = await getApplicationCacheDirectory();
      final dir = Directory('${base.path}/${scope.audioCacheRelativePath}');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      context.cacheDir = dir;
      return dir;
    } catch (_) {
      final base = await getTemporaryDirectory();
      final dir = Directory('${base.path}/${scope.audioCacheRelativePath}');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      context.cacheDir = dir;
      return dir;
    }
  }

  /// 缓存索引 key
  static String _cacheKey(String platformCode, String songId) =>
      '${platformCode}_$songId';

  /// 从 URL 中提取文件扩展名
  static String _extractExt(String url) {
    final clean = url.split('?').first;
    final dot = clean.lastIndexOf('.');
    if (dot >= 0 && dot < clean.length - 1) {
      final ext = clean.substring(dot + 1).toLowerCase();
      if (['mp3', 'flac', 'm4a', 'aac', 'ogg', 'wav', 'ape'].contains(ext)) {
        return ext;
      }
    }
    return 'mp3';
  }

  /// 文件名安全化（替换非法字符）
  static String _sanitizeName(String name) {
    return name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// 生成缓存文件名: 歌曲名-歌手.ext
  static String _cacheFileName(String name, String artist, String ext) {
    final safeName = _sanitizeName(name);
    final safeArtist = _sanitizeName(artist);
    return '$safeName-$safeArtist.$ext';
  }

  /// 加载缓存索引
  static Future<Map<String, Map<String, dynamic>>> _loadIndex(
    UserDataScope scope,
  ) async {
    final context = _context(scope);
    if (context.index != null) return context.index!;
    try {
      final dir = await _getCacheDir(scope);
      final file = File('${dir.path}/_index.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final Map<String, dynamic> data = json.decode(content);
        context.index = data.map(
          (k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)),
        );
      } else {
        context.index = {};
      }
    } catch (e) {
      debugPrint('加载缓存索引失败: $e');
      context.index = {};
    }
    return context.index!;
  }

  /// 保存缓存索引
  static Future<void> _saveIndex(UserDataScope scope) async {
    if (scope.isDeleted) return;
    final context = _context(scope);
    if (context.index == null) return;
    try {
      final dir = await _getCacheDir(scope);
      final file = File('${dir.path}/_index.json');
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(json.encode(context.index), flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    } catch (e) {
      debugPrint('保存缓存索引失败: $e');
    }
  }

  /// 检查指定歌曲是否已有缓存
  static Future<String?> getCachedPath({
    required String platformCode,
    required String songId,
    // 保留旧调用方的命名参数兼容；缓存索引按歌曲身份查找，不依赖 URL。
    String? url,
    UserDataScope scope = UserDataScope.defaultScope,
  }) async {
    if (scope.isDeleted) return null;
    try {
      final index = await _loadIndex(scope);
      final key = _cacheKey(platformCode, songId);
      final entry = index[key];
      if (entry != null) {
        final filePath = entry['filePath'] as String?;
        if (filePath != null) {
          final file = File(filePath);
          if (await file.exists() && await file.length() > 10240) {
            return filePath;
          }
        }
      }
    } catch (e) {
      debugPrint('检查缓存失败: $e');
    }
    return null;
  }

  /// 下载音频并缓存到本地
  static Future<String?> cacheAudio({
    required String platformCode,
    required String songId,
    required String url,
    String name = '未知歌曲',
    String artist = '未知歌手',
    Map<String, String>? headers,
    void Function(int received, int total)? onProgress,
    UserDataScope scope = UserDataScope.defaultScope,
  }) async {
    if (scope.isDeleted) return null;
    return _withCacheLock(scope, () async {
      if (scope.isDeleted) return null;
      try {
        final dir = await _getCacheDir(scope);
        final index = await _loadIndex(scope);
        final key = _cacheKey(platformCode, songId);

        // 先检查索引中是否已有缓存
        final existing = index[key];
        if (existing != null) {
          final existingPath = existing['filePath'] as String?;
          if (existingPath != null) {
            final file = File(existingPath);
            if (await file.exists() && await file.length() > 10240) {
              return existingPath;
            }
          }
        }

        final ext = _extractExt(url);
        final fileName = _cacheFileName(name, artist, ext);
        final path = '${dir.path}/$fileName';

        // 先下载到临时文件，成功后重命名
        final tempPath = '$path.tmp';
        final tempFile = File(tempPath);
        if (await tempFile.exists()) await tempFile.delete();

        final dio = Dio();
        await dio.download(
          url,
          tempPath,
          onReceiveProgress: onProgress,
          options: Options(
            headers: headers,
            receiveTimeout: const Duration(seconds: 30),
            sendTimeout: const Duration(seconds: 10),
          ),
        );

        // 下载完成，重命名为正式缓存文件
        if (await tempFile.exists()) {
          final size = await tempFile.length();
          if (size > 10240) {
            // 如果目标文件已存在（同名不同歌曲），加 id 后缀
            String finalPath = path;
            if (await File(path).exists()) {
              finalPath =
                  '${dir.path}/${_sanitizeName(name)}-${_sanitizeName(artist)}_${songId}.$ext';
            }
            await tempFile.rename(finalPath);
            // 更新索引
            index[key] = {
              'name': name,
              'artist': artist,
              'platformCode': platformCode,
              'songId': songId,
              'filePath': finalPath,
              'fileSize': size,
            };
            _context(scope).index = index;
            await _saveIndex(scope);
            debugPrint('缓存成功: $finalPath ($size bytes)');
            return finalPath;
          } else {
            await tempFile.delete();
          }
        }
      } catch (e) {
        debugPrint('缓存下载失败: $e');
        try {
          final dir = await _getCacheDir(scope);
          final ext = _extractExt(url);
          final fileName = _cacheFileName(name, artist, ext);
          final tempFile = File('${dir.path}/$fileName.tmp');
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
      }
      return null;
    });
  }

  /// 获取缓存总大小（字节）
  static Future<int> getCacheSize({
    UserDataScope scope = UserDataScope.defaultScope,
  }) async {
    if (scope.isDeleted) return 0;
    try {
      final dir = await _getCacheDir(scope);
      int total = 0;
      await for (final entity in dir.list(recursive: false)) {
        if (entity is File && !entity.path.endsWith('_index.json')) {
          total += await entity.length();
        }
      }
      return total;
    } catch (e) {
      debugPrint('获取缓存大小失败: $e');
      return 0;
    }
  }

  /// 格式化缓存大小为可读字符串
  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 获取缓存歌曲数量
  static Future<int> getCacheCount({
    UserDataScope scope = UserDataScope.defaultScope,
  }) async {
    if (scope.isDeleted) return 0;
    try {
      final index = await _loadIndex(scope);
      // 清理无效条目后返回数量
      int count = 0;
      for (final entry in index.values) {
        final filePath = entry['filePath'] as String?;
        if (filePath != null) {
          final file = File(filePath);
          if (await file.exists()) {
            count++;
          }
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// 获取缓存歌曲列表
  static Future<List<CachedSongInfo>> getCacheList({
    UserDataScope scope = UserDataScope.defaultScope,
  }) async {
    if (scope.isDeleted) return const [];
    try {
      final index = await _loadIndex(scope);
      final List<CachedSongInfo> list = [];
      for (final entry in index.values) {
        final filePath = entry['filePath'] as String?;
        if (filePath != null) {
          final file = File(filePath);
          if (await file.exists()) {
            final size = await file.length();
            if (size > 10240) {
              list.add(
                CachedSongInfo(
                  platformCode: entry['platformCode'] as String? ?? '',
                  songId: entry['songId'] as String? ?? '',
                  name: entry['name'] as String? ?? '未知歌曲',
                  artist: entry['artist'] as String? ?? '未知歌手',
                  filePath: filePath,
                  fileSize: size,
                ),
              );
            }
          }
        }
      }
      return list;
    } catch (e) {
      debugPrint('获取缓存列表失败: $e');
      return [];
    }
  }

  /// 清除全部缓存
  static Future<void> clearCache({
    UserDataScope scope = UserDataScope.defaultScope,
  }) async {
    if (scope.isDeleted) return;
    await _withCacheLock(scope, () async {
      try {
        final dir = await _getCacheDir(scope);
        await for (final entity in dir.list(recursive: false)) {
          if (entity is File) {
            await entity.delete();
          }
        }
        _context(scope).index = {};
        await _saveIndex(scope);
        debugPrint('缓存已清除');
      } catch (e) {
        debugPrint('清除缓存失败: $e');
      }
    });
  }

  /// 删除指定歌曲的缓存
  static Future<void> removeCache(
    String platformCode,
    String songId, {
    UserDataScope scope = UserDataScope.defaultScope,
  }) async {
    if (scope.isDeleted) return;
    await _withCacheLock(scope, () async {
      try {
        final index = await _loadIndex(scope);
        final key = _cacheKey(platformCode, songId);
        final entry = index[key];
        if (entry != null) {
          final filePath = entry['filePath'] as String?;
          if (filePath != null) {
            final file = File(filePath);
            if (await file.exists()) {
              await file.delete();
            }
          }
          index.remove(key);
          _context(scope).index = index;
          await _saveIndex(scope);
        }
      } catch (e) {
        debugPrint('删除缓存失败: $e');
      }
    });
  }

  static Future<void> deleteUserCache(UserDataScope scope) async {
    if (scope.isDefault) return;
    await _withCacheLock(scope, () async {
      try {
        final context = _context(scope);
        final directories = <String, Directory>{};
        final activeDirectory = context.cacheDir;
        if (activeDirectory != null) {
          directories[activeDirectory.path] = activeDirectory;
        }
        try {
          final base = await getApplicationCacheDirectory();
          final directory = Directory(
            '${base.path}/${scope.audioCacheRelativePath}',
          );
          directories[directory.path] = directory;
        } catch (_) {}
        try {
          final base = await getTemporaryDirectory();
          final directory = Directory(
            '${base.path}/${scope.audioCacheRelativePath}',
          );
          directories[directory.path] = directory;
        } catch (_) {}
        for (final directory in directories.values) {
          if (await directory.exists()) await directory.delete(recursive: true);
        }
        context.cacheDir = null;
        context.index = null;
      } catch (error, stackTrace) {
        debugPrint('清理用户音频缓存失败: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    });
    _contexts.remove(scope.userId);
  }
}

class _AudioCacheContext {
  Directory? cacheDir;
  Map<String, Map<String, dynamic>>? index;
  Future<void> operationTail = Future<void>.value();
}
