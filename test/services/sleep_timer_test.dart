import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/services/sleep_timer.dart';

void main() {
  testWidgets('timer replaces the old deadline and fires once', (tester) async {
    var now = DateTime(2026);
    var calls = 0;
    final timer = SleepTimer(now: () => now, onElapsed: () async => calls++);
    timer.start(const Duration(minutes: 10));
    timer.start(const Duration(minutes: 2));
    now = now.add(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 1);
    expect(timer.active, isFalse);
    await tester.pump(const Duration(minutes: 20));
    expect(calls, 1);
    timer.dispose();
  });

  testWidgets('track end, cancellation and disposal never leave a ticker', (
    tester,
  ) async {
    var calls = 0;
    final timer = SleepTimer(onElapsed: () async => calls++);
    timer.start(const Duration(minutes: 5));
    timer.stopAfterTrack();
    expect(timer.consumeTrackEnd(), isTrue);
    expect(timer.consumeTrackEnd(), isFalse);
    await tester.pump();
    expect(calls, 1);
    timer.start(const Duration(minutes: 5));
    timer.cancel();
    await tester.pump(const Duration(minutes: 6));
    expect(calls, 1);
    timer.start(const Duration(minutes: 5));
    timer.dispose();
    await tester.pump(const Duration(minutes: 6));
    expect(calls, 1);
  });

  testWidgets('late failing callbacks cannot publish after disposal', (
    tester,
  ) async {
    final pending = Completer<void>();
    final timer = SleepTimer(onElapsed: () => pending.future);
    timer.stopAfterTrack();
    timer.consumeTrackEnd();
    timer.dispose();
    pending.completeError(StateError('device unavailable'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('invalid durations are rejected and remaining is readable', () {
    final timer = SleepTimer(onElapsed: () async {});
    expect(() => timer.start(Duration.zero), throwsArgumentError);
    expect(() => timer.start(const Duration(days: 2)), throwsArgumentError);
    expect(formatSleepRemaining(const Duration(seconds: 61)), '1:01');
    timer.dispose();
  });
}
