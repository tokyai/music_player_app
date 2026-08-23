import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/ai_assistant.dart';
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

  test('forwards the selected offline model to the recognizer', () {
    final recognizer = _FakeRecognizer();
    final engine = PlatformAiSpeechEngine(
      speech: recognizer,
      microphonePermission: _FakeMicrophonePermission(granted: true),
      audioFocus: _FakeAudioFocus(),
    );

    engine.setVoiceModel(AiVoiceModelKind.paraformerBilingual);

    expect(recognizer.voiceModel, AiVoiceModelKind.paraformerBilingual);
  });

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

class _FakeRecognizer implements AiSpeechRecognizer, AiVoiceModelSelector {
  void Function(String)? _onError;
  void Function(String)? _onStatus;
  int initializeCalls = 0;
  int listenCalls = 0;
  int cancelCalls = 0;
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

  void emitStatus(String status) => _onStatus?.call(status);

  // Keep the error callback reachable for future platform error coverage.
  void emitError(String error) => _onError?.call(error);
}
