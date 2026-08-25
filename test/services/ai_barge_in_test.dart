import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/services/ai_barge_in.dart';
import 'package:music_player_app/services/ai_voice_service.dart';

void main() {
  test('voice gate ignores warmup noise and single transients', () {
    final gate = AiBargeInVoiceGate(
      sampleRate: 1000,
      warmup: const Duration(milliseconds: 100),
      requiredSpeech: const Duration(milliseconds: 100),
    );

    expect(gate.accept(Float32List.fromList(List.filled(100, 0.01))), isFalse);
    expect(gate.accept(Float32List.fromList(List.filled(20, 0.08))), isFalse);
    expect(gate.triggered, isFalse);
    expect(gate.accept(Float32List.fromList(List.filled(100, 0.08))), isTrue);
    expect(gate.triggered, isTrue);
  });

  test('ring buffer remains bounded and preserves newest PCM order', () {
    final buffer = AiPcmRingBuffer(capacityBytes: 8);
    buffer.add(Uint8List.fromList([1, 2, 3]));
    buffer.add(Uint8List.fromList([4, 5, 6, 7, 8, 9]));
    expect(buffer.length, 8);
    expect(buffer.snapshot(), Uint8List.fromList([2, 3, 4, 5, 6, 7, 8, 9]));
    buffer.add(Uint8List.fromList(List.generate(20, (index) => index + 10)));
    expect(buffer.length, 8);
    expect(buffer.snapshot(maxBytes: 3), Uint8List.fromList([27, 28, 29]));
  });

  test('barge-in monitor triggers once and releases capture on stop', () async {
    final capture = _FakeCapture();
    var detections = 0;
    final monitor = AiBargeInMonitor(captureStarter: () async => capture);
    addTearDown(monitor.dispose);

    expect(
      await monitor.start(() async {
        detections++;
      }),
      isTrue,
    );
    capture.emit(_pcm(0.01, 8960));
    capture.emit(_pcm(0.08, 1600));
    await Future<void>.delayed(Duration.zero);

    expect(detections, 1);
    final preroll = await monitor.stop();
    expect(preroll, isNotEmpty);
    expect(preroll.length, lessThanOrEqualTo(16000 * 2 * 240 ~/ 1000));
    expect(capture.cancelCalls, 1);
    expect(capture.disposeCalls, 1);
    expect(monitor.active, isFalse);
  });

  test('monitor dispose cancels a late capture start', () async {
    final capture = _FakeCapture();
    final started = Completer<AiAudioCapture>();
    final starterInvoked = Completer<void>();
    final monitor = AiBargeInMonitor(
      captureStarter: () {
        starterInvoked.complete();
        return started.future;
      },
    );

    final starting = monitor.start(() async {});
    await starterInvoked.future;
    final disposing = monitor.dispose();
    started.complete(capture);

    expect(await starting, isFalse);
    await disposing;
    expect(capture.cancelCalls, 1);
    expect(capture.disposeCalls, 1);
  });
}

Uint8List _pcm(double amplitude, int samples) {
  final bytes = Uint8List(samples * 2);
  final value = (amplitude * 32767).round();
  final data = ByteData.sublistView(bytes);
  for (var index = 0; index < samples; index++) {
    data.setInt16(index * 2, value, Endian.little);
  }
  return bytes;
}

class _FakeCapture implements AiAudioCapture {
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();
  int cancelCalls = 0;
  int disposeCalls = 0;

  @override
  Stream<Uint8List> get audioStream => _controller.stream;

  @override
  int get channelCount => 1;

  @override
  int get mixDivisor => 1;

  @override
  String get description => 'fake-barge-in';

  void emit(Uint8List bytes) => _controller.add(bytes);

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _controller.close();
  }
}
