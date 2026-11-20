import 'dart:async';
import 'package:flutter/services.dart';
import '../models/song.dart';
import '../models/audio_effects.dart';
import '../providers/player_provider.dart';
import '../providers/user_controller.dart';
import '../providers/theme_controller.dart';
import '../providers/ai_config_controller.dart';
import '../providers/search_session.dart';
import 'favorite_service.dart';
import 'backup_service.dart';
import 'favorite_file_service.dart';
import 'webdav_backup_service.dart';
import 'lan_backup_service.dart';
import 'audio_cache_service.dart';
import 'local_music_library.dart';
import 'runtime_bridge_protocol.dart';
import 'runtime_backup.dart';
import 'user_data_scope.dart';

/// 框架已有的本地数据和系统文件能力；页面布局与交互由业务包决定。
/// SHIXIAOYANG，2026/11/19。
class NativeRuntimeLibrary {
  final PlayerProvider player;
  final FavoriteService favorites;
  final UserController users;
  final ThemeController theme;
  final AiConfigController aiConfig;
  final SearchSession search;
  final void Function() ensureActive;
  final void Function(String, Map<String, dynamic>) emit;
  final LocalMusicLibrary _local = LocalMusicLibrary();
  LanBackupSession? _lan;
  WebDavBackupService? _dav;
  String? _pendingRestore;
  bool get hasPendingTransfer =>
      _pendingRestore != null || _lan?.isActive == true || _dav != null;

  NativeRuntimeLibrary({
    required this.player,
    required this.favorites,
    required this.users,
    required this.theme,
    required this.aiConfig,
    required this.search,
    required this.ensureActive,
    required this.emit,
  });

  /// 分页读取和操作当前用户的收藏、历史、下载及本地音乐。
  Future<Map<String, dynamic>> handle(Map<String, dynamic> data) async {
    ensureActive();
    final action = RuntimeBridgeProtocol.text(data, 'action', max: 32);
    final offset = RuntimeBridgeProtocol.integer(data, 'offset');
    switch (action) {
      case 'favorites':
        return {
          'songs': favorites.allFavorites
              .skip(offset)
              .take(50)
              .map((song) => song.toJson())
              .toList(),
          'playlists': favorites.favoritePlaylists
              .take(100)
              .map((item) => item.toJson())
              .toList(),
          'total': favorites.allFavorites.length,
        };
      case 'favorite_playlist':
        final value = data['playlist'];
        if (value is! Map) throw const FormatException('歌单数据无效');
        final favorite = FavoritePlaylist.fromJson(
          Map<String, dynamic>.from(value),
        );
        if (favorites.favoritePlaylists.length >= 1000 &&
            !favorites.isPlaylistFavorite(favorite.platform, favorite.id)) {
          throw StateError('收藏歌单已达到 1000 个');
        }
        return {
          'favorite': await favorites.togglePlaylist(
            favorite.platform,
            favorite.playlist,
          ),
        };
      case 'history':
        return {
          'songs': player.playbackHistory
              .skip(offset)
              .take(50)
              .map((item) => item.song.toJson())
              .toList(),
          'total': player.playbackHistory.length,
        };
      case 'history_clear':
        await player.clearPlaybackHistory();
        return {'cleared': true};
      case 'local_scan':
        await _local.scan(requestPermission: true);
        ensureActive();
        return _localPage(offset);
      case 'local':
        return _localPage(offset);
      case 'downloads':
        await player.downloads.ready;
        await player.downloads.initializeNetwork();
        ensureActive();
        return {
          'entries': player.downloads.entries
              .skip(offset)
              .take(50)
              .map(
                (entry) => {
                  ...entry.toJson(),
                  'received': entry.received,
                  'total': entry.total,
                  'offlineSong': entry.offlineSong.toJson(),
                },
              )
              .toList(),
          'total': player.downloads.entries.length,
          'wifiOnly': player.downloads.wifiOnly,
          'wifiConnected': player.downloads.wifiConnected,
        };
      case 'download_add':
        final entry = await player.downloads.enqueue(
          RuntimeBridgeProtocol.song(data['song']),
          RuntimeBridgeProtocol.text(data, 'quality', max: 32),
        );
        return {'entry': entry.toJson()};
      case 'download_wifi':
        await player.downloads.setWifiOnly(data['enabled'] == true);
        return {'saved': true};
      case 'download_pause':
      case 'download_resume':
      case 'download_remove':
        final id = RuntimeBridgeProtocol.text(data, 'id', max: 24);
        await player.downloads.ready;
        ensureActive();
        final entries = player.downloads.entries.where((item) => item.id == id);
        if (entries.isEmpty) throw StateError('下载记录不存在');
        final entry = entries.first;
        if (action == 'download_pause') await player.downloads.pause(entry);
        if (action == 'download_resume') await player.downloads.resume(entry);
        if (action == 'download_remove') await player.downloads.remove(entry);
        return {'accepted': true};
      case 'cache':
        final entries = await AudioCacheService.getCacheList(
          scope: player.dataScope,
        );
        ensureActive();
        return {
          'entries': entries
              .skip(offset)
              .take(50)
              .map(
                (item) => {
                  'platform': item.platformCode,
                  'id': item.songId,
                  'name': item.name,
                  'artist': item.artist,
                  'bytes': item.fileSize,
                },
              )
              .toList(),
          'total': entries.length,
        };
      case 'cache_remove':
        await AudioCacheService.removeCache(
          RuntimeBridgeProtocol.text(data, 'platform', max: 32),
          RuntimeBridgeProtocol.text(data, 'id', max: 128),
          scope: player.dataScope,
        );
        return {'removed': true};
      case 'cache_clear':
        await AudioCacheService.clearCache(scope: player.dataScope);
        return {'cleared': true};
      case 'player_settings':
        if (data['values'] is Map) {
          await player.restoreBackupJson(
            Map<String, dynamic>.from(data['values'] as Map),
          );
        }
        return {'values': player.toBackupJson()};
      case 'effects':
        if (data['values'] is Map) {
          await player.audioEffects.setSettings(
            AudioEffectsSettings.fromJson(
              Map<String, dynamic>.from(data['values'] as Map),
            ),
          );
        }
        return {
          'values': player.audioEffects.settings.toJson(),
          'supported': player.audioEffects.supported,
          'failures': player.audioEffects.failures,
        };
      case 'bilibili_search':
        return {
          'songs': (await player.api.bilibili.search(
            RuntimeBridgeProtocol.text(data, 'keyword', max: 128),
          )).take(50).map((song) => song.toJson()).toList(),
        };
      default:
        throw const FormatException('本地数据操作无效');
    }
  }

  Map<String, dynamic> _localPage(int offset) => {
    'songs': _local.songs
        .skip(offset)
        .take(50)
        .map((song) => song.toJson())
        .toList(),
    'total': _local.songs.length,
    'error': _local.error,
    'permissionDenied': _local.permissionDenied,
    'scanning': _local.scanning,
  };

  String _legacyExport() => BackupService.exportJson(
    favorites: favorites,
    player: player,
    theme: theme,
    aiConfig: aiConfig,
    search: search,
  );

  Future<String> _export({bool full = false}) async {
    final base = full
        ? await BackupService.exportFullJson(
            users: users,
            favorites: favorites,
            player: player,
            aiConfig: aiConfig,
            theme: theme,
            search: search,
          )
        : _legacyExport();
    ensureActive();
    final scopes = full
        ? users.users.map((user) => UserDataScope(user.id)).toList()
        : [player.dataScope];
    return RuntimeBackup.attach(base, scopes, full: full);
  }

  /// 文件和网络导入先提供预览，业务页面明确确认后才恢复数据。
  Future<Map<String, dynamic>> backup(Map<String, dynamic> data) async {
    ensureActive();
    final action = RuntimeBridgeProtocol.text(data, 'action', max: 32);
    switch (action) {
      case 'export':
        final content = await _export(full: data['full'] == true);
        ensureActive();
        return {
          'result': (await FavoriteFileService.exportBackup(content)).name,
        };
      case 'import_file':
        return _stage(await FavoriteFileService.importBackup());
      case 'import_clipboard':
        return _stage((await Clipboard.getData(Clipboard.kTextPlain))?.text);
      case 'restore':
        final raw = _pendingRestore;
        if (raw == null) throw StateError('没有待恢复的备份');
        _pendingRestore = null;
        final result = await RuntimeBackup.restore(
          raw,
          player.dataScope,
          () => BackupService.importJson(
            raw: raw,
            favorites: favorites,
            player: player,
            theme: theme,
            aiConfig: aiConfig,
            search: search,
            users: users,
            mode: data['replace'] == true
                ? FavoriteImportMode.replace
                : FavoriteImportMode.merge,
          ),
        );
        return {
          'restored': true,
          'songs': result.songsAdded,
          'playlists': result.playlistsAdded,
        };
      case 'cancel':
        _pendingRestore = null;
        return {'cancelled': true};
      case 'dav_config':
        var config = await WebDavConfig.load(dataScope: player.dataScope);
        if (data['values'] is Map) {
          final values = Map<String, dynamic>.from(data['values'] as Map);
          config = config.copyWith(
            url: RuntimeBridgeProtocol.text(values, 'url', max: 2048),
            username: RuntimeBridgeProtocol.text(values, 'username', max: 128),
            password:
                values['password'] is String &&
                    (values['password'] as String).isNotEmpty
                ? values['password'] as String
                : null,
            certificateSha256: RuntimeBridgeProtocol.text(
              values,
              'certificateSha256',
              max: 128,
              required: false,
            ),
          );
          config.parsedUrl;
          ensureActive();
          await config.save();
        }
        return {
          'url': config.url,
          'username': config.username,
          'certificateSha256': config.certificateSha256,
          'configured': config.isConfigured,
        };
      case 'dav_upload':
      case 'dav_download':
        return _webdav(action);
      case 'lan_start':
        await _lan?.stop();
        ensureActive();
        final content = await _export();
        final session = await LanBackupService.start(
          exportBackup: () => content,
        );
        try {
          ensureActive();
        } catch (_) {
          await session.stop();
          rethrow;
        }
        _lan = session;
        unawaited(_watchLan(session));
        return {
          'url': session.url,
          'pin': session.pin,
          'expiresAt': session.expiresAt.toIso8601String(),
        };
      case 'lan_stop':
        await _lan?.stop();
        _lan = null;
        return {'stopped': true};
      default:
        throw const FormatException('备份操作无效');
    }
  }

  Map<String, dynamic> _stage(String? raw) {
    ensureActive();
    if (raw == null) return {'cancelled': true};
    final contents = BackupService.inspect(raw);
    final runtime = RuntimeBackup.inspect(raw, player.dataScope);
    _pendingRestore = raw;
    return {
      'ready': true,
      'sections': [
        ...contents.availableSections.map((item) => item.name),
        if (runtime.isNotEmpty) 'remoteBusiness',
      ],
      'bytes': raw.length,
    };
  }

  Future<Map<String, dynamic>> _webdav(String action) async {
    final config = await WebDavConfig.load(dataScope: player.dataScope);
    ensureActive();
    final service = WebDavBackupService(config: config);
    _dav = service;
    try {
      if (action == 'dav_upload') {
        await service.upload(await _export());
        return {'uploaded': true};
      }
      return _stage(await service.download());
    } finally {
      service.close();
      if (identical(_dav, service)) _dav = null;
    }
  }

  Future<void> _watchLan(LanBackupSession session) async {
    try {
      final raw = await session.restored;
      if (!identical(_lan, session) || raw == null) return;
      ensureActive();
      emit('backup_ready', _stage(raw));
    } catch (_) {
      // 页面或用户切换会停止会话，迟到的数据不能再进入新用户的恢复流程。
      if (identical(_lan, session)) _pendingRestore = null;
    }
  }

  /// 热包卸载时取消扫描、关闭 WebDAV 和局域网监听，并释放待恢复文件。
  Future<void> resetPage() async {
    _pendingRestore = null;
    _dav?.close();
    _dav = null;
    final session = _lan;
    _lan = null;
    await Future.wait<void>([
      _local.cancel(),
      if (session != null) session.stop(),
    ]);
  }

  /// 用户会话销毁时释放扫描控制器。
  void dispose() {
    _local.dispose();
  }
}
