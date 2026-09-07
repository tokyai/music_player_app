import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/services/audio_cache_service.dart';
import 'package:music_player_app/services/user_data_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'quality replacement retains good audio on failure and bounds cache files',
    () async {
      final originalOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final directory = await Directory.systemTemp.createTemp(
        'audio_quality_cache_',
      );
      final scope = UserDataScope(
        'cache-quality-${DateTime.now().microsecondsSinceEpoch}',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        if (request.uri.path == '/fail.mp3') {
          request.response.statusCode = 503;
        } else {
          request.response.add(List<int>.filled(16384, 1));
        }
        await request.response.close();
      });
      Future<String?> cache(String quality, {bool fail = false}) =>
          AudioCacheService.cacheAudio(
            platformCode: 'qq',
            songId: 'test',
            name: 'test',
            artist: 'artist',
            quality: quality,
            scope: scope,
            url: 'http://127.0.0.1:${server.port}/${fail ? 'fail' : 'ok'}.mp3',
          );
      Future<String?> lookup(String quality) => AudioCacheService.getCachedPath(
        platformCode: 'qq',
        songId: 'test',
        quality: quality,
        scope: scope,
      );
      try {
        final first = await cache('128k');
        expect(first, isNotNull);
        expect(await lookup('128k'), first);
        expect(await lookup('flac'), isNull);
        expect(await cache('flac', fail: true), isNull);
        expect(await lookup('128k'), first);
        expect(await File(first!).exists(), isTrue);
        for (final quality in ['flac', '128k', 'flac']) {
          final next = await cache(quality);
          expect(next, isNotNull);
          expect(await lookup(quality), next);
          final cacheDir = Directory(
            '${directory.path}/${scope.audioCacheRelativePath}',
          );
          final files = await cacheDir
              .list()
              .where((item) => item.path.endsWith('.mp3'))
              .toList();
          expect(files, hasLength(1));
        }
        await AudioCacheService.releaseMemoryContext(scope);
        expect(await lookup('flac'), isNotNull);
        final previousPath = await lookup('flac');
        final blockedIndex = await Directory(
          '${directory.path}/${scope.audioCacheRelativePath}/_index.json.tmp',
        ).create();
        expect(await cache('hires'), isNull);
        expect(await lookup('flac'), previousPath);
        expect(await File(previousPath!).exists(), isTrue);
        await blockedIndex.delete();
        await AudioCacheService.releaseMemoryContext(scope);
        expect(await lookup('flac'), previousPath);
      } finally {
        await AudioCacheService.releaseMemoryContext(scope);
        await subscription.cancel();
        await server.close(force: true);
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
        HttpOverrides.global = originalOverrides;
      }
    },
  );
}
