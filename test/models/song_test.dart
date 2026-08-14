import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';

void main() {
  group('SongSearchResult', () {
    test('normalizes Netease cover and duration', () {
      final song = SongSearchResult.fromNetease({
        'id': 42,
        'name': 'Example',
        'ar': [
          {'name': 'Singer'},
        ],
        'al': {
          'name': 'Album',
          'picUrl': 'http://music.126.net/cover.jpg',
        },
        'dt': 215000,
      });

      expect(song.id, '42');
      expect(song.artist, 'Singer');
      expect(song.coverUrl, 'https://music.126.net/cover.jpg');
      expect(song.duration, 215);
    });

    test('parses official Kugou search response', () {
      final song = SongSearchResult.fromKugouSearchSong({
        'hash': 'ABC',
        'songname': 'Search Song',
        'singername': 'Singer',
        'album_name': 'Album',
        'album_sizable_cover': 'http://imge.kugou.com/{size}/cover.jpg',
        'duration': '189',
      });

      expect(song.id, 'ABC');
      expect(song.coverUrl, 'http://imge.kugou.com/500/cover.jpg');
      expect(song.duration, 189);
    });

    test('parses official Kugou rank response authors', () {
      final song = SongSearchResult.fromKugouRankSong({
        'hash': 'DEF',
        'songname': 'Rank Song',
        'authors': [
          {'author_name': 'First'},
          {'author_name': 'Second'},
        ],
        'duration': 201,
      });

      expect(song.artist, 'First / Second');
      expect(song.duration, 201);
    });
  });

  test('PlayQueueItem can clear a previous error', () {
    final item = PlayQueueItem(
      platform: MusicPlatform.qq,
      id: 'id',
      name: 'Song',
      artist: 'Singer',
      album: 'Album',
      error: 'failed',
    );

    expect(item.copyWith(loading: true).error, 'failed');
    expect(item.copyWith(clearError: true).error, isNull);
  });
}
