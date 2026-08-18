import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as media_kit;
import 'package:media_kit_video/media_kit_video.dart' as media_kit_video;
import 'package:video_player/video_player.dart';

import '../models/song.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../utils/system_ui.dart';

enum _MvEngine { exo, mpv }

abstract class _MvPlaybackController extends ChangeNotifier {
  String get label;
  bool get isInitialized;
  bool get isPlaying;
  bool get isBuffering;
  Duration get position;
  Duration get duration;
  double get aspectRatio;
  String? get error;

  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  Widget buildSurface(Key key);
  Future<void> close();
}

class _ExoPlaybackController extends _MvPlaybackController {
  late final VideoPlayerController _controller;
  bool _closed = false;

  _ExoPlaybackController(String url, Map<String, String> headers) {
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    )..addListener(_handleChanged);
  }

  @override
  String get label => 'ExoPlayer';

  @override
  bool get isInitialized => _controller.value.isInitialized;

  @override
  bool get isPlaying => _controller.value.isPlaying;

  @override
  bool get isBuffering => _controller.value.isBuffering;

  @override
  Duration get position => _controller.value.position;

  @override
  Duration get duration => _controller.value.duration;

  @override
  double get aspectRatio => _controller.value.aspectRatio > 0
      ? _controller.value.aspectRatio
      : 16 / 9;

  @override
  String? get error => _controller.value.hasError
      ? (_controller.value.errorDescription ?? 'ExoPlayer 播放失败')
      : null;

  void _handleChanged() {
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> initialize() async {
    await _controller.initialize();
    await _controller.play();
  }

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> seekTo(Duration position) => _controller.seekTo(position);

  @override
  Widget buildSurface(Key key) => VideoPlayer(_controller, key: key);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _controller.removeListener(_handleChanged);
    await _controller.dispose();
    dispose();
  }
}

class _MpvPlaybackController extends _MvPlaybackController {
  late final media_kit.Player _player;
  late final media_kit_video.VideoController _controller;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final String url;
  final Map<String, String> headers;
  bool _initialized = false;
  bool _closed = false;
  String? _error;

  _MpvPlaybackController(this.url, this.headers) {
    _player = media_kit.Player(
      configuration: const media_kit.PlayerConfiguration(
        title: '库仔音乐 MV',
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    _controller = media_kit_video.VideoController(
      _player,
      configuration: const media_kit_video.VideoControllerConfiguration(
        hwdec: 'auto-safe',
        enableHardwareAcceleration: true,
      ),
    );
    _subscriptions.addAll([
      _player.stream.playing.listen((_) => _changed()),
      _player.stream.position.listen((_) => _changed()),
      _player.stream.duration.listen((_) => _changed()),
      _player.stream.buffering.listen((_) => _changed()),
      _player.stream.width.listen((_) => _changed()),
      _player.stream.height.listen((_) => _changed()),
      _player.stream.error.listen((message) {
        if (message.trim().isEmpty || _closed) return;
        _error = message;
        _changed();
      }),
    ]);
  }

  @override
  String get label => 'MPV';

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isPlaying => _player.state.playing;

  @override
  bool get isBuffering => _player.state.buffering;

  @override
  Duration get position => _player.state.position;

  @override
  Duration get duration => _player.state.duration;

  @override
  double get aspectRatio {
    final width = _player.state.width ?? 0;
    final height = _player.state.height ?? 0;
    return width > 0 && height > 0 ? width / height : 16 / 9;
  }

  @override
  String? get error => _error;

  void _changed() {
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> initialize() async {
    _error = null;
    await _player.open(media_kit.Media(url, httpHeaders: headers), play: true);
    _initialized = true;
    _changed();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seekTo(Duration position) => _player.seek(position);

  @override
  Widget buildSurface(Key key) => media_kit_video.Video(
    key: key,
    controller: _controller,
    controls: media_kit_video.NoVideoControls,
    fit: BoxFit.contain,
  );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    dispose();
  }
}

class VideoPlayerScreen extends StatefulWidget {
  final String url;
  final List<String> alternateUrls;
  final Map<String, String>? headers;
  final String title;
  final String artist;
  final MusicPlatform platform;
  final VideoPlayerMode mode;

  const VideoPlayerScreen({
    super.key,
    required this.url,
    this.alternateUrls = const [],
    this.headers,
    required this.title,
    required this.artist,
    required this.platform,
    this.mode = VideoPlayerMode.exo,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with WidgetsBindingObserver {
  late final List<String> _sourceUrls;
  int _sourceIndex = 0;
  late _MvEngine _activeEngine;
  late _MvPlaybackController _controller;
  Timer? _controlsTimer;
  bool _initializing = true;
  bool _controlsVisible = true;
  bool _switchingEngine = false;
  bool _automaticFallbackUsed = false;
  String? _initializationError;
  String? _engineNotice;
  Timer? _videoUiTimer;
  final Stopwatch _videoUiClock = Stopwatch()..start();
  int _lastVideoUiRefreshMs = -1000;
  ({
    bool initialized,
    bool playing,
    bool buffering,
    int durationMs,
    int aspectMilli,
    String? error,
  })?
  _lastVideoUiState;

  static const _videoPositionUiInterval = Duration(milliseconds: 180);

  @override
  void initState() {
    super.initState();
    _sourceUrls = <String>{
      widget.url,
      ...widget.alternateUrls,
    }.where((url) => url.isNotEmpty).toList(growable: false);
    WidgetsBinding.instance.addObserver(this);
    applySystemUi(dark: true);
    _activeEngine = widget.mode == VideoPlayerMode.mpv
        ? _MvEngine.mpv
        : _MvEngine.exo;
    _controller = _createController(_activeEngine)
      ..addListener(_handleVideoChanged);
    unawaited(_initialize());
  }

  static Map<String, String> _headersFor(
    MusicPlatform platform,
    Map<String, String>? customHeaders,
  ) {
    return {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36',
      'Referer': switch (platform) {
        MusicPlatform.qq => 'https://y.qq.com/',
        MusicPlatform.netease => 'https://music.163.com/',
        MusicPlatform.kugou => 'https://www.kugou.com/',
        MusicPlatform.bilibili => 'https://www.bilibili.com/',
      },
      if (platform == MusicPlatform.bilibili)
        'Origin': 'https://www.bilibili.com',
      ...?customHeaders,
    };
  }

  _MvPlaybackController _createController(_MvEngine engine) {
    final headers = _headersFor(widget.platform, widget.headers);
    final url = _sourceUrls[_sourceIndex];
    return switch (engine) {
      _MvEngine.exo => _ExoPlaybackController(url, headers),
      _MvEngine.mpv => _MpvPlaybackController(url, headers),
    };
  }

  Future<void> _initialize() async {
    _controlsTimer?.cancel();
    if (mounted) {
      setState(() {
        _initializing = true;
        _initializationError = null;
      });
    }
    final initializingController = _controller;
    try {
      await initializingController.initialize().timeout(
        const Duration(seconds: 18),
      );
      if (!mounted || initializingController != _controller) return;
      final controllerError = _controller.error;
      if (controllerError != null) throw StateError(controllerError);
      setState(() {
        _initializing = false;
        _engineNotice = null;
      });
      _lastVideoUiState = _readVideoUiState();
      _lastVideoUiRefreshMs = _videoUiClock.elapsedMilliseconds;
      _scheduleControlsHide();
    } catch (_) {
      if (!mounted || initializingController != _controller) return;
      await _handlePlaybackFailure();
    }
  }

  void _handleVideoChanged() {
    if (!mounted || _switchingEngine) return;
    if (_controller.error != null && !_initializing) {
      unawaited(_handlePlaybackFailure());
      return;
    }
    final nextState = _readVideoUiState();
    final presentationChanged = nextState != _lastVideoUiState;
    _lastVideoUiState = nextState;
    // During startup the loading state is already visible. Avoid rebuilding
    // it for every native position/buffer callback before initialization ends.
    if (_initializing) return;
    if (presentationChanged) {
      _refreshVideoUiNow();
    } else {
      _scheduleVideoUiRefresh();
    }
  }

  ({
    bool initialized,
    bool playing,
    bool buffering,
    int durationMs,
    int aspectMilli,
    String? error,
  })
  _readVideoUiState() {
    final aspect = _controller.aspectRatio;
    return (
      initialized: _controller.isInitialized,
      playing: _controller.isPlaying,
      buffering: _controller.isBuffering,
      durationMs: _controller.duration.inMilliseconds,
      aspectMilli: (aspect.isFinite ? aspect : 16 / 9) * 1000 ~/ 1,
      error: _controller.error,
    );
  }

  void _refreshVideoUiNow() {
    _videoUiTimer?.cancel();
    _videoUiTimer = null;
    _lastVideoUiRefreshMs = _videoUiClock.elapsedMilliseconds;
    if (mounted) setState(() {});
  }

  void _scheduleVideoUiRefresh() {
    if (_videoUiTimer != null) return;
    final elapsed = _videoUiClock.elapsedMilliseconds - _lastVideoUiRefreshMs;
    final remaining = _videoPositionUiInterval.inMilliseconds - elapsed;
    if (remaining <= 0) {
      _refreshVideoUiNow();
      return;
    }
    _videoUiTimer = Timer(Duration(milliseconds: remaining), () {
      _videoUiTimer = null;
      if (!mounted || _switchingEngine || _initializing) return;
      _lastVideoUiRefreshMs = _videoUiClock.elapsedMilliseconds;
      setState(() {});
    });
  }

  void _cancelVideoUiRefresh() {
    _videoUiTimer?.cancel();
    _videoUiTimer = null;
    _lastVideoUiState = null;
  }

  Future<void> _handlePlaybackFailure() async {
    if (_switchingEngine) return;
    if (_sourceIndex + 1 < _sourceUrls.length) {
      await _switchSource(notice: '当前 CDN 不可用，正在切换 B 站备用地址');
      return;
    }
    if (widget.mode == VideoPlayerMode.automatic &&
        !_automaticFallbackUsed &&
        _activeEngine == _MvEngine.exo) {
      _automaticFallbackUsed = true;
      await _switchEngine(_MvEngine.mpv, notice: 'ExoPlayer 播放失败，正在切换 MPV');
      return;
    }
    if (!mounted) return;
    final detail = _controller.error;
    setState(() {
      _initializing = false;
      _initializationError = detail == null || detail.trim().isEmpty
          ? '${_controller.label} 无法播放此 MV'
          : '${_controller.label} 无法播放此 MV\n$detail';
    });
  }

  Future<void> _switchSource({String? notice}) async {
    if (_switchingEngine || _sourceIndex + 1 >= _sourceUrls.length) return;
    _switchingEngine = true;
    _controlsTimer?.cancel();
    _cancelVideoUiRefresh();
    if (mounted) {
      setState(() {
        _initializing = true;
        _initializationError = null;
        _engineNotice = notice;
      });
    }
    final previous = _controller;
    previous.removeListener(_handleVideoChanged);
    await previous.close();
    if (!mounted) return;
    _sourceIndex++;
    _controller = _createController(_activeEngine)
      ..addListener(_handleVideoChanged);
    _switchingEngine = false;
    await _initialize();
  }

  Future<void> _switchEngine(_MvEngine engine, {String? notice}) async {
    if (_switchingEngine || engine == _activeEngine) return;
    _switchingEngine = true;
    _controlsTimer?.cancel();
    _cancelVideoUiRefresh();
    if (mounted) {
      setState(() {
        _initializing = true;
        _initializationError = null;
        _engineNotice = notice;
      });
    }
    final previous = _controller;
    previous.removeListener(_handleVideoChanged);
    await previous.close();
    if (!mounted) return;
    _sourceIndex = 0;
    _activeEngine = engine;
    _controller = _createController(engine)..addListener(_handleVideoChanged);
    _switchingEngine = false;
    await _initialize();
  }

  Future<void> _retry() async {
    if (_switchingEngine) return;
    _cancelVideoUiRefresh();
    _controller.removeListener(_handleVideoChanged);
    await _controller.close();
    if (!mounted) return;
    _sourceIndex = 0;
    _controller = _createController(_activeEngine)
      ..addListener(_handleVideoChanged);
    await _initialize();
  }

  Future<void> _tryAlternateEngine() {
    return _switchEngine(
      _activeEngine == _MvEngine.exo ? _MvEngine.mpv : _MvEngine.exo,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _controller.isPlaying) {
      unawaited(_controller.pause());
      _showControls();
    }
  }

  void _showControls() {
    _controlsTimer?.cancel();
    if (mounted && !_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
  }

  void _toggleControls() {
    _controlsTimer?.cancel();
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (!_controller.isPlaying) return;
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  Future<void> _togglePlayback() async {
    _showControls();
    if (_controller.isPlaying) {
      await _controller.pause();
    } else {
      await _controller.play();
      _scheduleControlsHide();
    }
  }

  Future<void> _seekRelative(Duration delta) async {
    final duration = _controller.duration;
    var target = _controller.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    await _controller.seekTo(target);
    _showControls();
    _scheduleControlsHide();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controlsTimer?.cancel();
    _cancelVideoUiRefresh();
    _controller.removeListener(_handleVideoChanged);
    unawaited(_controller.close());
    applySystemUi(dark: AppColors.isDark);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = size.height < 480;
    final error = _initializationError;

    return Scaffold(
      key: const ValueKey('built-in-mv-player'),
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _controller.isInitialized ? _toggleControls : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!_initializing && error == null)
                Positioned.fill(
                  child: RepaintBoundary(
                    key: const ValueKey('mv-video-repaint-boundary'),
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: _controller.aspectRatio,
                        child: _controller.buildSurface(
                          ValueKey('mv-video-surface-${_activeEngine.name}'),
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned.fill(
                child: AppMotionSwitcher(
                  beginOffset: Offset.zero,
                  child: _initializing
                      ? KeyedSubtree(
                          key: const ValueKey('mv-loading-state'),
                          child: _buildLoading(compact),
                        )
                      : error != null
                      ? KeyedSubtree(
                          key: const ValueKey('mv-error-state'),
                          child: _buildError(error, compact),
                        )
                      : const SizedBox.shrink(key: ValueKey('mv-ready-state')),
                ),
              ),
              if (!_initializing && error == null && _controller.isBuffering)
                const Center(child: CircularProgressIndicator()),
              _buildTopControls(compact),
              if (_controller.isInitialized && error == null)
                _buildBottomControls(compact),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoading(bool compact) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (_engineNotice != null) ...[
            SizedBox(height: compact ? 8 : 14),
            Text(
              _engineNotice!,
              style: TextStyle(
                color: Colors.white70,
                fontSize: compact ? 14 : 17,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTopControls(bool compact) {
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: AppMotion.resolve(context, AppMotion.state),
        child: Align(
          alignment: Alignment.topCenter,
          child: Container(
            padding: EdgeInsets.fromLTRB(
              compact ? 4 : 12,
              compact ? 2 : 8,
              compact ? 8 : 16,
              compact ? 18 : 28,
            ),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xD9000000), Color(0x00000000)],
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('mv-player-back'),
                  tooltip: '返回',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back_rounded),
                  color: Colors.white,
                  iconSize: compact ? 26 : 32,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: compact ? 17 : 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        [
                          if (widget.artist.trim().isNotEmpty) widget.artist,
                          _controller.label,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: compact ? 13 : 16,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls(bool compact) {
    final durationMs = _controller.duration.inMilliseconds.clamp(1, 1 << 31);
    final positionMs = _controller.position.inMilliseconds.clamp(0, durationMs);
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: AppMotion.resolve(context, AppMotion.state),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            padding: EdgeInsets.fromLTRB(
              compact ? 8 : 18,
              compact ? 18 : 28,
              compact ? 8 : 18,
              compact ? 4 : 10,
            ),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x00000000), Color(0xE6000000)],
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: '快退 10 秒',
                  onPressed: () => _seekRelative(const Duration(seconds: -10)),
                  icon: const Icon(Icons.replay_10_rounded),
                  color: Colors.white,
                  iconSize: compact ? 25 : 31,
                ),
                IconButton(
                  tooltip: _controller.isPlaying ? '暂停' : '播放',
                  onPressed: _togglePlayback,
                  icon: AppAnimatedIcon(
                    stateKey: _controller.isPlaying,
                    child: Icon(
                      _controller.isPlaying
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                    ),
                  ),
                  color: Colors.white,
                  iconSize: compact ? 35 : 44,
                ),
                IconButton(
                  tooltip: '快进 10 秒',
                  onPressed: () => _seekRelative(const Duration(seconds: 10)),
                  icon: const Icon(Icons.forward_10_rounded),
                  color: Colors.white,
                  iconSize: compact ? 25 : 31,
                ),
                Text(
                  _formatDuration(_controller.position),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 12 : 15,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: positionMs.toDouble(),
                    max: durationMs.toDouble(),
                    onChanged: (next) {
                      unawaited(
                        _controller.seekTo(
                          Duration(milliseconds: next.round()),
                        ),
                      );
                    },
                    onChangeStart: (_) => _showControls(),
                    onChangeEnd: (_) => _scheduleControlsHide(),
                  ),
                ),
                Text(
                  _formatDuration(_controller.duration),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 12 : 15,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildError(String message, bool compact) {
    final alternateLabel = _activeEngine == _MvEngine.exo ? 'MPV' : 'Exo';
    return Center(
      key: const ValueKey('mv-video-error'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              color: Colors.white70,
              size: compact ? 40 : 56,
            ),
            SizedBox(height: compact ? 8 : 14),
            Text(
              message,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: compact ? 15 : 18,
              ),
            ),
            SizedBox(height: compact ? 10 : 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  key: const ValueKey('mv-player-alternate-engine'),
                  onPressed: _tryAlternateEngine,
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: Text('$alternateLabel 播放'),
                ),
                OutlinedButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重试'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
