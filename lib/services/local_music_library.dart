import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/song.dart';

class LocalMusicLibrary extends ChangeNotifier {
  static const channel = MethodChannel('music_player/local_music');
  static const maxSongs = 5000;
  static int _nextId = DateTime.now().microsecondsSinceEpoch;
  final List<SongSearchResult> _songs = [];
  List<SongSearchResult> get songs => UnmodifiableListView(_songs);
  bool scanning = false;
  bool permissionDenied = false;
  bool permanentlyDenied = false;
  bool reachedLimit = false;
  String? error;
  bool _disposed = false;
  int? _requestId;
  bool _cancelled = false;

  Future<void> scan({bool requestPermission = false}) async {
    if (_disposed || scanning) return;
    scanning = true;
    _cancelled = false;
    error = null;
    permissionDenied = false;
    permanentlyDenied = false;
    reachedLimit = false;
    notifyListeners();
    try {
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
        throw UnsupportedError('当前平台不支持本机音乐扫描');
      }
      final info = await channel
          .invokeMapMethod<String, dynamic>('info')
          .timeout(const Duration(seconds: 5));
      if (_disposed || _cancelled) return;
      final permission = (info?['sdk'] as num? ?? 33) >= 33
          ? Permission.audio
          : Permission.storage;
      final status = requestPermission
          ? await permission.request()
          : await permission.status;
      if (_disposed || _cancelled) return;
      if (!status.isGranted) {
        permissionDenied = true;
        permanentlyDenied = status.isPermanentlyDenied;
        throw StateError('需要音频访问权限');
      }
      _songs.clear();
      final seen = <String>{};
      var afterId = 0;
      var pages = 0;
      while (!_disposed && !_cancelled) {
        if (++pages > maxSongs ~/ 200 + 1) {
          reachedLimit = true;
          break;
        }
        final requestId = _requestId = ++_nextId;
        final page = await channel
            .invokeMapMethod<String, dynamic>('scan', {
              'requestId': requestId,
              'afterId': afterId,
            })
            .timeout(const Duration(seconds: 15));
        _requestId = null;
        if (_disposed || _cancelled) return;
        final raw = page?['songs'];
        final cursor = page?['afterId'];
        if (raw is! List ||
            raw.length > 200 ||
            cursor is! int ||
            cursor < afterId) {
          throw const FormatException('本地音乐扫描结果无效');
        }
        for (final item in raw) {
          if (item is! Map) throw const FormatException('本地歌曲数据无效');
          final song = SongSearchResult.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (song.platform != MusicPlatform.local) {
            throw const FormatException('本地歌曲来源无效');
          }
          if (seen.add(song.id)) _songs.add(song);
          if (_songs.length >= maxSongs) break;
        }
        notifyListeners();
        if (page?['hasMore'] != true) break;
        if (_songs.length >= maxSongs) {
          reachedLimit = true;
          break;
        }
        if (cursor <= afterId || raw.isEmpty) {
          throw const FormatException('本地扫描游标没有前进');
        }
        afterId = cursor;
      }
    } catch (failure) {
      if (!_disposed && !_cancelled) {
        if (failure is PlatformException && failure.code == 'PERMISSION') {
          permissionDenied = true;
        }
        error = failure is PlatformException && failure.code == 'PERMISSION'
            ? '音频访问权限已撤销'
            : '$failure';
      }
      await _cancelNative();
    } finally {
      _requestId = null;
      scanning = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _cancelNative() async {
    final requestId = _requestId;
    if (requestId == null) return;
    try {
      await channel
          .invokeMethod<void>('cancel', {'requestId': requestId})
          .timeout(const Duration(seconds: 3));
    } catch (error) {
      debugPrint('取消本地音乐扫描失败: $error');
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    await _cancelNative();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(cancel());
    _songs.clear();
    super.dispose();
  }
}
