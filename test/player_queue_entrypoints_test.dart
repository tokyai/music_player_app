import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/services/playback_history_service.dart';
import 'package:music_player_app/services/playback_state_service.dart';
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

  test('restores a paused playback session on startup', () async {
    final snapshot = PlaybackSessionSnapshot(
      queue: [_song('saved-one', '已保存一'), _song('saved-two', '已保存二')],
      currentIndex: 1,
      position: const Duration(seconds: 27),
      isPlaying: false,
      playMode: 'repeat',
    );
    SharedPreferences.setMockInitialValues({
      PlaybackStateService.preferenceKey: jsonEncode(snapshot.toJson()),
    });
    final player = PlayerProvider();
    addTearDown(player.dispose);

    await player.playbackStateReady;

    expect(player.queue.map((item) => item.id), ['saved-one', 'saved-two']);
    expect(player.currentIndex, 1);
    expect(player.position, const Duration(seconds: 27));
    expect(player.playMode, PlayMode.repeat);
    expect(player.isPlaying, isFalse);
  });

  test(
    'persists the selected queue and play mode after a queue change',
    () async {
      final player = PlayerProvider();
      addTearDown(player.dispose);
      await player.playbackStateReady;

      await player.playFromPlaylist([
        _song('persist-one', '保存一'),
        _song('persist-two', '保存二'),
      ], 1);
      player.togglePlayMode();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final restored = await PlaybackStateService.load();
      expect(restored, isNotNull);
      expect(restored!.queue.map((song) => song.id), [
        'persist-one',
        'persist-two',
      ]);
      expect(restored.currentIndex, 1);
      expect(restored.playMode, 'repeat');
    },
  );

  test('complete exit flushes the current queue and history once', () async {
    final snapshot = PlaybackSessionSnapshot(
      queue: [_song('exit-one', '退出保存一'), _song('exit-two', '退出保存二')],
      currentIndex: 1,
      position: const Duration(seconds: 41),
      isPlaying: false,
      playMode: 'shuffle',
    );
    SharedPreferences.setMockInitialValues({
      PlaybackStateService.preferenceKey: jsonEncode(snapshot.toJson()),
    });
    final player = PlayerProvider();
    addTearDown(player.dispose);

    await player.prepareForAppExit();
    await player.prepareForAppExit();

    final restored = await PlaybackStateService.load();
    expect(restored, isNotNull);
    expect(restored!.queue.map((song) => song.id), ['exit-one', 'exit-two']);
    expect(restored.currentIndex, 1);
    expect(restored.position, const Duration(seconds: 41));
    expect(restored.playMode, 'shuffle');

    final history = await PlaybackHistoryService.load();
    expect(history, hasLength(1));
    expect(history.single.song.id, 'exit-two');
    expect(history.single.position, const Duration(seconds: 41));
  });
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
