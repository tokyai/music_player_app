import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/ai_assistant.dart';
import 'package:music_player_app/services/doubao_ime_asr_client.dart';
import 'package:music_player_app/services/ai_voice_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('enables homophone replacement only with complete resources', () {
    final complete = aiHomophoneConfigFromPaths(const {
      'lexicon': '/models/lexicon.txt',
      'rules': '/models/replace.fst',
    });
    final incomplete = aiHomophoneConfigFromPaths(const {
      'lexicon': '/models/lexicon.txt',
    });
    final blank = aiHomophoneConfigFromPaths(const {
      'lexicon': ' ',
      'rules': '/models/replace.fst',
    });

    expect(complete.lexicon, '/models/lexicon.txt');
    expect(complete.ruleFsts, '/models/replace.fst');
    expect(incomplete.lexicon, isEmpty);
    expect(incomplete.ruleFsts, isEmpty);
    expect(blank.lexicon, isEmpty);
    expect(blank.ruleFsts, isEmpty);
  });

  test(
    'does not initialize recognition without microphone permission',
    () async {
      final permission = _FakeMicrophonePermission(granted: false);
      final recognizer = _FakeRecognizer();
      final focus = _FakeAudioFocus();
      final errors = <String>[];
      final engine = PlatformAiSpeechEngine(
        speech: recognizer,
        microphonePermission: permission,
        audioFocus: focus,
      );

      expect(
        await engine.initialize(onError: errors.add, onStatus: (_) {}),
        isFalse,
      );
      expect(permission.calls, 1);
      expect(recognizer.initializeCalls, 0);
      expect(errors, ['麦克风权限未授予']);
    },
  );

  test('holds audio focus for listen and releases it on cancel', () async {
    final recognizer = _FakeRecognizer();
    final focus = _FakeAudioFocus();
    final engine = PlatformAiSpeechEngine(
      speech: recognizer,
      microphonePermission: _FakeMicrophonePermission(granted: true),
      audioFocus: focus,
    );
    await engine.initialize(onError: (_) {}, onStatus: (_) {});

    await engine.listen((_, _) {});
    expect(focus.requestCalls, 1);
    expect(recognizer.listenCalls, 1);
    expect(focus.events, ['request']);

    await engine.cancel();
    expect(recognizer.cancelCalls, 1);
    expect(focus.abandonCalls, 1);
    expect(focus.events, ['request', 'abandon']);
  });

  test('releases focus when the recognizer reports done', () async {
    final recognizer = _FakeRecognizer();
    final focus = _FakeAudioFocus();
    final engine = PlatformAiSpeechEngine(
      speech: recognizer,
      microphonePermission: _FakeMicrophonePermission(granted: true),
      audioFocus: focus,
    );
    await engine.initialize(onError: (_) {}, onStatus: (_) {});
    await engine.listen((_, _) {});

    recognizer.emitStatus('done');
    await Future<void>.delayed(Duration.zero);

    expect(focus.abandonCalls, 1);

    await engine.listen((_, _) {});
    expect(focus.events, ['request', 'abandon', 'request']);
  });

  test('cancels recognition when audio focus is lost', () async {
    final recognizer = _FakeRecognizer();
    final focus = _FakeAudioFocus();
    final errors = <String>[];
    final engine = PlatformAiSpeechEngine(
      speech: recognizer,
      microphonePermission: _FakeMicrophonePermission(granted: true),
      audioFocus: focus,
    );
    await engine.initialize(onError: errors.add, onStatus: (_) {});
    await engine.listen((_, _) {});

    focus.emitFocusLost();
    await Future<void>.delayed(Duration.zero);

    expect(recognizer.cancelCalls, 1);
    expect(focus.abandonCalls, 1);
    expect(errors.single, contains('error_audio_focus_lost'));
  });

  test('forwards the selected voice engine to the recognizer', () {
    final recognizer = _FakeRecognizer();
    final engine = PlatformAiSpeechEngine(
      speech: recognizer,
      microphonePermission: _FakeMicrophonePermission(granted: true),
      audioFocus: _FakeAudioFocus(),
    );

    engine.setVoiceModel(AiVoiceModelKind.doubaoIme);

    expect(recognizer.voiceModel, AiVoiceModelKind.doubaoIme);
  });

  test(
    'preloads Zipformer without permission and retains it while idle',
    () async {
      final permission = _FakeMicrophonePermission(granted: false);
      final recognizer = _FakeRecognizer();
      final engine = PlatformAiSpeechEngine(
        speech: recognizer,
        microphonePermission: permission,
        audioFocus: _FakeAudioFocus(),
      );
      engine.setRetainIdleModel(true);

      expect(
        await engine.preloadModel(AiVoiceModelKind.zipformerChinese),
        isTrue,
      );
      expect(permission.calls, 0);
      expect(recognizer.initializeCalls, 1);

      await engine.releaseIdleResources();
      expect(recognizer.releaseIdleCalls, 0);

      await engine.releasePreloadedModel();
      expect(recognizer.releaseIdleCalls, 1);
    },
  );

  test('retries normal initialization after a failed preload', () async {
    final permission = _FakeMicrophonePermission(granted: true);
    final recognizer = _FailFirstRecognizer();
    final engine = PlatformAiSpeechEngine(
      speech: recognizer,
      microphonePermission: permission,
      audioFocus: _FakeAudioFocus(),
    );

    expect(
      await engine.preloadModel(AiVoiceModelKind.zipformerChinese),
      isFalse,
    );
    expect(permission.calls, 0);

    expect(await engine.initialize(onError: (_) {}, onStatus: (_) {}), isTrue);
    expect(permission.calls, 1);
    expect(recognizer.initializeCalls, 2);
  });

  test('does not preload system or online voice engines', () async {
    final recognizer = _FakeRecognizer();
    final engine = PlatformAiSpeechEngine(
      speech: recognizer,
      microphonePermission: _FakeMicrophonePermission(granted: true),
      audioFocus: _FakeAudioFocus(),
    );

    expect(await engine.preloadModel(AiVoiceModelKind.systemSpeech), isFalse);
    expect(await engine.preloadModel(AiVoiceModelKind.doubaoIme), isFalse);
    expect(recognizer.initializeCalls, 0);
  });

  test(
    'routes all three voice engine choices and disposes replaced engines',
    () async {
      final zipformer = _FakeRecognizer();
      final system = _FakeRecognizer();
      final doubao = _FakeRecognizer();
      final router = AiSpeechRecognizerRouter(
        zipformerFactory: () => zipformer,
        systemFactory: () => system,
        doubaoFactory: () => doubao,
      );

      for (final entry in [
        (AiVoiceModelKind.zipformerChinese, zipformer),
        (AiVoiceModelKind.systemSpeech, system),
        (AiVoiceModelKind.doubaoIme, doubao),
      ]) {
        router.setVoiceModel(entry.$1);
        expect(
          await router.initialize(onError: (_) {}, onStatus: (_) {}),
          isTrue,
        );
        expect(entry.$2.initializeCalls, 1);
      }

      expect(zipformer.disposeCalls, 1);
      expect(system.disposeCalls, 1);
      await router.dispose();
      await router.dispose();
      expect(doubao.disposeCalls, 1);
    },
  );

  test(
    'retries the selected engine after an in-flight preload changes',
    () async {
      final zipformer = _DelayedRecognizer();
      final system = _FakeRecognizer();
      final router = AiSpeechRecognizerRouter(
        zipformerFactory: () => zipformer,
        systemFactory: () => system,
        doubaoFactory: _FakeRecognizer.new,
      );
      router.setVoiceModel(AiVoiceModelKind.zipformerChinese);
      final preload = router.initialize(onError: (_) {}, onStatus: (_) {});
      await zipformer.started.future;

      router.setVoiceModel(AiVoiceModelKind.systemSpeech);
      final selected = router.initialize(onError: (_) {}, onStatus: (_) {});
      zipformer.finish.complete(true);

      expect(await preload, isFalse);
      expect(await selected, isTrue);
      expect(zipformer.disposeCalls, 1);
      expect(system.initializeCalls, 1);
    },
  );

  test('contains recognizer callbacks that throw', () async {
    final recognizer = _FakeRecognizer();
    final engine = PlatformAiSpeechEngine(
      speech: recognizer,
      microphonePermission: _FakeMicrophonePermission(granted: true),
      audioFocus: _FakeAudioFocus(),
    );

    await engine.initialize(
      onError: (_) => throw StateError('callback error'),
      onStatus: (_) => throw StateError('callback error'),
    );

    expect(() => recognizer.emitError('native error'), returnsNormally);
    expect(() => recognizer.emitStatus('done'), returnsNormally);
  });

  test(
    'replaces rejected Doubao credentials once and keeps recognizing',
    () async {
      final gateway = _FakeDoubaoGateway(rejectFirstSession: true);
      final capture = _FakeAudioCapture();
      final recognizer = DoubaoImeSpeechRecognizer(
        client: gateway,
        captureStarter: () async => capture,
      );
      final results = <(String, bool)>[];
      final errors = <String>[];
      final done = Completer<void>();

      expect(
        await recognizer.initialize(
          onError: errors.add,
          onStatus: (status) {
            if (status == 'done' && !done.isCompleted) done.complete();
          },
        ),
        isTrue,
      );
      await recognizer.listen((text, isFinal) {
        results.add((text, isFinal));
      });
      capture.emit(Uint8List(640));
      await gateway.secondSessionOpened.future.timeout(
        const Duration(seconds: 2),
      );
      capture.emit(Uint8List(640));
      await done.future.timeout(const Duration(seconds: 2));

      expect(gateway.resetCalls, 1);
      expect(gateway.openSessionCalls, 2);
      expect(results, [('豆包识别成功', true)]);
      expect(errors, isEmpty);
      expect(capture.stopCalls, 1);
      expect(capture.disposeCalls, 1);
      expect(
        gateway.connections.every((connection) => connection.closeCalls == 1),
        isTrue,
      );

      await recognizer.dispose();
      await recognizer.dispose();
      expect(gateway.disposeCalls, 1);
    },
  );

  test('contains repeated Doubao cancel and dispose operations', () async {
    final gateway = _FakeDoubaoGateway();
    final capture = _FakeAudioCapture();
    final recognizer = DoubaoImeSpeechRecognizer(
      client: gateway,
      captureStarter: () async => capture,
    );
    await recognizer.initialize(onError: (_) {}, onStatus: (_) {});
    await recognizer.listen((_, _) {});

    await Future.wait([recognizer.cancel(), recognizer.cancel()]);
    expect(capture.cancelCalls, 1);
    expect(capture.disposeCalls, 1);
    expect(gateway.connections.single.closeCalls, 1);

    await Future.wait([recognizer.dispose(), recognizer.dispose()]);
    expect(gateway.disposeCalls, 1);
  });
}

class _FakeMicrophonePermission implements AiMicrophonePermission {
  final bool granted;
  int calls = 0;

  _FakeMicrophonePermission({required this.granted});

  @override
  Future<bool> ensureGranted() async {
    calls++;
    return granted;
  }
}

class _FakeAudioFocus implements AiAudioFocusCoordinator {
  final List<String> events = [];
  void Function()? _onFocusLost;
  int requestCalls = 0;
  int abandonCalls = 0;

  @override
  void setOnFocusLost(void Function()? callback) => _onFocusLost = callback;

  @override
  Future<bool> request() async {
    requestCalls++;
    events.add('request');
    return true;
  }

  @override
  Future<void> abandon() async {
    abandonCalls++;
    events.add('abandon');
  }

  void emitFocusLost() => _onFocusLost?.call();
}

class _FakeRecognizer
    implements
        AiSpeechRecognizer,
        AiVoiceModelSelector,
        AiSpeechResourceOwner,
        AiSpeechIdleResourceOwner {
  void Function(String)? _onError;
  void Function(String)? _onStatus;
  int initializeCalls = 0;
  int listenCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;
  int releaseIdleCalls = 0;
  AiVoiceModelKind? voiceModel;

  @override
  void setVoiceModel(AiVoiceModelKind model) => voiceModel = model;

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async {
    initializeCalls++;
    _onError = onError;
    _onStatus = onStatus;
    return true;
  }

  @override
  Future<void> listen(AiSpeechResultCallback onResult) async {
    listenCalls++;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  @override
  Future<void> releaseIdleResources() async {
    releaseIdleCalls++;
  }

  void emitStatus(String status) => _onStatus?.call(status);

  // Keep the error callback reachable for future platform error coverage.
  void emitError(String error) => _onError?.call(error);
}

class _DelayedRecognizer extends _FakeRecognizer {
  final Completer<void> started = Completer<void>();
  final Completer<bool> finish = Completer<bool>();

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async {
    initializeCalls++;
    if (!started.isCompleted) started.complete();
    return finish.future;
  }
}

class _FailFirstRecognizer extends _FakeRecognizer {
  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async {
    initializeCalls++;
    return initializeCalls > 1;
  }
}

class _FakeDoubaoGateway implements DoubaoImeAsrGateway {
  final bool rejectFirstSession;
  final List<_FakeDoubaoConnection> connections = [];
  final Completer<void> secondSessionOpened = Completer<void>();
  int openSessionCalls = 0;
  int resetCalls = 0;
  int disposeCalls = 0;

  _FakeDoubaoGateway({this.rejectFirstSession = false});

  @override
  Future<void> prepare() async {}

  @override
  Future<DoubaoImeAsrConnection> openSession() async {
    openSessionCalls++;
    final shouldReject = rejectFirstSession && openSessionCalls == 1;
    final connection = _FakeDoubaoConnection(
      responseAfterFirstFrame: shouldReject
          ? const DoubaoImeAsrResponse(
              kind: DoubaoImeAsrResponseKind.error,
              error: 'service discovery failure',
            )
          : rejectFirstSession
          ? const DoubaoImeAsrResponse(
              kind: DoubaoImeAsrResponseKind.finalResult,
              text: '豆包识别成功',
            )
          : null,
    );
    connections.add(connection);
    if (openSessionCalls == 2 && !secondSessionOpened.isCompleted) {
      secondSessionOpened.complete();
    }
    return connection;
  }

  @override
  Future<void> resetCredentials() async {
    resetCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    for (final connection in connections) {
      await connection.close();
    }
  }
}

class _FakeDoubaoConnection implements DoubaoImeAsrConnection {
  final DoubaoImeAsrResponse? responseAfterFirstFrame;
  final StreamController<DoubaoImeAsrResponse?> _responses =
      StreamController<DoubaoImeAsrResponse?>();
  late final StreamIterator<DoubaoImeAsrResponse?> _iterator =
      StreamIterator<DoubaoImeAsrResponse?>(_responses.stream);
  bool _responseSent = false;
  bool _closed = false;
  int closeCalls = 0;

  _FakeDoubaoConnection({this.responseAfterFirstFrame});

  @override
  void sendAudio(
    Uint8List bytes, {
    required DoubaoImeAudioFrameState frameState,
    required int timestampMilliseconds,
  }) {
    final response = responseAfterFirstFrame;
    if (_closed || _responseSent || response == null) return;
    _responseSent = true;
    _responses.add(response);
  }

  @override
  void finish() {}

  @override
  Future<DoubaoImeAsrResponse?> nextResponse() async {
    if (_closed) return null;
    return await _iterator.moveNext() ? _iterator.current : null;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closeCalls++;
    await _iterator.cancel();
    await _responses.close();
  }
}

class _FakeAudioCapture implements AiAudioCapture {
  final StreamController<Uint8List> _audio = StreamController<Uint8List>();
  bool _closed = false;
  int stopCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;

  @override
  Stream<Uint8List> get audioStream => _audio.stream;

  @override
  int get channelCount => 1;

  @override
  int get mixDivisor => 1;

  @override
  String get description => 'fake';

  void emit(Uint8List bytes) {
    if (!_closed) _audio.add(bytes);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    await _close();
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    await _close();
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _close();
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await _audio.close();
  }
}
