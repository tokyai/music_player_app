import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/playback_state_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('round-trips queue, position, mode and playing state', () async {
    final snapshot = PlaybackSessionSnapshot(
      queue: [_song('one'), _song('two')],
      currentIndex: 1,
      position: const Duration(seconds: 42),
      isPlaying: true,
      playMode: 'shuffle',
    );

    await PlaybackStateService.save(snapshot);
    final restored = await PlaybackStateService.load();

    expect(restored, isNotNull);
    expect(restored!.queue.map((song) => song.id), ['one', 'two']);
    expect(restored.currentIndex, 1);
    expect(restored.position, const Duration(seconds: 42));
    expect(restored.isPlaying, isTrue);
    expect(restored.playMode, 'shuffle');
  });

  test(
    'ignores malformed queue entries and clamps the selected index',
    () async {
      SharedPreferences.setMockInitialValues({
        PlaybackStateService.preferenceKey: jsonEncode({
          'queue': [
            _song('valid').toJson(),
            {'platform': 'qq', 'id': ''},
          ],
          'currentIndex': 99,
          'positionMs': -10,
          'isPlaying': false,
          'playMode': 'unknown',
        }),
      });

      final restored = await PlaybackStateService.load();

      expect(restored, isNotNull);
      expect(restored!.queue, hasLength(1));
      expect(restored.currentIndex, 0);
      expect(restored.position, Duration.zero);
      expect(restored.playMode, 'sequence');
    },
  );
}

SongSearchResult _song(String id) => SongSearchResult(
  platform: MusicPlatform.qq,
  id: id,
  name: '歌曲 $id',
  artist: '歌手',
  album: '专辑',
);
