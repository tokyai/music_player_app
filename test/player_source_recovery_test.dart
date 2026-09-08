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
import 'package:music_player_app/services/user_data_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
          }
          if (call.method == 'load') {
            final url =
                ((call.arguments as Map)['audioSource'] as Map)['uri']
                    as String;
            fixture.loaded.add(url);
            if (fixture.failAllLoads ||
                (fixture.failQingLoads &&
                    Uri.parse(url).host == 'audio-qing.test')) {
              if (fixture.emitLoadError) await fixture.failStream();
              throw PlatformException(code: '404', message: 'audio missing');
            }
            await fixture.readyEvent();
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

  Future<void> readyEvent({int state = 3}) => _event(
    const StandardMethodCodec().encodeSuccessEnvelope({
      'processingState': state,
      'updateTime': DateTime.now().millisecondsSinceEpoch,
      'updatePosition': 0,
      'bufferedPosition': 0,
      'duration': 180000000,
      'currentIndex': 0,
    }),
  );

  Future<void> failStream() => _event(
    const StandardMethodCodec().encodeErrorEnvelope(
      code: '404',
      message: 'stream failed',
    ),
  );

  Future<void> _event(ByteData data) async {
    await messenger.handlePlatformMessage(
      'com.ryanheise.just_audio.events.$playerId',
      data,
      (_) {},
    );
  }

  Future<http.Response> request(http.Request request) async {
    requestCount++;
    if (request.url.host == 'qing.test') {
      final body = jsonDecode(request.body) as Map;
      final id = body['rid'] as String;
      resolvingIds.add(id);
      await resolutionGates[id]?.future;
      requestedQualities.add(body['level'] as String);
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {'url': 'https://audio-qing.test/$id.mp3'},
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
