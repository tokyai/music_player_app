import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/playback_source_config.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/models/download_entry.dart';
import 'package:music_player_app/services/download_manager.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/services/audio_cache_service.dart';
import 'package:music_player_app/services/playback_history_service.dart';
import 'package:music_player_app/services/playback_state_service.dart';
import 'package:music_player_app/services/user_data_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pause checkpoints survive selecting the same song normally', () async {
    await _scenario((fixture, player) async {
      final song = _song('song');
      await player.playSingle(song);
      await _until(player, () => player.isPlaying);
      await fixture.readyEvent(position: const Duration(seconds: 37));
      await _until(
        player,
        () => player.position >= const Duration(seconds: 37),
      );
      await player.pause();
      await player.playPause();
      await _until(player, () => player.isPlaying);
      expect(
        player.position,
        greaterThanOrEqualTo(const Duration(seconds: 37)),
      );
      await player.playPause();
      final checkpoint = player.position;
      await _expectCheckpoint(fixture, song, checkpoint);

      await player.playFromSearchResults([song], 0);
      await _expectResumed(fixture, player, checkpoint);
      await player.pause();
      await player.seekTo(const Duration(seconds: 51));
      await player.pause();
      await player.playFromPlaylist([song], 0);
      await _expectResumed(fixture, player, const Duration(seconds: 51));
      await player.pause();
      await player.seekTo(const Duration(seconds: 63));
      await player.pause();
      await player.playSingle(song);
      await _expectResumed(fixture, player, const Duration(seconds: 63));
    });
  });

  test(
    'stop persists a checkpoint across restart and unloaded seeking',
    () async {
      await _scenario((fixture, player) async {
        final song = _song('song');
        await player.playSingle(song);
        await player.pause();
        await player.seekTo(const Duration(seconds: 42));
        await player.stop();
        await _expectCheckpoint(fixture, song, const Duration(seconds: 42));
        await player.disposeResources();
        final loadsBefore = fixture.loaded.length;
        final restarted = PlayerProvider(
          dataScope: fixture.scope,
          activateRestoredSession: false,
        );
        try {
          await Future.wait([
            restarted.settingsReady,
            restarted.playbackStateReady,
          ]);
          await Future<void>.delayed(Duration.zero);
          expect(restarted.position, const Duration(seconds: 42));
          expect(restarted.isPlaying, isFalse);
          expect(fixture.loaded.length, loadsBefore);
          await restarted.seekTo(const Duration(seconds: 58));
          await restarted.pause();
          await _expectCheckpoint(fixture, song, const Duration(seconds: 58));
          await restarted.playPause();
          await _expectResumed(fixture, restarted, const Duration(seconds: 58));
        } finally {
          await restarted.disposeResources();
        }
      });
    },
  );

  test(
    'clearing history removes old bookmarks but keeps current session',
    () async {
      await _scenario((fixture, player) async {
        final song = _song('song');
        final other = _song('other');
        await player.playSingle(song);
        await player.pause();
        await player.seekTo(const Duration(seconds: 28));
        await player.pause();
        await player.playSingle(other);
        await player.pause();
        await player.clearPlaybackHistory();
        await _until(player, () => player.playbackHistory.isEmpty);
        expect(
          await PlaybackHistoryService.load(scope: fixture.scope),
          isEmpty,
        );
        final session = await PlaybackStateService.load(scope: fixture.scope);
        expect(session, isNotNull);
        expect(session!.queue[session.currentIndex].id, 'other');
        expect(session.position, Duration.zero);
        expect(session.isPlaying, isFalse);
        fixture.seekPositions.clear();
        await player.playSingle(song);
        await _until(player, () => player.isPlaying);
        expect(player.position.inMilliseconds, lessThan(1000));
        expect(
          fixture.seekPositions.where((position) => position > 0),
          isEmpty,
        );
      });
    },
  );

  test('queue navigation retains independent song bookmarks', () async {
    await _scenario((fixture, player) async {
      await player.playFromSearchResults([_song('a'), _song('b')], 0);
      await player.pause();
      await player.seekTo(const Duration(seconds: 23));
      await player.pause();
      await player.playNext();
      expect(player.currentSong!.id, 'b');
      expect(player.position.inMilliseconds, lessThan(1000));
      await player.pause();
      await player.seekTo(const Duration(seconds: 67));
      await player.pause();
      await player.playPrevious();
      await _expectResumed(fixture, player, const Duration(seconds: 23));
      await player.playQueueItem(1);
      await _expectResumed(fixture, player, const Duration(seconds: 67));
      await player.pause();
      final history = await PlaybackHistoryService.load(scope: fixture.scope);
      expect(
        history.singleWhere((entry) => entry.song.id == 'a').position.inSeconds,
        23,
      );
      expect(
        history.singleWhere((entry) => entry.song.id == 'b').position.inSeconds,
        67,
      );
    });
  });
  test('Bilibili pages of the same video retain separate bookmarks', () async {
    await _scenario((fixture, player) async {
      final cache = await Directory(
        '${fixture.directory.path}/${fixture.scope.audioCacheRelativePath}',
      ).create(recursive: true);
      final index = <String, dynamic>{};
      for (final cid in [101, 202]) {
        final audio = await File(
          '${cache.path}/$cid.mp3',
        ).writeAsBytes(List<int>.filled(16384, 0));
        index['bilibili_video_${cid}_q30280'] = {
          'filePath': audio.path,
          'platformCode': 'bilibili',
          'songId': 'video_${cid}_q30280',
          'quality': '30280',
        };
      }
      await File('${cache.path}/_index.json').writeAsString(jsonEncode(index));
      await AudioCacheService.releaseMemoryContext(fixture.scope);
      const pages = [
        BilibiliPageInfo(cid: 101, page: 1, title: 'first'),
        BilibiliPageInfo(cid: 202, page: 2, title: 'second'),
      ];
      final first = SongSearchResult(
        platform: MusicPlatform.bilibili,
        id: 'video',
        name: 'first',
        artist: 'artist',
        album: 'video',
        bilibiliDescription: 'desc',
        bilibiliCid: 101,
        bilibiliPage: 1,
        bilibiliPages: pages,
      );
      final second = SongSearchResult(
        platform: MusicPlatform.bilibili,
        id: 'video',
        name: 'second',
        artist: 'artist',
        album: 'video',
        bilibiliDescription: 'desc',
        bilibiliCid: 202,
        bilibiliPage: 2,
        bilibiliPages: pages,
      );
      expect(player.addTracksToQueue([first, second]), isTrue);
      await player.playQueueItem(0);
      expect(player.queue.map((song) => song.bilibiliCid), [101, 202]);
      await player.pause();
      await player.seekTo(const Duration(seconds: 19));
      await player.pause();
      await player.playQueueItem(1);
      await player.pause();
      await player.seekTo(const Duration(seconds: 71));
      await player.pause();
      await player.playQueueItem(0);
      await _expectResumed(fixture, player, const Duration(seconds: 19));
      await player.playQueueItem(1);
      await _expectResumed(fixture, player, const Duration(seconds: 71));
      await player.pause();
      final history = await PlaybackHistoryService.load(scope: fixture.scope);
      expect(
        history
            .singleWhere((entry) => entry.song.bilibiliCid == 101)
            .position
            .inSeconds,
        19,
      );
      expect(
        history
            .singleWhere((entry) => entry.song.bilibiliCid == 202)
            .position
            .inSeconds,
        71,
      );
    });
  });

  test(
    'unfinished final second resumes but completed playback restarts',
    () async {
      await _scenario((fixture, player) async {
        final song = _song('song');
        await player.playSingle(song);
        await player.pause();
        await player.seekTo(const Duration(seconds: 179));
        await player.pause();
        await player.playSingle(song);
        await _expectResumed(fixture, player, const Duration(seconds: 179));
        final playsBeforeCompletion = fixture.playCalls;
        player.sleepTimer.stopAfterTrack();
        await fixture.readyEvent(
          state: 4,
          position: const Duration(seconds: 180),
        );
        await _until(player, () => !player.isPlaying && !player.isLoading);
        await player.stop();
        await _expectCheckpoint(fixture, song, Duration.zero);
        expect(player.sleepTimer.error, isNull);
        fixture.seekPositions.clear();
        await player.playSingle(song);
        await _until(player, () => player.isPlaying);
        expect(player.position.inMilliseconds, lessThan(1000));
        expect(
          fixture.seekPositions.where((position) => position > 0),
          isEmpty,
        );
        expect(fixture.playCalls, greaterThan(playsBeforeCompletion));
      });
    },
  );

  test(
    'stop cancels late resolution without destroying its bookmark',
    () async {
      await _scenario((fixture, player) async {
        await player.setPlaybackSource(
          MusicPlatform.qq,
          PlaybackSource.qingMusic,
        );
        await player.playSingle(_song('song'));
        await player.pause();
        await player.seekTo(const Duration(seconds: 46));
        await player.pause();
        final gate = fixture.resolutionGates['delayed'] = Completer<void>();
        final pending = player.playSingle(_song('delayed'));
        try {
          await fixture.waitForResolution('delayed');
          await player.stop();
          final playsAtStop = fixture.playCalls;
          final loadsAtStop = fixture.loaded.length;
          gate.complete();
          await pending.timeout(const Duration(seconds: 2));
          expect(player.isPlaying, isFalse);
          expect(player.isLoading, isFalse);
          expect(fixture.playCalls, playsAtStop);
          expect(fixture.loaded.length, loadsAtStop);
          await player.playSingle(_song('song'));
          await _expectResumed(fixture, player, const Duration(seconds: 46));
        } finally {
          if (!gate.isCompleted) gate.complete();
          await pending.timeout(const Duration(seconds: 2));
        }
      });
    },
  );

  test(
    'pause cancels a native load even when it later reports ready',
    () async {
      await _scenario((fixture, player) async {
        await player.playSingle(_song('song'));
        await player.pause();
        await player.seekTo(const Duration(seconds: 39));
        await player.pause();
        final gate = fixture.loadGate = Completer<void>();
        final started = fixture.loadStarted = Completer<void>();
        final pending = player.playSingle(_song('song'));
        try {
          await started.future.timeout(const Duration(seconds: 2));
          await player.pause();
          final playsAtPause = fixture.playCalls;
          gate.complete();
          await pending.timeout(const Duration(seconds: 2));
          expect(player.isPlaying, isFalse);
          expect(player.isLoading, isFalse);
          expect(fixture.playCalls, playsAtPause);
          await _expectCheckpoint(
            fixture,
            _song('song'),
            const Duration(seconds: 39),
          );
          fixture.loadGate = null;
          await player.playSingle(_song('song'));
          await _expectResumed(fixture, player, const Duration(seconds: 39));
        } finally {
          if (!gate.isCompleted) gate.complete();
          await pending.timeout(const Duration(seconds: 2));
        }
      });
    },
  );

  test('failed native loads retain the last usable checkpoint', () async {
    await _scenario((fixture, player) async {
      final song = _song('song');
      await player.playSingle(song);
      await player.pause();
      await player.seekTo(const Duration(seconds: 54));
      await player.pause();
      fixture.failAllLoads = true;
      await player.playSingle(song);
      expect(player.errorMessage, isNotNull);
      expect(player.isPlaying, isFalse);
      await player.stop();
      await _expectCheckpoint(fixture, song, const Duration(seconds: 54));
      fixture.failAllLoads = false;
      await player.playSingle(song);
      await _expectResumed(fixture, player, const Duration(seconds: 54));
    });
  });

  for (final dispose in [false, true]) {
    test(
      'late resolution cannot resume after ${dispose ? 'dispose' : 'user switch'}',
      () async {
        await _scenario((fixture, player) async {
          await player.setPlaybackSource(
            MusicPlatform.qq,
            PlaybackSource.qingMusic,
          );
          await player.playSingle(_song('song'));
          await player.pause();
          await player.seekTo(const Duration(seconds: 32));
          await player.pause();
          final gate = fixture.resolutionGates['delayed'] = Completer<void>();
          final pending = player.playSingle(_song('delayed'));
          try {
            await fixture.waitForResolution('delayed');
            if (dispose) {
              await player.disposeResources();
            } else {
              await player.prepareForUserSwitch(waitForWrites: true);
            }
            final playsAtShutdown = fixture.playCalls;
            final loadsAtShutdown = fixture.loaded.length;
            gate.complete();
            await pending.timeout(const Duration(seconds: 2));
            expect(player.isPlaying, isFalse);
            expect(fixture.playCalls, playsAtShutdown);
            expect(fixture.loaded.length, loadsAtShutdown);
            final history = await PlaybackHistoryService.load(
              scope: fixture.scope,
            );
            expect(
              history.singleWhere((entry) => entry.song.id == 'song').position,
              const Duration(seconds: 32),
            );
            final otherScope = UserDataScope('${fixture.scope.userId}-other');
            expect(
              await PlaybackHistoryService.load(scope: otherScope),
              isEmpty,
            );
          } finally {
            if (!gate.isCompleted) gate.complete();
            await pending.timeout(const Duration(seconds: 2));
          }
        });
      },
    );
  }

  test('manual switching bypasses a local cached recording', () async {
    await _scenario((fixture, player) async {
      await player.playFromSearchResults([_song('song')], 0);
      expect(fixture.loaded.last, contains('cached.mp3'));
      final before = player.toBackupJson();
      expect(
        await player.switchCurrentPlaybackSource(PlaybackSource.hyw),
        isTrue,
      );
      expect(Uri.parse(fixture.loaded.last).host, 'audio-hyw.test');
      expect(player.currentPlaybackSource, PlaybackSource.hyw);
      expect(player.toBackupJson(), before);
    }, cached: true);
  });

  for (final platform in musicPlatformDisplayOrder) {
    test(
      '$platform cached audio reads full lyrics before any network request',
      () async {
        await _scenario((fixture, player) async {
          final isBilibili = platform == MusicPlatform.bilibili;
          final cacheId = isBilibili ? 'song_123_q30280' : 'song';
          final quality = switch (platform) {
            MusicPlatform.netease => 'jymaster',
            MusicPlatform.bilibili => '30280',
            _ => 'flac',
          };
          final cache = await Directory(
            '${fixture.directory.path}/${fixture.scope.audioCacheRelativePath}',
          ).create(recursive: true);
          final audio = await File(
            '${cache.path}/offline.mp3',
          ).writeAsBytes(List<int>.filled(16384, 0));
          await File('${cache.path}/_index.json').writeAsString(
            jsonEncode({
              '${platform.code}_$cacheId': {
                'filePath': audio.path,
                'platformCode': platform.code,
                'songId': cacheId,
                'quality': quality,
              },
            }),
          );
          await AudioCacheService.cacheLyrics(
            platformCode: platform.code,
            songId: cacheId,
            audioPath: audio.path,
            lyrics: _offlineLyrics,
            scope: fixture.scope,
          );
          await AudioCacheService.releaseMemoryContext(fixture.scope);
          fixture.responseOverride = (_) =>
              throw const SocketException('offline');
          await player.playSingle(
            SongSearchResult(
              platform: platform,
              id: 'song',
              name: '离线歌曲',
              artist: '歌手',
              album: '',
              bilibiliCid: isBilibili ? 123 : null,
              bilibiliPages: isBilibili
                  ? const [BilibiliPageInfo(cid: 123, page: 1, title: '离线歌曲')]
                  : const [],
            ),
          );
          expect(fixture.requestCount, 0);
          expect(fixture.loaded.single, Uri.file(audio.path).toString());
          expect(player.errorMessage, isNull);
          expect(player.lyricsLoading, isFalse);
          expect(player.lyrics.single.primaryText, '你好');
          expect(player.lyrics.single.translationText, 'Hello');
          expect(player.lyrics.single.hasReliableWordTiming, isTrue);
        });
      },
    );
  }

  for (final clearQueueWhileCaching in [false, true]) {
    test(
      'audio completion saves lyrics across restart (clear queue: $clearQueueWhileCaching)',
      () async {
        await _scenario((fixture, player) async {
          final originalOverrides = HttpOverrides.current;
          HttpOverrides.global = null;
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final audioStarted = Completer<void>();
          final finishAudio = Completer<void>();
          final subscription = server.listen((request) async {
            if (!audioStarted.isCompleted) audioStarted.complete();
            await finishAudio.future;
            request.response.add(List<int>.filled(16384, 1));
            await request.response.close();
          });
          try {
            fixture.audioBaseUrl = 'http://127.0.0.1:${server.port}';
            var lyricRequests = 0;
            fixture.responseOverride = (request) async {
              if (!request.url.path.contains('lyric')) return null;
              lyricRequests++;
              return _lyricResponse(_offlineLyrics);
            };
            await player.setPlaybackSource(
              MusicPlatform.qq,
              PlaybackSource.qingMusic,
            );
            await player.playSingle(_song('song'));
            await _until(player, () => player.lyrics.isNotEmpty);
            await audioStarted.future.timeout(const Duration(seconds: 5));
            final cache = Directory(
              '${fixture.directory.path}/${fixture.scope.audioCacheRelativePath}',
            );
            expect(
              await cache
                  .list()
                  .where((file) => file.path.contains('lyrics_'))
                  .toList(),
              isEmpty,
            );
            if (clearQueueWhileCaching) player.clearQueue();
            finishAudio.complete();
            final audioPath = await _waitForCachedLyrics(fixture, 'song');
            expect(lyricRequests, 1);
            await player.disposeResources();
            await AudioCacheService.releaseMemoryContext(fixture.scope);
            fixture.responseOverride = (_) =>
                throw const SocketException('offline');
            final requestsBeforeRestart = fixture.requestCount;
            final restarted = PlayerProvider(
              dataScope: fixture.scope,
              activateRestoredSession: false,
            );
            try {
              await restarted.playSingle(_song('song'));
              expect(fixture.loaded.last, Uri.file(audioPath).toString());
              expect(fixture.requestCount, requestsBeforeRestart);
              expect(restarted.lyrics.single.translationText, 'Hello');
              expect(restarted.lyrics.single.hasReliableWordTiming, isTrue);
            } finally {
              await restarted.disposeResources();
            }
          } finally {
            if (!finishAudio.isCompleted) finishAudio.complete();
            await subscription.cancel();
            await server.close(force: true);
            HttpOverrides.global = originalOverrides;
          }
        });
      },
    );
  }

  test(
    'legacy cache fills missing lyrics without holding up audio playback',
    () async {
      await _scenario((fixture, player) async {
        final gate = Completer<void>();
        fixture.responseOverride = (request) async {
          if (!request.url.path.contains('lyric')) return null;
          await gate.future;
          return _lyricResponse(_offlineLyrics);
        };
        try {
          await player.playSingle(_song('song'));
          expect(player.isLoading, isFalse);
          expect(player.lyricsLoading, isTrue);
          expect(fixture.loaded.single, contains('cached.mp3'));
          gate.complete();
          await _waitForCachedLyrics(fixture, 'song');
          expect(player.lyrics.single.translationText, 'Hello');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      }, cached: true);
    },
  );

  for (final action in ['remove', 'clear', 'switch', 'dispose']) {
    test('late lyric responses are safe after $action', () async {
      await _scenario((fixture, player) async {
        final gate = Completer<void>();
        fixture.responseOverride = (request) async {
          if (!request.url.path.contains('lyric')) return null;
          await gate.future;
          return _lyricResponse(_offlineLyrics);
        };
        try {
          await player.playSingle(_song('song'));
          switch (action) {
            case 'remove':
              await AudioCacheService.removeCache(
                'qq',
                'song',
                scope: fixture.scope,
              );
            case 'clear':
              await AudioCacheService.clearCache(scope: fixture.scope);
            case 'switch':
              await player.playSingle(
                SongSearchResult(
                  platform: MusicPlatform.local,
                  id: 'content://media/external/audio/media/123',
                  name: '下一首',
                  artist: '',
                  album: '',
                ),
              );
            case 'dispose':
              await player.disposeResources();
          }
          gate.complete();
          if (action == 'switch') {
            await _waitForCachedLyrics(fixture, 'song');
            expect(player.currentSong?.name, '下一首');
            expect(player.lyrics, isEmpty);
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await AudioCacheService.releaseMemoryContext(fixture.scope);
            final cache = Directory(
              '${fixture.directory.path}/${fixture.scope.audioCacheRelativePath}',
            );
            expect(
              await cache
                  .list()
                  .where((file) => file.path.contains('lyrics_'))
                  .toList(),
              isEmpty,
            );
          }
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      }, cached: true);
    });
  }

  test(
    'missing lyrics leave cached audio playable and retry on a later play',
    () async {
      await _scenario((fixture, player) async {
        fixture.responseOverride = (_) =>
            throw const SocketException('offline');
        await player.playSingle(_song('song'));
        await _until(player, () => !player.lyricsLoading);
        expect(player.errorMessage, isNull);
        expect(player.lyrics, isEmpty);
        expect(fixture.loaded.single, contains('cached.mp3'));
        expect(
          await AudioCacheService.getCachedPath(
            platformCode: 'qq',
            songId: 'song',
            scope: fixture.scope,
          ),
          isNotNull,
        );
        fixture.responseOverride = (request) async {
          if (!request.url.path.contains('lyric')) return null;
          return _lyricResponse(_offlineLyrics);
        };
        await player.playSingle(_song('song'));
        await _waitForCachedLyrics(fixture, 'song');
        expect(player.lyrics.single.translationText, 'Hello');
      }, cached: true);
    },
  );

  test('manual lyric selection replaces the associated cache', () async {
    await _scenario((fixture, player) async {
      fixture.responseOverride = (request) async {
        if (!request.url.path.contains('lyric')) return null;
        return _lyricResponse(_offlineLyrics);
      };
      await player.playSingle(_song('song'));
      final path = await _waitForCachedLyrics(fixture, 'song');
      fixture.responseOverride = (request) async {
        if (!request.url.path.contains('lyric')) return null;
        return _lyricResponse(LyricData(original: '[00:01.00]手动匹配的版本'));
      };
      await player.applyLyricCandidate(_song('alternate'));
      final saved = await AudioCacheService.getCachedLyrics(
        platformCode: 'qq',
        songId: 'song',
        audioPath: path,
        scope: fixture.scope,
      );
      expect(saved?.original, contains('手动匹配的版本'));
      fixture.responseOverride = (_) => throw const SocketException('offline');
      await player.playSingle(_song('song'));
      expect(player.lyrics.single.text, '手动匹配的版本');
    }, cached: true);
  });

  test(
    'Bilibili retries failed matching and associates lyrics with its cached page',
    () async {
      await _scenario((fixture, player) async {
        const cacheId = 'song_123_q30280';
        final cache = Directory(
          '${fixture.directory.path}/${fixture.scope.audioCacheRelativePath}',
        );
        final path = '${cache.path}/cached.mp3';
        await File('${cache.path}/_index.json').writeAsString(
          jsonEncode({
            'bilibili_$cacheId': {
              'filePath': path,
              'platformCode': 'bilibili',
              'songId': cacheId,
              'quality': '30280',
            },
          }),
        );
        final song = SongSearchResult(
          platform: MusicPlatform.bilibili,
          id: 'song',
          name: '你好',
          artist: '歌手',
          album: '',
          bilibiliCid: 123,
          bilibiliPages: const [
            BilibiliPageInfo(cid: 123, page: 1, title: '你好'),
          ],
        );
        fixture.responseOverride = (_) =>
            throw const SocketException('offline');
        await player.playSingle(song);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(player.errorMessage, isNull);
        expect(player.lyrics, isEmpty);
        fixture.responseOverride = (request) async {
          if (request.url.host == 'u.y.qq.com') {
            return http.Response(
              jsonEncode({
                'req_1': {
                  'code': 0,
                  'data': {
                    'body': {
                      'song': {
                        'list': [
                          {
                            'mid': 'qq-match',
                            'name': '你好',
                            'singer': [
                              {'name': '歌手'},
                            ],
                            'album': {'name': ''},
                          },
                        ],
                      },
                    },
                  },
                },
              }),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }
          if (request.url.path.contains('lyric')) {
            return _lyricResponse(_offlineLyrics);
          }
          return http.Response('{}', 200);
        };
        await player.playSingle(song);
        expect(
          await _waitForCachedLyrics(
            fixture,
            cacheId,
            platformCode: 'bilibili',
          ),
          path,
        );
        expect(player.lyrics.single.translationText, 'Hello');
        final requestCount = fixture.requestCount;
        fixture.responseOverride = (_) =>
            throw const SocketException('offline');
        await player.playSingle(song);
        expect(player.lyrics.single.primaryText, '你好');
        expect(fixture.requestCount, requestCount);
      }, cached: true);
    },
  );

  for (final platform in [MusicPlatform.qq, MusicPlatform.bilibili]) {
    test(
      'downloaded $platform plays and restores without network requests',
      () async {
        await _scenario((fixture, player) async {
          final entry = DownloadEntry(
            id: 'a' * 24,
            song: SongSearchResult(
              platform: platform,
              id: 'offline',
              name: 'offline',
              artist: 'artist',
              album: 'album',
              bilibiliCid: platform == MusicPlatform.bilibili ? 123 : null,
            ),
            quality: 'flac',
            status: DownloadStatus.completed,
            fileName: '${'a' * 24}.mp3',
          );
          final folder = sha256
              .convert(utf8.encode(fixture.scope.userId))
              .toString()
              .substring(0, 16);
          final dir = await Directory(
            '${fixture.directory.path}/downloads/$folder/media',
          ).create(recursive: true);
          await File(
            '${dir.path}/${entry.fileName}',
          ).writeAsBytes(List.filled(4096, 0));
          await File(
            '${dir.path}/${entry.id}.lrc',
          ).writeAsString('[00:00.00]离线歌词');
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
            fixture.scope.preferenceKey(DownloadManager.preferenceKey),
            jsonEncode({
              'version': 1,
              'wifiOnly': true,
              'entries': [entry.toJson()],
            }),
          );
          await player.playSingle(entry.offlineSong);
          expect(fixture.requestCount, 0);
          expect(fixture.loaded.single, contains(entry.fileName!));
          expect(player.lyrics.single.text, '离线歌词');
          final persistedSong = SongSearchResult.fromQueueItem(
            player.currentSong!,
          ).compactForPlaybackPersistence();
          expect(
            SongSearchResult.fromJson(persistedSong.toJson()).downloadId,
            entry.id,
          );
          fixture.failAllLoads = true;
          await player.playSingle(entry.offlineSong);
          expect(fixture.requestCount, 0);
          expect(player.isLoading, isFalse);
          expect(player.errorMessage, isNotNull);
        });
      },
    );
  }

  test(
    'local playback never contacts a resolver even after native failures',
    () async {
      await _scenario((fixture, player) async {
        final song = SongSearchResult(
          platform: MusicPlatform.local,
          id: 'content://media/external/audio/media/123',
          name: 'local',
          artist: 'artist',
          album: 'album',
        );
        await player.playSingle(song);
        expect(fixture.loaded.single, song.id);
        expect(fixture.requestCount, 0);
        expect(player.playbackSourceOptions(MusicPlatform.local), isEmpty);
        fixture.failAllLoads = true;
        await player.playSingle(song);
        expect(fixture.loaded, hasLength(2));
        expect(fixture.requestCount, 0);
        expect(player.errorMessage, isNotNull);
        expect(player.isLoading, isFalse);
      });
    },
  );

  test('playback and download resolution do not cancel each other', () async {
    await _scenario((fixture, player) async {
      await player.setPlaybackSource(
        MusicPlatform.qq,
        PlaybackSource.qingMusic,
      );
      fixture.install(DownloadManager.channel, (_) async => false);
      fixture.install(
        const MethodChannel('music_player/download_network'),
        (_) async => null,
      );
      final playingGate = fixture.resolutionGates['playing'] =
          Completer<void>();
      final downloadGate = fixture.resolutionGates['download'] =
          Completer<void>();
      try {
        await player.downloads.setWifiOnly(false);
        final playing = player.playSingle(_song('playing'));
        await fixture.waitForResolution('playing');
        final entry = await player.downloadSong(_song('download'));
        await fixture.waitForResolution('download');
        playingGate.complete();
        await playing.timeout(const Duration(seconds: 2));
        expect(player.errorMessage, isNull);
        expect(fixture.loaded.single, contains('playing.mp3'));

        await player.playSingle(_song('next'));
        expect(player.errorMessage, isNull);
        expect(fixture.loaded.last, contains('next.mp3'));
        expect(entry.status, DownloadStatus.downloading);
        expect(entry.error, isNull);
        await player.downloads.suspend().timeout(const Duration(seconds: 1));
        expect(entry.status, DownloadStatus.paused);
      } finally {
        if (!playingGate.isCompleted) playingGate.complete();
        if (!downloadGate.isCompleted) downloadGate.complete();
      }
    });
  });

  test(
    'end-of-track timer suppresses queue advancement and repeated completion',
    () async {
      await _scenario((fixture, player) async {
        await player.playFromSearchResults([_song('song'), _song('next')], 0);
        player.sleepTimer.stopAfterTrack();
        await fixture.readyEvent(state: 4);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await fixture.readyEvent(state: 4);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(player.currentIndex, 0);
        expect(fixture.loaded, hasLength(1));
        expect(player.sleepTimer.active, isFalse);
        await player.playNext();
        expect(player.currentIndex, 1);
        player.sleepTimer.start(const Duration(minutes: 15));
        await player.prepareForUserSwitch();
        expect(player.sleepTimer.active, isFalse);
      });
    },
  );

  for (final disposeDuringLoad in [false, true]) {
    test(
      'shuffle removal cancels stale loads (dispose: $disposeDuringLoad)',
      () async {
        await _scenario((fixture, player) async {
          await player.setPlaybackSource(
            MusicPlatform.qq,
            PlaybackSource.qingMusic,
          );
          await player.playFromSearchResults([
            _song('a'),
            _song('b'),
            _song('c'),
          ], 1);
          player.togglePlayMode();
          player.togglePlayMode();
          final removedGate = fixture.resolutionGates['a'] = Completer<void>();
          final successorGate = disposeDuringLoad
              ? fixture.resolutionGates['c'] = Completer<void>()
              : null;
          final removedPlayback = player.playQueueItem(0);
          try {
            await fixture.waitForResolution('a');
            player.removeFromQueue(0);
            expect(player.currentSong!.id, 'c');

            if (disposeDuringLoad) {
              await fixture.waitForResolution('c');
              await player.disposeResources();
            } else {
              await _until(player, () => !player.isLoading);
              expect(player.errorMessage, isNull);
            }
          } finally {
            removedGate.complete();
            successorGate?.complete();
            await removedPlayback.timeout(const Duration(seconds: 2));
          }
          await Future<void>.delayed(Duration.zero);
          expect(
            fixture.loaded.map((url) => Uri.parse(url).path),
            disposeDuringLoad ? ['/b.mp3'] : ['/b.mp3', '/c.mp3'],
          );
          if (disposeDuringLoad) {
            expect(player.currentSong, isNull);
            expect(player.queue, isEmpty);
          } else {
            expect(player.currentSong!.id, 'c');
          }
        });
      },
    );
  }

  test('shuffle removal handles a successor native load failure', () async {
    await _scenario((fixture, player) async {
      await player.setPlaybackSource(
        MusicPlatform.qq,
        PlaybackSource.qingMusic,
      );
      await player.playFromSearchResults([
        _song('a'),
        _song('b'),
        _song('c'),
      ], 1);
      player.togglePlayMode();
      player.togglePlayMode();
      await player.playNext();
      final unplayed = player.currentSong!.id == 'a' ? 'c' : 'a';
      final loadedBefore = fixture.loaded.length;
      fixture.failAllLoads = true;

      player.removeFromQueue(player.currentIndex);
      await _until(player, () => !player.isLoading);

      expect(player.currentSong!.id, unplayed);
      expect(player.currentSong!.loading, isFalse);
      expect(player.errorMessage, isNotNull);
      expect(fixture.loaded, hasLength(loadedBefore + 1));
    });
  });

  test('shuffle removal is ignored while preparing a user switch', () async {
    await _scenario((fixture, player) async {
      await player.playFromSearchResults([_song('a'), _song('b')], 0);
      player.togglePlayMode();
      player.togglePlayMode();
      await player.prepareForUserSwitch();

      player.removeFromQueue(0);
      expect(player.queue.map((song) => song.id), ['a', 'b']);
      expect(player.currentSong!.id, 'a');

      await player.cancelPreparedUserSwitch();
      player.removeFromQueue(0);
      await _until(player, () => !player.isLoading);
      expect(player.currentSong!.id, 'b');
      expect(player.errorMessage, isNull);
    });
  });

  test('quality changes bypass old cache and retain paused position', () async {
    await _scenario((fixture, player) async {
      await player.playFromSearchResults([_song('song')], 0);
      await player.pause();
      await player.seekTo(const Duration(seconds: 37));
      final playCalls = fixture.playCalls;
      await player.setCommonLevel(CommonLevel.k320);
      expect(fixture.loaded, hasLength(2));
      expect(Uri.parse(fixture.loaded.last).host, 'audio-qing.test');
      expect(fixture.seekPositions.last, 37000000);
      expect(player.position, const Duration(seconds: 37));
      expect(player.isPlaying, isFalse);
      expect(fixture.playCalls, playCalls);
      expect(fixture.requestedQualities.last, 'exhigh');
      expect(
        await AudioCacheService.getCachedPath(
          platformCode: 'qq',
          songId: 'song',
          quality: '320k',
          scope: fixture.scope,
        ),
        isNull,
      );
      expect(
        await AudioCacheService.getCachedPath(
          platformCode: 'qq',
          songId: 'song',
          quality: 'flac',
          scope: fixture.scope,
        ),
        isNotNull,
      );
      await player.setCommonLevel(CommonLevel.k320);
      expect(fixture.loaded, hasLength(2));
      await player.seekTo(const Duration(seconds: 179));
      await player.setCommonLevel(CommonLevel.hires);
      expect(player.position, const Duration(seconds: 179));
    }, cached: true);
  });

  test('quality remains global for subsequent tracks and restart', () async {
    await _scenario((fixture, player) async {
      await player.playFromSearchResults([_song('song'), _song('next')], 0);
      await player.setCommonLevel(CommonLevel.k128);
      await player.playNext();
      expect(fixture.requestedQualities.last, 'standard');
      expect(player.currentSong!.id, 'next');
      final restored = PlayerProvider(activateRestoredSession: false);
      try {
        await restored.settingsReady;
        expect(restored.commonLevel, CommonLevel.k128);
      } finally {
        await restored.disposeResources();
      }
    });
  });

  test(
    'quality resolution failure finishes cleanly without changing queue',
    () async {
      await _scenario((fixture, player) async {
        await player.playFromSearchResults([_song('song')], 0);
        fixture.failAllLoads = true;
        await player.setCommonLevel(CommonLevel.hires);
        expect(player.changingAudioQuality, isFalse);
        expect(player.isLoading, isFalse);
        expect(player.errorMessage, isNotNull);
        expect(player.currentSong!.id, 'song');
        expect(player.queue, hasLength(1));
      });
    },
  );

  test(
    'a broken resolver winner is excluded after native load failure',
    () async {
      await _scenario((fixture, player) async {
        fixture.failQingLoads = true;
        await player.playFromSearchResults([_song('song')], 0);
        expect(fixture.loaded.map((url) => Uri.parse(url).host), [
          'audio-qing.test',
          'audio-hyw.test',
        ]);
        expect(player.currentPlaybackSource, PlaybackSource.hyw);
        expect(player.isLoading, isFalse);
        expect(player.currentSong!.loading, isFalse);
        expect(player.errorMessage, isNull);
      });
    },
  );

  test('stream failure does not reuse the failed cached URL', () async {
    await _scenario((fixture, player) async {
      await player.playFromSearchResults([_song('song')], 0);
      expect(player.currentPlaybackSource, PlaybackSource.qingMusic);
      final recovered = _until(
        player,
        () =>
            !player.isLoading &&
            player.currentPlaybackSource == PlaybackSource.hyw,
      );
      await fixture.failStream();
      await recovered;
      expect(fixture.loaded.map((url) => Uri.parse(url).host), [
        'audio-qing.test',
        'audio-hyw.test',
      ]);
      expect(player.currentSong!.loading, isFalse);
      expect(
        await player.switchCurrentPlaybackSource(
          PlaybackSource.hyw,
          expectedSong: PlayQueueItem.fromSearchResult(_song('different-song')),
        ),
        isFalse,
      );
    });
  });

  test(
    'a manual source does not stick to the next occurrence of the song',
    () async {
      await _scenario((fixture, player) async {
        await player.playFromSearchResults([_song('song'), _song('song')], 0);
        await player.switchCurrentPlaybackSource(PlaybackSource.hyw);
        expect(player.currentPlaybackSource, PlaybackSource.hyw);
        await player.playNext();
        expect(player.currentIndex, 1);
        expect(player.currentPlaybackSource, PlaybackSource.qingMusic);
        expect(Uri.parse(fixture.loaded.last).host, 'audio-qing.test');
      });
    },
  );

  test('stream and load errors do not start competing recoveries', () async {
    await _scenario((fixture, player) async {
      fixture.failQingLoads = true;
      fixture.emitLoadError = true;
      await player.playFromSearchResults([_song('song')], 0);
      expect(fixture.loaded.map((url) => Uri.parse(url).host), [
        'audio-qing.test',
        'audio-hyw.test',
      ]);
      expect(player.currentPlaybackSource, PlaybackSource.hyw);
      expect(player.errorMessage, isNull);
      expect(player.currentSong!.loading, isFalse);
    });
  });

  test(
    'exhausted native candidates stop with no reusable failed URL',
    () async {
      await _scenario((fixture, player) async {
        fixture.failAllLoads = true;
        await player.playFromSearchResults([_song('song')], 0);
        expect(fixture.loaded, hasLength(2));
        expect(player.isLoading, isFalse);
        expect(player.currentSong!.loading, isFalse);
        expect(player.errorMessage, isNotNull);
        expect(player.currentSong!.playUrl, isNull);
      });
    },
  );

  test(
    'temporary automatic mode does not alter a manual platform default',
    () async {
      await _scenario((fixture, player) async {
        await player.setPlaybackSource(MusicPlatform.qq, PlaybackSource.hyw);
        await player.playFromSearchResults([_song('song'), _song('next')], 0);
        expect(player.currentPlaybackSource, PlaybackSource.hyw);
        await player.switchCurrentPlaybackSource(PlaybackSource.automatic);
        expect(player.currentPlaybackSource, PlaybackSource.qingMusic);
        expect(player.playbackSourceFor(MusicPlatform.qq), PlaybackSource.hyw);
        await player.playNext();
        expect(player.currentPlaybackSource, PlaybackSource.hyw);
      });
    },
  );
}

Future<void> _scenario(
  Future<void> Function(_NativeFixture fixture, PlayerProvider player) action, {
  bool cached = false,
}) async {
  final fixture = await _NativeFixture.create(cached: cached);
  try {
    await http.runWithClient(() async {
      final player = PlayerProvider(
        dataScope: fixture.scope,
        activateRestoredSession: false,
      );
      try {
        await Future.wait([player.settingsReady, player.playbackStateReady]);
        await action(fixture, player);
      } finally {
        await player.disposeResources();
        await AudioCacheService.releaseMemoryContext(fixture.scope);
      }
    }, () => MockClient(fixture.request));
  } finally {
    await fixture.dispose();
  }
}

final _offlineLyrics = LyricData(
  original: '[00:01.00]你好',
  translated: '[00:01.00]Hello',
  wordSynced: '[1000,1000](1000,500,0)你(1500,500,0)好',
);

http.Response _lyricResponse(LyricData lyrics) => http.Response(
  jsonEncode({
    'code': 0,
    'lyric': lyrics.original,
    'trans': lyrics.translated,
    'qrc': lyrics.wordSynced,
  }),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Future<String> _waitForCachedLyrics(
  _NativeFixture fixture,
  String id, {
  String platformCode = 'qq',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final path = await AudioCacheService.getCachedPath(
      platformCode: platformCode,
      songId: id,
      scope: fixture.scope,
    );
    if (path != null &&
        await AudioCacheService.getCachedLyrics(
              platformCode: platformCode,
              songId: id,
              audioPath: path,
              scope: fixture.scope,
            ) !=
            null) {
      return path;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Lyrics were not associated with the cached audio');
}

Future<void> _until(PlayerProvider player, bool Function() predicate) async {
  final done = Completer<void>();
  void check() {
    if (!done.isCompleted && predicate()) done.complete();
  }

  player.addListener(check);
  try {
    check();
    await done.future.timeout(const Duration(seconds: 2));
  } finally {
    player.removeListener(check);
  }
}

Future<void> _expectCheckpoint(
  _NativeFixture fixture,
  SongSearchResult song,
  Duration position,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    final history = await PlaybackHistoryService.load(scope: fixture.scope);
    final session = await PlaybackStateService.load(scope: fixture.scope);
    final matches = history
        .where((entry) => entry.key == PlaybackHistoryService.keyForSong(song))
        .toList();
    final entry = matches.isEmpty ? null : matches.first;
    if (entry?.position.inMilliseconds == position.inMilliseconds &&
        session?.position.inMilliseconds == position.inMilliseconds &&
        session?.isPlaying == false) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final history = await PlaybackHistoryService.load(scope: fixture.scope);
  final entry = history.singleWhere(
    (entry) => entry.key == PlaybackHistoryService.keyForSong(song),
  );
  final session = await PlaybackStateService.load(scope: fixture.scope);
  expect(entry.position.inMilliseconds, position.inMilliseconds);
  expect(session, isNotNull);
  expect(session!.position.inMilliseconds, position.inMilliseconds);
  expect(session.isPlaying, isFalse);
}

Future<void> _expectResumed(
  _NativeFixture fixture,
  PlayerProvider player,
  Duration position,
) async {
  await _until(player, () => player.isPlaying);
  expect(fixture.seekPositions.last, position.inMilliseconds * 1000);
  expect(
    player.position.inMilliseconds,
    inInclusiveRange(position.inMilliseconds, position.inMilliseconds + 1000),
  );
}

SongSearchResult _song(String id) => SongSearchResult(
  platform: MusicPlatform.qq,
  id: id,
  name: id,
  artist: 'artist',
  album: 'album',
);

class _NativeFixture {
  static var sequence = 0;
  final Directory directory;
  final UserDataScope scope;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final List<MethodChannel> channels = [];
  final List<String> loaded = [];
  final List<String> requestedQualities = [];
  final List<int> seekPositions = [];
  final Map<String, Completer<void>> resolutionGates = {};
  final Set<String> resolvingIds = {};
  int playCalls = 0;
  int requestCount = 0;
  String? playerId;
  bool failQingLoads = false;
  bool failAllLoads = false;
  bool emitLoadError = false;
  String? audioBaseUrl;
  Future<http.Response?> Function(http.Request)? responseOverride;
  Completer<void>? loadGate;
  Completer<void>? loadStarted;

  _NativeFixture(this.directory, this.scope);

  static Future<_NativeFixture> create({required bool cached}) async {
    final directory = await Directory.systemTemp.createTemp(
      'player_source_test_',
    );
    final fixture = _NativeFixture(
      directory,
      UserDataScope('source-test-${sequence++}'),
    );
    SharedPreferences.setMockInitialValues({
      PlaybackSourceConfig.preferenceKey: jsonEncode(
        PlaybackSourceConfig.defaults()
            .copyWith(
              chkszEnabled: false,
              xinghaiEnabled: false,
              gdStudioEnabled: false,
              qingMusicUrl: 'https://qing.test/resolve',
              hywBaseUrl: 'https://hyw.test',
            )
            .toJson(),
      ),
    });
    fixture.install(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    fixture.install(
      const MethodChannel('com.ryanheise.audio_session'),
      (_) async => null,
    );
    fixture.install(const MethodChannel('com.ryanheise.just_audio.methods'), (
      call,
    ) async {
      if (call.method == 'init') {
        final id = (call.arguments as Map)['id'] as String;
        fixture.playerId = id;
        fixture.install(
          MethodChannel('com.ryanheise.just_audio.events.$id'),
          (_) async => null,
        );
        fixture.install(
          MethodChannel('com.ryanheise.just_audio.data.$id'),
          (_) async => null,
        );
        fixture.install(MethodChannel('com.ryanheise.just_audio.methods.$id'), (
          call,
        ) async {
          if (call.method == 'play') fixture.playCalls++;
          if (call.method == 'seek') {
            fixture.seekPositions.add(
              (call.arguments as Map)['position'] as int,
            );
            await fixture.readyEvent(
              position: Duration(microseconds: fixture.seekPositions.last),
              targetId: id,
            );
          }
          if (call.method == 'load') {
            final url =
                ((call.arguments as Map)['audioSource'] as Map)['uri']
                    as String;
            fixture.loaded.add(url);
            if (fixture.loadGate case final gate?) {
              await fixture.readyEvent(state: 1, targetId: id);
              final started = fixture.loadStarted;
              if (started != null && !started.isCompleted) started.complete();
              await gate.future;
            }
            if (fixture.failAllLoads ||
                (fixture.failQingLoads &&
                    Uri.parse(url).host == 'audio-qing.test')) {
              if (fixture.emitLoadError) await fixture.failStream();
              throw PlatformException(code: '404', message: 'audio missing');
            }
            await fixture.readyEvent(targetId: id);
            return {'duration': 180000000};
          }
          return <String, dynamic>{};
        });
      }
      return <String, dynamic>{};
    });
    if (cached) {
      final cache = await Directory(
        '${directory.path}/${fixture.scope.audioCacheRelativePath}',
      ).create(recursive: true);
      final file = await File(
        '${cache.path}/cached.mp3',
      ).writeAsBytes(List.filled(16384, 0));
      await File('${cache.path}/_index.json').writeAsString(
        jsonEncode({
          'qq_song': {
            'filePath': file.path,
            'name': 'song',
            'artist': 'artist',
            'platformCode': 'qq',
            'songId': 'song',
            'quality': 'flac',
          },
        }),
      );
    }
    return fixture;
  }

  void install(
    MethodChannel channel,
    Future<Object?> Function(MethodCall) handler,
  ) {
    channels.add(channel);
    messenger.setMockMethodCallHandler(channel, handler);
  }

  Future<void> readyEvent({
    int state = 3,
    Duration position = Duration.zero,
    String? targetId,
  }) => _event(
    const StandardMethodCodec().encodeSuccessEnvelope({
      'processingState': state,
      'updateTime': DateTime.now().millisecondsSinceEpoch,
      'updatePosition': position.inMicroseconds,
      'bufferedPosition': 0,
      'duration': 180000000,
      'currentIndex': 0,
    }),
    targetId: targetId,
  );

  Future<void> failStream() => _event(
    const StandardMethodCodec().encodeErrorEnvelope(
      code: '404',
      message: 'stream failed',
    ),
  );

  Future<void> _event(ByteData data, {String? targetId}) async {
    await messenger.handlePlatformMessage(
      'com.ryanheise.just_audio.events.${targetId ?? playerId}',
      data,
      (_) {},
    );
  }

  Future<http.Response> request(http.Request request) async {
    requestCount++;
    final override = await responseOverride?.call(request);
    if (override != null) return override;
    if (request.url.host == 'qing.test') {
      final body = jsonDecode(request.body) as Map;
      final id = body['rid'] as String;
      resolvingIds.add(id);
      await resolutionGates[id]?.future;
      requestedQualities.add(body['level'] as String);
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'url': '${audioBaseUrl ?? 'https://audio-qing.test'}/$id.mp3',
          },
        }),
        200,
      );
    }
    if (request.url.host == 'hyw.test') {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return http.Response(
        jsonEncode({
          'code': 200,
          'url':
              'https://audio-hyw.test/${request.url.queryParameters['songId']}.mp3',
        }),
        200,
      );
    }
    return http.Response('{}', 200);
  }

  Future<void> waitForResolution(String id) async {
    final end = DateTime.now().add(const Duration(seconds: 2));
    while (!resolvingIds.contains(id) && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(resolvingIds, contains(id));
  }

  Future<void> dispose() async {
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    await directory.delete(recursive: true);
  }
}
