import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_cache_service.dart';
import '../services/bilibili_service.dart';
import '../services/floating_capsule_service.dart';
import '../services/global_settings_service.dart';
import '../services/playback_history_service.dart';
import '../services/playback_state_service.dart';
import '../services/user_data_scope.dart';
import '../utils/lyric_parser.dart';

// Lyrics are returned as user-facing text but then expanded into many parsed
// objects and retained in a session cache. Keep a malformed or unexpectedly
// large response from creating a second memory spike in the player.
const _maxLyricTextChars = 256 * 1024;

String? _boundLyricText(String? value) {
  if (value == null || value.length <= _maxLyricTextChars) return value;
  return value.substring(0, _maxLyricTextChars);
}

/// 播放模式
enum PlayMode { sequence, repeat, shuffle }

/// 全局播放器状态管理
class PlayerProvider extends ChangeNotifier {
  static const _resolvedUrlLifetime = Duration(minutes: 5);
  static const defaultLyricOffsetStep = Duration(milliseconds: 500);
  static const minLyricOffsetStep = Duration(milliseconds: 100);
  static const maxLyricOffsetStep = Duration(seconds: 2);
  static const lyricOffsetLimit = Duration(minutes: 1);
  static const _lyricOffsetStepKey = 'lyric_offset_step_ms';
  static const _historyPersistDelay = Duration(seconds: 2);
  static const _playbackStatePersistDelay = Duration(seconds: 1);
  // Keep session-only metadata bounded during long car sessions. Lyrics are
  // parsed into many Dart objects, while the other maps otherwise grow once
  // for every song visited in the current process.
  static const _maxCachedLyrics = 24;
  static const _maxCachedPlayUrls = 64;
  static const _maxCachedLyricOffsets = 128;
  static const _maxBilibiliLyricAttempts = 64;
  // A single B 站视频通常只有几个分 P. Keep an unexpectedly malformed
  // response from turning one tap into an unbounded queue allocation.
  static const _maxBilibiliPagesPerResource = 500;
  static const _bilibiliLyricPlatformOrderKey = 'bilibili_lyric_platform_order';
  static const _defaultBilibiliLyricPlatformOrder = <MusicPlatform>[
    MusicPlatform.qq,
    MusicPlatform.kugou,
    MusicPlatform.netease,
  ];

  final AudioPlayer _audioPlayer = AudioPlayer();
  late ApiService _api;
  late final Future<void> settingsReady;
  late final Future<void> playbackStateReady;

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
  Duration _lyricOffsetStep = defaultLyricOffsetStep;
  final Map<String, _ResolvedLyrics> _lyricCache = {};
  final Map<String, Duration> _lyricOffsets = {};
  final Set<String> _bilibiliLyricAutoAttempted = {};
  final Map<String, DateTime> _playUrlResolvedAt = {};
  List<PlaybackHistoryEntry> _playbackHistory = [];
  int _playbackHistoryRevision = 0;
  Timer? _historyPersistTimer;
  bool _historyPersistInFlight = false;
  bool _historyPersistAgain = false;
  Completer<void>? _historyPersistCompletion;
  bool _historyLoaded = false;
  Timer? _playbackStatePersistTimer;
  bool _playbackStatePersistInFlight = false;
  bool _playbackStatePersistAgain = false;
  Completer<void>? _playbackStatePersistCompletion;
  bool _playbackStateLoaded = false;
  bool _restoredPlaybackPending = false;
  bool _playbackStateInteraction = false;
  bool _restoredSessionActivationEnabled;
  bool _preparingForExit = false;
  bool _resumeAfterCancelledUserSwitch = false;
  Future<void>? _exitPreparationFuture;
  Future<void>? _resourceDisposeFuture;
  double? _volumeBeforeAssistantDucking;

  // 音质
  NeteaseLevel _neteaseLevel = NeteaseLevel.jymaster;
  CommonLevel _commonLevel = CommonLevel.flac;
  PlaybackSource _neteasePlaybackSource = PlaybackSource.chksz;
  PlaybackSource _qqPlaybackSource = PlaybackSource.chksz;
  PlaybackSource _kugouPlaybackSource = PlaybackSource.chksz;
  List<MusicPlatform> _bilibiliLyricPlatformOrder = List<MusicPlatform>.from(
    _defaultBilibiliLyricPlatformOrder,
  );
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
  int _bilibiliPlayRequestId = 0;
  int _bilibiliAddRequestId = 0;
  bool _disposed = false;
  final UserDataScope dataScope;

  PlayerProvider({
    this.dataScope = UserDataScope.defaultScope,
    bool activateRestoredSession = true,
    BilibiliService? bilibiliService,
  }) : _restoredSessionActivationEnabled = activateRestoredSession {
    _api = ApiService(
      apiKey: '',
      bilibili: bilibiliService ?? BilibiliService(dataScope: dataScope),
    );
    _api.bilibili.addListener(_handleBilibiliChanged);
    _initAudioPlayer();
    historyReady = _loadPlaybackHistory();
    settingsReady = _loadSettings();
    playbackStateReady = _loadPlaybackState();
  }

  late final Future<void> historyReady;

  void _handleBilibiliChanged() {
    if (!_disposed) notifyListeners();
  }

  /// Audio/plugin callbacks can arrive after [dispose] starts cancelling the
  /// subscriptions. Keep every existing notification call safe at the
  /// provider boundary instead of relying on each async path to remember a
  /// separate mounted-style check.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
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
  Duration get lyricOffsetStep => _lyricOffsetStep;
  Duration get lyricOffset {
    final song = currentSong;
    return song == null
        ? Duration.zero
        : _lyricOffsets[_lyricKey(song)] ?? Duration.zero;
  }

  Duration get lyricPosition {
    final adjusted = position - lyricOffset;
    return adjusted.isNegative ? Duration.zero : adjusted;
  }

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

  List<MusicPlatform> get bilibiliLyricPlatformOrder =>
      List.unmodifiable(_bilibiliLyricPlatformOrder);

  VideoPlayerMode get videoPlayerMode => _videoPlayerMode;

  Map<String, dynamic> bilibiliAccountToBackupJson() =>
      _api.bilibili.toBackupJson();

  Future<void> restoreBilibiliAccountBackupJson(
    Map<String, dynamic> json,
  ) async {
    await _api.bilibili.restoreBackupJson(json);
    if (!_disposed) notifyListeners();
  }

  /// Serializes the playback preferences that are otherwise kept in
  /// SharedPreferences. API Key is intentionally handled by BackupService.
  Map<String, dynamic> toBackupJson() => {
    'version': 1,
    'neteaseLevel': _neteaseLevel.value,
    'commonLevel': _commonLevel.value,
    'playbackSources': {
      MusicPlatform.netease.code: _neteasePlaybackSource.value,
      MusicPlatform.qq.code: _qqPlaybackSource.value,
      MusicPlatform.kugou.code: _kugouPlaybackSource.value,
    },
    'bilibiliAudioQuality': _bilibiliAudioQuality,
    'bilibiliVideoQuality': _bilibiliVideoQuality,
    'bilibiliLyricPlatformOrder': _bilibiliLyricPlatformOrder
        .map((platform) => platform.code)
        .toList(growable: false),
    'lyricOffsetStepMs': _lyricOffsetStep.inMilliseconds,
    'videoPlayerMode': _videoPlayerMode.value,
  };

  /// Restores playback preferences in one batch so an import does not cause
  /// several intermediate player rebuilds or repeated URL resolution.
  Future<void> restoreBackupJson(Map<String, dynamic> json) async {
    await settingsReady;
    if (_disposed) return;

    var changed = false;
    final neteaseValue = json['neteaseLevel'];
    if (neteaseValue is String) {
      final level = NeteaseLevel.values.where(
        (item) => item.value == neteaseValue,
      );
      if (level.isNotEmpty && _neteaseLevel != level.first) {
        _neteaseLevel = level.first;
        changed = true;
      }
    }
    final commonValue = json['commonLevel'];
    if (commonValue is String) {
      final level = CommonLevel.values.where(
        (item) => item.value == commonValue,
      );
      if (level.isNotEmpty && _commonLevel != level.first) {
        _commonLevel = level.first;
        changed = true;
      }
    }

    final rawSources = json['playbackSources'];
    final sources = rawSources is Map
        ? rawSources.map((key, value) => MapEntry(key.toString(), value))
        : <String, dynamic>{};
    PlaybackSource? sourceFor(MusicPlatform platform) {
      final value =
          sources[platform.code] ?? json['${platform.code}PlaybackSource'];
      if (value is! String) return null;
      for (final source in PlaybackSource.values) {
        if (source.value == value) return source;
      }
      return null;
    }

    final neteaseSource = sourceFor(MusicPlatform.netease);
    if (neteaseSource != null && _neteasePlaybackSource != neteaseSource) {
      _neteasePlaybackSource = neteaseSource;
      changed = true;
    }
    final qqSource = sourceFor(MusicPlatform.qq);
    if (qqSource != null && _qqPlaybackSource != qqSource) {
      _qqPlaybackSource = qqSource;
      changed = true;
    }
    final kugouSource = sourceFor(MusicPlatform.kugou);
    if (kugouSource != null && _kugouPlaybackSource != kugouSource) {
      _kugouPlaybackSource = kugouSource;
      changed = true;
    }

    final audioQuality = _positiveInt(json['bilibiliAudioQuality']);
    if (audioQuality != null && audioQuality != _bilibiliAudioQuality) {
      _bilibiliAudioQuality = audioQuality;
      changed = true;
    }
    final videoQuality = _positiveInt(json['bilibiliVideoQuality']);
    if (videoQuality != null && videoQuality != _bilibiliVideoQuality) {
      _bilibiliVideoQuality = videoQuality;
      changed = true;
    }

    final rawOrder = json['bilibiliLyricPlatformOrder'];
    if (rawOrder is List) {
      final order = rawOrder.whereType<String>().map((value) {
        for (final platform in MusicPlatform.values) {
          if (platform.code == value) return platform;
        }
        return null;
      }).whereType<MusicPlatform>();
      final normalized = _normalizeBilibiliLyricPlatformOrder(order);
      if (!_samePlatformOrder(_bilibiliLyricPlatformOrder, normalized)) {
        _bilibiliLyricPlatformOrder = normalized;
        changed = true;
      }
    }

    final rawStep = _positiveInt(json['lyricOffsetStepMs']);
    if (rawStep != null) {
      final step = _normalizeLyricOffsetStep(Duration(milliseconds: rawStep));
      if (_lyricOffsetStep != step) {
        _lyricOffsetStep = step;
        changed = true;
      }
    }

    final modeValue = json['videoPlayerMode'];
    if (modeValue is String) {
      final mode = VideoPlayerMode.values.where(
        (item) => item.value == modeValue,
      );
      if (mode.isNotEmpty && _videoPlayerMode != mode.first) {
        _videoPlayerMode = mode.first;
        changed = true;
      }
    }

    if (!changed) return;
    _playUrlResolvedAt.clear();
    await _savePreference('播放器设置', (prefs) async {
      await Future.wait([
        prefs.setString('netease_level', _neteaseLevel.value),
        prefs.setString('common_level', _commonLevel.value),
        prefs.setString(
          _playbackSourcePreferenceKey(MusicPlatform.netease),
          _neteasePlaybackSource.value,
        ),
        prefs.setString(
          _playbackSourcePreferenceKey(MusicPlatform.qq),
          _qqPlaybackSource.value,
        ),
        prefs.setString(
          _playbackSourcePreferenceKey(MusicPlatform.kugou),
          _kugouPlaybackSource.value,
        ),
        prefs.setInt('bilibili_audio_quality', _bilibiliAudioQuality),
        prefs.setInt('bilibili_video_quality', _bilibiliVideoQuality),
        prefs.setStringList(
          _bilibiliLyricPlatformOrderKey,
          _bilibiliLyricPlatformOrder
              .map((platform) => platform.code)
              .toList(growable: false),
        ),
        prefs.setInt(_lyricOffsetStepKey, _lyricOffsetStep.inMilliseconds),
        prefs.setString('video_player_mode', _videoPlayerMode.value),
      ]);
      return true;
    });
    if (!_disposed) notifyListeners();
  }

  static int? _positiveInt(dynamic value) {
    if (value is int && value > 0) return value;
    if (value is num && value > 0) return value.round();
    return null;
  }

  static bool _samePlatformOrder(
    List<MusicPlatform> first,
    List<MusicPlatform> second,
  ) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  void _rememberLyric(String key, _ResolvedLyrics value) {
    _lyricCache.remove(key);
    _lyricCache[key] = value;
    while (_lyricCache.length > _maxCachedLyrics) {
      _lyricCache.remove(_lyricCache.keys.first);
    }
  }

  void _rememberPlayUrl(String key) {
    final now = DateTime.now();
    _playUrlResolvedAt.removeWhere(
      (_, resolvedAt) => now.difference(resolvedAt) > _resolvedUrlLifetime,
    );
    _playUrlResolvedAt.remove(key);
    _playUrlResolvedAt[key] = now;
    while (_playUrlResolvedAt.length > _maxCachedPlayUrls) {
      _playUrlResolvedAt.remove(_playUrlResolvedAt.keys.first);
    }
  }

  bool _rememberBilibiliLyricAttempt(String key) {
    if (!_bilibiliLyricAutoAttempted.add(key)) return false;
    while (_bilibiliLyricAutoAttempted.length > _maxBilibiliLyricAttempts) {
      _bilibiliLyricAutoAttempted.remove(_bilibiliLyricAutoAttempted.first);
    }
    return true;
  }

  List<PlaybackHistoryEntry> get playbackHistory =>
      List.unmodifiable(_playbackHistory);
  int get playbackHistoryRevision => _playbackHistoryRevision;

  String get apiKey => _apiKey;
  AudioPlayer get audioPlayer => _audioPlayer;
  ApiService get api => _api;

  // ==================== 初始化 ====================

  Future<void> _loadPlaybackHistory() async {
    try {
      _playbackHistory = await PlaybackHistoryService.load(scope: dataScope);
    } catch (error, stackTrace) {
      // Keep the constructor-owned future contained if storage fails outside
      // the service's normal error boundary.
      debugPrint('读取播放历史失败: $error');
      debugPrintStack(stackTrace: stackTrace);
      _playbackHistory = [];
    }
    _playbackHistoryRevision++;
    _historyLoaded = true;
    if (!_disposed) notifyListeners();
  }

  Future<void> _loadPlaybackState() async {
    final snapshot = await PlaybackStateService.load(scope: dataScope);
    if (_disposed) return;
    _playbackStateLoaded = true;
    if (snapshot == null || _playbackStateInteraction) {
      if (_queue.isNotEmpty) _persistPlaybackStateNow();
      return;
    }

    try {
      _queue = snapshot.queue
          .map(PlayQueueItem.fromSearchResult)
          .toList(growable: true);
      _currentIndex = snapshot.currentIndex;
      _position = snapshot.position;
      _duration = _queue[_currentIndex].duration == null
          ? Duration.zero
          : Duration(seconds: _queue[_currentIndex].duration!);
      _playMode = switch (snapshot.playMode) {
        'repeat' => PlayMode.repeat,
        'shuffle' => PlayMode.shuffle,
        _ => PlayMode.sequence,
      };
      _restoredPlaybackPending = snapshot.isPlaying;
      notifyListeners();
      // A paused session still has a meaningful current song. Keep the
      // always-on-top car mini window informative even when no audio source
      // needs to be resolved on startup.
      final restoredSong = currentSong;
      if (_restoredSessionActivationEnabled &&
          restoredSong != null &&
          FloatingCapsuleService.enabled) {
        unawaited(
          FloatingCapsuleService.show(
            title: restoredSong.name,
            artist: restoredSong.artist,
            coverUrl: restoredSong.coverUrl,
            isPlaying: snapshot.isPlaying,
          ),
        );
      }
      if (_restoredSessionActivationEnabled &&
          snapshot.isPlaying &&
          !_preparingForExit) {
        unawaited(_resumeRestoredPlayback());
      }
    } catch (error, stackTrace) {
      debugPrint('恢复播放会话失败: $error');
      debugPrintStack(stackTrace: stackTrace);
      _queue = [];
      _currentIndex = -1;
      _position = Duration.zero;
      _duration = Duration.zero;
    }
  }

  Future<void> _resumeRestoredPlayback() async {
    await Future.wait([settingsReady, historyReady]);
    if (_disposed || !_restoredPlaybackPending || _queue.isEmpty) return;
    _restoredPlaybackPending = false;
    await _playCurrent(resumePosition: _position);
  }

  void _cancelPendingPlaybackRestore() {
    _restoredPlaybackPending = false;
    _playbackStateInteraction = true;
  }

  void _cancelPendingBilibiliPlay() {
    _bilibiliPlayRequestId++;
  }

  Future<void> activateRestoredSession() async {
    await playbackStateReady;
    if (_disposed || _restoredSessionActivationEnabled) return;
    _restoredSessionActivationEnabled = true;
    final song = currentSong;
    if (song != null && FloatingCapsuleService.enabled) {
      await FloatingCapsuleService.show(
        title: song.name,
        artist: song.artist,
        coverUrl: song.coverUrl,
        isPlaying: _restoredPlaybackPending,
      );
    }
    if (_restoredPlaybackPending) await _resumeRestoredPlayback();
  }

  void _initAudioPlayer() {
    _playerSub = _audioPlayer.playerStateStream.listen(
      (state) {
        if (_disposed) return;
        _isPlaying = state.playing;
        // 系统悬浮胶囊同步播放状态
        if (FloatingCapsuleService.enabled) {
          FloatingCapsuleService.updatePlayState(state.playing);
        }
        // 空音频/加载失败保护：加载或解码失败（如 404、空文件、格式不支持）
        // 会触发 playbackEventStream 的 onError（下方 _errorSub 统一处理：停止 + 提示）
        if (state.processingState == ProcessingState.completed) {
          _recordCurrentHistory(position: Duration.zero, immediate: true);
          _persistPlaybackStateNow();
          _onSongComplete();
        } else if (!state.playing &&
            state.processingState != ProcessingState.idle) {
          // A pause is an explicit persistence boundary, so a resumed session
          // does not lose the latest position while waiting for the debounce.
          _recordCurrentHistory(immediate: true);
          _persistPlaybackStateNow();
        } else {
          _schedulePlaybackStatePersist();
        }
        notifyListeners();
      },
      onError: (Object error, StackTrace stackTrace) {
        _handlePlayerStreamError('player state', error, stackTrace);
      },
    );

    _durationSub = _audioPlayer.durationStream.listen(
      (d) {
        if (_disposed) return;
        _duration = d ?? Duration.zero;
        notifyListeners();
      },
      onError: (Object error, StackTrace stackTrace) {
        _handlePlayerStreamError('duration', error, stackTrace);
      },
    );

    _positionSub = _audioPlayer.positionStream.listen(
      (p) {
        if (_disposed) return;
        _position = p;
        _updateLyricIndex();
        if (_isPlaying) {
          _recordCurrentHistory(position: p);
          _schedulePlaybackStatePersist();
        }
        notifyListeners();
      },
      onError: (Object error, StackTrace stackTrace) {
        _handlePlayerStreamError('position', error, stackTrace);
      },
    );

    _bufferSub = _audioPlayer.bufferedPositionStream.listen(
      (b) {
        if (_disposed) return;
        _buffered = b;
        notifyListeners();
      },
      onError: (Object error, StackTrace stackTrace) {
        _handlePlayerStreamError('buffered position', error, stackTrace);
      },
    );

    _errorSub = _audioPlayer.playbackEventStream.listen(
      (_) {},
      onError: (e) {
        if (_disposed) return;
        // 播放中途出错（解码失败/数据流中断）：停止并提示，避免静默
        _isLoading = false;
        _errorMessage = '播放错误: $e';
        _lastError = '播放出错：音源可能已失效，已停止播放';
        unawaited(_stopAfterPlaybackError());
        notifyListeners();
      },
    );
  }

  void _handlePlayerStreamError(
    String streamName,
    Object error,
    StackTrace stackTrace,
  ) {
    if (_disposed) return;
    debugPrint('播放器 $streamName 状态流异常: $error');
    debugPrintStack(stackTrace: stackTrace);
  }

  Future<void> _stopAfterPlaybackError() async {
    try {
      await _audioPlayer.stop();
    } catch (error) {
      // The original playback error is already surfaced to the UI. A second
      // stop failure must not become an unhandled async exception.
      debugPrint('播放错误后的停止失败: $error');
    }
  }

  void _recordCurrentHistory({Duration? position, bool immediate = false}) {
    final item = currentSong;
    if (item == null) return;
    _recordHistory(item, position ?? _position, immediate: immediate);
  }

  void _recordHistory(
    PlayQueueItem item,
    Duration position, {
    bool immediate = false,
  }) {
    if (!_historyLoaded || _disposed) return;
    final song = SongSearchResult.fromQueueItem(item);
    var positionMs = position.inMilliseconds;
    if (positionMs < 0) positionMs = 0;
    final durationMs = (item.duration ?? 0) * 1000;
    if (durationMs > 0 && positionMs > durationMs) positionMs = durationMs;
    final entry = PlaybackHistoryEntry(
      song: song,
      position: Duration(milliseconds: positionMs),
      playedAt: DateTime.now(),
    );
    final existingIndex = _playbackHistory.indexWhere(
      (current) => current.key == entry.key,
    );
    final historyViewChanged = existingIndex != 0 || immediate;
    if (existingIndex >= 0) _playbackHistory.removeAt(existingIndex);
    _playbackHistory.insert(0, entry);
    if (_playbackHistory.length > PlaybackHistoryService.maxEntries) {
      _playbackHistory = _playbackHistory
          .take(PlaybackHistoryService.maxEntries)
          .toList(growable: true);
    }
    if (historyViewChanged) _playbackHistoryRevision++;
    if (immediate) {
      _historyPersistTimer?.cancel();
      _historyPersistTimer = null;
      unawaited(_persistPlaybackHistory());
      notifyListeners();
    } else {
      _schedulePlaybackHistoryPersist();
    }
  }

  void _schedulePlaybackHistoryPersist() {
    if (_disposed || _preparingForExit) return;
    if (_historyPersistInFlight) {
      _historyPersistAgain = true;
      return;
    }
    if (_historyPersistTimer != null) return;
    _historyPersistTimer = Timer(_historyPersistDelay, () {
      _historyPersistTimer = null;
      unawaited(_persistPlaybackHistory());
    });
  }

  Future<void> _persistPlaybackHistory() async {
    if (_historyPersistInFlight) {
      _historyPersistAgain = true;
      return;
    }
    _historyPersistInFlight = true;
    final completion = Completer<void>();
    _historyPersistCompletion = completion;
    final snapshot = List<PlaybackHistoryEntry>.of(_playbackHistory);
    try {
      await PlaybackHistoryService.save(snapshot, scope: dataScope);
    } catch (error) {
      debugPrint('保存播放历史失败: $error');
    } finally {
      _historyPersistInFlight = false;
      if (_historyPersistAgain && !_disposed) {
        _historyPersistAgain = false;
        _schedulePlaybackHistoryPersist();
      } else {
        _historyPersistAgain = false;
      }
      if (identical(_historyPersistCompletion, completion)) {
        _historyPersistCompletion = null;
      }
      completion.complete();
    }
  }

  Future<void> clearPlaybackHistory() async {
    if (_disposed || _playbackHistory.isEmpty) return;
    _playbackHistory = [];
    _playbackHistoryRevision++;
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    notifyListeners();
    await _persistPlaybackHistory();
  }

  PlaybackSessionSnapshot _playbackStateSnapshot() {
    const maxEntries = PlaybackStateService.maxQueueEntries;
    var start = 0;
    if (_queue.length > maxEntries) {
      start = (_currentIndex - maxEntries ~/ 2)
          .clamp(0, _queue.length - maxEntries)
          .toInt();
    }
    final songs = _queue
        .skip(start)
        .take(maxEntries)
        .map(SongSearchResult.fromQueueItem)
        .toList(growable: false);
    final savedIndex = _currentIndex < 0
        ? 0
        : (_currentIndex - start).clamp(0, songs.length - 1).toInt();
    return PlaybackSessionSnapshot(
      queue: songs,
      currentIndex: savedIndex,
      position: _position,
      isPlaying: _isPlaying && _queue.isNotEmpty,
      playMode: _playMode.name,
    );
  }

  void _schedulePlaybackStatePersist() {
    if (!_playbackStateLoaded || _disposed || _preparingForExit) return;
    if (_playbackStatePersistInFlight) {
      _playbackStatePersistAgain = true;
      return;
    }
    if (_playbackStatePersistTimer != null) return;
    _playbackStatePersistTimer = Timer(_playbackStatePersistDelay, () {
      _playbackStatePersistTimer = null;
      unawaited(_persistPlaybackState());
    });
  }

  void _persistPlaybackStateNow() {
    if (!_playbackStateLoaded || _disposed || _preparingForExit) return;
    _playbackStatePersistTimer?.cancel();
    _playbackStatePersistTimer = null;
    unawaited(_persistPlaybackState());
  }

  Future<void> _persistPlaybackState() async {
    if (!_playbackStateLoaded) return;
    if (_playbackStatePersistInFlight) {
      _playbackStatePersistAgain = true;
      return;
    }
    _playbackStatePersistInFlight = true;
    final completion = Completer<void>();
    _playbackStatePersistCompletion = completion;
    final snapshot = _playbackStateSnapshot();
    try {
      await PlaybackStateService.save(snapshot, scope: dataScope);
    } catch (error, stackTrace) {
      debugPrint('保存播放会话失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      _playbackStatePersistInFlight = false;
      if (_playbackStatePersistAgain && !_disposed) {
        _playbackStatePersistAgain = false;
        unawaited(_persistPlaybackState());
      } else {
        _playbackStatePersistAgain = false;
      }
      if (identical(_playbackStatePersistCompletion, completion)) {
        _playbackStatePersistCompletion = null;
      }
      completion.complete();
    }
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
      await GlobalSettingsService.migrateLegacyScopedSettings(dataScope);
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
      _bilibiliLyricPlatformOrder = _readBilibiliLyricPlatformOrder(
        prefs.getStringList(_bilibiliLyricPlatformOrderKey),
      );
      _lyricOffsetStep = _normalizeLyricOffsetStep(
        Duration(
          milliseconds:
              prefs.getInt(_lyricOffsetStepKey) ??
              defaultLyricOffsetStep.inMilliseconds,
        ),
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

  Future<void> _savePreference(
    String label,
    Future<bool> Function(SharedPreferences prefs) write,
  ) async {
    if (dataScope.isDeleted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (dataScope.isDeleted) return;
      await write(prefs);
    } catch (error, stack) {
      // Settings remain active in memory even when the platform store is
      // unavailable (for example during a transient plugin/IO failure).
      debugPrint('保存$label失败: $error');
      debugPrintStack(stackTrace: stack);
    }
  }

  Future<void> setApiKey(String key) async {
    await settingsReady;
    if (_disposed) return;
    _apiKey = key;
    _api.setApiKey(key);
    await _savePreference(
      'API Key',
      (prefs) => prefs.setString('api_key', key),
    );
    notifyListeners();
  }

  Future<void> setNeteaseLevel(NeteaseLevel level) async {
    await settingsReady;
    if (_disposed) return;
    _neteaseLevel = level;
    _playUrlResolvedAt.clear();
    await _savePreference(
      '网易云音质',
      (prefs) => prefs.setString('netease_level', level.value),
    );
    notifyListeners();
  }

  Future<void> setCommonLevel(CommonLevel level) async {
    await settingsReady;
    if (_disposed) return;
    _commonLevel = level;
    _playUrlResolvedAt.clear();
    await _savePreference(
      '通用音质',
      (prefs) => prefs.setString('common_level', level.value),
    );
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
    await _savePreference(
      '${platform.label}音源',
      (prefs) =>
          prefs.setString(_playbackSourcePreferenceKey(platform), source.value),
    );
    notifyListeners();
  }

  Future<void> setBilibiliLyricPlatformOrder(List<MusicPlatform> order) async {
    await settingsReady;
    if (_disposed) return;
    final normalized = _normalizeBilibiliLyricPlatformOrder(order);
    _bilibiliLyricPlatformOrder = normalized;
    await _savePreference(
      'B 站歌词平台顺序',
      (prefs) => prefs.setStringList(
        _bilibiliLyricPlatformOrderKey,
        normalized.map((platform) => platform.code).toList(growable: false),
      ),
    );
    notifyListeners();
  }

  Future<void> setLyricOffsetStep(Duration step) async {
    await settingsReady;
    if (_disposed) return;
    final normalized = _normalizeLyricOffsetStep(step);
    if (_lyricOffsetStep == normalized) return;
    _lyricOffsetStep = normalized;
    notifyListeners();
    await _savePreference(
      '歌词偏移步长',
      (prefs) => prefs.setInt(_lyricOffsetStepKey, normalized.inMilliseconds),
    );
  }

  static Duration _normalizeLyricOffsetStep(Duration step) {
    final milliseconds = step.inMilliseconds.clamp(
      minLyricOffsetStep.inMilliseconds,
      maxLyricOffsetStep.inMilliseconds,
    );
    return Duration(milliseconds: milliseconds);
  }

  Future<void> setVideoPlayerMode(VideoPlayerMode mode) async {
    await settingsReady;
    if (_disposed || _videoPlayerMode == mode) return;
    _videoPlayerMode = mode;
    await _savePreference(
      '视频播放器模式',
      (prefs) => prefs.setString('video_player_mode', mode.value),
    );
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
    await _savePreference(
      'B 站音频音质',
      (prefs) => prefs.setInt('bilibili_audio_quality', quality),
    );
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
    await _savePreference(
      'B 站视频清晰度',
      (prefs) => prefs.setInt('bilibili_video_quality', quality),
    );
    notifyListeners();
  }

  Future<List<SongSearchResult>> searchLyricCandidates(String keyword) async {
    final song = currentSong;
    final query = keyword.trim();
    if (song == null || query.isEmpty) return const [];
    final results = song.platform == MusicPlatform.bilibili
        ? await _searchBilibiliLyricCandidates(song, query)
        : await _api.searchLyricCandidates(
            platform: song.platform,
            keyword: query,
            currentName: song.name,
            currentArtist: song.artist,
            currentAlbum: song.album,
          );
    final current = currentSong;
    if (!_isSameLyricTarget(current, song)) {
      throw const ApiException('SONG_CHANGED', '当前歌曲已切换，请重新查找歌词');
    }
    return results;
  }

  String lyricSearchQueryFor(PlayQueueItem song) {
    return song.platform == MusicPlatform.bilibili
        ? _cleanBilibiliLyricTitle(song.name)
        : song.name;
  }

  Future<List<SongSearchResult>> _searchBilibiliLyricCandidates(
    PlayQueueItem song,
    String keyword,
  ) async {
    final cleanedKeyword = _cleanBilibiliLyricTitle(keyword);
    final batches = await Future.wait(
      configurableMusicPlatforms.map((platform) async {
        try {
          return await _api.searchLyricCandidates(
            platform: platform,
            keyword: cleanedKeyword,
            currentName: cleanedKeyword,
            // B站的 artist 通常是 UP 主，不一定是真实歌手。搜索仍只用
            // 标题关键词，歌手/UP主在本地评分，避免把跨平台歌词搜索限制得过窄。
            currentArtist: song.artist,
            currentAlbum: '',
          );
        } catch (error) {
          debugPrint('${platform.label}歌词候选搜索失败: $error');
          return const <SongSearchResult>[];
        }
      }),
    );
    final seen = <String>{};
    final candidates = batches
        .expand((batch) => batch)
        .where(
          (candidate) => seen.add('${candidate.platform.code}:${candidate.id}'),
        )
        .toList();
    candidates.sort((a, b) {
      final platformPriority = _bilibiliLyricPlatformOrder
          .indexOf(a.platform)
          .compareTo(_bilibiliLyricPlatformOrder.indexOf(b.platform));
      if (platformPriority != 0) return platformPriority;
      final score =
          _bilibiliLyricMatchScore(
            b,
            cleanedKeyword,
            song.duration,
            expectedArtist: song.artist,
          ).compareTo(
            _bilibiliLyricMatchScore(
              a,
              cleanedKeyword,
              song.duration,
              expectedArtist: song.artist,
            ),
          );
      return score != 0 ? score : a.platform.index.compareTo(b.platform.index);
    });
    return candidates.take(30).toList(growable: false);
  }

  Future<void> applyLyricCandidate(SongSearchResult candidate) async {
    final song = currentSong;
    if (song == null) {
      throw const ApiException('NO_CURRENT_SONG', '当前没有正在播放的歌曲');
    }
    if (song.platform != MusicPlatform.bilibili &&
        candidate.platform != song.platform) {
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
      if (!_isSameLyricTarget(current, song)) {
        throw const ApiException('SONG_CHANGED', '当前歌曲已切换，请重新查找歌词');
      }

      final activeSong = current!;
      _lyricOffsets.remove(_lyricKey(activeSong));
      _lyrics = resolved.lines;
      _currentLyricIndex = LyricParser.findCurrentIndex(_lyrics, lyricPosition);
      _lyricsLoading = false;
      _rememberLyric(_lyricKey(activeSong), resolved);
      _queue[_currentIndex] = activeSong.copyWith(lyric: resolved.rawText);
      notifyListeners();
    } catch (_) {
      final current = currentSong;
      if (_isSameLyricTarget(current, song)) {
        _lyricsLoading = false;
        notifyListeners();
      }
      rethrow;
    }
  }

  static bool _isSameLyricTarget(
    PlayQueueItem? current,
    PlayQueueItem expected,
  ) {
    return current != null &&
        current.platform == expected.platform &&
        current.id == expected.id &&
        (expected.platform != MusicPlatform.bilibili ||
            current.bilibiliCid == expected.bilibiliCid);
  }

  static String _cleanBilibiliLyricTitle(String value) {
    var result = value.trim();
    result = result.replaceFirst(
      RegExp(r'^\s*(?:p\s*)?\d{1,4}\s*[.\-_:：、，]+\s*', caseSensitive: false),
      '',
    );
    result = result.replaceFirst(
      RegExp(r'^\s*(?:p\s*)?\d{1,4}\s+', caseSensitive: false),
      '',
    );
    result = result.replaceAllMapped(
      RegExp(r'\b([a-z]+),([a-z]{1,3})\b', caseSensitive: false),
      (match) => "${match.group(1)}'${match.group(2)}",
    );
    return result.trim().isEmpty ? value.trim() : result.trim();
  }

  static int _bilibiliLyricMatchScore(
    SongSearchResult candidate,
    String keyword,
    int? expectedDuration, {
    String? expectedArtist,
  }) {
    var score = _bilibiliLyricTitleMatchScore(candidate.name, keyword);
    if (expectedArtist != null) {
      score += _bilibiliLyricArtistMatchScore(candidate.artist, expectedArtist);
    }

    final candidateDuration = candidate.duration;
    if (expectedDuration != null && candidateDuration != null) {
      final difference = (candidateDuration - expectedDuration).abs();
      final tolerance = (expectedDuration * 0.2).round().clamp(10, 45).toInt();
      if (difference <= tolerance) {
        score += 240 - (difference * 4).clamp(0, 200).toInt();
      }
    }
    return score;
  }

  static int _bilibiliLyricTitleMatchScore(
    String candidateTitle,
    String keyword,
  ) {
    final expected = _normalizeLyricMatchText(keyword);
    final name = _normalizeLyricMatchText(candidateTitle);
    if (expected.isEmpty || name.isEmpty) return 0;
    if (name == expected) return 1200;
    if (expected.length >= 2 && name.startsWith(expected)) return 850;
    if (name.length >= 2 && expected.startsWith(name)) return 720;
    if (expected.length >= 2 && name.contains(expected)) return 650;

    final expectedTokens = _lyricMatchTokens(keyword);
    final candidateTokens = _lyricMatchTokens(candidateTitle);
    if (expectedTokens.isEmpty || candidateTokens.isEmpty) return 0;
    final overlap = expectedTokens
        .where(
          (token) => candidateTokens.any(
            (candidateToken) =>
                candidateToken == token ||
                candidateToken.contains(token) ||
                token.contains(candidateToken),
          ),
        )
        .length;
    final requiredOverlap = expectedTokens.length >= 3 ? 2 : 1;
    if (overlap < requiredOverlap) return 0;
    return 420 + overlap * 80;
  }

  static int _bilibiliLyricArtistMatchScore(
    String candidateArtist,
    String expectedArtist,
  ) {
    final expected = _normalizeLyricMatchText(expectedArtist);
    final artist = _normalizeLyricMatchText(candidateArtist);
    if (!_isUsefulLyricArtist(expected) || artist.isEmpty) return 0;
    if (artist == expected) return 360;
    if (artist.contains(expected) || expected.contains(artist)) return 180;

    final expectedTokens = _lyricMatchTokens(expectedArtist);
    final artistTokens = _lyricMatchTokens(candidateArtist);
    final overlap = expectedTokens
        .where(
          (token) => artistTokens.any(
            (artistToken) =>
                artistToken == token ||
                artistToken.contains(token) ||
                token.contains(artistToken),
          ),
        )
        .length;
    return overlap > 0 ? 100 : 0;
  }

  @visibleForTesting
  static bool bilibiliLyricTitleMatches(
    String candidateTitle,
    String keyword,
  ) => _bilibiliLyricTitleMatchScore(candidateTitle, keyword) > 0;

  static bool _isUsefulLyricArtist(String normalizedArtist) {
    if (normalizedArtist.isEmpty) return false;
    const placeholders = {
      '未知歌手',
      '未知up主',
      'up主',
      'uploader',
      'unknown',
      'bilibili',
    };
    return !placeholders.contains(normalizedArtist);
  }

  static List<String> _lyricMatchTokens(String value) {
    return RegExp(r'[a-z0-9]+|[\u4e00-\u9fff]')
        .allMatches(_cleanBilibiliLyricTitle(value).toLowerCase())
        .map((match) => match.group(0)!)
        .where(
          (token) =>
              token.length >= 2 || RegExp(r'[\u4e00-\u9fff]').hasMatch(token),
        )
        .toList(growable: false);
  }

  static String _normalizeLyricMatchText(String value) {
    return _cleanBilibiliLyricTitle(
      value,
    ).toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'), '');
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

  static List<MusicPlatform> _readBilibiliLyricPlatformOrder(
    List<String>? values,
  ) {
    if (values == null) {
      return List<MusicPlatform>.from(_defaultBilibiliLyricPlatformOrder);
    }
    final parsed = values
        .map(
          (value) => MusicPlatform.values.cast<MusicPlatform?>().firstWhere(
            (platform) => platform?.code == value,
            orElse: () => null,
          ),
        )
        .whereType<MusicPlatform>();
    return _normalizeBilibiliLyricPlatformOrder(parsed);
  }

  static List<MusicPlatform> _normalizeBilibiliLyricPlatformOrder(
    Iterable<MusicPlatform> order,
  ) {
    final normalized = <MusicPlatform>[];
    for (final platform in order) {
      if (configurableMusicPlatforms.contains(platform) &&
          !normalized.contains(platform)) {
        normalized.add(platform);
      }
    }
    for (final platform in _defaultBilibiliLyricPlatformOrder) {
      if (!normalized.contains(platform)) normalized.add(platform);
    }
    return normalized;
  }

  // ==================== 播放控制 ====================

  /// 从搜索结果播放（替换整个队列）
  Future<void> playFromSearchResults(
    List<SongSearchResult> results,
    int index,
  ) async {
    if (index < 0 || index >= results.length) return;
    final selected = results[index];
    if (selected.platform == MusicPlatform.bilibili) {
      await playBilibiliResource(selected);
      return;
    }
    _cancelPendingBilibiliPlay();
    _cancelPendingPlaybackRestore();
    late final List<PlayQueueItem> nextQueue;
    try {
      nextQueue = results
          .map((result) => PlayQueueItem.fromSearchResult(result))
          .toList(growable: true);
    } catch (error, stackTrace) {
      _handleQueueAllocationFailure(error, stackTrace);
      return;
    }
    _recordCurrentHistory(immediate: true);
    _queueSessionId++;
    _queue = nextQueue;
    _currentIndex = index;
    _persistPlaybackStateNow();
    notifyListeners();
    await _playCurrent();
  }

  /// 添加到队列并播放
  Future<void> playSingle(SongSearchResult result) async {
    if (result.platform == MusicPlatform.bilibili) {
      await playBilibiliResource(result);
      return;
    }
    _cancelPendingBilibiliPlay();
    _cancelPendingPlaybackRestore();
    _recordCurrentHistory(immediate: true);
    _queueSessionId++;
    _queue = [PlayQueueItem.fromSearchResult(result)];
    _currentIndex = 0;
    _persistPlaybackStateNow();
    notifyListeners();
    await _playCurrent();
  }

  /// 添加到队列末尾（不立即播放）。保留 void 签名，兼容车机遥控、旧页面
  /// 和第三方调用方；需要知道实际追加数量的页面使用
  /// [addToQueueAndGetCount]。
  void addToQueue(SongSearchResult result) {
    if (result.platform != MusicPlatform.bilibili) {
      addTracksToQueue([result]);
      return;
    }
    unawaited(addToQueueAndGetCount(result));
  }

  /// Adds a result to the queue and returns the number of concrete queue items
  /// appended. B 站 results expand to one item per valid page.
  Future<int> addToQueueAndGetCount(SongSearchResult result) async {
    if (result.platform != MusicPlatform.bilibili) {
      return addTracksToQueue([result]) ? 1 : 0;
    }
    final requestId = ++_bilibiliAddRequestId;
    final queueSessionId = _queueSessionId;
    try {
      final expanded = await _expandBilibiliResource(result);
      if (_disposed ||
          requestId != _bilibiliAddRequestId ||
          queueSessionId != _queueSessionId) {
        return 0;
      }
      return addTracksToQueue(expanded) ? expanded.length : 0;
    } catch (error, stackTrace) {
      if (!_disposed &&
          requestId == _bilibiliAddRequestId &&
          queueSessionId == _queueSessionId) {
        _handleBilibiliQueueError(error, stackTrace);
      }
      return 0;
    }
  }

  /// Plays one B 站 search result as a queue containing all of that video's
  /// valid pages. Search results themselves are separate videos and must not
  /// be mixed into the same queue when the user taps one result.
  Future<void> playBilibiliResource(SongSearchResult result) async {
    if (_disposed || result.platform != MusicPlatform.bilibili) return;
    final requestId = ++_bilibiliPlayRequestId;
    try {
      final expanded = await _expandBilibiliResource(result);
      if (_disposed ||
          requestId != _bilibiliPlayRequestId ||
          expanded.isEmpty) {
        return;
      }
      late final List<PlayQueueItem> nextQueue;
      try {
        nextQueue = expanded
            .map(PlayQueueItem.fromSearchResult)
            .toList(growable: true);
      } catch (error, stackTrace) {
        _handleQueueAllocationFailure(error, stackTrace);
        return;
      }
      _cancelPendingPlaybackRestore();
      _recordCurrentHistory(immediate: true);
      _queueSessionId++;
      _queue = nextQueue;
      _currentIndex = 0;
      _persistPlaybackStateNow();
      notifyListeners();
      await _playCurrent();
    } catch (error, stackTrace) {
      if (!_disposed && requestId == _bilibiliPlayRequestId) {
        _handleBilibiliQueueError(error, stackTrace);
      }
    }
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
    _cancelPendingPlaybackRestore();
    try {
      _queue.addAll(
        tracks.map(PlayQueueItem.fromSearchResult).toList(growable: false),
      );
    } catch (error, stackTrace) {
      _handleQueueAllocationFailure(error, stackTrace);
      return false;
    }
    _schedulePlaybackStatePersist();
    notifyListeners();
    return true;
  }

  /// Loads the authoritative B 站 video metadata and turns every valid page
  /// into an independent queue item. The source result is never mutated.
  Future<List<SongSearchResult>> _expandBilibiliResource(
    SongSearchResult result,
  ) async {
    if (result.platform != MusicPlatform.bilibili) return [result];
    final info = result.bilibiliPages.isNotEmpty
        ? BilibiliVideoInfo(
            bvid: result.id,
            title: result.bilibiliVideoTitle ?? result.album,
            description: result.bilibiliDescription ?? '',
            ownerName: result.artist,
            coverUrl: result.coverUrl,
            duration: result.duration,
            pages: result.bilibiliPages,
          )
        : await _api.bilibili.videoInfo(result.id);
    final pages = info.pages
        .where((page) => page.cid > 0)
        .toList(growable: false);
    if (pages.isEmpty) {
      throw const BilibiliApiException('VIDEO_NO_PAGE', '视频没有可播放的分P');
    }
    if (pages.length > _maxBilibiliPagesPerResource) {
      throw const BilibiliApiException(
        'VIDEO_TOO_MANY_PAGES',
        '视频分P数量异常，已拒绝加入播放队列',
      );
    }
    final videoTitle = info.title.trim().isEmpty
        ? (result.bilibiliVideoTitle ?? result.album).trim()
        : info.title.trim();
    final artist = info.ownerName.trim().isEmpty
        ? result.artist
        : info.ownerName.trim();
    final cover = _preferExisting(result.coverUrl, info.coverUrl);
    final description = info.description.trim().isEmpty
        ? result.bilibiliDescription
        : info.description.trim();
    return pages
        .map(
          (page) => SongSearchResult(
            platform: MusicPlatform.bilibili,
            id: info.bvid.trim().isEmpty ? result.id : info.bvid,
            name: page.title.trim().isEmpty ? 'P${page.page}' : page.title,
            artist: artist,
            album: videoTitle.isEmpty ? result.album : videoTitle,
            coverUrl: cover,
            duration: page.duration,
            bilibiliVideoTitle: videoTitle.isEmpty
                ? result.bilibiliVideoTitle
                : videoTitle,
            bilibiliDescription: description,
            bilibiliCid: page.cid,
            bilibiliPage: page.page,
            bilibiliPages: pages,
          ),
        )
        .toList(growable: false);
  }

  void _handleBilibiliQueueError(Object error, StackTrace stackTrace) {
    debugPrint('展开 B 站视频分P失败: $error');
    debugPrintStack(stackTrace: stackTrace);
    if (_disposed) return;
    _errorMessage = error.toString();
    _lastError = error is BilibiliApiException
        ? error.message
        : 'B站视频分P加载失败，请重试';
    notifyListeners();
  }

  /// 从歌单播放
  Future<void> playFromPlaylist(
    List<SongSearchResult> tracks,
    int index,
  ) async {
    if (index < 0 || index >= tracks.length) return;
    final selected = tracks[index];
    if (selected.platform == MusicPlatform.bilibili) {
      await playBilibiliResource(selected);
      return;
    }
    _cancelPendingBilibiliPlay();
    _cancelPendingPlaybackRestore();
    late final List<PlayQueueItem> nextQueue;
    try {
      nextQueue = tracks
          .map((track) => PlayQueueItem.fromSearchResult(track))
          .toList(growable: true);
    } catch (error, stackTrace) {
      _handleQueueAllocationFailure(error, stackTrace);
      return;
    }
    _recordCurrentHistory(immediate: true);
    _queueSessionId++;
    _queue = nextQueue;
    _currentIndex = index;
    _persistPlaybackStateNow();
    notifyListeners();
    await _playCurrent();
  }

  void _handleQueueAllocationFailure(Object error, StackTrace stackTrace) {
    debugPrint('创建播放队列失败: $error');
    debugPrintStack(stackTrace: stackTrace);
    if (_disposed) return;
    _errorMessage = '播放列表过大，无法继续加入队列';
    _lastError = _errorMessage;
    notifyListeners();
  }

  /// 从历史记录重新播放，并在音源准备完成后跳回上次断点。
  Future<void> playFromHistory(PlaybackHistoryEntry entry) async {
    _cancelPendingBilibiliPlay();
    _cancelPendingPlaybackRestore();
    _recordCurrentHistory(immediate: true);
    _queueSessionId++;
    _queue = [PlayQueueItem.fromSearchResult(entry.song)];
    _currentIndex = 0;
    _persistPlaybackStateNow();
    notifyListeners();
    await _playCurrent(resumePosition: entry.position);
  }

  /// 从历史列表播放，保留列表中其他歌曲作为后续队列。
  ///
  /// 单条列表继续走旧入口，便于车机遥控和旧调用方保持相同的行为。
  Future<void> playFromHistoryEntries(
    List<PlaybackHistoryEntry> entries,
    int index,
  ) async {
    if (index < 0 || index >= entries.length) return;
    _cancelPendingBilibiliPlay();
    _cancelPendingPlaybackRestore();
    if (entries.length == 1) {
      await playFromHistory(entries.first);
      return;
    }
    _recordCurrentHistory(immediate: true);
    _queueSessionId++;
    _queue = entries
        .map((entry) => PlayQueueItem.fromSearchResult(entry.song))
        .toList();
    _currentIndex = index;
    _persistPlaybackStateNow();
    notifyListeners();
    await _playCurrent(resumePosition: entries[index].position);
  }

  Future<void> _playCurrent({Duration? resumePosition}) async {
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
      await historyReady;
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
        scope: dataScope,
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
          _rememberPlayUrl(itemKey);
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

      // 系统媒体会话由 PlayerMediaHandler 同步当前歌曲元数据。
      final audioUri = playPath.startsWith('/')
          ? Uri.file(playPath)
          : Uri.parse(playPath);
      await _audioPlayer.setAudioSource(
        AudioSource.uri(audioUri, headers: playbackHeaders),
        preload: true,
      );
      if (!_isCurrentRequest(requestId, item)) return;

      final startPosition = _normalizeResumePosition(resumePosition, item);
      if (startPosition > Duration.zero) {
        await _audioPlayer.seek(startPosition);
      }
      _position = startPosition;
      _recordCurrentHistory(position: startPosition, immediate: true);
      _schedulePlaybackStatePersist();

      // just_audio 的 play() Future 会在暂停、停止或播放结束时才完成。
      // 音源准备完成即结束“加载中”，播放过程放到后台等待。
      _isLoading = false;
      notifyListeners();
      unawaited(_startPlayback(requestId, item));

      // 歌词独立完成：网络慢或失败都不阻塞声音。酷狗歌词随解析详情返回；
      // 若本地音频秒开且没有歌词，只在后台补一次歌词。
      if (immediateLyrics == null) {
        if (item.platform == MusicPlatform.bilibili) {
          unawaited(_loadBilibiliLyricsInBackground(requestId, item));
        } else if (independentLyrics != null) {
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

  Duration _normalizeResumePosition(Duration? requested, PlayQueueItem item) {
    if (requested == null || requested <= Duration.zero) {
      return Duration.zero;
    }
    final loadedDuration = _audioPlayer.duration;
    final declaredDuration = item.duration == null
        ? Duration.zero
        : Duration(seconds: item.duration!);
    final total = loadedDuration != null && loadedDuration > Duration.zero
        ? loadedDuration
        : declaredDuration;
    if (total > Duration.zero) {
      if (requested >= total - const Duration(seconds: 3)) {
        return Duration.zero;
      }
      if (requested >= total) return Duration.zero;
    }
    return requested;
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
    if (pages.isEmpty) {
      throw const BilibiliApiException('VIDEO_NO_PAGE', '视频没有可播放的分P');
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
      if (playInfo.audioStreams.isEmpty) {
        throw const BilibiliApiException('PLAY_NO_AUDIO', '当前分P没有可播放的音频');
      }
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

  Future<void> _loadBilibiliLyricsInBackground(
    int requestId,
    PlayQueueItem item,
  ) async {
    if (!_rememberBilibiliLyricAttempt(_lyricKey(item))) return;
    try {
      final query = lyricSearchQueryFor(item);
      final candidates = await _searchBilibiliLyricCandidates(item, query);
      if (!_isCurrentRequest(requestId, item)) return;
      // B站分P标题常带编号、版本说明，跨平台歌词候选的时长也经常缺失。
      // 标题关键字是自动匹配的必要条件；歌手/UP主和时长只参与上面的排序。
      final matchedCandidates = candidates
          .where(
            (candidate) => bilibiliLyricTitleMatches(candidate.name, query),
          )
          .take(8);

      for (final candidate in matchedCandidates) {
        try {
          final data = await _api.getLyric(candidate.platform, candidate.id);
          if (!_isCurrentRequest(requestId, item)) return;
          final resolved = data == null ? null : _resolveLyricData(data);
          if (resolved != null && resolved.lines.isNotEmpty) {
            _applyLyrics(requestId, item, resolved);
            return;
          }
        } catch (_) {
          // 候选无歌词时继续尝试下一个高置信版本。
        }
      }
    } catch (_) {
      // 自动匹配失败时保留 B 站分P与视频信息，不影响音频播放。
    }
  }

  String _lyricKey(PlayQueueItem item) {
    if (item.platform == MusicPlatform.bilibili) {
      return '${item.platform.code}:${item.id}:${item.bilibiliCid ?? 0}';
    }
    return _itemKey(item);
  }

  _ResolvedLyrics? _cachedLyrics(PlayQueueItem item) {
    final cached = _lyricCache[_lyricKey(item)];
    if (cached != null) return cached;
    final raw = item.lyric;
    if (raw == null || raw.trim().isEmpty) return null;
    final resolved = _ResolvedLyrics.fromPlainText(raw);
    if (resolved != null) _rememberLyric(_lyricKey(item), resolved);
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
    final wordSynced = _boundLyricText(data.wordSynced);
    final originalText = _boundLyricText(data.original);
    final translatedText = _boundLyricText(data.translated);
    final enhanced = LyricParser.parseEnhanced(wordSynced);
    final hasWordTiming = enhanced.any((line) => line.words.isNotEmpty);
    final original = hasWordTiming
        ? enhanced
        : LyricParser.parseBestEffort(originalText);
    if (original.isEmpty) return null;
    final translated = LyricParser.parse(translatedText);
    return _ResolvedLyrics(
      rawText: hasWordTiming ? wordSynced : originalText,
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
    _currentLyricIndex = LyricParser.findCurrentIndex(_lyrics, lyricPosition);
    _lyricsLoading = false;
    if (resolved != null) {
      _rememberLyric(_lyricKey(item), resolved);
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
        _rememberPlayUrl(_itemKey(item));
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
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!_isCurrentRequest(requestId, item)) return;
      final localPath = await AudioCacheService.cacheAudio(
        platformCode: item.platform.code,
        songId: _audioCacheSongId(item),
        url: url,
        name: item.name,
        artist: item.artist,
        headers: headers,
        scope: dataScope,
      );
      if (localPath != null) debugPrint('后台缓存完成: $localPath');
    } catch (error, stackTrace) {
      // Caching is optional and must not surface as an unhandled background
      // Future error after playback has already started.
      debugPrint('后台缓存失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
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
        _runAudioCommandInBackground('自动播放下一首', playNext);
        break;
      case PlayMode.repeat:
        _runAudioCommandInBackground('单曲循环', () async {
          await _audioPlayer.seek(Duration.zero);
          await _audioPlayer.play();
        });
        break;
      case PlayMode.shuffle:
        if (_queue.length > 1) {
          final random = DateTime.now().millisecondsSinceEpoch % _queue.length;
          _currentIndex = random;
          _runAudioCommandInBackground('随机播放下一首', _playCurrent);
        }
        break;
    }
  }

  Future<bool> _tryAudioCommand(
    String label,
    Future<void> Function() command,
  ) async {
    try {
      await command();
      return true;
    } catch (error, stack) {
      debugPrint('$label失败: $error');
      debugPrintStack(stackTrace: stack);
      if (!_disposed) {
        _errorMessage = '$label失败: $error';
        _lastError = '$label失败，请重试';
        notifyListeners();
      }
      return false;
    }
  }

  void _runAudioCommandInBackground(
    String label,
    Future<void> Function() command,
  ) {
    unawaited(_tryAudioCommand(label, command));
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
    _cancelPendingPlaybackRestore();
    _recordCurrentHistory(immediate: true);
    _queue[_currentIndex] = song.copyWith(
      name: page.title,
      duration: page.duration,
      bilibiliCid: page.cid,
      bilibiliPage: page.page,
      clearPlayUrl: true,
      clearPlaybackHeaders: true,
      clearLyric: true,
    );
    _persistPlaybackStateNow();
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
    final source = await _api.bilibili.videoSource(
      song.id,
      cid,
      _bilibiliVideoQuality,
      audioQuality: _bilibiliAudioQuality,
    );
    if (source.urls.isEmpty) {
      throw const BilibiliApiException('PLAY_NO_VIDEO', 'B站未返回视频地址');
    }
    return source;
  }

  Future<String> currentBilibiliVideoUrl() async {
    return (await currentBilibiliVideoSource()).url;
  }

  Future<void> playPause() async {
    if (currentSong == null || _isLoading) return;
    _cancelPendingBilibiliPlay();
    _cancelPendingPlaybackRestore();
    if (_isPlaying) {
      final paused = await _tryAudioCommand('暂停播放', _audioPlayer.pause);
      if (paused) {
        _recordCurrentHistory(immediate: true);
        _persistPlaybackStateNow();
      }
    } else {
      if (_audioPlayer.processingState == ProcessingState.idle) {
        await _playCurrent(resumePosition: _position);
      } else {
        await _tryAudioCommand('继续播放', _audioPlayer.play);
      }
    }
  }

  Future<void> pause() async {
    _cancelPendingBilibiliPlay();
    _cancelPendingPlaybackRestore();
    final paused = await _tryAudioCommand('暂停播放', _audioPlayer.pause);
    if (paused) {
      _recordCurrentHistory(immediate: true);
      _persistPlaybackStateNow();
    }
  }

  Future<bool> beginAssistantDucking(int reductionPercent) async {
    if (_disposed) return false;
    if (_volumeBeforeAssistantDucking != null) return true;
    final before = _audioPlayer.volume.clamp(0.0, 1.0).toDouble();
    final reduction = reductionPercent.clamp(0, 100) / 100;
    final target = (before * (1 - reduction)).clamp(0.0, 1.0).toDouble();
    final applied = await _tryAudioCommand(
      '降低助手会话背景音量',
      () => _audioPlayer.setVolume(target),
    );
    if (!applied || _disposed) return false;
    _volumeBeforeAssistantDucking = before;
    return true;
  }

  Future<bool> endAssistantDucking() async {
    final before = _volumeBeforeAssistantDucking;
    if (before == null) return true;
    if (_disposed) {
      _volumeBeforeAssistantDucking = null;
      return false;
    }
    final restored = await _tryAudioCommand(
      '恢复助手会话前音量',
      () => _audioPlayer.setVolume(before),
    );
    if (restored) _volumeBeforeAssistantDucking = null;
    return restored;
  }

  Future<void> stop() async {
    _cancelPendingBilibiliPlay();
    _cancelPendingPlaybackRestore();
    _recordCurrentHistory(immediate: true);
    await _tryAudioCommand('停止播放', _audioPlayer.stop);
    _persistPlaybackStateNow();
  }

  /// Saves the last playable session and releases active playback before the
  /// Android task is terminated. Repeated exit requests share one operation.
  Future<void> prepareForAppExit() {
    return _exitPreparationFuture ??= _prepareForSessionEnd(
      waitForWrites: true,
    );
  }

  Future<void> prepareForUserSwitch() =>
      _prepareForSessionEnd(waitForWrites: false);

  Future<void> cancelPreparedUserSwitch() async {
    if (_disposed || _exitPreparationFuture != null) return;
    final shouldResume = _resumeAfterCancelledUserSwitch;
    _resumeAfterCancelledUserSwitch = false;
    _preparingForExit = false;
    if (!shouldResume || currentSong == null) return;
    if (_audioPlayer.processingState == ProcessingState.idle) {
      await _tryAudioCommand(
        '恢复用户切换前的播放',
        () => _playCurrent(resumePosition: _position),
      );
    } else {
      await _tryAudioCommand('恢复用户切换前的播放', _audioPlayer.play);
    }
  }

  Future<void> _prepareForSessionEnd({required bool waitForWrites}) async {
    // Mark shutdown before restoration completes so an auto-resume cannot
    // start while the final snapshot is being prepared. The queue itself is
    // still restored and preserved below.
    _preparingForExit = true;
    if (waitForWrites) {
      try {
        await playbackStateReady;
        await historyReady;
      } catch (error, stackTrace) {
        debugPrint('退出前等待播放器数据失败: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
    _resumeAfterCancelledUserSwitch = _isPlaying || _restoredPlaybackPending;
    _cancelPendingPlaybackRestore();
    if (_disposed) return;

    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    _historyPersistAgain = false;
    _playbackStatePersistTimer?.cancel();
    _playbackStatePersistTimer = null;
    _playbackStatePersistAgain = false;

    _recordCurrentHistory(position: _position);
    final historySnapshot = _historyLoaded
        ? List<PlaybackHistoryEntry>.of(_playbackHistory)
        : null;
    final playbackSnapshot = _playbackStateLoaded
        ? _playbackStateSnapshot()
        : null;

    if (_queue.isNotEmpty ||
        _audioPlayer.processingState != ProcessingState.idle) {
      if (!waitForWrites) {
        unawaited(
          _audioPlayer.stop().catchError((error) {
            debugPrint('切换用户时停止播放器失败: $error');
          }),
        );
      } else {
        try {
          await _audioPlayer.stop().timeout(const Duration(seconds: 2));
        } catch (error, stackTrace) {
          debugPrint('退出前停止播放器失败: $error');
          debugPrintStack(stackTrace: stackTrace);
        }
      }
    }

    final pendingWrites = <Future<void>>[
      if (_historyPersistCompletion case final completion?) completion.future,
      if (_playbackStatePersistCompletion case final completion?)
        completion.future,
    ];
    if (waitForWrites && pendingWrites.isNotEmpty) {
      try {
        await Future.wait(pendingWrites).timeout(const Duration(seconds: 2));
      } catch (error, stackTrace) {
        debugPrint('退出前等待已有数据写入失败: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
    final writes = <Future<void>>[
      if (historySnapshot != null) _saveExitHistory(historySnapshot),
      if (playbackSnapshot != null) _saveExitPlaybackState(playbackSnapshot),
    ];
    if (waitForWrites) {
      await Future.wait(writes);
    } else {
      unawaited(Future.wait(writes));
    }
  }

  Future<void> _saveExitHistory(List<PlaybackHistoryEntry> snapshot) async {
    try {
      await PlaybackHistoryService.save(snapshot, scope: dataScope);
    } catch (error, stackTrace) {
      debugPrint('退出前保存播放历史失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _saveExitPlaybackState(PlaybackSessionSnapshot snapshot) async {
    try {
      await PlaybackStateService.save(snapshot, scope: dataScope);
    } catch (error, stackTrace) {
      debugPrint('退出前保存播放会话失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> playNext() async {
    if (_queue.isEmpty) return;
    _cancelPendingBilibiliPlay();
    _cancelPendingPlaybackRestore();
    _recordCurrentHistory(immediate: true);
    if (_playMode == PlayMode.shuffle) {
      _currentIndex = DateTime.now().millisecondsSinceEpoch % _queue.length;
    } else {
      _currentIndex = (_currentIndex + 1) % _queue.length;
    }
    _persistPlaybackStateNow();
    notifyListeners();
    await _playCurrent();
  }

  Future<void> playPrevious() async {
    if (_queue.isEmpty) return;
    _cancelPendingBilibiliPlay();
    _cancelPendingPlaybackRestore();
    _recordCurrentHistory(immediate: true);
    _currentIndex = (_currentIndex - 1 + _queue.length) % _queue.length;
    _persistPlaybackStateNow();
    notifyListeners();
    await _playCurrent();
  }

  Future<void> seekTo(Duration position) async {
    _cancelPendingPlaybackRestore();
    final succeeded = await _tryAudioCommand(
      '调整播放进度',
      () => _audioPlayer.seek(position),
    );
    if (!succeeded) return;
    _position = position;
    _persistPlaybackStateNow();
    _updateLyricIndex();
    notifyListeners();
  }

  void adjustLyricOffset(Duration delta) {
    setLyricOffset(lyricOffset + delta);
  }

  void resetLyricOffset() {
    setLyricOffset(Duration.zero);
  }

  void setLyricOffset(Duration offset) {
    final song = currentSong;
    if (song == null) return;
    final limit = lyricOffsetLimit.inMilliseconds;
    final milliseconds = offset.inMilliseconds.clamp(-limit, limit).toInt();
    final next = Duration(milliseconds: milliseconds);
    if (next == lyricOffset) return;
    final key = _lyricKey(song);
    if (next == Duration.zero) {
      _lyricOffsets.remove(key);
    } else {
      _lyricOffsets.remove(key);
      _lyricOffsets[key] = next;
      while (_lyricOffsets.length > _maxCachedLyricOffsets) {
        _lyricOffsets.remove(_lyricOffsets.keys.first);
      }
    }
    _updateLyricIndex();
    notifyListeners();
  }

  void togglePlayMode() {
    _cancelPendingPlaybackRestore();
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
    _persistPlaybackStateNow();
    notifyListeners();
  }

  void toggleShowLyric() {
    _showLyric = !_showLyric;
    notifyListeners();
  }

  Future<void> playQueueItem(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _cancelPendingBilibiliPlay();
    _cancelPendingPlaybackRestore();
    _recordCurrentHistory(immediate: true);
    _currentIndex = index;
    _persistPlaybackStateNow();
    notifyListeners();
    await _playCurrent();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    _cancelPendingBilibiliPlay();
    _cancelPendingPlaybackRestore();
    if (index == _currentIndex) _recordCurrentHistory(immediate: true);
    _queue.removeAt(index);
    if (index < _currentIndex) {
      _currentIndex--;
    } else if (index == _currentIndex) {
      if (_currentIndex >= _queue.length) _currentIndex = _queue.length - 1;
      if (_currentIndex >= 0) {
        unawaited(_playCurrent());
      } else {
        _playRequestId++;
        _runAudioCommandInBackground('停止播放', _audioPlayer.stop);
      }
    }
    _persistPlaybackStateNow();
    notifyListeners();
  }

  void clearQueue() {
    _cancelPendingBilibiliPlay();
    _bilibiliAddRequestId++;
    _cancelPendingPlaybackRestore();
    _recordCurrentHistory(immediate: true);
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
    _runAudioCommandInBackground('停止播放', _audioPlayer.stop);
    unawaited(FloatingCapsuleService.hide());
    _persistPlaybackStateNow();
    notifyListeners();
  }

  // ==================== 歌词同步 ====================

  void _updateLyricIndex() {
    if (_lyrics.isEmpty) return;
    final newIndex = LyricParser.findCurrentIndex(_lyrics, lyricPosition);
    if (newIndex != _currentLyricIndex) {
      _currentLyricIndex = newIndex;
    }
  }

  // ==================== 清理 ====================

  @override
  void dispose() {
    if (_resourceDisposeFuture != null) return;
    // Mark the provider first so a final audio position event cannot schedule
    // another history persistence timer while the subscriptions are stopping.
    _disposed = true;
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    _historyPersistAgain = false;
    _playbackStatePersistTimer?.cancel();
    _playbackStatePersistTimer = null;
    _playbackStatePersistAgain = false;
    if (!_preparingForExit) {
      unawaited(_persistPlaybackHistory());
      unawaited(_persistPlaybackState());
    }
    _playRequestId++;
    _queueSessionId++;
    _bilibiliPlayRequestId++;
    _bilibiliAddRequestId++;
    _volumeBeforeAssistantDucking = null;
    final subscriptions = <StreamSubscription?>[
      _playerSub,
      _durationSub,
      _positionSub,
      _bufferSub,
      _errorSub,
    ];
    _api.bilibili.removeListener(_handleBilibiliChanged);
    _api.close();
    // Release ChangeNotifier listeners immediately; native audio teardown can
    // continue asynchronously without retaining the old widget tree.
    super.dispose();
    _resourceDisposeFuture = _disposeAudioResources(subscriptions);
  }

  /// Releases the native audio player and waits for every stream subscription
  /// to finish cancelling. This is awaited during profile switches so two
  /// players do not retain decoders and buffers at the same time.
  Future<void> disposeResources() {
    final existing = _resourceDisposeFuture;
    if (existing != null) return existing;
    dispose();
    return _resourceDisposeFuture!;
  }

  Future<void> _disposeAudioResources(
    List<StreamSubscription?> subscriptions,
  ) async {
    for (final subscription in subscriptions) {
      try {
        await subscription?.cancel();
      } catch (error) {
        debugPrint('取消播放器订阅失败: $error');
      }
    }
    final playerDispose = _audioPlayer.dispose();
    // An untouched AudioPlayer has no decoder or platform stream to wait for.
    // Do not block a profile switch on a platform channel teardown in that
    // case; active players still await the native release below.
    if (_queue.isEmpty &&
        _audioPlayer.processingState == ProcessingState.idle) {
      unawaited(
        playerDispose.catchError((error) {
          debugPrint('释放播放器失败: $error');
        }),
      );
    } else {
      try {
        await playerDispose;
      } catch (error) {
        debugPrint('释放播放器失败: $error');
      }
    }
    _queue.clear();
    _lyrics.clear();
    _lyricCache.clear();
    _lyricOffsets.clear();
    _bilibiliLyricAutoAttempted.clear();
    _playUrlResolvedAt.clear();
    _playbackHistory.clear();
  }
}

class _ResolvedLyrics {
  final String? rawText;
  final List<LyricLine> lines;

  const _ResolvedLyrics({required this.rawText, required this.lines});

  static _ResolvedLyrics? fromPlainText(String? rawText) {
    final boundedText = _boundLyricText(rawText);
    if (boundedText == null || boundedText.trim().isEmpty) return null;
    return _ResolvedLyrics(
      rawText: boundedText,
      lines: LyricParser.parseBestEffort(boundedText),
    );
  }
}
