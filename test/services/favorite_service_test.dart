import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'loads the upstream legacy array and removes duplicate entries',
    () async {
      final song = _song(MusicPlatform.qq, 'qq-1', 'Song One');
      SharedPreferences.setMockInitialValues({
        'favorites': jsonEncode([song.toJson(), song.toJson(), 'invalid']),
      });

      final service = FavoriteService();
      await service.load();

      expect(service.favorites, hasLength(1));
      expect(service.favorites.single.id, 'qq-1');
    },
  );

  test('exports a versioned backup and merges valid unique songs', () async {
    final existing = _song(MusicPlatform.qq, 'qq-1', 'Song One');
    final imported = _song(MusicPlatform.netease, '163-2', 'Song Two');
    final service = FavoriteService();
    await service.toggle(existing);

    final backup = jsonEncode({
      'format': FavoriteService.exportFormat,
      'version': FavoriteService.exportVersion,
      'songs': [
        existing.toJson(),
        imported.toJson(),
        {'id': 'broken'},
      ],
    });
    final result = await service.importJson(backup);

    expect(result.added, 1);
    expect(result.skipped, 2);
    expect(result.total, 3);
    expect(service.favorites.map((song) => song.id), ['qq-1', '163-2']);

    final exported = jsonDecode(service.exportJson()) as Map<String, dynamic>;
    expect(exported['format'], FavoriteService.exportFormat);
    expect(exported['version'], FavoriteService.exportVersion);
    expect(exported['songs'], hasLength(2));
  });

  test(
    'replace import overwrites existing favorites and persists them',
    () async {
      final service = FavoriteService();
      await service.toggle(_song(MusicPlatform.qq, 'old', 'Old Song'));
      final replacement = _song(MusicPlatform.kugou, 'new', 'New Song');

      final result = await service.importJson(
        jsonEncode([replacement.toJson()]),
        mode: FavoriteImportMode.replace,
      );

      expect(result.added, 1);
      expect(service.favorites.single.id, 'new');

      final restored = FavoriteService();
      await restored.load();
      expect(restored.favorites.single.id, 'new');
      expect(restored.favorites.single.platform, MusicPlatform.kugou);
    },
  );

  test(
    'batch source replacement keeps unmatched and conflicting songs',
    () async {
      final first = _song(MusicPlatform.netease, 'a', 'First');
      final second = _song(MusicPlatform.netease, 'b', 'Second');
      final existingTarget = _song(MusicPlatform.qq, 'taken', 'Existing');
      final service = FavoriteService();
      await service.importJson(
        jsonEncode([first.toJson(), second.toJson(), existingTarget.toJson()]),
        mode: FavoriteImportMode.replace,
      );

      final replaced = await service.replaceMany({
        FavoriteService.keyOf(first): _song(MusicPlatform.qq, 'new-a', 'First'),
        FavoriteService.keyOf(second): _song(
          MusicPlatform.qq,
          'taken',
          'Second',
        ),
      });

      expect(replaced, 1);
      expect(service.favorites.map(FavoriteService.keyOf), [
        FavoriteService.songKey(MusicPlatform.qq, 'new-a'),
        FavoriteService.songKey(MusicPlatform.netease, 'b'),
        FavoriteService.songKey(MusicPlatform.qq, 'taken'),
      ]);
    },
  );

  test('invalid backup does not change existing favorites', () async {
    final service = FavoriteService();
    await service.toggle(_song(MusicPlatform.qq, 'qq-1', 'Song One'));

    await expectLater(
      service.importJson('{not-json'),
      throwsA(isA<FormatException>()),
    );
    expect(service.favorites.single.id, 'qq-1');
  });

  test(
    'playlist favorites toggle, deduplicate and persist separately',
    () async {
      final playlist = PlaylistInfo(
        id: 'playlist-1',
        name: 'Favorite Playlist',
        coverUrl: 'https://example.com/cover.jpg',
        creator: 'Creator',
        trackCount: 18,
        tracks: const [],
      );
      final service = FavoriteService();

      expect(await service.togglePlaylist(MusicPlatform.qq, playlist), isTrue);
      expect(service.favoritePlaylists, hasLength(1));
      expect(service.isPlaylistFavorite(MusicPlatform.qq, playlist.id), isTrue);

      final restored = FavoriteService();
      await restored.load();
      expect(restored.favoritePlaylists, hasLength(1));
      expect(
        restored.favoritePlaylists.single.playlist.name,
        'Favorite Playlist',
      );
      expect(restored.favoritePlaylists.single.platform, MusicPlatform.qq);
      expect(restored.favorites, isEmpty);

      expect(
        await restored.togglePlaylist(MusicPlatform.qq, playlist),
        isFalse,
      );
      expect(restored.favoritePlaylists, isEmpty);
    },
  );
}

SongSearchResult _song(
  MusicPlatform platform,
  String id,
  String name, {
  String artist = 'Singer',
  String album = 'Album',
  int duration = 200,
}) {
  return SongSearchResult(
    platform: platform,
    id: id,
    name: name,
    artist: artist,
    album: album,
    duration: duration,
  );
}
