import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/ai_assistant.dart';
import 'package:music_player_app/services/ai_voice_service.dart';
import 'package:music_player_app/services/voice_input_session.dart';

void main() {
  test(
    'forwards recognition and ignores native callbacks after stop',
    () async {
      final speech = _FakeSpeech();
      final session = VoiceInputSession(
        speech: speech,
        voiceModel: AiVoiceModelKind.zipformerChinese,
      );
      final results = <String>[];
      final statuses = <String>[];
      final errors = <String>[];

      expect(
        await session.start(
          onResult: (text, isFinal) => results.add('$text:$isFinal'),
          onError: errors.add,
          onStatus: statuses.add,
        ),
        isTrue,
      );
      expect(speech.voiceModel, AiVoiceModelKind.zipformerChinese);
      expect(session.isListening, isTrue);

      speech.emitResult('七里', false);
      speech.finalResultOnStop = '七里香';
      await session.stop();
      speech.emitResult('迟到结果', true);
      speech.emitStatus('done');
      speech.emitError('迟到错误');

      expect(results, ['七里:false', '七里香:true']);
      expect(statuses, isEmpty);
      expect(errors, isEmpty);
      expect(session.isListening, isFalse);

      await session.close();
      await session.close();
      expect(session.isClosed, isTrue);
      expect(speech.releaseCalls, 1);
      expect(
        await session.start(
          onResult: (_, _) {},
          onError: (_) {},
          onStatus: (_) {},
        ),
        isFalse,
      );
    },
  );

  test(
    'close during initialization prevents capture and late callbacks',
    () async {
      final initialization = Completer<bool>();
      final speech = _FakeSpeech(initialization: initialization);
      final session = VoiceInputSession(
        speech: speech,
        voiceModel: AiVoiceModelKind.doubaoIme,
      );
      final results = <String>[];
      final statuses = <String>[];
      final errors = <String>[];

      final starting = session.start(
        onResult: (text, _) => results.add(text),
        onError: errors.add,
        onStatus: statuses.add,
      );
      await Future<void>.delayed(Duration.zero);
      final closing = session.close();
      initialization.complete(true);

      expect(await starting, isFalse);
      await closing;
      speech.emitResult('不应出现', true);
      speech.emitStatus('listening');
      speech.emitError('不应出现');

      expect(speech.voiceModel, AiVoiceModelKind.doubaoIme);
      expect(speech.listenCalls, 0);
      expect(speech.cancelCalls, greaterThanOrEqualTo(1));
      expect(speech.releaseCalls, 1);
      expect(results, isEmpty);
      expect(statuses, isEmpty);
      expect(errors, isEmpty);
    },
  );

  test('engine failures use a non-crashing cleanup path', () async {
    final speech = _FakeSpeech(
      listenError: StateError('listen failed'),
      throwOnCancel: true,
      throwOnRelease: true,
    );
    final session = VoiceInputSession(
      speech: speech,
      voiceModel: AiVoiceModelKind.systemSpeech,
    );
    final errors = <String>[];

    expect(
      await session.start(
        onResult: (_, _) {},
        onError: errors.add,
        onStatus: (_) {},
      ),
      isFalse,
    );
    expect(errors, ['listen failed']);
    await expectLater(session.close(), completes);
    expect(session.isClosed, isTrue);
  });

  test('model selector failures are reported without escaping start', () async {
    final speech = _FakeSpeech(throwOnSelect: true);
    final session = VoiceInputSession(
      speech: speech,
      voiceModel: AiVoiceModelKind.zipformerChinese,
    );
    final errors = <String>[];

    expect(
      await session.start(
        onResult: (_, _) {},
        onError: errors.add,
        onStatus: (_) {},
      ),
      isFalse,
    );
    expect(errors, ['select failed']);
    await session.close();
  });
}

class _FakeSpeech
    implements AiSpeechEngine, AiVoiceModelSelector, AiSpeechIdleResourceOwner {
  final Completer<bool>? initialization;
  final Object? listenError;
  final bool throwOnCancel;
  final bool throwOnRelease;
  final bool throwOnSelect;

  AiSpeechResultCallback? _onResult;
  void Function(String message)? _onError;
  void Function(String status)? _onStatus;
  AiVoiceModelKind? voiceModel;
  String? finalResultOnStop;
  int listenCalls = 0;
  int cancelCalls = 0;
  int releaseCalls = 0;

  _FakeSpeech({
    this.initialization,
    this.listenError,
    this.throwOnCancel = false,
    this.throwOnRelease = false,
    this.throwOnSelect = false,
  });

  @override
  void setVoiceModel(AiVoiceModelKind model) {
    if (throwOnSelect) throw StateError('select failed');
    voiceModel = model;
  }

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async {
    _onError = onError;
    _onStatus = onStatus;
    return initialization == null ? true : initialization!.future;
  }

  @override
  Future<void> listen(AiSpeechResultCallback onResult) async {
    listenCalls++;
    _onResult = onResult;
    if (listenError != null) throw listenError!;
  }

  @override
  Future<void> stop() async {
    final result = finalResultOnStop;
    if (result != null) _onResult?.call(result, true);
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (throwOnCancel) throw StateError('cancel failed');
  }

  @override
  Future<void> releaseIdleResources() async {
    releaseCalls++;
    if (throwOnRelease) throw StateError('release failed');
  }

  void emitResult(String text, bool isFinal) => _onResult?.call(text, isFinal);
  void emitStatus(String status) => _onStatus?.call(status);
  void emitError(String message) => _onError?.call(message);
}
