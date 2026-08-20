import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/sound_effect.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('music_player/sound_effect');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sound effect selection is restored, applied, and persisted', () async {
    SharedPreferences.setMockInitialValues({
      'sound_effect_enabled': true,
      'sound_effect_id': 501,
      'sound_effect_type': 1,
      'sound_effect_name': '超重低音',
    });
    final nativeCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          nativeCalls.add(call);
          if (call.method == 'initialize') {
            return {
              'available': true,
              'state': 'ready',
              'message': '',
              'presets': [
                {
                  'id': 501,
                  'type': 1,
                  'name': '超重低音',
                  'description': '加强低频',
                  'tags': ['重低音'],
                },
                {
                  'id': 500,
                  'type': 1,
                  'name': '全景环绕',
                  'description': '拓宽声场',
                  'tags': ['环绕'],
                },
              ],
            };
          }
          return true;
        });

    final player = PlayerProvider();
    addTearDown(player.dispose);
    await player.settingsReady;

    expect(player.soundEffectAvailable, isTrue);
    expect(player.soundEffectEnabled, isTrue);
    expect(player.soundEffectPreset?.id, 501);
    expect(_effectArguments(nativeCalls.last), {'type': 1, 'id': 501});

    const surround = SoundEffectPreset(
      id: 500,
      type: 1,
      name: '全景环绕',
      description: '拓宽声场',
      tags: ['环绕'],
    );
    expect(await player.selectSoundEffect(surround), isTrue);
    var prefs = await SharedPreferences.getInstance();
    expect(player.soundEffectPreset?.id, 500);
    expect(prefs.getBool('sound_effect_enabled'), isTrue);
    expect(prefs.getInt('sound_effect_id'), 500);
    expect(_effectArguments(nativeCalls.last), {'type': 1, 'id': 500});

    expect(await player.setSoundEffectEnabled(false), isTrue);
    prefs = await SharedPreferences.getInstance();
    expect(player.soundEffectEnabled, isFalse);
    expect(prefs.getBool('sound_effect_enabled'), isFalse);
    expect(_effectArguments(nativeCalls.last), {'type': 1, 'id': 0});
  });
}

Map<Object?, Object?> _effectArguments(MethodCall call) {
  expect(call.method, 'setEffect');
  return Map<Object?, Object?>.from(call.arguments as Map);
}
