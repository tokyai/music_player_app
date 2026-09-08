import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/download_entry.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/download_manager.dart';
import 'package:music_player_app/services/user_data_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late HttpServer server;
  late StreamSubscription<HttpRequest> serverSub;
  HttpOverrides? originalOverrides;
  var requests = 0;
  var resolves = 0;
  var fail = false;
  var huge = false;
  Completer<void>? hold;
  Completer<void>? resolveHold;
  late DownloadManager manager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    originalOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    directory = await Directory.systemTemp.createTemp('kuzai_download_test_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = 0;
    resolves = 0;
    fail = false;
    huge = false;
    hold = null;
    resolveHold = null;
    serverSub = server.listen((request) async {
      requests++;
      if (hold != null) await hold!.future;
      try {
        if (huge) {
          request.response.contentLength = DownloadManager.maxAudioBytes + 1;
        }
        if (fail) {
          request.response.statusCode = 503;
        } else {
          request.response.add(List.filled(4096, 3));
        }
        if (huge) {
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await request.response.close();
      } catch (_) {}
    });
    messenger.setMockMethodCallHandler(DownloadManager.channel, (call) async {
      if (call.method == 'wifi') return false;
      if (call.method == 'writeTags') {
        throw PlatformException(code: 'UNSUPPORTED');
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('music_player/download_network'),
      (_) async => null,
    );
    manager = DownloadManager(
      scope: UserDataScope.defaultScope,
      directory: directory,
      resolve: (song, quality, cancelled, cancelSignal) async {
        resolves++;
        if (resolveHold != null) await resolveHold!.future;
        return SongDetail(
          name: song.name,
          artist: song.artist,
          album: song.album,
          url: 'http://127.0.0.1:${server.port}/audio.mp3',
          format: 'mp3',
          lyric: '[00:00.00]歌词',
        );
      },
    );
    await manager.ready;
  });
  tearDown(() async {
    if (hold != null && !hold!.isCompleted) hold!.complete();
    if (resolveHold != null && !resolveHold!.isCompleted) {
      resolveHold!.complete();
    }
    await manager.close();
    await serverSub.cancel();
    await server.close(force: true);
    messenger.setMockMethodCallHandler(DownloadManager.channel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('music_player/download_network'),
      null,
    );
    await directory.delete(recursive: true);
    HttpOverrides.global = originalOverrides;
  });

  test(
    'wifi-only queues without fetching, duplicate requests reuse the same task',
    () async {
      final entry = await manager.enqueue(_song('one'), 'flac');
      expect(
        identical(await manager.enqueue(_song('one'), 'flac'), entry),
        isTrue,
      );
      expect(manager.entries, hasLength(1));
      expect(entry.status, DownloadStatus.queued);
      expect(resolves, 0);
      expect(requests, 0);
      await manager.setWifiOnly(false);
      await _until(manager, () => entry.status == DownloadStatus.completed);
      final file = await manager.playablePath(entry.id);
      expect(file, isNotNull);
      expect(await File(file!).length(), 4096);
      expect(entry.warning, contains('标签'));
      expect(await manager.lyricsFor(entry.id), '[00:00.00]歌词');
      expect(
        (await Directory('${directory.path}/staging').list().toList()),
        isEmpty,
      );
      await manager.close();
      final restored = DownloadManager(
        scope: UserDataScope.defaultScope,
        directory: directory,
        resolve: (_, _, _, _) async => throw StateError('offline only'),
      );
      await restored.ready;
      expect(await restored.playablePath(entry.id), file);
      await restored.remove(restored.entries.single);
      expect(await File(file).exists(), isFalse);
      expect(restored.entries, isEmpty);
      await restored.close();
    },
  );

  test(
    'pause cancels active transfer and the next task remains bounded',
    () async {
      hold = Completer<void>();
      await manager.setWifiOnly(false);
      final entry = await manager.enqueue(_song('one'), 'flac');
      await _until(manager, () => requests == 1);
      await manager.pause(entry);
      expect(entry.status, DownloadStatus.paused);
      hold!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await manager.playablePath(entry.id), isNull);
      expect(
        await Directory('${directory.path}/staging').list().toList(),
        isEmpty,
      );
      await manager.resume(entry);
      await _until(manager, () => entry.status == DownloadStatus.completed);
      expect(requests, 2);
    },
  );

  test(
    'wifi loss cancels in-flight work and waits for wifi before retrying',
    () async {
      await manager.setWifiOnly(false);
      hold = Completer<void>();
      final entry = await manager.enqueue(_song('wifi'), 'flac');
      await _until(manager, () => requests == 1);
      await manager.setWifiOnly(true);
      hold!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(entry.status, DownloadStatus.queued);
      expect(await manager.playablePath(entry.id), isNull);
      expect(requests, 1);
      await messenger.handlePlatformMessage(
        'music_player/download_network',
        const StandardMethodCodec().encodeSuccessEnvelope(true),
        (_) {},
      );
      await _until(manager, () => entry.status == DownloadStatus.completed);
    },
  );

  test(
    'failed transfers allow explicit retry and do not publish partial audio',
    () async {
      fail = true;
      await manager.setWifiOnly(false);
      final entry = await manager.enqueue(_song('fail'), 'flac');
      await _until(manager, () => entry.status == DownloadStatus.failed);
      expect(await manager.playablePath(entry.id), isNull);
      fail = false;
      await manager.resume(entry);
      await _until(manager, () => entry.status == DownloadStatus.completed);
    },
  );

  test(
    'session suspension prevents late resolution from starting a transfer',
    () async {
      resolveHold = Completer<void>();
      await manager.setWifiOnly(false);
      final entry = await manager.enqueue(_song('late'), 'flac');
      await _until(manager, () => resolves == 1);
      final stopping = manager.suspend();
      await stopping.timeout(const Duration(seconds: 1));
      expect(resolveHold!.isCompleted, isFalse);
      resolveHold!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requests, 0);
      expect(entry.status, DownloadStatus.paused);
    },
  );

  test('over-sized audio is rejected without a retry loop', () async {
    huge = true;
    await manager.setWifiOnly(false);
    final entry = await manager.enqueue(_song('huge'), 'flac');
    await _until(manager, () => entry.status == DownloadStatus.failed);
    expect(entry.error, contains('256 MB'));
    expect(requests, 1);
    expect(await manager.playablePath(entry.id), isNull);
  });

  test(
    'closing twice cancels a pending resolver without late updates',
    () async {
      resolveHold = Completer<void>();
      await manager.setWifiOnly(false);
      final entry = await manager.enqueue(_song('close'), 'flac');
      await _until(manager, () => resolves == 1);
      var notifications = 0;
      manager.addListener(() => notifications++);
      final closing = manager.close();
      expect(identical(manager.close(), closing), isTrue);
      await closing.timeout(const Duration(seconds: 1));
      expect(resolveHold!.isCompleted, isFalse);
      resolveHold!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requests, 0);
      expect(notifications, 0);
      expect(entry.status, DownloadStatus.paused);
    },
  );

  test(
    'closing cancels the native tag worker before releasing its files',
    () async {
      final tagsStarted = Completer<void>();
      final tagsFinished = Completer<String>();
      var cancelCalls = 0;
      messenger.setMockMethodCallHandler(DownloadManager.channel, (call) async {
        if (call.method == 'wifi') return false;
        if (call.method == 'writeTags') {
          tagsStarted.complete();
          return tagsFinished.future;
        }
        if (call.method == 'cancelTags') {
          cancelCalls++;
          if (!tagsFinished.isCompleted) {
            tagsFinished.completeError(PlatformException(code: 'CANCELLED'));
          }
        }
        return null;
      });
      await manager.setWifiOnly(false);
      final entry = await manager.enqueue(_song('tags'), 'flac');
      await tagsStarted.future.timeout(const Duration(seconds: 2));
      await manager.close().timeout(const Duration(seconds: 1));
      expect(cancelCalls, greaterThanOrEqualTo(1));
      expect(entry.status, DownloadStatus.paused);
      expect(
        await Directory('${directory.path}/staging').list().toList(),
        isEmpty,
      );
    },
  );

  test('removing a task excludes overlapping enqueue and retry', () async {
    resolveHold = Completer<void>();
    await manager.setWifiOnly(false);
    final entry = await manager.enqueue(_song('remove'), 'flac');
    await _until(manager, () => resolves == 1);
    final removing = manager.remove(entry);
    await expectLater(
      manager.enqueue(_song('remove'), 'flac'),
      throwsStateError,
    );
    await manager.resume(entry);
    await removing.timeout(const Duration(seconds: 1));
    resolveHold!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(manager.entries, isEmpty);
    expect(requests, 0);
    expect(resolves, 1);
  });

  test(
    'suspension while loading preserves the index for a cancelled switch',
    () async {
      final entry = await manager.enqueue(_song('restored'), 'flac');
      await manager.close();
      final restored = DownloadManager(
        scope: UserDataScope.defaultScope,
        directory: directory,
        resolve: (_, _, _, _) async => throw StateError('must not resolve'),
      );
      addTearDown(restored.close);
      final loading = restored.ready;
      final suspending = restored.suspend();
      await Future.wait([loading, suspending]);
      restored.resumeSession();
      expect(restored.entries.single.id, entry.id);
      expect(restored.entries.single.status, DownloadStatus.paused);
    },
  );

  test('failed persistence never leaves a falsely completed file', () async {
    final entry = await manager.enqueue(_song('persist'), 'flac');
    SharedPreferencesStorePlatform.instance = _FailCompletedStore();
    await manager.setWifiOnly(false);
    await _until(manager, () => entry.status == DownloadStatus.failed);
    expect(await manager.playablePath(entry.id), isNull);
    final media = Directory('${directory.path}/media');
    expect(await media.list().toList(), isEmpty);
  });

  test(
    'corrupt persisted filenames are rejected without touching files',
    () async {
      await manager.close();
      final prefs = await SharedPreferences.getInstance();
      final bad = jsonEncode({
        'version': 1,
        'wifiOnly': false,
        'entries': [
          {
            'id': 'a' * 24,
            'song': _song('bad').toJson(),
            'quality': 'flac',
            'status': 'completed',
            'fileName': '../secret',
          },
        ],
      });
      await prefs.setString(DownloadManager.preferenceKey, bad);
      final corrupt = DownloadManager(
        scope: UserDataScope.defaultScope,
        directory: directory,
        resolve: (_, _, _, _) async => throw StateError('must not resolve'),
      );
      await corrupt.ready;
      expect(corrupt.error, isNotNull);
      await expectLater(
        corrupt.enqueue(_song('bad'), 'flac'),
        throwsStateError,
      );
      await corrupt.close();
      expect(prefs.getString(DownloadManager.preferenceKey), bad);
    },
  );

  test(
    'task count is bounded and restored active tasks require explicit resume',
    () async {
      for (var i = 0; i < DownloadManager.maxTasks; i++) {
        await manager.enqueue(_song('$i'), 'flac');
      }
      await expectLater(
        manager.enqueue(_song('overflow'), 'flac'),
        throwsStateError,
      );
      await manager.close();
      final restored = DownloadManager(
        scope: UserDataScope.defaultScope,
        directory: directory,
        resolve: (_, _, _, _) async => throw StateError('must not auto resume'),
      );
      await restored.ready;
      expect(
        restored.entries.every(
          (entry) => entry.status == DownloadStatus.paused,
        ),
        isTrue,
      );
      await restored.close();
    },
  );
}

SongSearchResult _song(String id) => SongSearchResult(
  platform: MusicPlatform.qq,
  id: id,
  name: 'song',
  artist: 'artist',
  album: 'album',
);

class _FailCompletedStore extends InMemorySharedPreferencesStore {
  _FailCompletedStore() : super.empty();
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (value is String && value.contains('"status":"completed"')) return false;
    return super.setValue(type, key, value);
  }
}

Future<void> _until(DownloadManager manager, bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!condition() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    condition(),
    isTrue,
    reason:
        '${manager.error} ${manager.entries.map((e) => '${e.status} ${e.error}')}',
  );
  // Completion persistence and temporary-file cleanup run after the status update.
  await Future<void>.delayed(const Duration(milliseconds: 20));
}
