import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:media_kit/media_kit.dart' as media_kit;
import 'package:media_kit_video/media_kit_video.dart' as media_kit_video;
import 'package:video_player/video_player.dart';

import '../models/song.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../utils/system_ui.dart';
import '../widgets/remote_focusable.dart';

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

class _UnavailablePlaybackController extends _MvPlaybackController {
  final String _message;
  bool _closed = false;

  _UnavailablePlaybackController(this._message);

  @override
  String get label => '播放器';

  @override
  bool get isInitialized => false;

  @override
  bool get isPlaying => false;

  @override
  bool get isBuffering => false;

  @override
  Duration get position => Duration.zero;

  @override
  Duration get duration => Duration.zero;

  @override
  double get aspectRatio => 16 / 9;

  @override
  String get error => _message;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(Duration position) async {}

  @override
  Widget buildSurface(Key key) => const SizedBox.shrink();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    super.dispose();
  }
}

class _ExoPlaybackController extends _MvPlaybackController {
  late final VideoPlayerController _controller;
  final String? _audioUrl;
  final Map<String, String> _headers;
  AudioPlayer? _audioPlayer;
  Future<void>? _audioSyncOperation;
  Future<void>? _audioPlayOperation;
  Future<void>? _closeFuture;
  final Completer<void> _closedSignal = Completer<void>();
  bool _closed = false;
  String? _audioError;

  _ExoPlaybackController(
    String url,
    Map<String, String> headers, {
    String? audioUrl,
  }) : _audioUrl = audioUrl,
       _headers = headers {
    final hasExternalAudio = audioUrl != null && audioUrl.isNotEmpty;
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers,
      // The separate just_audio player owns audio focus for B站 DASH.
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: hasExternalAudio),
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
  String? get error {
    if (_controller.value.hasError) {
      return _controller.value.errorDescription ?? 'ExoPlayer 播放失败';
    }
    return _audioError;
  }

  void _handleChanged() {
    if (_closed) return;
    _scheduleExternalAudioSync();
    notifyListeners();
  }

  void _scheduleExternalAudioSync() {
    if (_closed || _audioPlayer == null || _audioSyncOperation != null) return;
    late final Future<void> operation;
    operation = _syncExternalAudio().whenComplete(() {
      if (identical(_audioSyncOperation, operation)) {
        _audioSyncOperation = null;
      }
    });
    _audioSyncOperation = operation;
    unawaited(operation);
  }

  Future<void> _syncExternalAudio() async {
    final audioPlayer = _audioPlayer;
    if (_closed || audioPlayer == null) return;
    try {
      final value = _controller.value;
      if (!value.isInitialized) return;
      if (!value.isPlaying || value.isBuffering || value.isCompleted) {
        if (audioPlayer.playing) await audioPlayer.pause();
        return;
      }
      final drift = (audioPlayer.position - value.position).abs();
      if (drift > const Duration(milliseconds: 650)) {
        await audioPlayer.seek(value.position);
      }
      if (!_closed && !audioPlayer.playing) _startExternalAudio();
    } catch (error) {
      if (!_closed) {
        _audioError = 'B站音轨播放失败：$error';
        notifyListeners();
      }
    }
  }

  void _startExternalAudio() {
    final audioPlayer = _audioPlayer;
    if (_closed || audioPlayer == null || _audioPlayOperation != null) return;
    late final Future<void> operation;
    operation = _playExternalAudio(audioPlayer).whenComplete(() {
      if (identical(_audioPlayOperation, operation)) {
        _audioPlayOperation = null;
      }
    });
    _audioPlayOperation = operation;
    unawaited(operation);
  }

  Future<void> _playExternalAudio(AudioPlayer audioPlayer) async {
    try {
      await audioPlayer.play();
    } catch (error) {
      if (!_closed) {
        _audioError = 'B站音轨播放失败：$error';
        notifyListeners();
      }
    }
  }

  @override
  Future<void> initialize() async {
    await Future.any<void>([_controller.initialize(), _closedSignal.future]);
    if (_closed) return;
    final audioUrl = _audioUrl;
    if (audioUrl != null && audioUrl.isNotEmpty) {
      final audioPlayer = AudioPlayer();
      _audioPlayer = audioPlayer;
      await Future.any<Object?>([
        audioPlayer.setAudioSource(
          AudioSource.uri(Uri.parse(audioUrl), headers: _headers),
        ),
        _closedSignal.future,
      ]);
      if (_closed) return;
    }
    await _controller.play();
    if (_closed) return;
    _scheduleExternalAudioSync();
  }

  @override
  Future<void> play() async {
    if (_closed) return;
    await _controller.play();
    if (_closed) return;
    _scheduleExternalAudioSync();
  }

  @override
  Future<void> pause() async {
    if (_closed) return;
    await _controller.pause();
    if (_closed) return;
    await _audioPlayer?.pause();
  }

  @override
  Future<void> seekTo(Duration position) async {
    if (_closed) return;
    await _controller.seekTo(position);
    if (_closed) return;
    await _audioPlayer?.seek(position);
  }

  @override
  Widget buildSurface(Key key) => VideoPlayer(_controller, key: key);

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    _closedSignal.complete();
    _controller.removeListener(_handleChanged);
    final audioPlayer = _audioPlayer;
    // just_audio.play() completes when playback is stopped or paused. Stop it
    // before waiting for an in-flight play operation during teardown.
    try {
      await audioPlayer?.stop();
    } catch (_) {}
    try {
      await _audioSyncOperation;
    } catch (_) {}
    try {
      await _audioPlayOperation;
    } catch (_) {}
    try {
      await audioPlayer?.dispose();
    } catch (_) {}
    try {
      await _controller.dispose();
    } catch (_) {}
    super.dispose();
  }
}

class _MpvPlaybackController extends _MvPlaybackController {
  late final media_kit.Player _player;
  late final media_kit_video.VideoController _controller;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final String url;
  final String? audioUrl;
  final Map<String, String> headers;
  bool _initialized = false;
  bool _closed = false;
  Future<void>? _closeFuture;
  final Completer<void> _closedSignal = Completer<void>();
  String? _error;

  _MpvPlaybackController(this.url, this.headers, {this.audioUrl}) {
    _player = media_kit.Player(
      configuration: const media_kit.PlayerConfiguration(title: '库仔音乐 MV'),
    );
    _controller = media_kit_video.VideoController(
      _player,
      configuration: const media_kit_video.VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        androidAttachSurfaceAfterVideoParameters: false,
      ),
    );
    _subscriptions.addAll([
      _player.stream.playing.listen(
        (_) => _changed(),
        onError: (Object error, StackTrace stackTrace) {
          _handleStreamError('playing', error, stackTrace);
        },
      ),
      _player.stream.position.listen(
        (_) => _changed(),
        onError: (Object error, StackTrace stackTrace) {
          _handleStreamError('position', error, stackTrace);
        },
      ),
      _player.stream.duration.listen(
        (_) => _changed(),
        onError: (Object error, StackTrace stackTrace) {
          _handleStreamError('duration', error, stackTrace);
        },
      ),
      _player.stream.buffering.listen(
        (_) => _changed(),
        onError: (Object error, StackTrace stackTrace) {
          _handleStreamError('buffering', error, stackTrace);
        },
      ),
      _player.stream.width.listen(
        (_) => _changed(),
        onError: (Object error, StackTrace stackTrace) {
          _handleStreamError('width', error, stackTrace);
        },
      ),
      _player.stream.height.listen(
        (_) => _changed(),
        onError: (Object error, StackTrace stackTrace) {
          _handleStreamError('height', error, stackTrace);
        },
      ),
      _player.stream.error.listen(
        (message) {
          if (message.trim().isEmpty || _closed) return;
          _error = message;
          _changed();
        },
        onError: (Object error, StackTrace stackTrace) {
          _handleStreamError('error', error, stackTrace);
        },
      ),
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

  void _handleStreamError(
    String streamName,
    Object error,
    StackTrace stackTrace,
  ) {
    if (_closed) return;
    _error = 'MPV $streamName 状态异常：$error';
    debugPrint('MPV $streamName 状态流异常: $error');
    debugPrintStack(stackTrace: stackTrace);
    _changed();
  }

  @override
  Future<void> initialize() async {
    if (_closed) return;
    _error = null;
    final source = audioUrl == null || audioUrl!.isEmpty
        ? url
        : _edlSource(url, audioUrl!);
    final nativePlayer = _player.platform;
    if (nativePlayer is media_kit.NativePlayer) {
      final userAgent = headers['User-Agent'];
      final referer = headers['Referer'];
      if (userAgent != null) {
        await nativePlayer.setProperty('user-agent', userAgent);
        if (_closed) return;
      }
      if (referer != null) {
        await nativePlayer.setProperty('referrer', referer);
        if (_closed) return;
      }
    }
    await Future.any<void>([
      _player.open(media_kit.Media(source, httpHeaders: headers), play: true),
      _closedSignal.future,
    ]);
    if (_closed) return;
    _initialized = true;
    _changed();
  }

  static String _edlSource(String video, String audio) {
    final videoLength = utf8.encode(video).length;
    final audioLength = utf8.encode(audio).length;
    return 'edl://!no_clip;!no_chapters;'
        '%$videoLength%$video;'
        '!new_stream;!no_clip;!no_chapters;'
        '%$audioLength%$audio';
  }

  @override
  Future<void> play() => _closed ? Future.value() : _player.play();

  @override
  Future<void> pause() => _closed ? Future.value() : _player.pause();

  @override
  Future<void> seekTo(Duration position) =>
      _closed ? Future.value() : _player.seek(position);

  @override
  Widget buildSurface(Key key) => media_kit_video.Video(
    key: key,
    controller: _controller,
    controls: media_kit_video.NoVideoControls,
    fit: BoxFit.contain,
  );

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    _closedSignal.complete();
    for (final subscription in _subscriptions) {
      try {
        await subscription.cancel();
      } catch (_) {}
    }
    try {
      await _player.dispose();
    } catch (_) {}
    super.dispose();
  }
}

class VideoPlayerScreen extends StatefulWidget {
  final String url;
  final List<String> alternateUrls;
  final String? audioUrl;
  final Map<String, String>? headers;
  final String title;
  final String artist;
  final MusicPlatform platform;
  final VideoPlayerMode mode;

  const VideoPlayerScreen({
    super.key,
    required this.url,
    this.alternateUrls = const [],
    this.audioUrl,
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
  bool _topControlsFocused = false;
  bool _bottomControlsFocused = false;
  bool _switchingEngine = false;
  bool _handlingPlaybackFailure = false;
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
    }.where(_isPlayableSource).toList(growable: false);
    WidgetsBinding.instance.addObserver(this);
    applySystemUi(dark: true);
    _activeEngine = widget.mode == VideoPlayerMode.mpv
        ? _MvEngine.mpv
        : _MvEngine.exo;
    _controller = _createController(_activeEngine)
      ..addListener(_handleVideoChanged);
    if (_sourceUrls.isEmpty) {
      _initializing = false;
      _initializationError = 'MV 播放地址无效或为空';
    } else {
      unawaited(_initialize());
    }
  }

  static bool _isPlayableSource(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
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
    if (_sourceUrls.isEmpty) {
      return _UnavailablePlaybackController('MV 播放地址无效或为空');
    }
    // MPV is a native backend. Keep its initialization off the ordinary audio
    // startup path and pay the cost only when an MV actually needs it.
    try {
      if (engine == _MvEngine.mpv) {
        media_kit.MediaKit.ensureInitialized();
      }
      final headers = _headersFor(widget.platform, widget.headers);
      final url = _sourceUrls[_sourceIndex];
      final audioUrl = _isPlayableSource(widget.audioUrl ?? '')
          ? widget.audioUrl
          : null;
      return switch (engine) {
        _MvEngine.exo => _ExoPlaybackController(
          url,
          headers,
          audioUrl: audioUrl,
        ),
        _MvEngine.mpv => _MpvPlaybackController(
          url,
          headers,
          audioUrl: audioUrl,
        ),
      };
    } catch (error) {
      return _UnavailablePlaybackController(
        '${engine == _MvEngine.exo ? 'ExoPlayer' : 'MPV'} 初始化失败: $error',
      );
    }
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
    } catch (error) {
      if (!mounted || initializingController != _controller) return;
      await _handlePlaybackFailure(error);
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

  Future<void> _handlePlaybackFailure([Object? cause]) async {
    if (!mounted || _switchingEngine || _handlingPlaybackFailure) return;
    _handlingPlaybackFailure = true;
    try {
      if (_sourceUrls.isEmpty) {
        _showPlaybackError(cause);
        return;
      }
      if (_sourceIndex + 1 < _sourceUrls.length) {
        // _switchSource initializes the replacement controller. Release this
        // guard first so a real error from that new controller can be handled.
        _handlingPlaybackFailure = false;
        await _switchSource(notice: '当前 CDN 不可用，正在切换 B 站备用地址');
        return;
      }
      if (widget.mode == VideoPlayerMode.automatic &&
          !_automaticFallbackUsed &&
          _activeEngine == _MvEngine.exo) {
        _automaticFallbackUsed = true;
        _handlingPlaybackFailure = false;
        await _switchEngine(_MvEngine.mpv, notice: 'ExoPlayer 播放失败，正在切换 MPV');
        return;
      }
      _showPlaybackError(cause);
    } catch (error) {
      _showPlaybackError(error);
    } finally {
      _handlingPlaybackFailure = false;
    }
  }

  void _showPlaybackError(Object? cause) {
    if (!mounted) return;
    final controllerDetail = _controller.error;
    final detail = controllerDetail == null || controllerDetail.trim().isEmpty
        ? cause?.toString().trim()
        : controllerDetail.trim();
    setState(() {
      _initializing = false;
      _initializationError = detail == null || detail.isEmpty
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
    Object? transitionError;
    var controllerReplaced = false;
    try {
      previous.removeListener(_handleVideoChanged);
      await previous.close();
      if (!mounted) return;
      _sourceIndex++;
      _controller = _createController(_activeEngine)
        ..addListener(_handleVideoChanged);
      controllerReplaced = true;
    } catch (error) {
      transitionError = error;
    } finally {
      _switchingEngine = false;
    }
    if (!mounted) return;
    if (transitionError != null) {
      _showPlaybackError(transitionError);
    } else if (controllerReplaced) {
      await _initialize();
    }
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
    Object? transitionError;
    var controllerReplaced = false;
    try {
      previous.removeListener(_handleVideoChanged);
      await previous.close();
      if (!mounted) return;
      _sourceIndex = 0;
      _activeEngine = engine;
      _controller = _createController(engine)..addListener(_handleVideoChanged);
      controllerReplaced = true;
    } catch (error) {
      transitionError = error;
    } finally {
      _switchingEngine = false;
    }
    if (!mounted) return;
    if (transitionError != null) {
      _showPlaybackError(transitionError);
    } else if (controllerReplaced) {
      await _initialize();
    }
  }

  Future<void> _retry() async {
    if (_switchingEngine) return;
    _switchingEngine = true;
    _controlsTimer?.cancel();
    _cancelVideoUiRefresh();
    if (mounted) {
      setState(() {
        _initializing = true;
        _initializationError = null;
        _engineNotice = null;
      });
    }
    final previous = _controller;
    Object? transitionError;
    var controllerReplaced = false;
    try {
      previous.removeListener(_handleVideoChanged);
      await previous.close();
      if (!mounted) return;
      _sourceIndex = 0;
      _controller = _createController(_activeEngine)
        ..addListener(_handleVideoChanged);
      controllerReplaced = true;
    } catch (error) {
      transitionError = error;
    } finally {
      _switchingEngine = false;
    }
    if (!mounted) return;
    if (transitionError != null) {
      _showPlaybackError(transitionError);
    } else if (controllerReplaced) {
      await _initialize();
    }
  }

  Future<void> _tryAlternateEngine() {
    return _switchEngine(
      _activeEngine == _MvEngine.exo ? _MvEngine.mpv : _MvEngine.exo,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state != AppLifecycleState.resumed && _controller.isPlaying) {
      final controller = _controller;
      unawaited(_pauseForLifecycle(controller));
      _showControls();
    }
  }

  Future<void> _pauseForLifecycle(_MvPlaybackController controller) async {
    try {
      await controller.pause();
    } catch (error) {
      debugPrint('MV 进入后台时暂停失败: $error');
    }
  }

  void _showControls() {
    _controlsTimer?.cancel();
    if (mounted && !_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
  }

  void _toggleControls() {
    if (!mounted) return;
    _controlsTimer?.cancel();
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (!_controller.isPlaying || _controlsHaveFocus) return;
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_controlsHaveFocus) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  bool get _controlsHaveFocus => _topControlsFocused || _bottomControlsFocused;

  void _handleControlsFocus({required bool top, required bool focused}) {
    if (!mounted) return;
    if (top) {
      _topControlsFocused = focused;
    } else {
      _bottomControlsFocused = focused;
    }
    if (focused) {
      _showControls();
    } else if (!_controlsHaveFocus) {
      _scheduleControlsHide();
    }
  }

  KeyEventResult _handleRemoteKey(FocusNode _, KeyEvent event) {
    if (!mounted) return KeyEventResult.ignored;
    final isPress = event is KeyDownEvent || event is KeyRepeatEvent;
    if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause) {
      if (isPress && _controller.isInitialized) unawaited(_togglePlayback());
      return KeyEventResult.handled;
    }
    if (isPress &&
        (event.logicalKey == LogicalKeyboardKey.arrowUp ||
            event.logicalKey == LogicalKeyboardKey.arrowDown ||
            event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight)) {
      _showControls();
    }
    return KeyEventResult.ignored;
  }

  Future<void> _togglePlayback() async {
    _showControls();
    final wasPlaying = _controller.isPlaying;
    final succeeded = await _runControllerCommand(
      (controller) => wasPlaying ? controller.pause() : controller.play(),
    );
    if (!succeeded) return;
    if (!wasPlaying) {
      _scheduleControlsHide();
    }
  }

  Future<bool> _runControllerCommand(
    Future<void> Function(_MvPlaybackController controller) command,
  ) async {
    final controller = _controller;
    try {
      await command(controller);
      return mounted && identical(controller, _controller);
    } catch (error) {
      if (mounted && identical(controller, _controller)) {
        await _handlePlaybackFailure(error);
      }
      return false;
    }
  }

  Future<void> _seekAbsolute(Duration position) async {
    final succeeded = await _runControllerCommand(
      (controller) => controller.seekTo(position),
    );
    if (succeeded) {
      _showControls();
    }
  }

  Future<void> _seekRelative(Duration delta) async {
    final duration = _controller.duration;
    var target = _controller.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    final succeeded = await _runControllerCommand(
      (controller) => controller.seekTo(target),
    );
    if (succeeded) {
      _showControls();
      _scheduleControlsHide();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _switchingEngine = true;
    _handlingPlaybackFailure = true;
    _controlsTimer?.cancel();
    _cancelVideoUiRefresh();
    final controller = _controller;
    controller.removeListener(_handleVideoChanged);
    unawaited(controller.close());
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
        child: RemoteFocusable(
          autofocus: true,
          enabled: true,
          onKeyEvent: _handleRemoteKey,
          onPressed: _controller.isInitialized ? _toggleControls : null,
          semanticLabel: '视频播放区域',
          borderRadius: BorderRadius.zero,
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
              if (error == null && _controller.isInitialized)
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
    return ExcludeFocus(
      excluding: !_controlsVisible,
      child: Focus(
        canRequestFocus: false,
        onFocusChange: (focused) =>
            _handleControlsFocus(top: true, focused: focused),
        child: IgnorePointer(
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
                              if (widget.artist.trim().isNotEmpty)
                                widget.artist,
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
        ),
      ),
    );
  }

  Widget _buildBottomControls(bool compact) {
    final durationMs = _controller.duration.inMilliseconds.clamp(1, 1 << 31);
    final positionMs = _controller.position.inMilliseconds.clamp(0, durationMs);
    return ExcludeFocus(
      excluding: !_controlsVisible,
      child: Focus(
        canRequestFocus: false,
        onFocusChange: (focused) =>
            _handleControlsFocus(top: false, focused: focused),
        child: IgnorePointer(
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
                      onPressed: () =>
                          _seekRelative(const Duration(seconds: -10)),
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
                      onPressed: () =>
                          _seekRelative(const Duration(seconds: 10)),
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
                            _seekAbsolute(Duration(milliseconds: next.round())),
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
