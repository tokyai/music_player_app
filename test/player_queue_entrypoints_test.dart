import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/services/bilibili_service.dart';
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

  test(
    'Bilibili list playback expands only the selected resource pages',
    () async {
      final player = _bilibiliQueuePlayer(
        infos: {
          'BVfirst': _bilibiliInfo('BVfirst', 100),
          'BVsecond': _bilibiliInfo('BVsecond', 200),
        },
      );
      addTearDown(player.dispose);

      await player.playFromSearchResults([
        _bilibiliSong('BVfirst', '第一个视频'),
        _bilibiliSong('BVsecond', '第二个视频'),
      ], 1);

      expect(player.queue, hasLength(2));
      expect(player.queue.map((item) => item.id), ['BVsecond', 'BVsecond']);
      expect(player.queue.map((item) => item.bilibiliCid), [201, 202]);
      expect(player.queue.map((item) => item.name), ['第一P', '第二P']);
      expect(player.currentIndex, 0);
      expect(player.currentSong?.bilibiliCid, 201);
    },
  );

  test('Bilibili queue append is atomic and includes every page', () async {
    final player = _bilibiliQueuePlayer(
      infos: {'BVappend': _bilibiliInfo('BVappend', 300)},
    );
    addTearDown(player.dispose);
    await player.addToQueueAndGetCount(_song('existing', '原队列歌曲'));

    final added = await player.addToQueueAndGetCount(
      _bilibiliSong('BVappend', '待追加视频'),
    );

    expect(added, 2);
    expect(player.queue.map((item) => item.id), [
      'existing',
      'BVappend',
      'BVappend',
    ]);
    expect(player.queue.skip(1).map((item) => item.bilibiliCid), [301, 302]);
  });

  test(
    'a failed Bilibili expansion leaves the existing queue unchanged',
    () async {
      final player = _bilibiliQueuePlayer(errors: {'BVbroken': '视频详情加载失败'});
      addTearDown(player.dispose);
      await player.addToQueueAndGetCount(_song('existing', '原队列歌曲'));

      final added = await player.addToQueueAndGetCount(
        _bilibiliSong('BVbroken', '损坏视频'),
      );

      expect(added, 0);
      expect(player.queue.map((item) => item.id), ['existing']);
      expect(player.lastError, '视频详情加载失败');
    },
  );

  test(
    'the latest Bilibili playback tap wins when details finish out of order',
    () async {
      final deferred = {
        'BVslow': Completer<http.Response>(),
        'BVlatest': Completer<http.Response>(),
      };
      final player = _bilibiliQueuePlayer(deferred: deferred);
      addTearDown(player.dispose);

      final first = player.playBilibiliResource(
        _bilibiliSong('BVslow', '较早点击'),
      );
      final second = player.playBilibiliResource(
        _bilibiliSong('BVlatest', '最后点击'),
      );
      deferred['BVslow']!.complete(
        _bilibiliInfoResponse(_bilibiliInfo('BVslow', 400)),
      );
      await first;
      expect(player.queue, isEmpty);

      deferred['BVlatest']!.complete(
        _bilibiliInfoResponse(_bilibiliInfo('BVlatest', 500)),
      );
      await second;

      expect(player.queue.map((item) => item.id), ['BVlatest', 'BVlatest']);
      expect(player.queue.map((item) => item.bilibiliCid), [501, 502]);
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

SongSearchResult _bilibiliSong(String id, String name) => SongSearchResult(
  platform: MusicPlatform.bilibili,
  id: id,
  name: name,
  artist: '测试UP主',
  album: name,
  bilibiliVideoTitle: name,
);

BilibiliVideoInfo _bilibiliInfo(String bvid, int cidBase) => BilibiliVideoInfo(
  bvid: bvid,
  title: '$bvid 视频标题',
  description: '视频简介',
  ownerName: '测试UP主',
  coverUrl: 'https://example.com/$bvid.jpg',
  duration: 300,
  pages: [
    BilibiliPageInfo(cid: cidBase + 1, page: 1, title: '第一P', duration: 120),
    BilibiliPageInfo(cid: cidBase + 2, page: 2, title: '第二P', duration: 180),
  ],
);

PlayerProvider _bilibiliQueuePlayer({
  Map<String, BilibiliVideoInfo> infos = const {},
  Map<String, String> errors = const {},
  Map<String, Completer<http.Response>> deferred = const {},
}) {
  return PlayerProvider(
    bilibiliService: BilibiliService(
      client: _bilibiliPlaybackClient(
        infos: infos,
        errors: errors,
        deferred: deferred,
      ),
    ),
  );
}

http.Client _bilibiliPlaybackClient({
  Map<String, BilibiliVideoInfo> infos = const {},
  Map<String, String> errors = const {},
  Map<String, Completer<http.Response>> deferred = const {},
}) {
  return MockClient((request) async {
    if (request.url.path == '/x/web-interface/nav') {
      return _jsonResponse({
        'code': 0,
        'data': {
          'wbi_img': {
            'img_url':
                'https://i0.hdslb.com/bfs/wbi/abcdefghijklmnopqrstuvwxyz012345.png',
            'sub_url':
                'https://i0.hdslb.com/bfs/wbi/9876543210abcdefghijklmnopqrstuvwxyz.png',
          },
        },
      });
    }
    if (request.url.path == '/x/web-interface/view') {
      final bvid = request.url.queryParameters['bvid'] ?? '';
      final pending = deferred[bvid];
      if (pending != null) return pending.future;
      final error = errors[bvid];
      if (error != null) {
        return _jsonResponse({'code': -404, 'message': error});
      }
      return _bilibiliInfoResponse(infos[bvid] ?? _bilibiliInfo(bvid, 900));
    }
    if (request.url.path == '/x/player/wbi/playurl') {
      return _jsonResponse({
        'code': 0,
        'data': {
          'timelength': 120000,
          'dash': {
            // Queue behavior is under test here. Returning no stream makes
            // playback fail before just_audio reaches a platform channel.
            'audio': <Object>[],
            'video': <Object>[],
          },
        },
      });
    }
    return _jsonResponse({'code': -404, 'message': 'not found'});
  });
}

http.Response _bilibiliInfoResponse(BilibiliVideoInfo info) {
  return _jsonResponse({
    'code': 0,
    'data': {
      'bvid': info.bvid,
      'title': info.title,
      'desc': info.description,
      'pic': info.coverUrl,
      'duration': info.duration,
      'owner': {'name': info.ownerName},
      'pages': info.pages.map((page) => page.toJson()).toList(),
    },
  });
}

http.Response _jsonResponse(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
