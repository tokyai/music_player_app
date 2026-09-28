import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as media_kit;
import 'package:media_kit_video/media_kit_video.dart' as media_kit_video;
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/screens/video_player_screen.dart';
import 'package:music_player_app/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('invalid MV sources render an error instead of throwing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const VideoPlayerScreen(
          url: '',
          alternateUrls: ['not a URL'],
          title: '测试 MV',
          artist: '测试歌手',
          platform: MusicPlatform.bilibili,
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('MV 播放地址无效或为空'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('MPV compatibility recovery', () {
    test(
      'normal open is unchanged; recovery retains URL headers and position',
      () async {
        final native = _NativePlayerStub();
        final controller = _controllerFor(native);
        await controller.initialize();
        expect(native.opens, hasLength(1));
        expect(native.opens.single.media.uri, _videoUrl);
        expect(native.opens.single.media.start, isNull);
        expect(native.opens.single.play, isTrue);
        expect(native.properties, isNot(contains('hwdec')));
        expect(controller.label, 'MPV');

        native.emitFailure('hardware decoder failed');
        await Future<void>.delayed(Duration.zero);
        expect(controller.error, 'hardware decoder failed');
        await controller.retryWithSoftwareDecoding(const Duration(seconds: 73));

        expect(native.opens, hasLength(2));
        expect(native.opens.last.media.uri, _videoUrl);
        expect(native.opens.last.media.httpHeaders, _headers);
        expect(native.opens.last.media.start, const Duration(seconds: 73));
        expect(native.opens.last.play, isFalse);
        expect(
          native.events,
          containsAllInOrder(['open:1', 'stop', 'hwdec:no', 'open:2']),
        );
        expect(native.disposeCalls, 0);
        expect(controller.canRetryWithSoftwareDecoding, isFalse);
        expect(controller.error, isNull);
      },
    );

    test('initial open exceptions allow one compatibility attempt', () async {
      final native = _NativePlayerStub()
        ..firstOpenError = StateError('hardware decoder unavailable');
      final controller = _controllerFor(native);
      await expectLater(controller.initialize(), throwsStateError);
      await controller.retryWithSoftwareDecoding(Duration.zero);
      expect(native.opens, hasLength(2));
      expect(native.opens.last.media.start, isNull);
      expect(native.opens.last.play, isFalse);
      expect(controller.isInitialized, isTrue);
    });

    test('recovery waits for the entire original initialization', () async {
      final native = _NativePlayerStub()..userAgentGate = Completer<void>();
      final controller = _controllerFor(native);
      final initializing = controller.initialize();
      final recovering = controller.retryWithSoftwareDecoding(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(native.events, ['user-agent:$_userAgent']);
      native.userAgentGate!.complete();
      await initializing;
      await recovering;
      expect(
        native.events,
        containsAllInOrder([
          'referrer:https://y.qq.com/',
          'stop',
          'hwdec:no',
          'open:1',
        ]),
      );
      expect(native.opens, hasLength(1));
      expect(native.opens.single.play, isFalse);
    });

    test('duplicate recovery requests share one native operation', () async {
      final native = _NativePlayerStub()..stopGate = Completer<void>();
      final controller = _controllerFor(native);
      await controller.initialize();
      final first = controller.retryWithSoftwareDecoding(Duration.zero);
      final second = controller.retryWithSoftwareDecoding(Duration.zero);
      expect(identical(first, second), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(native.events.where((event) => event == 'stop'), hasLength(1));
      native.stopGate!.complete();
      await Future.wait([first, second]);
      expect(native.opens, hasLength(2));
    });

    test(
      'decoder allocation failure is surfaced and resources still close',
      () async {
        final native = _NativePlayerStub()
          ..hwdecError = PlatformException(code: 'decoder_allocation_failed');
        final controller = _controllerFor(native);
        await controller.initialize();
        await expectLater(
          controller.retryWithSoftwareDecoding(Duration.zero),
          throwsA(isA<PlatformException>()),
        );
        expect(native.opens, hasLength(1));
        expect(controller.canRetryWithSoftwareDecoding, isFalse);
        await controller.close();
        await controller.close();
        expect(native.disposeCalls, 1);
      },
    );

    for (final stage in [
      'initial open',
      'stop',
      'property',
      'reopen',
      'resume',
    ]) {
      test(
        'close waits for pending $stage and cancels later recovery work',
        () async {
          final native = _NativePlayerStub();
          final gate = Completer<void>();
          switch (stage) {
            case 'initial open':
              native.firstOpenGate = gate;
            case 'stop':
              native.stopGate = gate;
            case 'property':
              native.hwdecGate = gate;
            case 'reopen':
              native.reopenGate = gate;
            case 'resume':
              native.playGate = gate;
          }
          final controller = _controllerFor(native);
          final initializing = controller.initialize();
          if (stage == 'initial open') {
            await Future<void>.delayed(Duration.zero);
            expect(native.opens, hasLength(1));
          } else {
            await initializing;
          }
          final recovering = controller.retryWithSoftwareDecoding(
            Duration.zero,
            shouldResume: () => stage == 'resume',
          );
          await Future<void>.delayed(Duration.zero);
          var notifications = 0;
          controller.addListener(() => notifications++);
          final closing = controller.close();
          final countAtClose = notifications;
          expect(native.disposeCalls, 0);
          gate.complete();
          await Future.wait([initializing, recovering, closing]);
          expect(native.disposeCalls, 1);
          expect(
            native.opens,
            hasLength(stage == 'reopen' || stage == 'resume' ? 2 : 1),
          );
          expect(notifications, countAtClose);
          expect(native.callsAfterDispose, 0);
        },
      );
    }

    test(
      'cancelled recovery cannot reopen when original initialization finishes late',
      () async {
        final native = _NativePlayerStub()..firstOpenGate = Completer<void>();
        final controller = _controllerFor(native);
        final initializing = controller.initialize();
        await Future<void>.delayed(Duration.zero);
        expect(native.opens, hasLength(1));
        final recovering = controller.retryWithSoftwareDecoding(Duration.zero);
        controller.cancelSoftwareDecodingRetry();
        native.firstOpenGate!.complete();
        await Future.wait([initializing, recovering]);
        expect(native.opens, hasLength(1));
        expect(native.state.playing, isFalse);
        expect(native.properties, isNot(contains('hwdec')));
      },
    );

    test(
      'cancelled recovery prevents a late initial open after setting headers',
      () async {
        final native = _NativePlayerStub()..userAgentGate = Completer<void>();
        final controller = _controllerFor(native);
        final initializing = controller.initialize();
        final recovering = controller.retryWithSoftwareDecoding(Duration.zero);
        controller.cancelSoftwareDecodingRetry();
        native.userAgentGate!.complete();
        await Future.wait([initializing, recovering]);
        expect(native.opens, isEmpty);
        expect(native.events, ['user-agent:$_userAgent']);
        expect(controller.isInitialized, isFalse);
      },
    );
  });

  for (final mode in VideoPlayerMode.values) {
    testWidgets('successful $mode playback does not enable compatibility', (
      tester,
    ) async {
      final harness = _ScreenHarness([_NativePlayerStub()], mode: mode);
      await _mount(tester, harness);
      expect(harness.modes, [
        mode == VideoPlayerMode.automatic ? VideoPlayerMode.exo : mode,
      ]);
      expect(harness.players.single.opens, hasLength(1));
      expect(harness.players.single.properties, isNot(contains('hwdec')));
      expect(find.byTooltip('暂停').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'initial MPV exception retries the same media without replacing the player',
    (tester) async {
      final native = _NativePlayerStub()
        ..firstOpenError = StateError('decoder failed');
      final harness = _ScreenHarness([native]);
      await _mount(tester, harness);
      expect(harness.modes, [VideoPlayerMode.mpv]);
      expect(native.opens, hasLength(2));
      expect(native.opens.last.media.uri, _videoUrl);
      expect(
        native.opens.last.media.httpHeaders!['Referer'],
        'https://y.qq.com/',
      );
      expect(native.properties['hwdec'], 'no');
      expect(native.playCalls, 1);
      expect(native.disposeCalls, 0);
      expect(find.textContaining('兼容模式'), findsOneWidget);
      expect(find.byKey(const ValueKey('mv-video-error')), findsNothing);
    },
  );

  testWidgets('automatic mode keeps Exo then MPV then compatibility order', (
    tester,
  ) async {
    final exo = _NativePlayerStub()..firstOpenError = StateError('Exo failed');
    final mpv = _NativePlayerStub()..firstOpenError = StateError('MPV failed');
    final harness = _ScreenHarness([exo, mpv], mode: VideoPlayerMode.automatic);
    await _mount(tester, harness);
    await _flushStreamCancellation(tester);
    expect(harness.modes, [
      VideoPlayerMode.exo,
      VideoPlayerMode.mpv,
    ], reason: exo.events.join(', '));
    expect(exo.disposeCalls, 1);
    expect(exo.properties, isNot(contains('hwdec')));
    expect(mpv.opens, hasLength(2));
    expect(mpv.properties['hwdec'], 'no');
  });

  for (final paused in [false, true]) {
    testWidgets('runtime recovery retains position and paused=$paused', (
      tester,
    ) async {
      final native = _NativePlayerStub();
      final harness = _ScreenHarness([native]);
      await _mount(tester, harness);
      native.updatePosition(const Duration(seconds: 73));
      if (paused) {
        await tester.tap(find.byTooltip('暂停'));
        await tester.pump();
      }
      native.emitFailure('hardware decode failed');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(native.opens.last.media.start, const Duration(seconds: 73));
      expect(native.opens.last.media.uri, _videoUrl);
      expect(native.playCalls, paused ? 0 : 1);
      expect(
        find.byTooltip(paused ? '播放' : '暂停').hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'error bursts cause one retry and a later failure shows existing actions',
    (tester) async {
      final native = _NativePlayerStub()..stopGate = Completer<void>();
      final harness = _ScreenHarness([native]);
      await _mount(tester, harness);
      native.emitFailure('first error');
      native.emitFailure('second error');
      await tester.pump();
      await tester.pump();
      expect(find.text('播放异常，正在尝试兼容模式'), findsOneWidget);
      native.emitFailure('late original error');
      await tester.pump();
      native.stopGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(native.opens, hasLength(2));
      expect(native.events.where((event) => event == 'hwdec:no'), hasLength(1));

      native.emitFailure('software decode also failed');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(native.opens, hasLength(2));
      expect(find.byKey(const ValueKey('mv-video-error')), findsOneWidget);
      expect(find.text('重试').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mv-player-alternate-engine')).hitTestable(),
        findsOneWidget,
      );
    },
  );

  testWidgets('compatibility failure permits an explicit fresh retry', (
    tester,
  ) async {
    final first = _NativePlayerStub()
      ..firstOpenError = StateError('hardware failed')
      ..hwdecError = StateError('software unavailable');
    final next = _NativePlayerStub();
    final harness = _ScreenHarness([first, next]);
    await _mount(tester, harness);
    expect(find.byKey(const ValueKey('mv-video-error')), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await _flushStreamCancellation(tester);
    await tester.pump(const Duration(milliseconds: 250));
    expect(first.disposeCalls, 1, reason: first.events.join(', '));
    expect(harness.modes, [VideoPlayerMode.mpv, VideoPlayerMode.mpv]);
    expect(next.opens, hasLength(1));
    expect(next.properties, isNot(contains('hwdec')));
  });

  for (final scenario in ['other platform', 'other system', 'Exo only']) {
    testWidgets(
      '$scenario retains its existing failure behavior',
      (tester) async {
        final native = _NativePlayerStub()
          ..firstOpenError = StateError('failed');
        final harness = _ScreenHarness(
          [native],
          platform: scenario == 'other platform'
              ? MusicPlatform.netease
              : MusicPlatform.qq,
          mode: scenario == 'Exo only'
              ? VideoPlayerMode.exo
              : VideoPlayerMode.mpv,
        );
        await _mount(tester, harness);
        expect(native.opens, hasLength(1));
        expect(native.properties, isNot(contains('hwdec')));
        expect(find.byKey(const ValueKey('mv-video-error')), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(
        scenario == 'other system'
            ? TargetPlatform.iOS
            : TargetPlatform.android,
      ),
    );
  }

  testWidgets('leaving during recovery prevents late playback and closes once', (
    tester,
  ) async {
    final native = _NativePlayerStub()..hwdecGate = Completer<void>();
    final harness = _ScreenHarness([native]);
    await _mount(tester, harness);
    native.emitFailure('decoder failed');
    await tester.pump();
    await tester.pump();
    expect(find.text('播放异常，正在尝试兼容模式'), findsOneWidget);
    // Replacing the navigator on user switch also disposes the MV page this way.
    await tester.pumpWidget(const SizedBox.shrink());
    expect(native.disposeCalls, 0);
    native.hwdecGate!.complete();
    await tester.pump();
    await _flushStreamCancellation(tester);
    expect(native.opens, hasLength(1));
    expect(native.playCalls, 0);
    expect(native.disposeCalls, 1);
    expect(native.callsAfterDispose, 0);
    expect(tester.takeException(), isNull);
  });

  for (final stage in ['stop', 'resume']) {
    testWidgets(
      'backgrounding during recovery $stage prevents late auto resume',
      (tester) async {
        final native = _NativePlayerStub();
        final gate = Completer<void>();
        if (stage == 'stop') {
          native.stopGate = gate;
        } else {
          native.playGate = gate;
        }
        final harness = _ScreenHarness([native]);
        await _mount(tester, harness);
        native.emitFailure('decoder failed');
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        gate.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(native.opens, hasLength(2));
        expect(native.playCalls, stage == 'stop' ? 0 : 1);
        expect(native.state.playing, isFalse);
        expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
      },
    );

    testWidgets(
      'timed out recovery $stage stops late playback and keeps error actions usable',
      (tester) async {
        final native = _NativePlayerStub();
        final gate = Completer<void>();
        if (stage == 'stop') {
          native.stopGate = gate;
        } else {
          native.playGate = gate;
        }
        final harness = _ScreenHarness([native]);
        await _mount(tester, harness);
        native.emitFailure('decoder failed');
        await tester.pump();
        await tester.pump(const Duration(seconds: 19));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byKey(const ValueKey('mv-video-error')), findsOneWidget);
        expect(find.text('重试').hitTestable(), findsOneWidget);
        gate.complete();
        await tester.pump();
        expect(native.opens, hasLength(stage == 'stop' ? 1 : 2));
        if (stage == 'stop') {
          expect(native.properties, isNot(contains('hwdec')));
        }
        expect(native.playCalls, stage == 'stop' ? 0 : 1);
        expect(native.state.playing, isFalse);
        expect(find.byKey(const ValueKey('mv-video-error')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a compatibility stream error prevents resuming the failed media',
    (tester) async {
      final native = _NativePlayerStub()..reopenGate = Completer<void>();
      final harness = _ScreenHarness([native]);
      await _mount(tester, harness);
      native.emitFailure('hardware failed');
      await tester.pump();
      expect(native.opens, hasLength(2));
      native.emitFailure('software decoder failed');
      await tester.pump();
      native.reopenGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(native.playCalls, 0);
      expect(find.byKey(const ValueKey('mv-video-error')), findsOneWidget);
      expect(find.text('重试').hitTestable(), findsOneWidget);
    },
  );

  for (final size in [const Size(640, 360), const Size(1280, 800)]) {
    testWidgets('compatibility status and controls remain usable at $size', (
      tester,
    ) async {
      final native = _NativePlayerStub()..stopGate = Completer<void>();
      final harness = _ScreenHarness([native]);
      await _mount(tester, harness, size: const Size(360, 640));
      native.emitFailure('decoder failed');
      await tester.pump();
      tester.view.physicalSize = size;
      await tester.pump();
      expect(find.text('播放异常，正在尝试兼容模式'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mv-player-back')).hitTestable(),
        findsOneWidget,
      );
      native.stopGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byTooltip('暂停').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('快进 10 秒'));
      await tester.pump();
      expect(native.state.position, const Duration(seconds: 10));
      await tester.tap(find.byTooltip('暂停'));
      await tester.pump();
      expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
      native.emitFailure('compatibility also failed');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('重试').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mv-player-alternate-engine')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mv-player-back')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

const _videoUrl = 'https://video.test/qq-1080.mp4?quality=original';
const _userAgent = 'MV test agent';
const _headers = {'User-Agent': _userAgent, 'Referer': 'https://y.qq.com/'};

MpvPlaybackController _controllerFor(_NativePlayerStub native) {
  final controller = _TestMpvController(native, _videoUrl, _headers);
  addTearDown(() async {
    native.finishPending();
    await controller.close();
  });
  return controller;
}

Future<void> _mount(
  WidgetTester tester,
  _ScreenHarness harness, {
  Size size = const Size(640, 360),
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final native in harness.players) {
      native.finishPending();
    }
    await tester.pump();
    await _flushStreamCancellation(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: VideoPlayerScreen(
        url: _videoUrl,
        title: 'QQ MV 测试',
        artist: '测试歌手',
        platform: harness.platform,
        mode: harness.mode,
        controllerFactory: harness.create,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _flushStreamCancellation(WidgetTester tester) async {
  // StreamSubscription.cancel may complete on the real event loop, outside
  // the widget test's fake clock. Drain it before checking native disposal.
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

class _ScreenHarness {
  final List<_NativePlayerStub> players;
  final VideoPlayerMode mode;
  final MusicPlatform platform;
  final List<VideoPlayerMode> modes = [];

  _ScreenHarness(
    this.players, {
    this.mode = VideoPlayerMode.mpv,
    this.platform = MusicPlatform.qq,
  });

  MvPlaybackController create({
    required VideoPlayerMode mode,
    required String url,
    required Map<String, String> headers,
    String? audioUrl,
  }) {
    final native = players[modes.length];
    modes.add(mode);
    return _TestMpvController(native, url, headers);
  }
}

class _TestMpvController extends MpvPlaybackController {
  _TestMpvController(_NativePlayerStub native, super.url, super.headers)
    : super.withPlayer(
        player: media_kit.Player(platformPlayer: native),
        videoController: _VideoControllerStub(),
      );

  @override
  Widget buildSurface(Key key) => SizedBox(key: key);
}

class _VideoControllerStub extends Fake
    implements media_kit_video.VideoController {}

class _PlayerStreams extends media_kit.PlatformPlayer {
  _PlayerStreams()
    : super(configuration: const media_kit.PlayerConfiguration());

  void emitFailure(String message) => errorController.add(message);
  void emitPlaying(bool playing) => playingController.add(playing);
  void emitPosition(Duration position) => positionController.add(position);
}

class _NativePlayerStub extends Fake implements media_kit.NativePlayer {
  final _streams = _PlayerStreams();

  @override
  media_kit.PlayerState get state => _streams.state;

  @override
  set state(media_kit.PlayerState value) => _streams.state = value;

  @override
  media_kit.PlayerStream get stream => _streams.stream;

  final events = <String>[];
  final properties = <String, String>{};
  final opens = <({media_kit.Media media, bool play})>[];
  int disposeCalls = 0;
  int playCalls = 0;
  int callsAfterDispose = 0;
  @override
  bool disposed = false;
  Completer<void>? firstOpenGate;
  Completer<void>? reopenGate;
  Completer<void>? stopGate;
  Completer<void>? hwdecGate;
  Completer<void>? userAgentGate;
  Completer<void>? playGate;
  Object? firstOpenError;
  Object? hwdecError;

  void _checkAlive() {
    if (disposed) {
      callsAfterDispose++;
      throw StateError('native call after dispose');
    }
  }

  void emitFailure(String message) => _streams.emitFailure(message);

  void updatePosition(Duration position) {
    state = state.copyWith(position: position);
    _streams.emitPosition(position);
  }

  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {
    _checkAlive();
    events.add('$property:$value');
    if (property == 'user-agent') await userAgentGate?.future;
    if (property == 'hwdec') {
      await hwdecGate?.future;
      if (hwdecError != null) throw hwdecError!;
    }
    _checkAlive();
    properties[property] = value;
  }

  @override
  Future<void> open(
    media_kit.Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) async {
    _checkAlive();
    final media = playable as media_kit.Media;
    opens.add((media: media, play: play));
    final index = opens.length;
    events.add('open:$index');
    if (index == 1) {
      await firstOpenGate?.future;
      if (firstOpenError != null) throw firstOpenError!;
    } else {
      await reopenGate?.future;
    }
    _checkAlive();
    state = state.copyWith(
      playing: play,
      position: media.start ?? Duration.zero,
      duration: const Duration(minutes: 4),
    );
    _streams.emitPlaying(play);
  }

  @override
  Future<void> stop({
    bool open = false,
    bool notify = true,
    bool synchronized = true,
  }) async {
    _checkAlive();
    events.add('stop');
    await stopGate?.future;
    _checkAlive();
    state = state.copyWith(playing: false, position: Duration.zero);
    _streams.emitPlaying(false);
  }

  @override
  Future<void> play({bool synchronized = true}) async {
    _checkAlive();
    events.add('play');
    playCalls++;
    await playGate?.future;
    _checkAlive();
    state = state.copyWith(playing: true);
    _streams.emitPlaying(true);
  }

  @override
  Future<void> pause({bool synchronized = true}) async {
    _checkAlive();
    events.add('pause');
    state = state.copyWith(playing: false);
    _streams.emitPlaying(false);
  }

  @override
  Future<void> seek(Duration position, {bool synchronized = true}) async {
    _checkAlive();
    updatePosition(position);
  }

  @override
  Future<void> dispose({bool synchronized = true}) async {
    _checkAlive();
    disposeCalls++;
    disposed = true;
    events.add('dispose');
    await _streams.dispose();
  }

  void finishPending() {
    for (final gate in [
      firstOpenGate,
      reopenGate,
      stopGate,
      hwdecGate,
      userAgentGate,
      playGate,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
  }
}
