import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/sound_effect.dart';

void main() {
  test('native sound effect result is parsed without optional metadata', () {
    final availability = SoundEffectAvailability.fromMap({
      'available': true,
      'state': 'ready',
      'message': '',
      'presets': [
        {
          'id': 501,
          'type': 1,
          'name': '超重低音',
          'description': null,
          'tags': ['重低音', '', null],
        },
        {'id': 0, 'type': 1, 'name': '无效项'},
      ],
    });

    expect(availability.available, isTrue);
    expect(availability.presets, hasLength(1));
    expect(availability.presets.single.id, 501);
    expect(availability.presets.single.description, isEmpty);
    expect(availability.presets.single.tags, ['重低音']);
  });
}
