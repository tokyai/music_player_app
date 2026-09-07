import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/audio_effects.dart';
import 'package:music_player_app/services/audio_effects_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    messenger.setMockMethodCallHandler(AudioEffectsService.channel, (
      call,
    ) async {
      calls.add(call);
      return {'failures': <String>[]};
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(AudioEffectsService.channel, null);
  });

  test(
    'global settings persist without creating an idle native engine',
    () async {
      final service = AudioEffectsService();
      await service.ready;
      await service.setSettings(
        const AudioEffectsSettings(
          enabled: true,
          equalizerEnabled: true,
        ).copyWith(bands: EqualizerPreset.rock.bands),
      );
      expect(calls, isEmpty);
      final restored = AudioEffectsService();
      await restored.ready;
      expect(restored.settings.enabled, isTrue);
      expect(restored.settings.preset, EqualizerPreset.rock);
      await service.close();
      await restored.close();
    },
  );

  test('malformed or oversized data falls back to original sound', () async {
    for (final raw in [
      jsonEncode({'version': 1, 'bands': []}),
      'x' * 4097,
    ]) {
      SharedPreferences.setMockInitialValues({
        AudioEffectsSettings.preferenceKey: raw,
      });
      final service = AudioEffectsService();
      await service.ready;
      expect(service.settings.enabled, isFalse);
      expect(service.settings.bands, hasLength(10));
      await service.close();
    }
  });

  test('invalid gain never changes the previous valid settings', () async {
    final service = AudioEffectsService();
    await service.ready;
    await expectLater(
      service.setSettings(const AudioEffectsSettings(balance: double.nan)),
      throwsFormatException,
    );
    await expectLater(
      service.setSettings(const AudioEffectsSettings(bands: [0])),
      throwsFormatException,
    );
    expect(service.settings.balance, 0);
    expect(
      (await SharedPreferences.getInstance()).getString(
        AudioEffectsSettings.preferenceKey,
      ),
      isNull,
    );
    await service.close();
  });

  test(
    'session changes coalesce and closing releases the matching owner',
    () async {
      final gate = Completer<void>();
      messenger.setMockMethodCallHandler(AudioEffectsService.channel, (
        call,
      ) async {
        calls.add(call);
        if (calls.length == 1) await gate.future;
        return {'failures': <String>[]};
      });
      final service = AudioEffectsService();
      await service.ready;
      service.setSessionId(10);
      await Future<void>.delayed(Duration.zero);
      for (var i = 11; i <= 200; i++) {
        service.setSessionId(i);
      }
      expect(calls, hasLength(1));
      gate.complete();
      await _settle(service);
      expect(calls, hasLength(2));
      expect((calls.last.arguments as Map)['sessionId'], 200);
      await service.close();
      expect(calls.last.method, 'release');
      expect(
        (calls.last.arguments as Map)['owner'],
        (calls.first.arguments as Map)['owner'],
      );
      service.setSessionId(300);
      await service.setSettings(const AudioEffectsSettings(enabled: true));
      expect(calls, hasLength(3));
    },
  );

  test(
    'dispose during a native call drops pending parameters before release',
    () async {
      final gate = Completer<void>();
      messenger.setMockMethodCallHandler(AudioEffectsService.channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'apply') await gate.future;
        return {'failures': <String>[]};
      });
      final service = AudioEffectsService();
      await service.ready;
      service.setSessionId(1);
      service.setSessionId(2);
      final close = service.close();
      gate.complete();
      await close;
      expect(calls.map((call) => call.method), ['apply', 'release']);
    },
  );

  test('device failures remain visible and recoverable', () async {
    final service = AudioEffectsService();
    await service.ready;
    messenger.setMockMethodCallHandler(
      AudioEffectsService.channel,
      (_) async => {
        'failures': ['声道平衡'],
      },
    );
    service.setSessionId(1);
    await _settle(service);
    expect(service.failures, ['声道平衡']);
    messenger.setMockMethodCallHandler(
      AudioEffectsService.channel,
      (_) async => throw PlatformException(code: 'UNAVAILABLE'),
    );
    service.setSessionId(2);
    await _settle(service);
    expect(service.failures, isNotEmpty);
    messenger.setMockMethodCallHandler(
      AudioEffectsService.channel,
      (_) async => {'failures': <String>[]},
    );
    service.setSessionId(3);
    await _settle(service);
    expect(service.failures, isEmpty);
    await service.close();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final unsupported = AudioEffectsService();
    await unsupported.ready;
    expect(unsupported.supported, isFalse);
    await unsupported.close();
  });
}

Future<void> _settle(AudioEffectsService service) async {
  for (var i = 0; i < 20 && service.applying; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(service.applying, isFalse);
}
