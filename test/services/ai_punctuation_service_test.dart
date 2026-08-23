import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/services/ai_punctuation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('music_player/ai_model');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'returns the original transcript when the model is unavailable',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            throw PlatformException(code: 'model_unavailable');
          });
      final service = PlatformAiPunctuationService();
      addTearDown(service.dispose);

      expect(await service.addPunctuation('  播放夜曲  '), '播放夜曲');
    },
  );

  test(
    'release cancels model initialization that is still preparing',
    () async {
      final prepareStarted = Completer<void>();
      final preparedPaths = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            if (!prepareStarted.isCompleted) prepareStarted.complete();
            return preparedPaths.future;
          });
      final service = PlatformAiPunctuationService();
      addTearDown(service.dispose);

      final punctuation = service.addPunctuation('我想听歌');
      await prepareStarted.future;
      final release = service.releaseIdleResources();
      preparedPaths.complete(<String, String>{'model': 'unused.onnx'});

      await release;
      expect(await punctuation, '我想听歌');
    },
  );
}
