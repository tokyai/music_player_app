import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/audio_cache_service.dart';
import 'package:music_player_app/services/user_data_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Directory cache;
  late UserDataScope scope;
  late Map<String, String> audioPaths;
  var sequence = 0;
  final lyrics = LyricData(
    original: '[00:01.00]你好',
    translated: '[00:01.00]Hello',
    romaji: '[00:01.00]ni hao',
    wordSynced: '[1000,1000](1000,500,0)你(1500,500,0)好',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('audio_lyrics_test_');
    scope = UserDataScope('audio-lyrics-${sequence++}');
    messenger.setMockMethodCallHandler(channel, (_) async => root.path);
    cache = await Directory(
      '${root.path}/${scope.audioCacheRelativePath}',
    ).create(recursive: true);
    final index = <String, dynamic>{};
    audioPaths = {};
    for (final (platform, id) in [
      ('qq', 'one'),
      ('qq', 'two'),
      ('163', 'one'),
    ]) {
      final key = '${platform}_$id';
      final file = await File(
        '${cache.path}/$key.mp3',
      ).writeAsBytes(List<int>.filled(16384, 0));
      audioPaths[key] = file.path;
      index[key] = {
        'platformCode': platform,
        'songId': id,
        'name': '同名歌曲',
        'artist': '同一歌手',
        'filePath': file.path,
        'quality': 'flac',
      };
    }
    await File('${cache.path}/_index.json').writeAsString(jsonEncode(index));
  });

  tearDown(() async {
    await AudioCacheService.releaseMemoryContext(scope);
    UserDataScope.markRestored(scope.userId);
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  Future<bool> save({
    String platform = 'qq',
    String id = 'one',
    LyricData? data,
    bool Function()? isCancelled,
  }) => AudioCacheService.cacheLyrics(
    platformCode: platform,
    songId: id,
    audioPath: audioPaths['${platform}_$id']!,
    lyrics: data ?? lyrics,
    isCancelled: isCancelled,
    scope: scope,
  );

  Future<LyricData?> read({String platform = 'qq', String id = 'one'}) =>
      AudioCacheService.getCachedLyrics(
        platformCode: platform,
        songId: id,
        audioPath: audioPaths['${platform}_$id']!,
        scope: scope,
      );

  Future<List<File>> lyricFiles() async => cache
      .list()
      .where(
        (file) =>
            file is File &&
            file.path.endsWith('.json') &&
            !file.path.endsWith('_index.json'),
      )
      .cast<File>()
      .toList();

  test(
    'lyrics survive restart with translation and word timing intact',
    () async {
      expect(await save(), isTrue);
      await AudioCacheService.releaseMemoryContext(scope);
      final restored = await read();
      expect(restored?.original, lyrics.original);
      expect(restored?.translated, lyrics.translated);
      expect(restored?.romaji, lyrics.romaji);
      expect(restored?.wordSynced, lyrics.wordSynced);
      final size = await (await lyricFiles()).single.length();
      final list = await AudioCacheService.getCacheList(scope: scope);
      expect(
        list
            .firstWhere(
              (song) => song.platformCode == 'qq' && song.songId == 'one',
            )
            .fileSize,
        16384 + size,
      );
      expect(
        await AudioCacheService.getCacheSize(scope: scope),
        3 * 16384 + size,
      );
      expect(
        await AudioCacheService.getCachedLyrics(
          platformCode: 'qq',
          songId: 'one',
          audioPath: audioPaths['qq_two']!,
          scope: scope,
        ),
        isNull,
      );
    },
  );

  test(
    'same titles remain separate by song and platform; deletion is paired',
    () async {
      await save();
      await save(
        id: 'two',
        data: LyricData(original: '[00:01.00]第二首'),
      );
      await save(
        platform: '163',
        data: LyricData(original: '[00:01.00]另一平台'),
      );
      expect((await read(id: 'two'))?.original, contains('第二首'));
      expect((await read(platform: '163'))?.original, contains('另一平台'));
      expect(await lyricFiles(), hasLength(3));
      await AudioCacheService.removeCache('qq', 'one', scope: scope);
      expect(await File(audioPaths['qq_one']!).exists(), isFalse);
      expect(await read(), isNull);
      expect(await lyricFiles(), hasLength(2));
      expect((await read(id: 'two'))?.original, contains('第二首'));
      await AudioCacheService.clearCache(scope: scope);
      expect(await lyricFiles(), isEmpty);
      expect(await AudioCacheService.getCacheList(scope: scope), isEmpty);
      expect(await AudioCacheService.getCacheSize(scope: scope), 0);
    },
  );

  for (final removeFirst in [true, false]) {
    test(
      'delete wins against a pending lyric write (remove first: $removeFirst)',
      () async {
        final operations = removeFirst
            ? [AudioCacheService.removeCache('qq', 'one', scope: scope), save()]
            : [
                save(),
                AudioCacheService.removeCache('qq', 'one', scope: scope),
              ];
        await Future.wait(operations);
        expect(await lyricFiles(), isEmpty);
        expect(await read(), isNull);
        expect(await save(), isFalse);
        expect(await File(audioPaths['qq_one']!).exists(), isFalse);
      },
    );
  }

  test(
    'clear and repeated writes leave no lyrics or temporary files',
    () async {
      await Future.wait([
        for (var i = 0; i < 8; i++) save(),
        AudioCacheService.clearCache(scope: scope),
        save(),
      ]);
      expect(await lyricFiles(), isEmpty);
      expect(
        await cache.list().where((file) => file.path.endsWith('.tmp')).toList(),
        isEmpty,
      );
      expect(await AudioCacheService.getCacheCount(scope: scope), 0);
    },
  );

  test(
    'cancelled or deleted users cannot write or recreate lyric caches',
    () async {
      var cancelled = false;
      final pending = save(isCancelled: () => cancelled);
      cancelled = true;
      expect(await pending, isFalse);
      expect(await lyricFiles(), isEmpty);
      await save();
      UserDataScope.markDeleted(scope.userId);
      await AudioCacheService.deleteUserCache(scope);
      expect(await cache.exists(), isFalse);
      expect(await save(), isFalse);
      expect(await read(), isNull);
      expect(await cache.exists(), isFalse);
    },
  );

  test('other users cannot read or overwrite associated lyrics', () async {
    await save();
    final otherScope = UserDataScope('${scope.userId}-other');
    try {
      expect(
        await AudioCacheService.getCachedLyrics(
          platformCode: 'qq',
          songId: 'one',
          audioPath: audioPaths['qq_one']!,
          scope: otherScope,
        ),
        isNull,
      );
      expect(
        await AudioCacheService.cacheLyrics(
          platformCode: 'qq',
          songId: 'one',
          audioPath: audioPaths['qq_one']!,
          lyrics: LyricData(original: '[00:01.00]别人的歌词'),
          scope: otherScope,
        ),
        isFalse,
      );
      expect((await read())?.original, lyrics.original);
    } finally {
      await AudioCacheService.releaseMemoryContext(otherScope);
    }
  });

  test(
    'failed or cancelled replacement preserves valid lyrics and audio',
    () async {
      await save();
      final lyricFile = (await lyricFiles()).single;
      final blocker = await Directory('${lyricFile.path}.tmp').create();
      expect(await save(data: LyricData(original: '[00:01.00]更新歌词')), isFalse);
      expect((await read())?.wordSynced, lyrics.wordSynced);
      expect(await File(audioPaths['qq_one']!).exists(), isTrue);
      await blocker.delete();
      expect(
        await save(
          data: LyricData(original: '[00:01.00]取消的更新'),
          isCancelled: () => File('${lyricFile.path}.tmp').existsSync(),
        ),
        isFalse,
      );
      expect(await File('${lyricFile.path}.tmp').exists(), isFalse);
      expect((await read())?.original, lyrics.original);
      expect(await save(data: LyricData(original: '[00:01.00]更新歌词')), isTrue);
      expect((await read())?.original, contains('更新歌词'));
    },
  );

  test(
    'invalid and oversized lyrics are cache misses without harming audio',
    () async {
      await save();
      expect(await save(data: LyricData()), isFalse);
      expect(
        await save(data: LyricData(original: 'x' * (256 * 1024 + 1))),
        isFalse,
      );
      expect((await read())?.original, lyrics.original);
      final file = (await lyricFiles()).single;
      final original = await file.readAsString();
      for (final content in [
        '{invalid json',
        jsonEncode({...jsonDecode(original) as Map, 'songId': 'two'}),
        jsonEncode({...jsonDecode(original) as Map, 'translated': 42}),
        jsonEncode({
          ...jsonDecode(original) as Map,
          'original': 'x' * (256 * 1024 + 1),
        }),
        'x' * (4 * 1024 * 1024 + 1),
      ]) {
        await file.writeAsString(content);
        expect(await read(), isNull);
        expect(
          await AudioCacheService.getCachedPath(
            platformCode: 'qq',
            songId: 'one',
            scope: scope,
          ),
          audioPaths['qq_one'],
        );
      }
      expect(await save(), isTrue);
      expect((await read())?.translated, lyrics.translated);
      await File(audioPaths['qq_one']!).delete();
      expect(await read(), isNull);
      expect(await save(), isFalse);
      await AudioCacheService.removeCache('qq', 'one', scope: scope);
      expect(await lyricFiles(), isEmpty);
    },
  );
}
