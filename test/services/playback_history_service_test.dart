import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/playback_history_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('round-trips metadata, resume position, and Bilibili page identity', () {
    final song = SongSearchResult(
      platform: MusicPlatform.bilibili,
      id: 'BV1history',
      name: '历史视频',
      artist: 'UP主',
      album: '历史视频',
      bilibiliCid: 987,
      bilibiliPage: 2,
      duration: 321,
    );
    final entry = PlaybackHistoryEntry(
      song: song,
      position: const Duration(seconds: 42),
      playedAt: DateTime.utc(2026, 8, 19, 12, 30),
    );

    final restored = PlaybackHistoryEntry.fromJson(
      jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>,
    );

    expect(restored.song.toJson(), song.toJson());
    expect(restored.position, const Duration(seconds: 42));
    expect(restored.playedAt.toUtc(), entry.playedAt);
    expect(restored.key, 'bilibili:BV1history:987');
  });

  test('load ignores malformed records and save caps history length', () async {
    final entries = List.generate(
      PlaybackHistoryService.maxEntries + 3,
      (index) => PlaybackHistoryEntry(
        song: SongSearchResult(
          platform: MusicPlatform.qq,
          id: 'song-$index',
          name: '歌曲 $index',
          artist: '歌手',
          album: '专辑',
        ),
        position: Duration(seconds: index),
        playedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: index)),
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      PlaybackHistoryService.preferenceKey,
      jsonEncode([
        ...entries.map((entry) => entry.toJson()),
        {
          'song': {'platform': 'qq', 'id': ''},
        },
      ]),
    );

    final loaded = await PlaybackHistoryService.load();

    expect(loaded, hasLength(PlaybackHistoryService.maxEntries));
    expect(loaded.first.song.id, 'song-102');
    expect(loaded.any((entry) => entry.song.id.isEmpty), isFalse);
  });
}
