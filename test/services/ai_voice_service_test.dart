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

  test('recovers a post-handshake Doubao routing rejection', () async {
    final gateway = _FakeDoubaoGateway(
      rejectFirstAudioSession: true,
      finalResultOnAudio: '恢复后的识别结果',
    );
    final capture = _FakeAudioCapture();
    final recognizer = DoubaoImeSpeechRecognizer(
      client: gateway,
      captureStarter: () async => capture,
    );
    final results = <(String, bool)>[];
    final done = Completer<void>();

    addTearDown(recognizer.dispose);
    expect(
      await recognizer.initialize(
        onError: (_) {},
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
    await Future<void>.delayed(Duration.zero);
    capture.emit(Uint8List(640));
    await recognizer.stop();
    await done.future.timeout(const Duration(seconds: 2));

    expect(gateway.openSessionCalls, 2);
    expect(results, [('恢复后的识别结果', true)]);
  });

  test(
    'stop wins while Doubao routing recovery is opening a replacement',
    () async {
      final gateway = _RecoveryRaceDoubaoGateway();
      final capture = _FakeAudioCapture();
      final recognizer = DoubaoImeSpeechRecognizer(
        client: gateway,
        captureStarter: () async => capture,
      );
      final done = Completer<void>();

      addTearDown(recognizer.dispose);
      await recognizer.initialize(
        onError: (_) {},
        onStatus: (status) {
          if (status == 'done' && !done.isCompleted) done.complete();
        },
      );
      await recognizer.listen((_, _) {});
      capture.emit(Uint8List(640));
      await gateway.replacementStarted.future.timeout(
        const Duration(seconds: 2),
      );

      final stopping = recognizer.stop();
      final replacement = _FakeDoubaoConnection();
      gateway.replacementResult.complete(replacement);

      await stopping.timeout(const Duration(seconds: 2));
      await done.future.timeout(const Duration(seconds: 2));

      expect(gateway.openSessionCalls, 2);
      expect(gateway.connections.single.closeCalls, 1);
      expect(replacement.closeCalls, 1);
    },
  );

  test(
    'cancelling while Doubao session opens closes the late session',
    () async {
      final gateway = _DelayedDoubaoGateway();
      final recognizer = DoubaoImeSpeechRecognizer(
        client: gateway,
        captureStarter: () async => _FakeAudioCapture(),
      );
      addTearDown(recognizer.dispose);
      await recognizer.initialize(onError: (_) {}, onStatus: (_) {});

      final listening = recognizer.listen((_, _) {});
      await gateway.openStarted.future.timeout(const Duration(seconds: 2));
      final cancelling = recognizer.cancel();
      final connection = _FakeDoubaoConnection();
      gateway.openResult.complete(connection);
      await Future.wait([
        listening,
        cancelling,
      ]).timeout(const Duration(seconds: 5));

      expect(connection.closeCalls, 1);
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

  test(
    'finishes a Doubao session after the provider emits an endpoint final',
    () async {
      final gateway = _FakeDoubaoGateway(
        finalResultOnAudio: '端点初步结果',
        finalResultOnFinish: '端点后的三遍修正结果',
      );
      final capture = _FakeAudioCapture();
      final recognizer = DoubaoImeSpeechRecognizer(
        client: gateway,
        captureStarter: () async => capture,
      );
      final results = <(String, bool)>[];
      final done = Completer<void>();

      addTearDown(recognizer.dispose);
      expect(
        await recognizer.initialize(
          onError: (_) {},
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

      await done.future.timeout(const Duration(seconds: 2));

      expect(results, [('端点后的三遍修正结果', true)]);
      expect(capture.stopCalls, 1);
      expect(capture.disposeCalls, 1);
      expect(gateway.connections.single.finishCalls, 1);
      expect(gateway.connections.single.closeCalls, 1);
    },
  );

  test(
    'emits a pending final when the provider closes before SessionFinished',
    () async {
      final gateway = _FakeDoubaoGateway(
        finalResultOnAudio: '端点结果',
        finishWithoutSessionFinished: true,
      );
      final capture = _FakeAudioCapture();
      final recognizer = DoubaoImeSpeechRecognizer(
        client: gateway,
        captureStarter: () async => capture,
      );
      final results = <(String, bool)>[];
      final done = Completer<void>();

      addTearDown(recognizer.dispose);
      await recognizer.initialize(
        onError: (_) {},
        onStatus: (status) {
          if (status == 'done' && !done.isCompleted) done.complete();
        },
      );
      await recognizer.listen((text, isFinal) {
        results.add((text, isFinal));
      });
      capture.emit(Uint8List(640));

      await done.future.timeout(const Duration(seconds: 2));

      expect(results, [('端点结果', true)]);
      expect(gateway.connections.single.finishCalls, 1);
      expect(gateway.connections.single.closeCalls, 1);
    },
  );
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
  final bool rejectFirstAudioSession;
  final String? finalResultOnAudio;
  final String? finalResultOnFinish;
  final bool finishWithoutSessionFinished;
  final List<_FakeDoubaoConnection> connections = [];
  int openSessionCalls = 0;
  int resetCalls = 0;
  int refreshCalls = 0;
  int disposeCalls = 0;

  _FakeDoubaoGateway({
    this.rejectFirstAudioSession = false,
    this.finalResultOnAudio,
    this.finalResultOnFinish,
    this.finishWithoutSessionFinished = false,
  });

  @override
  Future<void> prepare() async {}

  @override
  Future<DoubaoImeAsrConnection> openSession() async {
    openSessionCalls++;
    final connection = _FakeDoubaoConnection(
      responseAfterFirstFrame: rejectFirstAudioSession && openSessionCalls == 1
          ? const DoubaoImeAsrResponse(
              kind: DoubaoImeAsrResponseKind.error,
              error: 'service discovery failure',
            )
          : finalResultOnAudio != null
          ? DoubaoImeAsrResponse(
              kind: DoubaoImeAsrResponseKind.finalResult,
              text: finalResultOnAudio!,
            )
          : null,
      responseOnFinish: finalResultOnFinish == null
          ? null
          : DoubaoImeAsrResponse(
              kind: DoubaoImeAsrResponseKind.finalResult,
              text: finalResultOnFinish!,
            ),
      finishWithoutSessionFinished: finishWithoutSessionFinished,
    );
    connections.add(connection);
    return connection;
  }

  @override
  Future<void> resetCredentials() async {
    resetCalls++;
  }

  @override
  Future<void> refreshToken() async {
    refreshCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    for (final connection in connections) {
      await connection.close();
    }
  }
}

class _DelayedDoubaoGateway implements DoubaoImeAsrGateway {
  final Completer<void> openStarted = Completer<void>();
  final Completer<DoubaoImeAsrConnection> openResult =
      Completer<DoubaoImeAsrConnection>();

  @override
  Future<void> prepare() async {}

  @override
  Future<DoubaoImeAsrConnection> openSession() {
    if (!openStarted.isCompleted) openStarted.complete();
    return openResult.future;
  }

  @override
  Future<void> refreshToken() async {}

  @override
  Future<void> resetCredentials() async {}

  @override
  Future<void> dispose() async {}
}

class _RecoveryRaceDoubaoGateway implements DoubaoImeAsrGateway {
  final Completer<void> replacementStarted = Completer<void>();
  final Completer<DoubaoImeAsrConnection> replacementResult =
      Completer<DoubaoImeAsrConnection>();
  final List<_FakeDoubaoConnection> connections = [];
  int openSessionCalls = 0;

  @override
  Future<void> prepare() async {}

  @override
  Future<DoubaoImeAsrConnection> openSession() {
    openSessionCalls++;
    if (openSessionCalls == 1) {
      final connection = _FakeDoubaoConnection(
        responseAfterFirstFrame: const DoubaoImeAsrResponse(
          kind: DoubaoImeAsrResponseKind.error,
          error: 'service discovery failure',
        ),
      );
      connections.add(connection);
      return Future<DoubaoImeAsrConnection>.value(connection);
    }
    if (!replacementStarted.isCompleted) replacementStarted.complete();
    return replacementResult.future;
  }

  @override
  Future<void> refreshToken() async {}

  @override
  Future<void> resetCredentials() async {}

  @override
  Future<void> dispose() async {
    for (final connection in connections) {
      await connection.close();
    }
  }
}

class _FakeDoubaoConnection implements DoubaoImeAsrConnection {
  final DoubaoImeAsrResponse? responseAfterFirstFrame;
  final DoubaoImeAsrResponse? responseOnFinish;
  final bool finishWithoutSessionFinished;
  final StreamController<DoubaoImeAsrResponse?> _responses =
      StreamController<DoubaoImeAsrResponse?>.broadcast();
  StreamIterator<DoubaoImeAsrResponse?>? _iterator;
  bool _iteratorStarted = false;
  bool _responseSent = false;
  bool _closed = false;
  int closeCalls = 0;
  int finishCalls = 0;

  _FakeDoubaoConnection({
    this.responseAfterFirstFrame,
    this.responseOnFinish,
    this.finishWithoutSessionFinished = false,
  });

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
  void finish() {
    if (_closed) return;
    finishCalls++;
    final response = responseOnFinish ?? responseAfterFirstFrame;
    if (response != null) {
      _responses.add(response);
    }
    if (!finishWithoutSessionFinished) {
      _responses.add(
        const DoubaoImeAsrResponse(
          kind: DoubaoImeAsrResponseKind.sessionFinished,
        ),
      );
    } else {
      _responses.add(null);
    }
  }

  @override
  Future<DoubaoImeAsrResponse?> nextResponse() async {
    if (_closed) return null;
    _iteratorStarted = true;
    final iterator = _iterator ??= StreamIterator<DoubaoImeAsrResponse?>(
      _responses.stream,
    );
    return await iterator.moveNext() ? iterator.current : null;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closeCalls++;
    if (!_iteratorStarted) {
      await _responses.close();
      return;
    }
    // Wake a pending nextResponse() before cancelling the iterator. Closing
    // the controller first waits for the iterator to cancel, while cancelling
    // first waits for a response, which can deadlock this in-memory fake.
    if (!_responses.isClosed) _responses.add(null);
    await _iterator?.cancel();
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
