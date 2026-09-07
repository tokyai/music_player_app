import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/audio_effects.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/services/audio_effects_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Store store;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = _Store();
    SharedPreferencesStorePlatform.instance = store;
  });
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  test(
    'failed quality writes leave memory and persisted preference unchanged',
    () async {
      final player = PlayerProvider(activateRestoredSession: false);
      await player.settingsReady;
      await player.setCommonLevel(CommonLevel.flac);
      store.fail = true;
      await expectLater(
        player.setCommonLevel(CommonLevel.master),
        throwsStateError,
      );
      expect(player.commonLevel, CommonLevel.flac);
      expect(player.changingAudioQuality, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getString('common_level'),
        'flac',
      );
      store.fail = false;
      await (await SharedPreferences.getInstance()).reload();
      expect(
        (await SharedPreferences.getInstance()).getString('common_level'),
        'flac',
      );
      await player.disposeResources();
    },
  );

  test(
    'failed effects write keeps prior parameters and permits retry',
    () async {
      final service = AudioEffectsService();
      await service.ready;
      await service.setSettings(const AudioEffectsSettings());
      store.fail = true;
      await expectLater(
        service.setSettings(const AudioEffectsSettings(enabled: true)),
        throwsStateError,
      );
      expect(service.settings.enabled, isFalse);
      expect(service.saving, isFalse);
      final restored = AudioEffectsService();
      await restored.ready;
      expect(restored.settings.enabled, isFalse);
      store.fail = false;
      await service.setSettings(const AudioEffectsSettings(enabled: true));
      expect(service.settings.enabled, isTrue);
      await restored.close();
      await service.close();
    },
  );

  test(
    'close waits for an in-flight effects write and blocks overlapping saves',
    () async {
      final service = AudioEffectsService();
      await service.ready;
      store.gate = Completer<void>();
      final first = service.setSettings(
        const AudioEffectsSettings(enabled: true),
      );
      await store.entered.future;
      await expectLater(
        service.setSettings(const AudioEffectsSettings(bassEnabled: true)),
        throwsStateError,
      );
      var closed = false;
      final close = service.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      store.gate!.complete();
      await first;
      await close;
      final restored = AudioEffectsService();
      await restored.ready;
      expect(restored.settings.enabled, isTrue);
      expect(restored.settings.bassEnabled, isFalse);
      await restored.close();
    },
  );

  test('quality writes finish before disposing a user session', () async {
    final player = PlayerProvider(activateRestoredSession: false);
    await player.settingsReady;
    store.gate = Completer<void>();
    final first = player.setCommonLevel(CommonLevel.master);
    await store.entered.future;
    await expectLater(
      player.setCommonLevel(CommonLevel.k128),
      throwsStateError,
    );
    var disposed = false;
    final close = player.disposeResources().then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse);
    store.gate!.complete();
    await first;
    await close;
    expect(
      (await SharedPreferences.getInstance()).getString('common_level'),
      'master',
    );
  });
}

class _Store extends InMemorySharedPreferencesStore {
  _Store() : super.empty();
  bool fail = false;
  Completer<void>? gate;
  final entered = Completer<void>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (gate != null) {
      if (!entered.isCompleted) entered.complete();
      await gate!.future;
    }
    if (fail) return false;
    return super.setValue(valueType, key, value);
  }
}
