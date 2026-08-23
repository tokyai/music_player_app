import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/services/playback_history_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'search and favorite playback replace the queue with the source list',
    () async {
      final player = PlayerProvider();
      addTearDown(player.dispose);
      final songs = [
        _song('one', '第一首'),
        _song('two', '第二首'),
        _song('three', '第三首'),
      ];

      await player.playFromSearchResults(songs, 1);

      expect(player.queue.map((item) => item.id), ['one', 'two', 'three']);
      expect(player.currentIndex, 1);
      expect(player.currentSong?.name, '第二首');

      await player.playFromPlaylist(songs, 2);

      expect(player.queue.map((item) => item.id), ['one', 'two', 'three']);
      expect(player.currentIndex, 2);
      expect(player.currentSong?.name, '第三首');
    },
  );

  test(
    'history playback keeps every history entry and resumes the selected one',
    () async {
      final player = PlayerProvider();
      addTearDown(player.dispose);
      final entries = [
        _historyEntry('history-one', '历史一', const Duration(seconds: 12)),
        _historyEntry('history-two', '历史二', const Duration(seconds: 34)),
      ];

      await player.playFromHistoryEntries(entries, 1);

      expect(player.queue.map((item) => item.id), [
        'history-one',
        'history-two',
      ]);
      expect(player.currentIndex, 1);
      expect(player.currentSong?.name, '历史二');
    },
  );
}

SongSearchResult _song(String id, String name) => SongSearchResult(
  platform: MusicPlatform.qq,
  id: id,
  name: name,
  artist: '歌手',
  album: '专辑',
);

PlaybackHistoryEntry _historyEntry(String id, String name, Duration position) =>
    PlaybackHistoryEntry(
      song: _song(id, name),
      position: position,
      playedAt: DateTime(2026, 8, 23),
    );
