import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_cache_service.dart';
import '../services/bilibili_service.dart';
import '../services/floating_capsule_service.dart';
import '../utils/lyric_parser.dart';

/// 播放模式
enum PlayMode { sequence, repeat, shuffle }

/// 全局播放器状态管理
class PlayerProvider extends ChangeNotifier {
  static const _resolvedUrlLifetime = Duration(minutes: 5);

  final AudioPlayer _audioPlayer = AudioPlayer();
  late ApiService _api;
  late final Future<void> settingsReady;

  // ---- 状态 ----
  List<PlayQueueItem> _queue = [];
  int _currentIndex = -1;
  bool _isPlaying = false;
  bool _isLoading = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  PlayMode _playMode = PlayMode.sequence;
  String? _errorMessage;

  /// 最近一次播放错误（供 UI 弹提示；消费后清空，避免重复弹）
  String? _lastError;

  // 歌词
  List<LyricLine> _lyrics = [];
  int _currentLyricIndex = 0;
  bool _showLyric = false;
  bool _lyricsLoading = false;
  final Map<String, _ResolvedLyrics> _lyricCache = {};
  final Map<String, DateTime> _playUrlResolvedAt = {};

  // 音质
  NeteaseLevel _neteaseLevel = NeteaseLevel.jymaster;
  CommonLevel _commonLevel = CommonLevel.flac;
  PlaybackSource _neteasePlaybackSource = PlaybackSource.chksz;
  PlaybackSource _qqPlaybackSource = PlaybackSource.chksz;
  PlaybackSource _kugouPlaybackSource = PlaybackSource.chksz;
  VideoPlayerMode _videoPlayerMode = VideoPlayerMode.automatic;
  List<BilibiliStream> _bilibiliAudioQualities = const [];
  List<BilibiliStream> _bilibiliVideoQualities = const [];
  int _bilibiliAudioQuality = 30280;
  int _bilibiliVideoQuality = 80;

  // API Key
  String _apiKey = '';

  // 流订阅
  StreamSubscription? _playerSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _bufferSub;
  StreamSubscription? _errorSub;
  int _playRequestId = 0;
  int _queueSessionId = 0;
  bool _disposed = false;

  PlayerProvider() {
    _api = ApiService(apiKey: '');
    _api.bilibili.addListener(_handleBilibiliChanged);
    _initAudioPlayer();
    settingsReady = _loadSettings();
  }

  void _handleBilibiliChanged() {
    if (!_disposed) notifyListeners();
  }

  // ==================== Getters ====================

  List<PlayQueueItem> get queue => _queue;
  int get queueSessionId => _queueSessionId;
  int get currentIndex => _currentIndex;
  PlayQueueItem? get currentSong =>
      _currentIndex >= 0 && _currentIndex < _queue.length
      ? _queue[_currentIndex]
      : null;
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  Duration get position => _position;
  Duration get duration => _duration;
  Duration get buffered => _buffered;
  PlayMode get playMode => _playMode;
  String? get errorMessage => _errorMessage;
  String? get lastError => _lastError;
  List<LyricLine> get lyrics => _lyrics;
  int get currentLyricIndex => _currentLyricIndex;
  bool get showLyric => _showLyric;
  bool get lyricsLoading => _lyricsLoading;
  NeteaseLevel get neteaseLevel => _neteaseLevel;
  CommonLevel get commonLevel => _commonLevel;
  List<BilibiliStream> get bilibiliAudioQualities => _bilibiliAudioQualities;
  List<BilibiliStream> get bilibiliVideoQualities => _bilibiliVideoQualities;
  int get bilibiliAudioQuality => _bilibiliAudioQuality;
  int get bilibiliVideoQuality => _bilibiliVideoQuality;
  BilibiliUser? get bilibiliUser => _api.bilibili.user;
  bool get bilibiliLoggedIn => _api.bilibili.isLoggedIn;
  bool get bilibiliAccountLoading => _api.bilibili.accountLoading;
  PlaybackSource playbackSourceFor(MusicPlatform platform) {
    return switch (platform) {
      MusicPlatform.netease => _neteasePlaybackSource,
      MusicPlatform.qq => _qqPlaybackSource,
      MusicPlatform.kugou => _kugouPlaybackSource,
      MusicPlatform.bilibili => PlaybackSource.chksz,
    };
  }

  VideoPlayerMode get videoPlayerMode => _videoPlayerMode;

  String get apiKey => _apiKey;
  AudioPlayer get audioPlayer => _audioPlayer;
  ApiService get api => _api;

  // ==================== 初始化 ====================

  void _initAudioPlayer() {
    _playerSub = _audioPlayer.playerStateStream.listen((state) {
      _isPlaying = state.playing;
      // 系统悬浮胶囊同步播放状态
      if (FloatingCapsuleService.enabled) {
        FloatingCapsuleService.updatePlayState(state.playing);
      }
      // 空音频/加载失败保护：加载或解码失败（如 404、空文件、格式不支持）
      // 会触发 playbackEventStream 的 onError（下方 _errorSub 统一处理：停止 + 提示）
      if (state.processingState == ProcessingState.completed) {
        _onSongComplete();
      }
      notifyListeners();
    });

    _durationSub = _audioPlayer.durationStream.listen((d) {
      _duration = d ?? Duration.zero;
      notifyListeners();
    });

    _positionSub = _audioPlayer.positionStream.listen((p) {
      _position = p;
      _updateLyricIndex();
      notifyListeners();
    });

    _bufferSub = _audioPlayer.bufferedPositionStream.listen((b) {
      _buffered = b;
      notifyListeners();
    });

    _errorSub = _audioPlayer.playbackEventStream.listen(
      (_) {},
      onError: (e) {
        // 播放中途出错（解码失败/数据流中断）：停止并提示，避免静默
        _isLoading = false;
        _errorMessage = '播放错误: $e';
        _lastError = '播放出错：音源可能已失效，已停止播放';
        _audioPlayer.stop();
        notifyListeners();
      },
    );
  }

  /// UI 消费完错误后调用，防止重复弹提示
  void consumeError() {
    if (_lastError != null) {
      _lastError = null;
      notifyListeners();
    }
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _apiKey = prefs.getString('api_key') ?? '';
      _api.setApiKey(_apiKey);
      final levelStr = prefs.getString('netease_level');
      if (levelStr != null) {
        _neteaseLevel = NeteaseLevel.values.firstWhere(
          (e) => e.value == levelStr,
          orElse: () => NeteaseLevel.jymaster,
        );
      }
      final commonStr = prefs.getString('common_level');
      if (commonStr != null) {
        _commonLevel = CommonLevel.values.firstWhere(
          (e) => e.value == commonStr,
          orElse: () => CommonLevel.flac,
        );
      }
      _bilibiliAudioQuality = prefs.getInt('bilibili_audio_quality') ?? 30280;
      _bilibiliVideoQuality = prefs.getInt('bilibili_video_quality') ?? 80;
      _neteasePlaybackSource = _readPlaybackSource(
        prefs.getString(_playbackSourcePreferenceKey(MusicPlatform.netease)),
      );
      _qqPlaybackSource = _readPlaybackSource(
        prefs.getString(_playbackSourcePreferenceKey(MusicPlatform.qq)),
      );
      _kugouPlaybackSource = _readPlaybackSource(
        prefs.getString(_playbackSourcePreferenceKey(MusicPlatform.kugou)),
      );
      final savedVideoPlayerMode = prefs.getString('video_player_mode');
      _videoPlayerMode = VideoPlayerMode.values.firstWhere(
        (mode) => mode.value == savedVideoPlayerMode,
        // 旧版的 built_in/system 都迁移到不依赖系统播放器的自动兼容模式。
        orElse: () => VideoPlayerMode.automatic,
      );
      await _api.bilibili.ready;
      if (_api.bilibili.hasCookie) {
        unawaited(_api.bilibili.refreshAccount());
      }
    } catch (e) {
      debugPrint('读取播放器设置失败: $e');
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> setApiKey(String key) async {
    await settingsReady;
    if (_disposed) return;
    _apiKey = key;
    _api.setApiKey(key);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', key);
    notifyListeners();
  }

  Future<void> setNeteaseLevel(NeteaseLevel level) async {
    await settingsReady;
    if (_disposed) return;
    _neteaseLevel = level;
    _playUrlResolvedAt.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('netease_level', level.value);
    notifyListeners();
  }

  Future<void> setCommonLevel(CommonLevel level) async {
    await settingsReady;
    if (_disposed) return;
    _commonLevel = level;
    _playUrlResolvedAt.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('common_level', level.value);
    notifyListeners();
  }

  Future<void> setPlaybackSource(
    MusicPlatform platform,
    PlaybackSource source,
  ) async {
    await settingsReady;
    if (_disposed ||
        platform == MusicPlatform.bilibili ||
        playbackSourceFor(platform) == source) {
      return;
    }
    switch (platform) {
      case MusicPlatform.netease:
        _neteasePlaybackSource = source;
      case MusicPlatform.qq:
        _qqPlaybackSource = source;
      case MusicPlatform.kugou:
        _kugouPlaybackSource = source;
      case MusicPlatform.bilibili:
        return;
    }
    _playUrlResolvedAt.removeWhere(
      (key, _) => key.startsWith('${platform.code}:'),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_playbackSourcePreferenceKey(platform), source.value);
    notifyListeners();
  }

  Future<void> setVideoPlayerMode(VideoPlayerMode mode) async {
    await settingsReady;
    if (_disposed || _videoPlayerMode == mode) return;
    _videoPlayerMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('video_player_mode', mode.value);
    notifyListeners();
  }

  Future<BilibiliQrCode> createBilibiliQrCode() => _api.bilibili.createQrCode();

  Future<BilibiliQrPollResult> pollBilibiliQrCode(String key) =>
      _api.bilibili.pollQrCode(key);

  Future<void> refreshBilibiliAccount() => _api.bilibili.refreshAccount();

  Future<void> logoutBilibili() => _api.bilibili.logout();

  Future<void> setBilibiliAudioQuality(int quality) async {
    await settingsReady;
    if (_disposed || _bilibiliAudioQuality == quality) return;
    _bilibiliAudioQuality = quality;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('bilibili_audio_quality', quality);
    final song = currentSong;
    if (song?.platform == MusicPlatform.bilibili) {
      _playUrlResolvedAt.removeWhere(
        (key, _) => key.startsWith('${MusicPlatform.bilibili.code}:'),
      );
      _queue[_currentIndex] = song!.copyWith(clearPlayUrl: true);
      notifyListeners();
      await _playCurrent();
    } else {
      notifyListeners();
    }
  }

  Future<void> setBilibiliVideoQuality(int quality) async {
    await settingsReady;
    if (_disposed || _bilibiliVideoQuality == quality) return;
    _bilibiliVideoQuality = quality;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('bilibili_video_quality', quality);
    notifyListeners();
  }

  Future<List<SongSearchResult>> searchLyricCandidates(String keyword) async {
    final song = currentSong;
    final query = keyword.trim();
    if (song == null || query.isEmpty) return const [];
    final results = await _api.searchLyricCandidates(
      platform: song.platform,
      keyword: query,
      currentName: song.name,
      currentArtist: song.artist,
      currentAlbum: song.album,
    );
    final current = currentSong;
    if (current == null ||
        current.platform != song.platform ||
        current.id != song.id) {
      throw const ApiException('SONG_CHANGED', '当前歌曲已切换，请重新查找歌词');
    }
    return results;
  }

  Future<void> applyLyricCandidate(SongSearchResult candidate) async {
    final song = currentSong;
    if (song == null) {
      throw const ApiException('NO_CURRENT_SONG', '当前没有正在播放的歌曲');
    }
    if (candidate.platform != song.platform) {
      throw const ApiException('LYRIC_PLATFORM_MISMATCH', '歌词来源与当前歌曲平台不一致');
    }

    _lyricsLoading = true;
    notifyListeners();
    try {
      final data = await _api.getLyric(candidate.platform, candidate.id);
      final resolved = data == null ? null : _resolveLyricData(data);
      if (resolved == null || resolved.lines.isEmpty) {
        throw const ApiException('LYRIC_EMPTY', '这个版本没有可用歌词');
      }
      final current = currentSong;
      if (current == null ||
          current.platform != song.platform ||
          current.id != song.id) {
        throw const ApiException('SONG_CHANGED', '当前歌曲已切换，请重新查找歌词');
      }

      _lyrics = resolved.lines;
      _currentLyricIndex = LyricParser.findCurrentIndex(_lyrics, _position);
      _lyricsLoading = false;
      _lyricCache[_itemKey(current)] = resolved;
      _queue[_currentIndex] = current.copyWith(lyric: resolved.rawText);
      notifyListeners();
    } catch (_) {
      final current = currentSong;
      if (current != null &&
          current.platform == song.platform &&
          current.id == song.id) {
        _lyricsLoading = false;
        notifyListeners();
      }
      rethrow;
    }
  }

  static String _playbackSourcePreferenceKey(MusicPlatform platform) =>
      switch (platform) {
        MusicPlatform.netease => 'playback_source_netease',
        MusicPlatform.qq => 'playback_source_qq',
        MusicPlatform.kugou => 'playback_source_kugou',
        MusicPlatform.bilibili => throw UnsupportedError('B站不使用第三方播放源'),
      };

  static PlaybackSource _readPlaybackSource(String? value) {
    return PlaybackSource.values.firstWhere(
      (source) => source.value == value,
      orElse: () => PlaybackSource.chksz,
    );
  }

  // ==================== 播放控制 ====================

  /// 从搜索结果播放（替换整个队列）
  Future<void> playFromSearchResults(
    List<SongSearchResult> results,
    int index,
  ) async {
    if (index < 0 || index >= results.length) return;
    _queueSessionId++;
    _queue = results.map((e) => PlayQueueItem.fromSearchResult(e)).toList();
    _currentIndex = index;
    notifyListeners();
    await _playCurrent();
  }

  /// 添加到队列并播放
  Future<void> playSingle(SongSearchResult result) async {
    _queueSessionId++;
    _queue = [PlayQueueItem.fromSearchResult(result)];
    _currentIndex = 0;
    notifyListeners();
    await _playCurrent();
  }

  /// 添加到队列末尾（不立即播放）
  void addToQueue(SongSearchResult result) {
    addTracksToQueue([result]);
  }

  /// 批量追加到队列；传入会话编号时，只允许追加到发起加载时的队列。
  bool addTracksToQueue(
    List<SongSearchResult> tracks, {
    int? expectedQueueSessionId,
  }) {
    if (_disposed ||
        (expectedQueueSessionId != null &&
            expectedQueueSessionId != _queueSessionId)) {
      return false;
    }
    if (tracks.isEmpty) return true;
    _queue.addAll(tracks.map(PlayQueueItem.fromSearchResult));
    notifyListeners();
    return true;
  }

  /// 从歌单播放
  Future<void> playFromPlaylist(
    List<SongSearchResult> tracks,
    int index,
  ) async {
    if (index < 0 || index >= tracks.length) return;
    _queueSessionId++;
    _queue = tracks.map((e) => PlayQueueItem.fromSearchResult(e)).toList();
    _currentIndex = index;
    notifyListeners();
    await _playCurrent();
  }

  Future<void> _playCurrent() async {
    if (_currentIndex < 0 || _currentIndex >= _queue.length) return;
    var item = _queue[_currentIndex];
    final requestId = ++_playRequestId;
    final immediateLyrics = _cachedLyrics(item);

    _isLoading = true;
    _errorMessage = null;
    _lyrics = immediateLyrics?.lines ?? [];
    _lyricsLoading =
        item.platform != MusicPlatform.bilibili && immediateLyrics == null;
    _currentLyricIndex = 0;
    _position = Duration.zero;

    // 新请求会使旧请求失效，同时清掉旧请求遗留的加载状态。
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].loading) {
        _queue[i] = _queue[i].copyWith(loading: false);
      }
    }
    _queue[_currentIndex] = item.copyWith(loading: true, clearError: true);
    notifyListeners();

    try {
      await settingsReady;
      if (!_isCurrentRequest(requestId, item)) return;

      if (item.platform == MusicPlatform.bilibili) {
        item = await _prepareBilibiliItem(requestId, item);
        if (!_isCurrentRequest(requestId, item)) return;
      }
      final itemKey = _itemKey(item);
      final usesChksz =
          item.platform != MusicPlatform.bilibili &&
          playbackSourceFor(item.platform) == PlaybackSource.chksz;
      if (usesChksz && _apiKey.isEmpty) {
        throw ApiException('API_KEY_REQUIRED', '播放需要配置 API Key（设置 → API 配置）');
      }

      // 网易云和 QQ 的歌词接口与播放地址互不依赖，提前并发请求；歌词不会再
      // 阻塞音频源加载。已有歌词则直接复用，不发请求。
      final independentLyrics = immediateLyrics == null
          ? _fetchIndependentLyrics(item)
          : null;

      // 选中一首新歌后先停止旧音源，避免 UI 与实际播放内容不一致。
      await _audioPlayer.stop();
      if (!_isCurrentRequest(requestId, item)) return;

      // 缓存检查只依赖平台和歌曲 id，必须放在网络解析之前。命中缓存时
      // 直接播放本地文件，不再为了封面、歌手、专辑等已有信息请求详情。
      final cachedPath = await AudioCacheService.getCachedPath(
        platformCode: item.platform.code,
        songId: _audioCacheSongId(item),
      );
      if (!_isCurrentRequest(requestId, item)) return;

      SongDetail? detail;
      String? resolvedUrl;
      late final String playPath;
      var shouldCacheAudio = false;
      if (cachedPath != null) {
        debugPrint('缓存命中: $cachedPath');
        playPath = cachedPath;
      } else {
        resolvedUrl = _freshPlayUrl(item);
        if (resolvedUrl == null) {
          detail = await _resolveSongDetail(item);
          if (!_isCurrentRequest(requestId, item)) return;
          resolvedUrl = detail.url;
          if (resolvedUrl.isEmpty) {
            throw ApiException('404', '无法获取播放地址，可能是版权限制');
          }
          _playUrlResolvedAt[itemKey] = DateTime.now();
          shouldCacheAudio = true;
        }
        playPath = resolvedUrl;
      }

      // 已有封面优先，解析接口返回的封面只补空缺，避免 URL 改变导致播放页
      // 再下载一次相同图片。歌名、歌手和专辑始终使用列表已有元数据。
      final effectiveCover = _preferExisting(item.coverUrl, detail?.coverUrl);
      final playbackHeaders = cachedPath != null
          ? null
          : detail != null
          ? detail.playbackHeaders
          : item.playbackHeaders;
      _queue[_currentIndex] = _queue[_currentIndex].copyWith(
        playUrl: resolvedUrl,
        duration: detail?.duration,
        coverUrl: effectiveCover,
        playbackHeaders: playbackHeaders,
        clearPlaybackHeaders:
            cachedPath == null && detail != null && playbackHeaders == null,
        loading: false,
        clearError: true,
      );

      // 设置音频源并播放（tag: MediaItem 用于系统媒体通知显示歌曲信息）
      final audioUri = playPath.startsWith('/')
          ? Uri.file(playPath)
          : Uri.parse(playPath);
      await _audioPlayer.setAudioSource(
        AudioSource.uri(
          audioUri,
          headers: playbackHeaders,
          tag: MediaItem(
            id: '${item.platform.code}_${_audioCacheSongId(item)}',
            title: item.name,
            artist: item.artist,
            album: item.album,
            artUri: effectiveCover != null && effectiveCover.isNotEmpty
                ? Uri.parse(effectiveCover)
                : null,
          ),
        ),
        preload: true,
      );
      if (!_isCurrentRequest(requestId, item)) return;

      // just_audio 的 play() Future 会在暂停、停止或播放结束时才完成。
      // 音源准备完成即结束“加载中”，播放过程放到后台等待。
      _isLoading = false;
      notifyListeners();
      unawaited(_startPlayback(requestId, item));

      // 歌词独立完成：网络慢或失败都不阻塞声音。酷狗歌词随解析详情返回；
      // 若本地音频秒开且没有歌词，只在后台补一次歌词。
      if (immediateLyrics == null) {
        if (independentLyrics != null) {
          unawaited(
            _completeLyrics(
              requestId,
              item,
              independentLyrics,
              fallbackText: detail?.lyric,
            ),
          );
        } else if (detail != null) {
          _applyLyrics(
            requestId,
            item,
            _ResolvedLyrics.fromPlainText(detail.lyric),
          );
        } else {
          unawaited(_loadBundledLyricsInBackground(requestId, item));
        }
      }

      // 等音频源已预加载并开始播放后再启动后台下载，避免缓存下载与首包
      // 缓冲争抢带宽。
      if (shouldCacheAudio && resolvedUrl != null) {
        unawaited(
          _cacheAudioAfterPlaybackStarts(
            requestId,
            item,
            resolvedUrl,
            headers: playbackHeaders,
          ),
        );
      }

      // 系统悬浮胶囊：显示/更新当前歌曲
      if (FloatingCapsuleService.enabled) {
        FloatingCapsuleService.show(
          title: item.name,
          artist: item.artist,
          coverUrl: effectiveCover,
          isPlaying: true,
        );
      }

      // 歌词索引由 positionStream 驱动更新（无需额外定时器）
    } catch (e) {
      if (!_isCurrentRequest(requestId, item)) return;
      _queue[_currentIndex] = _queue[_currentIndex].copyWith(
        loading: false,
        error: e.toString(),
      );
      _errorMessage = e.toString();
      _lastError = _friendlyError(e);
      _isLoading = false;
      _lyricsLoading = false;
      notifyListeners();
    } finally {
      if (_isCurrentRequest(requestId, item) && _isLoading) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  String _itemKey(PlayQueueItem item) {
    if (item.platform == MusicPlatform.bilibili) {
      return '${item.platform.code}:${item.id}:${item.bilibiliCid ?? 0}:'
          'q$_bilibiliAudioQuality';
    }
    return '${item.platform.code}:${item.id}';
  }

  String _audioCacheSongId(PlayQueueItem item) {
    if (item.platform == MusicPlatform.bilibili) {
      return '${item.id}_${item.bilibiliCid ?? 0}_q$_bilibiliAudioQuality';
    }
    return item.id;
  }

  Future<PlayQueueItem> _prepareBilibiliItem(
    int requestId,
    PlayQueueItem item,
  ) async {
    var pages = item.bilibiliPages;
    var description = item.bilibiliDescription;
    var videoTitle = item.bilibiliVideoTitle ?? item.album;
    var coverUrl = item.coverUrl;
    if (pages.isEmpty || description == null) {
      final info = await _api.bilibili.videoInfo(item.id);
      if (!_isCurrentRequest(requestId, item)) return item;
      pages = info.pages;
      description = info.description;
      videoTitle = info.title;
      coverUrl = _preferExisting(coverUrl, info.coverUrl);
    }
    final selected = pages.firstWhere(
      (page) => page.cid == item.bilibiliCid,
      orElse: () => pages.first,
    );
    final prepared = item.copyWith(
      name: selected.title,
      album: videoTitle,
      coverUrl: coverUrl,
      duration: selected.duration,
      bilibiliVideoTitle: videoTitle,
      bilibiliDescription: description,
      bilibiliCid: selected.cid,
      bilibiliPage: selected.page,
      bilibiliPages: pages,
    );
    _queue[_currentIndex] = prepared;
    notifyListeners();
    return prepared;
  }

  String? _preferExisting(String? existing, String? fallback) {
    if (existing != null && existing.trim().isNotEmpty) return existing;
    if (fallback != null && fallback.trim().isNotEmpty) return fallback;
    return null;
  }

  String? _freshPlayUrl(PlayQueueItem item) {
    final url = item.playUrl;
    final resolvedAt = _playUrlResolvedAt[_itemKey(item)];
    if (url == null || url.isEmpty || resolvedAt == null) return null;
    if (DateTime.now().difference(resolvedAt) > _resolvedUrlLifetime) {
      _playUrlResolvedAt.remove(_itemKey(item));
      return null;
    }
    return url;
  }

  Future<SongDetail> _resolveSongDetail(PlayQueueItem item) async {
    if (item.platform == MusicPlatform.bilibili) {
      final cid = item.bilibiliCid;
      if (cid == null || cid <= 0) {
        throw const BilibiliApiException('VIDEO_CID', '当前分P信息不完整');
      }
      final playInfo = await _api.bilibili.playInfo(item.id, cid);
      _bilibiliAudioQualities = playInfo.audioStreams;
      _bilibiliVideoQualities = playInfo.videoStreams;
      final selected = playInfo.audioStreams.firstWhere(
        (stream) => stream.quality == _bilibiliAudioQuality,
        orElse: () => playInfo.audioStreams.first,
      );
      if (!playInfo.audioStreams.any(
        (stream) => stream.quality == _bilibiliAudioQuality,
      )) {
        _bilibiliAudioQuality = selected.quality;
      }
      return SongDetail(
        name: item.name,
        artist: item.artist,
        album: item.album,
        url: selected.url,
        duration: playInfo.duration,
        bitrate: selected.bandwidth.toString(),
        format: selected.mimeType?.split('/').last,
        playbackHeaders: _api.bilibili.playbackHeaders,
      );
    }
    if (playbackSourceFor(item.platform) == PlaybackSource.qingMusic) {
      return await _api.qingMusic(
        item.platform,
        item.id,
        quality: item.platform == MusicPlatform.netease
            ? _neteaseLevel.value
            : _commonLevel.value,
      );
    }
    switch (item.platform) {
      case MusicPlatform.netease:
        return _api.neteaseMusic(item.id, level: _neteaseLevel.value);
      case MusicPlatform.qq:
        return _api.qqMusic(item.id, size: _commonLevel.value);
      case MusicPlatform.kugou:
        return await _api.kugouMusic(item.id, size: _commonLevel.value);
      case MusicPlatform.bilibili:
        throw StateError('B站播放已在专用分支处理');
    }
  }

  _ResolvedLyrics? _cachedLyrics(PlayQueueItem item) {
    final cached = _lyricCache[_itemKey(item)];
    if (cached != null) return cached;
    final raw = item.lyric;
    if (raw == null || raw.trim().isEmpty) return null;
    final resolved = _ResolvedLyrics.fromPlainText(raw);
    if (resolved != null) _lyricCache[_itemKey(item)] = resolved;
    return resolved;
  }

  Future<_ResolvedLyrics?>? _fetchIndependentLyrics(PlayQueueItem item) {
    switch (item.platform) {
      case MusicPlatform.netease:
        return _fetchNeteaseLyrics(item.id);
      case MusicPlatform.qq:
        return _fetchQqLyrics(item.id);
      case MusicPlatform.kugou:
        return _fetchKugouLyrics(item.id);
      case MusicPlatform.bilibili:
        return null;
    }
  }

  Future<_ResolvedLyrics?> _fetchNeteaseLyrics(String id) async {
    try {
      return _resolveLyricData(await _api.neteaseLyric(id));
    } catch (_) {
      return null;
    }
  }

  Future<_ResolvedLyrics?> _fetchQqLyrics(String id) async {
    try {
      return _resolveLyricData(await _api.qqLyric(id));
    } catch (_) {
      return null;
    }
  }

  Future<_ResolvedLyrics?> _fetchKugouLyrics(String id) async {
    try {
      return _resolveLyricData(await _api.kugouPublicLyric(id));
    } catch (_) {
      return null;
    }
  }

  _ResolvedLyrics? _resolveLyricData(LyricData data) {
    final enhanced = LyricParser.parseEnhanced(data.wordSynced);
    final hasWordTiming = enhanced.any((line) => line.words.isNotEmpty);
    final original = hasWordTiming
        ? enhanced
        : LyricParser.parseBestEffort(data.original);
    if (original.isEmpty) return null;
    final translated = LyricParser.parse(data.translated);
    return _ResolvedLyrics(
      rawText: hasWordTiming ? data.wordSynced : data.original,
      lines: LyricParser.mergeTranslation(original, translated),
    );
  }

  Future<void> _completeLyrics(
    int requestId,
    PlayQueueItem item,
    Future<_ResolvedLyrics?> request, {
    String? fallbackText,
  }) async {
    _ResolvedLyrics? resolved;
    try {
      resolved = await request;
    } catch (_) {
      // 请求本身已做容错；保留兜底避免未来实现抛出未处理异常。
    }
    resolved ??= _ResolvedLyrics.fromPlainText(fallbackText);
    _applyLyrics(requestId, item, resolved);
  }

  void _applyLyrics(
    int requestId,
    PlayQueueItem item,
    _ResolvedLyrics? resolved,
  ) {
    if (!_isCurrentRequest(requestId, item)) return;
    _lyrics = resolved?.lines ?? [];
    _currentLyricIndex = 0;
    _lyricsLoading = false;
    if (resolved != null) {
      _lyricCache[_itemKey(item)] = resolved;
      final current = _queue[_currentIndex];
      _queue[_currentIndex] = current.copyWith(lyric: resolved.rawText);
    }
    notifyListeners();
  }

  Future<void> _loadBundledLyricsInBackground(
    int requestId,
    PlayQueueItem item,
  ) async {
    try {
      final detail = await _resolveSongDetail(item);
      if (!_isCurrentRequest(requestId, item)) return;
      if (detail.url.isNotEmpty) {
        _playUrlResolvedAt[_itemKey(item)] = DateTime.now();
        final current = _queue[_currentIndex];
        _queue[_currentIndex] = current.copyWith(
          playUrl: detail.url,
          duration: detail.duration,
          coverUrl: _preferExisting(current.coverUrl, detail.coverUrl),
        );
      }
      _applyLyrics(
        requestId,
        item,
        _ResolvedLyrics.fromPlainText(detail.lyric),
      );
    } catch (_) {
      _applyLyrics(requestId, item, null);
    }
  }

  Future<void> _cacheAudioAfterPlaybackStarts(
    int requestId,
    PlayQueueItem item,
    String url, {
    Map<String, String>? headers,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!_isCurrentRequest(requestId, item)) return;
    final localPath = await AudioCacheService.cacheAudio(
      platformCode: item.platform.code,
      songId: _audioCacheSongId(item),
      url: url,
      name: item.name,
      artist: item.artist,
      headers: headers,
    );
    if (localPath != null) debugPrint('后台缓存完成: $localPath');
  }

  Future<void> _startPlayback(int requestId, PlayQueueItem item) async {
    try {
      await _audioPlayer.play();
    } catch (e) {
      if (!_isCurrentRequest(requestId, item)) return;
      _errorMessage = '播放错误: $e';
      notifyListeners();
    }
  }

  bool _isCurrentRequest(int requestId, PlayQueueItem item) {
    final current = currentSong;
    return !_disposed &&
        requestId == _playRequestId &&
        current?.platform == item.platform &&
        current?.id == item.id;
  }

  /// 把底层异常翻译成用户可读的提示
  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('QingMusic') || s.contains('QING_')) {
      return 'QingMusic 音源解析失败，请重试或在设置中切换为 ChKSz';
    }
    if (s.contains('404') || s.contains('版权') || s.contains('无法获取播放地址')) {
      return '音源获取失败：可能是版权限制或无资源，换一首试试';
    }
    if (s.contains('SocketException') ||
        s.contains('Connection') ||
        s.contains('Failed host lookup') ||
        s.contains('timeout') ||
        s.contains('网络')) {
      return '网络异常：音源下载失败，请检查网络后重试';
    }
    return '播放失败：音源可能失效，请重试或切换音质';
  }

  void _onSongComplete() {
    switch (_playMode) {
      case PlayMode.sequence:
        playNext();
        break;
      case PlayMode.repeat:
        _audioPlayer.seek(Duration.zero);
        _audioPlayer.play();
        break;
      case PlayMode.shuffle:
        if (_queue.length > 1) {
          final random = DateTime.now().millisecondsSinceEpoch % _queue.length;
          _currentIndex = random;
          _playCurrent();
        }
        break;
    }
  }

  Future<void> selectBilibiliPage(int pageIndex) async {
    final song = currentSong;
    if (song == null ||
        song.platform != MusicPlatform.bilibili ||
        pageIndex < 0 ||
        pageIndex >= song.bilibiliPages.length) {
      return;
    }
    final page = song.bilibiliPages[pageIndex];
    if (page.cid == song.bilibiliCid) return;
    _queue[_currentIndex] = song.copyWith(
      name: page.title,
      duration: page.duration,
      bilibiliCid: page.cid,
      bilibiliPage: page.page,
      clearPlayUrl: true,
      clearPlaybackHeaders: true,
    );
    _lyrics.clear();
    _lyricsLoading = false;
    notifyListeners();
    await _playCurrent();
  }

  Future<BilibiliVideoSource> currentBilibiliVideoSource() async {
    final song = currentSong;
    if (song == null || song.platform != MusicPlatform.bilibili) {
      throw const BilibiliApiException('VIDEO_CURRENT', '当前不是B站视频');
    }
    final cid = song.bilibiliCid;
    if (cid == null || cid <= 0) {
      throw const BilibiliApiException('VIDEO_CID', '当前分P仍在加载');
    }
    return _api.bilibili.videoSource(song.id, cid, _bilibiliVideoQuality);
  }

  Future<String> currentBilibiliVideoUrl() async {
    return (await currentBilibiliVideoSource()).url;
  }

  Future<void> playPause() async {
    if (currentSong == null || _isLoading) return;
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
  }

  Future<void> pause() => _audioPlayer.pause();

  Future<void> playNext() async {
    if (_queue.isEmpty) return;
    if (_playMode == PlayMode.shuffle) {
      _currentIndex = DateTime.now().millisecondsSinceEpoch % _queue.length;
    } else {
      _currentIndex = (_currentIndex + 1) % _queue.length;
    }
    notifyListeners();
    await _playCurrent();
  }

  Future<void> playPrevious() async {
    if (_queue.isEmpty) return;
    _currentIndex = (_currentIndex - 1 + _queue.length) % _queue.length;
    notifyListeners();
    await _playCurrent();
  }

  Future<void> seekTo(Duration position) async {
    await _audioPlayer.seek(position);
    _position = position;
    _updateLyricIndex();
    notifyListeners();
  }

  void togglePlayMode() {
    switch (_playMode) {
      case PlayMode.sequence:
        _playMode = PlayMode.repeat;
        break;
      case PlayMode.repeat:
        _playMode = PlayMode.shuffle;
        break;
      case PlayMode.shuffle:
        _playMode = PlayMode.sequence;
        break;
    }
    notifyListeners();
  }

  void toggleShowLyric() {
    _showLyric = !_showLyric;
    notifyListeners();
  }

  Future<void> playQueueItem(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _currentIndex = index;
    notifyListeners();
    await _playCurrent();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    if (index < _currentIndex) {
      _currentIndex--;
    } else if (index == _currentIndex) {
      if (_currentIndex >= _queue.length) _currentIndex = _queue.length - 1;
      if (_currentIndex >= 0) {
        unawaited(_playCurrent());
      } else {
        _playRequestId++;
        unawaited(_audioPlayer.stop());
      }
    }
    notifyListeners();
  }

  void clearQueue() {
    _playRequestId++;
    _queueSessionId++;
    _queue.clear();
    _currentIndex = -1;
    _lyrics.clear();
    _lyricsLoading = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    _isLoading = false;
    _isPlaying = false;
    _errorMessage = null;
    unawaited(_audioPlayer.stop());
    unawaited(FloatingCapsuleService.hide());
    notifyListeners();
  }

  // ==================== 歌词同步 ====================

  void _updateLyricIndex() {
    if (_lyrics.isEmpty) return;
    final newIndex = LyricParser.findCurrentIndex(_lyrics, _position);
    if (newIndex != _currentLyricIndex) {
      _currentLyricIndex = newIndex;
    }
  }

  // ==================== 清理 ====================

  @override
  void dispose() {
    _disposed = true;
    _playRequestId++;
    _queueSessionId++;
    _playerSub?.cancel();
    _durationSub?.cancel();
    _positionSub?.cancel();
    _bufferSub?.cancel();
    _errorSub?.cancel();
    _api.bilibili.removeListener(_handleBilibiliChanged);
    _api.close();
    _audioPlayer.dispose();
    super.dispose();
  }
}

class _ResolvedLyrics {
  final String? rawText;
  final List<LyricLine> lines;

  const _ResolvedLyrics({required this.rawText, required this.lines});

  static _ResolvedLyrics? fromPlainText(String? rawText) {
    if (rawText == null || rawText.trim().isEmpty) return null;
    return _ResolvedLyrics(
      rawText: rawText,
      lines: LyricParser.parseBestEffort(rawText),
    );
  }
}
