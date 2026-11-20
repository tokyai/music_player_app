import 'dart:async';
import 'package:flutter/material.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/user_controller.dart';
import '../providers/theme_controller.dart';
import '../providers/ai_config_controller.dart';
import '../providers/ai_assistant_controller.dart';
import '../providers/search_session.dart';
import '../screens/video_player_screen.dart';
import 'favorite_service.dart';
import 'runtime_http_client.dart';
import 'runtime_preferences.dart';
import 'runtime_bridge_protocol.dart';
import 'native_runtime_library.dart';
import 'native_runtime_assistant.dart';
import 'app_exit_service.dart';

/// 固定能力桥接，播放会话由应用拥有而非业务页面拥有。SHIXIAOYANG，2026/11/19。
class NativeRuntimeBridge {
  final PlayerProvider player;
  final FavoriteService favorites;
  final UserController users;
  final ThemeController theme;
  final RuntimeHttpClient client;
  final BuildContext context;
  late final RuntimePreferences preferences = RuntimePreferences(
    player.dataScope,
  );
  late final NativeRuntimeLibrary library;
  late final NativeRuntimeAssistant assistant;
  final Set<String> _mutations = {};
  Map<String, dynamic> settings = {};
  bool _closed = false;
  int favoriteRevision = 0;
  bool get canReload => !library.hasPendingTransfer;

  NativeRuntimeBridge({
    required this.player,
    required this.favorites,
    required this.users,
    required this.theme,
    required this.client,
    required this.context,
    required AiConfigController aiConfig,
    required AiAssistantController aiAssistant,
    required SearchSession search,
    required void Function(String, Map<String, dynamic>) emit,
  }) {
    library = NativeRuntimeLibrary(
      player: player,
      favorites: favorites,
      users: users,
      theme: theme,
      aiConfig: aiConfig,
      search: search,
      ensureActive: _ensureActive,
      emit: emit,
    );
    assistant = NativeRuntimeAssistant(
      config: aiConfig,
      controller: aiAssistant,
      ensureActive: _ensureActive,
    );
    favorites.addListener(_favoritesChanged);
  }

  void _favoritesChanged() {
    favoriteRevision++;
  }

  void _ensureActive() {
    if (_closed ||
        !context.mounted ||
        player.dataScope.isDeleted ||
        users.activeUserId != player.dataScope.userId) {
      throw const RuntimeException('CANCELLED', '原生会话已切换或释放');
    }
  }

  /// 初始化业务配置；故障不会丢弃原有播放器或收藏。
  Future<void> initialize() async {
    await player.settingsReady;
    final values = await preferences.read();
    _ensureActive();
    settings = values;
  }

  /// 高频状态不包含整个队列、歌词或密钥，避免桥接消息反复复制大数据。
  Map<String, dynamic> state() {
    _ensureActive();
    return {
      'song': player.currentSong == null
          ? null
          : SongSearchResult.fromQueueItem(
              player.currentSong!,
            ).compactForPlaybackPersistence().toJson(),
      'playing': player.isPlaying,
      'loading': player.isLoading,
      'position': player.position.inMilliseconds,
      'duration': player.duration.inMilliseconds,
      'buffered': player.buffered.inMilliseconds,
      'mode': player.playMode.name,
      'queueCount': player.queue.length,
      'queueIndex': player.currentIndex,
      'queueRevision': player.queueSessionId,
      'favoriteRevision': favoriteRevision,
      'favorite': player.currentSong == null
          ? false
          : favorites.isFavorite(
              player.currentSong!.platform,
              player.currentSong!.id,
            ),
      'lyricIndex': player.currentLyricIndex,
      'lyricsLoading': player.lyricsLoading,
      'source':
          player.api.runtimePlaybackProvider ??
          player.currentPlaybackSource?.value,
      'error': player.errorMessage,
      'userId': users.activeUserId,
      'assistant': assistant.state(),
      'sleep': {
        'mode': player.sleepTimer.mode.name,
        'remaining': player.sleepTimer.remaining.inSeconds,
      },
      'theme': theme.mode.name,
      'fontScale': theme.fontScale,
    };
  }

  /// 只执行显式列出的能力，不能从页面任意调用 Flutter 或系统通道。
  Future<Map<String, dynamic>> handle(
    String operation,
    Map<String, dynamic> data, {
    required Future<void> cancelSignal,
  }) async {
    _ensureActive();
    final mutation = [
      'settings',
      'credentials',
      'users',
      'backup',
      'assistant_config',
      'network',
      'appearance',
    ].contains(operation);
    if (mutation && !_mutations.add(operation)) {
      throw const RuntimeException('BUSY', '同一操作正在执行，请稍候');
    }
    try {
      final result = await _handle(operation, data, cancelSignal);
      _ensureActive();
      return result;
    } finally {
      if (mutation) _mutations.remove(operation);
    }
  }

  Future<Map<String, dynamic>> _handle(
    String operation,
    Map<String, dynamic> data,
    Future<void> cancelSignal,
  ) async {
    switch (operation) {
      case 'network':
        if (data['proxy'] is String) {
          await RuntimeHttpClient.setProxy(data['proxy'] as String);
        }
        return {'proxy': await RuntimeHttpClient.proxy()};
      case 'state':
        return state();
      case 'api':
        final method = RuntimeBridgeProtocol.text(data, 'operation', max: 32);
        if (![
          'search',
          'discover',
          'playlist',
          'lyrics',
          'mv',
          'sources',
        ].contains(method)) {
          throw const FormatException('接口不对业务页面开放');
        }
        final params = data['data'];
        if (params is! Map) throw const FormatException('接口参数无效');
        return client.api(
          method,
          Map<String, dynamic>.from(params),
          cancelSignal: cancelSignal,
        );
      case 'source_probe':
        final song = RuntimeBridgeProtocol.song(data['song']);
        final source = RuntimeBridgeProtocol.text(
          Map<String, dynamic>.from(data['song'] as Map),
          'source',
          max: 64,
        );
        final quality = RuntimeBridgeProtocol.text(
          Map<String, dynamic>.from(data['song'] as Map),
          'quality',
          max: 64,
        );
        final secrets = await preferences.credentials();
        _ensureActive();
        final started = DateTime.now();
        await client.api('resolve', {
          'song': {...song.toJson(), 'source': source, 'quality': quality},
          'credentials': {
            'apiKey': player.apiKey,
            'hywCardKey': player.playbackSourceConfig.hywCardKey,
            'xinghaiLicenseKey': player.playbackSourceConfig.xinghaiLicenseKey,
            ...secrets,
          },
        }, cancelSignal: cancelSignal);
        return {'elapsed': DateTime.now().difference(started).inMilliseconds};
      case 'play':
        await _play(data);
        return {'accepted': true};
      case 'control':
        await _control(data);
        return state();
      case 'queue':
        return _queue(data);
      case 'lyrics':
        return _lyrics();
      case 'lyric_search':
        return {
          'songs': (await player.searchLyricCandidates(
            RuntimeBridgeProtocol.text(data, 'keyword', max: 128),
          )).map((song) => song.toJson()).toList(),
        };
      case 'lyric_apply':
        await player.applyLyricCandidate(
          RuntimeBridgeProtocol.song(data['song']),
        );
        return _lyrics();
      case 'favorite':
        final song = RuntimeBridgeProtocol.song(data['song']);
        if (favorites.allFavorites.length >= 5000 &&
            !favorites.isFavorite(song.platform, song.id)) {
          throw const RuntimeException('LIBRARY_FULL', '收藏数量已达到 5000 首');
        }
        return {'favorite': await favorites.toggle(song)};
      case 'library':
        return library.handle(data);
      case 'backup':
        return library.backup(data);
      case 'settings':
        if (data['values'] is Map) {
          final values = Map<String, dynamic>.from(data['values'] as Map);
          await preferences.write(values);
          _ensureActive();
          settings = values;
          await player.refreshRemotePlaybackSettings();
          player.api.clearRemotePlaybackFailures();
        }
        return {
          'values': settings,
          'player': player.toBackupJson(),
          'theme': theme.mode.name,
          'fontScale': theme.fontScale,
        };
      case 'credentials':
        final values = await preferences.credentials();
        if (data['values'] is Map) {
          values.addAll(Map<String, dynamic>.from(data['values'] as Map));
        }
        if (data['clear'] is List) {
          for (final key in (data['clear'] as List).whereType<String>().take(
            16,
          )) {
            values.remove(key);
          }
        }
        if (data['values'] != null || data['clear'] != null) {
          await preferences.writeCredentials(values);
        }
        return {
          'configured': values.map(
            (key, value) => MapEntry(key, value is String && value.isNotEmpty),
          ),
        };
      case 'users':
        return _users(data);
      case 'appearance':
        final mode = data['mode'];
        if (mode is String) {
          await theme.setMode(
            ThemeMode.values.firstWhere((item) => item.name == mode),
          );
        }
        final scale = data['fontScale'];
        if (scale is num && scale.isFinite && scale >= 0.5 && scale <= 1.5) {
          await theme.setFontScale(scale.toDouble());
        }
        return {'theme': theme.mode.name, 'fontScale': theme.fontScale};
      case 'assistant':
        return assistant.handle(data);
      case 'assistant_config':
        return assistant.configure(data);
      case 'video':
        await _video(data);
        return {'closed': true};
      case 'exit':
        await AppExitService.confirmAndExit(context);
        return {'accepted': true};
      default:
        throw const RuntimeException('CAPABILITY_NOT_FOUND', '原生框架不支持该能力');
    }
  }

  Future<void> _play(Map<String, dynamic> data) async {
    if (data['songs'] is List) {
      final raw = data['songs'] as List;
      if (raw.isEmpty || raw.length > 200) {
        throw const FormatException('单次播放列表数量无效');
      }
      final songs = raw.map(RuntimeBridgeProtocol.song).toList();
      final index = RuntimeBridgeProtocol.integer(
        data,
        'index',
        maximum: songs.length - 1,
      );
      await player.playFromSearchResults(songs, index);
    } else {
      await player.playSingle(RuntimeBridgeProtocol.song(data['song']));
    }
  }

  Future<void> _control(Map<String, dynamic> data) async {
    final action = RuntimeBridgeProtocol.text(data, 'action', max: 32);
    switch (action) {
      case 'toggle':
        await player.playPause();
        break;
      case 'next':
        await player.playNext();
        break;
      case 'previous':
        await player.playPrevious();
        break;
      case 'seek':
        await player.seekTo(
          Duration(
            milliseconds: RuntimeBridgeProtocol.integer(
              data,
              'position',
              maximum: 86400000,
            ),
          ),
        );
        break;
      case 'mode':
        player.togglePlayMode();
        break;
      case 'queue_play':
        await player.playQueueItem(
          RuntimeBridgeProtocol.integer(
            data,
            'index',
            maximum: player.queue.length - 1,
          ),
        );
        break;
      case 'queue_remove':
        player.removeFromQueue(
          RuntimeBridgeProtocol.integer(
            data,
            'index',
            maximum: player.queue.length - 1,
          ),
        );
        break;
      case 'queue_clear':
        player.clearQueue();
        break;
      case 'queue_add':
        if (player.queue.length >= 2000) {
          throw const RuntimeException('QUEUE_FULL', '队列已达到 2000 首');
        }
        await player.addToQueueAndGetCount(
          RuntimeBridgeProtocol.song(data['song']),
        );
        break;
      case 'sleep':
        final minutes = RuntimeBridgeProtocol.integer(
          data,
          'minutes',
          maximum: 720,
        );
        if (minutes == 0) {
          player.sleepTimer.cancel();
        } else {
          player.sleepTimer.start(Duration(minutes: minutes));
        }
        break;
      case 'sleep_track':
        player.sleepTimer.stopAfterTrack();
        break;
      case 'lyric_offset':
        player.adjustLyricOffset(
          Duration(
            milliseconds: RuntimeBridgeProtocol.integer(
              data,
              'offset',
              minimum: -60000,
              maximum: 60000,
            ),
          ),
        );
        break;
      default:
        throw const FormatException('播放操作无效');
    }
  }

  Map<String, dynamic> _queue(Map<String, dynamic> data) {
    final offset = RuntimeBridgeProtocol.integer(data, 'offset');
    final songs = player.queue
        .skip(offset)
        .take(50)
        .map(
          (item) => SongSearchResult.fromQueueItem(
            item,
          ).compactForPlaybackPersistence().toJson(),
        )
        .toList();
    return {
      'songs': songs,
      'total': player.queue.length,
      'offset': offset,
      'currentIndex': player.currentIndex,
    };
  }

  Map<String, dynamic> _lyrics() {
    final lines = <Map<String, dynamic>>[];
    for (final line in player.lyrics.take(2000)) {
      final words = line.hasReliableTokenTiming
          ? line.words
                .take(512)
                .map(
                  (word) => {
                    'time': word.time.inMilliseconds,
                    'duration': word.duration.inMilliseconds,
                    'text': word.text,
                  },
                )
                .toList()
          : [];
      lines.add({
        'time': line.time.inMilliseconds,
        'text': line.primaryText,
        'translated': line.translationText,
        'words': words,
      });
    }
    return {'lines': lines, 'offset': player.lyricOffset.inMilliseconds};
  }

  Future<Map<String, dynamic>> _users(Map<String, dynamic> data) async {
    final action = data['action'] ?? 'list';
    final id = RuntimeBridgeProtocol.text(
      data,
      'id',
      max: 128,
      required: false,
    );
    switch (action) {
      case 'create':
        await users.createUser(
          name: RuntimeBridgeProtocol.text(data, 'name', max: 32),
          avatarId: 'music',
          avatarColorIndex: 0,
        );
        break;
      case 'switch':
        await users.switchUser(id);
        break;
      case 'delete':
        await users.deleteUser(id);
        break;
      case 'rename':
        final user = users.userById(id);
        await users.updateUser(
          id,
          name: RuntimeBridgeProtocol.text(data, 'name', max: 32),
          avatarId: user.avatarId,
          avatarColorIndex: user.avatarColorIndex,
        );
        break;
      case 'list':
        break;
      default:
        throw const FormatException('用户操作无效');
    }
    return {
      'users': users.users.map((user) => user.toJson()).toList(),
      'active': users.activeUserId,
    };
  }

  Future<void> _video(Map<String, dynamic> data) async {
    final url = RuntimeBridgeProtocol.mediaUrl(
      RuntimeBridgeProtocol.text(data, 'url', max: 8192),
    );
    final title = RuntimeBridgeProtocol.text(data, 'title');
    final artist = RuntimeBridgeProtocol.text(data, 'artist', required: false);
    final platform = RuntimeBridgeProtocol.platform(
      RuntimeBridgeProtocol.text(data, 'platform', max: 32),
    );
    final mode = VideoPlayerMode.values.firstWhere(
      (item) => item.value == data['mode'],
      orElse: () => VideoPlayerMode.automatic,
    );
    final wasPlaying = player.isPlaying;
    if (wasPlaying) await player.playPause();
    _ensureActive();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => VideoPlayerScreen(
          url: url,
          title: title,
          artist: artist,
          platform: platform,
          mode: mode,
        ),
      ),
    );
    _ensureActive();
    if (wasPlaying && !player.isPlaying) await player.playPause();
  }

  /// 热包切换时取消页面拥有的临时传输，保留原生播放器和下载任务。
  Future<void> resetPage() async {
    assistant.resetPage();
    await library.resetPage();
  }

  /// 释放页面监听与临时资源；应用负责释放播放器。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    favorites.removeListener(_favoritesChanged);
    assistant.resetPage();
    try {
      await library.resetPage();
    } finally {
      library.dispose();
    }
  }
}
