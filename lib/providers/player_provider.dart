import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../models/sound_effect.dart';
import '../services/api_service.dart';
import '../services/audio_cache_service.dart';
import '../services/bilibili_service.dart';
import '../services/floating_capsule_service.dart';
import '../services/playback_history_service.dart';
import '../services/sound_effect_service.dart';
import '../utils/lyric_parser.dart';

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
  static const _bilibiliLyricPlatformOrderKey = 'bilibili_lyric_platform_order';
  static const _soundEffectEnabledKey = 'sound_effect_enabled';
  static const _soundEffectIdKey = 'sound_effect_id';
  static const _soundEffectTypeKey = 'sound_effect_type';
  static const _soundEffectNameKey = 'sound_effect_name';
  static const _defaultBilibiliLyricPlatformOrder = <MusicPlatform>[
    MusicPlatform.qq,
    MusicPlatform.kugou,
    MusicPlatform.netease,
  ];

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
  bool _historyLoaded = false;

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
  bool _soundEffectAvailable = false;
  bool _soundEffectEnabled = false;
  String _soundEffectStatusMessage = 'DSP 正在初始化';
  List<SoundEffectPreset> _soundEffectPresets = const [];
  SoundEffectPreset? _soundEffectPreset;
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
    historyReady = _loadPlaybackHistory();
    settingsReady = _loadSettings();
  }

  late final Future<void> historyReady;

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
  bool get soundEffectAvailable => _soundEffectAvailable;
  bool get soundEffectEnabled => _soundEffectEnabled;
  String get soundEffectStatusMessage => _soundEffectStatusMessage;
  List<SoundEffectPreset> get soundEffectPresets =>
      List.unmodifiable(_soundEffectPresets);
  SoundEffectPreset? get soundEffectPreset => _soundEffectPreset;

  List<PlaybackHistoryEntry> get playbackHistory =>
      List.unmodifiable(_playbackHistory);
  int get playbackHistoryRevision => _playbackHistoryRevision;

  String get apiKey => _apiKey;
  AudioPlayer get audioPlayer => _audioPlayer;
  ApiService get api => _api;

  // ==================== 初始化 ====================

  Future<void> _loadPlaybackHistory() async {
    _playbackHistory = await PlaybackHistoryService.load();
    _playbackHistoryRevision++;
    _historyLoaded = true;
    if (!_disposed) notifyListeners();
  }

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
        _recordCurrentHistory(position: Duration.zero, immediate: true);
        _onSongComplete();
      } else if (!state.playing &&
          state.processingState != ProcessingState.idle) {
        // A pause is an explicit persistence boundary, so a resumed session
        // does not lose the latest position while waiting for the debounce.
        _recordCurrentHistory(immediate: true);
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
      if (_isPlaying) _recordCurrentHistory(position: p);
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
        unawaited(_stopAfterPlaybackError());
        notifyListeners();
      },
    );
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
    if (_disposed) return;
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
    final snapshot = List<PlaybackHistoryEntry>.of(_playbackHistory);
    try {
      await PlaybackHistoryService.save(snapshot);
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
    }
  }

  Future<void> clearPlaybackHistory() async {
    if (_playbackHistory.isEmpty) return;
    _playbackHistory = [];
    _playbackHistoryRevision++;
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    notifyListeners();
    await _persistPlaybackHistory();
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
      final soundEffectAvailability = await SoundEffectService.initialize();
      _soundEffectAvailable = soundEffectAvailability.available;
      _soundEffectStatusMessage = soundEffectAvailability.message;
      _soundEffectPresets = soundEffectAvailability.presets;
      final savedSoundEffectId = prefs.getInt(_soundEffectIdKey) ?? 0;
      final savedSoundEffectType = prefs.getInt(_soundEffectTypeKey) ?? 1;
      final savedSoundEffectName = prefs.getString(_soundEffectNameKey) ?? '';
      for (final preset in _soundEffectPresets) {
        if (preset.id == savedSoundEffectId &&
            preset.type == savedSoundEffectType) {
          _soundEffectPreset = preset;
          break;
        }
      }
      if (_soundEffectPreset == null && savedSoundEffectId > 0) {
        _soundEffectPreset = SoundEffectPreset(
          id: savedSoundEffectId,
          type: savedSoundEffectType,
          name: savedSoundEffectName.isEmpty ? '已选音效' : savedSoundEffectName,
          description: '',
        );
      }
      _soundEffectEnabled =
          _soundEffectAvailable &&
          _soundEffectPreset != null &&
          (prefs.getBool(_soundEffectEnabledKey) ?? false);
      await SoundEffectService.setEffect(
        type: _soundEffectPreset?.type ?? 1,
        id: _soundEffectEnabled ? _soundEffectPreset!.id : 0,
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
    try {
      final prefs = await SharedPreferences.getInstance();
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

  Future<bool> setSoundEffectEnabled(bool enabled) async {
    await settingsReady;
    if (_disposed || !_soundEffectAvailable) return false;
    var selected = _soundEffectPreset;
    if (enabled && selected == null && _soundEffectPresets.isNotEmpty) {
      selected = _soundEffectPresets.first;
    }
    if (enabled && selected == null) return false;
    final applied = await SoundEffectService.setEffect(
      type: selected?.type ?? 1,
      id: enabled ? selected!.id : 0,
    );
    if (!applied || _disposed) return false;
    _soundEffectPreset = selected;
    _soundEffectEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await _persistSoundEffect(prefs);
    return true;
  }

  Future<bool> selectSoundEffect(SoundEffectPreset preset) async {
    await settingsReady;
    if (_disposed || !_soundEffectAvailable) return false;
    final applied = await SoundEffectService.setEffect(
      type: preset.type,
      id: preset.id,
    );
    if (!applied || _disposed) return false;
    _soundEffectPreset = preset;
    _soundEffectEnabled = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await _persistSoundEffect(prefs);
    return true;
  }

  Future<void> _persistSoundEffect(SharedPreferences prefs) async {
    await prefs.setBool(_soundEffectEnabledKey, _soundEffectEnabled);
    final preset = _soundEffectPreset;
    if (preset == null) {
      await prefs.remove(_soundEffectIdKey);
      await prefs.remove(_soundEffectTypeKey);
      await prefs.remove(_soundEffectNameKey);
      return;
    }
    await prefs.setInt(_soundEffectIdKey, preset.id);
    await prefs.setInt(_soundEffectTypeKey, preset.type);
    await prefs.setString(_soundEffectNameKey, preset.name);
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
      _lyricCache[_lyricKey(activeSong)] = resolved;
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
    _recordCurrentHistory(immediate: true);
    _queueSessionId++;
    _queue = results.map((e) => PlayQueueItem.fromSearchResult(e)).toList();
    _currentIndex = index;
    notifyListeners();
    await _playCurrent();
  }

  /// 添加到队列并播放
  Future<void> playSingle(SongSearchResult result) async {
    _recordCurrentHistory(immediate: true);
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
    _recordCurrentHistory(immediate: true);
    _queueSessionId++;
    _queue = tracks.map((e) => PlayQueueItem.fromSearchResult(e)).toList();
    _currentIndex = index;
    notifyListeners();
    await _playCurrent();
  }

  /// 从历史记录重新播放，并在音源准备完成后跳回上次断点。
  Future<void> playFromHistory(PlaybackHistoryEntry entry) async {
    _recordCurrentHistory(immediate: true);
    _queueSessionId++;
    _queue = [PlayQueueItem.fromSearchResult(entry.song)];
    _currentIndex = 0;
    notifyListeners();
    await _playCurrent(resumePosition: entry.position);
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
    if (!_bilibiliLyricAutoAttempted.add(_lyricKey(item))) return;
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
    if (resolved != null) _lyricCache[_lyricKey(item)] = resolved;
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
    _currentLyricIndex = LyricParser.findCurrentIndex(_lyrics, lyricPosition);
    _lyricsLoading = false;
    if (resolved != null) {
      _lyricCache[_lyricKey(item)] = resolved;
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
    if (_isPlaying) {
      final paused = await _tryAudioCommand('暂停播放', _audioPlayer.pause);
      if (paused) _recordCurrentHistory(immediate: true);
    } else {
      await _tryAudioCommand('继续播放', _audioPlayer.play);
    }
  }

  Future<void> pause() async {
    final paused = await _tryAudioCommand('暂停播放', _audioPlayer.pause);
    if (paused) _recordCurrentHistory(immediate: true);
  }

  Future<void> stop() async {
    _recordCurrentHistory(immediate: true);
    await _tryAudioCommand('停止播放', _audioPlayer.stop);
  }

  Future<void> playNext() async {
    if (_queue.isEmpty) return;
    _recordCurrentHistory(immediate: true);
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
    _recordCurrentHistory(immediate: true);
    _currentIndex = (_currentIndex - 1 + _queue.length) % _queue.length;
    notifyListeners();
    await _playCurrent();
  }

  Future<void> seekTo(Duration position) async {
    final succeeded = await _tryAudioCommand(
      '调整播放进度',
      () => _audioPlayer.seek(position),
    );
    if (!succeeded) return;
    _position = position;
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
      _lyricOffsets[key] = next;
    }
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
    _recordCurrentHistory(immediate: true);
    _currentIndex = index;
    notifyListeners();
    await _playCurrent();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
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
    notifyListeners();
  }

  void clearQueue() {
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
    // Mark the provider first so a final audio position event cannot schedule
    // another history persistence timer while the subscriptions are stopping.
    _disposed = true;
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    _historyPersistAgain = false;
    unawaited(_persistPlaybackHistory());
    _playRequestId++;
    _queueSessionId++;
    final subscriptions = <StreamSubscription?>[
      _playerSub,
      _durationSub,
      _positionSub,
      _bufferSub,
      _errorSub,
    ];
    _api.bilibili.removeListener(_handleBilibiliChanged);
    _api.close();
    unawaited(_disposeAudioResources(subscriptions));
    super.dispose();
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
    try {
      await _audioPlayer.dispose();
    } catch (error) {
      debugPrint('释放播放器失败: $error');
    }
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
