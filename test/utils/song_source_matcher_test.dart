import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/utils/song_source_matcher.dart';

void main() {
  test('selects the closest title, artist, duration, and album match', () {
    final original = _song(
      MusicPlatform.netease,
      'original',
      'Example Song',
      artist: 'Alice / Bob',
      album: 'Example Album',
      duration: 210,
    );
    final candidates = [
      _song(
        MusicPlatform.qq,
        'wrong-duration',
        'Example Song',
        artist: 'Alice',
        album: 'Other Album',
        duration: 260,
      ),
      _song(
        MusicPlatform.qq,
        'best',
        'Example Song',
        artist: 'Bob & Alice',
        album: 'Example Album',
        duration: 211,
      ),
    ];

    expect(SongSourceMatcher.bestMatch(original, candidates)?.id, 'best');
  });

  test(
    'normalizes punctuation and accepts a title variant by the same artist',
    () {
      final original = _song(
        MusicPlatform.netease,
        'original',
        'Hello - Live',
        artist: 'The Singer',
      );
      final candidate = _song(
        MusicPlatform.kugou,
        'variant',
        'Hello Live Version',
        artist: 'The Singer',
      );

      expect(
        SongSourceMatcher.bestMatch(original, [candidate]),
        same(candidate),
      );
    },
  );

  test('rejects an identical title from a different known artist', () {
    final original = _song(
      MusicPlatform.netease,
      'original',
      'Shared Title',
      artist: 'First Artist',
    );
    final candidate = _song(
      MusicPlatform.qq,
      'other',
      'Shared Title',
      artist: 'Different Artist',
    );

    expect(SongSourceMatcher.score(original, candidate), 0);
    expect(SongSourceMatcher.bestMatch(original, [candidate]), isNull);
  });

  test('rejects unrelated titles even when artist and duration match', () {
    final original = _song(
      MusicPlatform.netease,
      'original',
      'First Song',
      artist: 'Singer',
      duration: 180,
    );
    final candidate = _song(
      MusicPlatform.qq,
      'other',
      'Completely Different',
      artist: 'Singer',
      duration: 180,
    );

    expect(SongSourceMatcher.bestMatch(original, [candidate]), isNull);
  });
}

SongSearchResult _song(
  MusicPlatform platform,
  String id,
  String name, {
  required String artist,
  String album = '',
  int? duration,
}) {
  return SongSearchResult(
    platform: platform,
    id: id,
    name: name,
    artist: artist,
    album: album,
    duration: duration,
  );
}
