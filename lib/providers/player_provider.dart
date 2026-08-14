import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/floating_capsule_service.dart';
import '../utils/lyric_parser.dart';

/// 播放模式
enum PlayMode { sequence, repeat, shuffle }

/// 全局播放器状态管理
class PlayerProvider extends ChangeNotifier {
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

  // 歌词
  List<LyricLine> _lyrics = [];
  int _currentLyricIndex = 0;
  bool _showLyric = false;

  // 音质
  NeteaseLevel _neteaseLevel = NeteaseLevel.jymaster;
  CommonLevel _commonLevel = CommonLevel.flac;

  // API Key
  String _apiKey = '';

  // 流订阅
  StreamSubscription? _playerSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _bufferSub;
  StreamSubscription? _errorSub;
  int _playRequestId = 0;
  bool _disposed = false;

  PlayerProvider() {
    _api = ApiService(apiKey: '');
    _initAudioPlayer();
    settingsReady = _loadSettings();
  }

  // ==================== Getters ====================

  List<PlayQueueItem> get queue => _queue;
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
  List<LyricLine> get lyrics => _lyrics;
  int get currentLyricIndex => _currentLyricIndex;
  bool get showLyric => _showLyric;
  NeteaseLevel get neteaseLevel => _neteaseLevel;
  CommonLevel get commonLevel => _commonLevel;
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
        _errorMessage = '播放错误: $e';
        notifyListeners();
      },
    );
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('netease_level', level.value);
    notifyListeners();
  }

  Future<void> setCommonLevel(CommonLevel level) async {
    await settingsReady;
    if (_disposed) return;
    _commonLevel = level;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('common_level', level.value);
    notifyListeners();
  }

  // ==================== 播放控制 ====================

  /// 从搜索结果播放（替换整个队列）
  Future<void> playFromSearchResults(
    List<SongSearchResult> results,
    int index,
  ) async {
    if (index < 0 || index >= results.length) return;
    _queue = results.map((e) => PlayQueueItem.fromSearchResult(e)).toList();
    _currentIndex = index;
    notifyListeners();
    await _playCurrent();
  }

  /// 添加到队列并播放
  Future<void> playSingle(SongSearchResult result) async {
    _queue = [PlayQueueItem.fromSearchResult(result)];
    _currentIndex = 0;
    notifyListeners();
    await _playCurrent();
  }

  /// 添加到队列末尾（不立即播放）
  void addToQueue(SongSearchResult result) {
    _queue.add(PlayQueueItem.fromSearchResult(result));
    notifyListeners();
  }

  /// 从歌单播放
  Future<void> playFromPlaylist(
    List<SongSearchResult> tracks,
    int index,
  ) async {
    if (index < 0 || index >= tracks.length) return;
    _queue = tracks.map((e) => PlayQueueItem.fromSearchResult(e)).toList();
    _currentIndex = index;
    notifyListeners();
    await _playCurrent();
  }

  Future<void> _playCurrent() async {
    if (_currentIndex < 0 || _currentIndex >= _queue.length) return;
    final item = _queue[_currentIndex];
    final requestId = ++_playRequestId;

    _isLoading = true;
    _errorMessage = null;
    _lyrics = [];
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

      // 选中一首新歌后先停止旧音源，避免 UI 与实际播放内容不一致。
      await _audioPlayer.stop();
      if (!_isCurrentRequest(requestId, item)) return;

      // 网易云直连不需要 API Key；酷狗/QQ 解析播放地址需要。
      if (item.platform != MusicPlatform.netease && _apiKey.isEmpty) {
        throw ApiException('API_KEY_REQUIRED', '酷狗/QQ音乐播放需要配置 API Key');
      }

      // 解析播放地址
      SongDetail detail;
      if (item.platform == MusicPlatform.netease) {
        detail = await _api.neteaseMusic(item.id, level: _neteaseLevel.value);
      } else if (item.platform == MusicPlatform.qq) {
        detail = await _api.qqMusic(item.id, size: _commonLevel.value);
      } else {
        detail = await _api.kugouMusic(item.id, size: _commonLevel.value);
      }
      if (!_isCurrentRequest(requestId, item)) return;

      if (detail.url.isEmpty) {
        throw ApiException('404', '无法获取播放地址，可能是版权限制');
      }

      // 获取歌词
      String? lyricText;
      late final List<LyricLine> resolvedLyrics;
      if (item.platform == MusicPlatform.netease) {
        final lyricData = await _api.neteaseLyric(item.id);
        lyricText = lyricData.original;
        final transLyric = LyricParser.parse(lyricData.translated);
        resolvedLyrics = LyricParser.mergeTranslation(
          LyricParser.parse(lyricText),
          transLyric,
        );
      } else if (item.platform == MusicPlatform.qq) {
        // QQ音乐: 优先直连歌词 API，失败则用解析返回的歌词
        try {
          final lyricData = await _api.qqLyric(item.id);
          lyricText = lyricData.original;
          resolvedLyrics = LyricParser.parse(lyricText);
        } catch (_) {
          lyricText = detail.lyric;
          resolvedLyrics = LyricParser.parse(lyricText);
        }
      } else {
        lyricText = detail.lyric;
        resolvedLyrics = LyricParser.parse(lyricText);
      }
      if (!_isCurrentRequest(requestId, item)) return;
      _lyrics = resolvedLyrics;

      // 更新队列项
      _queue[_currentIndex] = _queue[_currentIndex].copyWith(
        playUrl: detail.url,
        lyric: lyricText,
        duration: detail.duration,
        coverUrl: detail.coverUrl ?? item.coverUrl,
        loading: false,
        clearError: true,
      );

      // 设置音频源并播放（tag: MediaItem 用于系统媒体通知显示歌曲信息）
      await _audioPlayer.setAudioSource(
        AudioSource.uri(
          Uri.parse(detail.url),
          tag: MediaItem(
            id: '${item.platform.code}_${item.id}',
            title: item.name,
            artist: item.artist,
            album: item.album,
            artUri:
                (detail.coverUrl ?? item.coverUrl) != null &&
                    (detail.coverUrl ?? item.coverUrl)!.isNotEmpty
                ? Uri.parse((detail.coverUrl ?? item.coverUrl)!)
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

      // 系统悬浮胶囊：显示/更新当前歌曲
      if (FloatingCapsuleService.enabled) {
        FloatingCapsuleService.show(
          title: item.name,
          artist: item.artist,
          coverUrl: detail.coverUrl ?? item.coverUrl,
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
      _isLoading = false;
      notifyListeners();
    } finally {
      if (_isCurrentRequest(requestId, item) && _isLoading) {
        _isLoading = false;
        notifyListeners();
      }
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

  Future<void> playPause() async {
    if (currentSong == null || _isLoading) return;
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
  }

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
    _queue.clear();
    _currentIndex = -1;
    _lyrics.clear();
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
      notifyListeners();
    }
  }

  // ==================== 清理 ====================

  @override
  void dispose() {
    _disposed = true;
    _playRequestId++;
    _playerSub?.cancel();
    _durationSub?.cancel();
    _positionSub?.cancel();
    _bufferSub?.cancel();
    _errorSub?.cancel();
    _api.close();
    _audioPlayer.dispose();
    super.dispose();
  }
}
