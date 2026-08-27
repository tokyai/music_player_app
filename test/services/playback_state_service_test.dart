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

  test('Bilibili playback snapshots stay linear for large expanded queues', () {
    String encodeQueue(int pageCount) {
      final pages = List<BilibiliPageInfo>.generate(
        pageCount,
        (index) => BilibiliPageInfo(
          cid: 10000 + index,
          page: index + 1,
          title: '分P ${index + 1}',
          duration: 180,
        ),
        growable: false,
      );
      final queue = pages
          .map(
            (page) => SongSearchResult(
              platform: MusicPlatform.bilibili,
              id: 'BVlarge',
              name: page.title,
              artist: 'UP主',
              album: '大型合集',
              bilibiliCid: page.cid,
              bilibiliPage: page.page,
              bilibiliPages: pages,
            ),
          )
          .toList(growable: false);
      return jsonEncode(
        PlaybackSessionSnapshot(
          queue: queue,
          currentIndex: 0,
          position: Duration.zero,
          isPlaying: false,
          playMode: 'sequence',
        ).toJson(),
      );
    }

    final hundredPages = encodeQueue(100);
    final twoHundredPages = encodeQueue(200);

    expect(twoHundredPages, isNot(contains('bilibiliPages')));
    expect(twoHundredPages.length, lessThan(hundredPages.length * 2.3));
  });

  test('old Bilibili snapshot entries are compacted while restoring', () {
    const pages = [
      BilibiliPageInfo(cid: 11, page: 1, title: '第一P', duration: 120),
      BilibiliPageInfo(cid: 12, page: 2, title: '第二P', duration: 180),
    ];
    final restored = PlaybackSessionSnapshot.fromJson({
      'queue': pages
          .map(
            (page) => SongSearchResult(
              platform: MusicPlatform.bilibili,
              id: 'BVold',
              name: page.title,
              artist: 'UP主',
              album: '旧合集',
              bilibiliCid: page.cid,
              bilibiliPage: page.page,
              bilibiliPages: pages,
            ).toJson(),
          )
          .toList(),
      'currentIndex': 0,
      'positionMs': 0,
      'isPlaying': false,
      'playMode': 'sequence',
    });

    expect(restored.queue.every((song) => song.bilibiliPages.isEmpty), isTrue);
    expect(restored.queue.map((song) => song.bilibiliCid), [11, 12]);
  });
}

SongSearchResult _song(String id) => SongSearchResult(
  platform: MusicPlatform.qq,
  id: id,
  name: '歌曲 $id',
  artist: '歌手',
  album: '专辑',
);
