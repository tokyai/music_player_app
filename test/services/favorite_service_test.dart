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

  test('reuses read-only favorite views until data changes', () async {
    final service = FavoriteService();
    await service.toggle(_song(MusicPlatform.qq, 'song-1', 'Song One'));

    final first = service.favorites;
    expect(identical(first, service.favorites), isTrue);

    await service.toggle(_song(MusicPlatform.qq, 'song-2', 'Song Two'));

    expect(identical(first, service.favorites), isFalse);
    expect(service.favorites.map((song) => song.id), ['song-2', 'song-1']);
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

  test('version 4 backup separates Bilibili favorites by user', () async {
    final service = FavoriteService();
    await service.toggle(_song(MusicPlatform.qq, 'song-1', 'Song One'));
    await service.toggle(_song(MusicPlatform.bilibili, 'BV1test', 'Video One'));
    await service.togglePlaylist(
      MusicPlatform.netease,
      PlaylistInfo(
        id: 'playlist-1',
        name: 'Playlist One',
        creator: 'Creator',
        trackCount: 30,
        tracks: const [],
      ),
    );

    final raw = service.exportJson(apiKey: 'api-key-for-backup');
    final exported = jsonDecode(raw) as Map<String, dynamic>;
    expect(exported['version'], 4);
    expect(exported['userDataVersion'], 1);
    expect(exported['songs'], hasLength(1));
    expect(exported['bilibili'], hasLength(1));
    expect(exported['playlists'], hasLength(1));
    expect(exported['apiKey'], 'api-key-for-backup');

    SharedPreferences.setMockInitialValues({});
    final restored = FavoriteService();
    final result = await restored.importJson(
      raw,
      mode: FavoriteImportMode.replace,
    );
    expect(restored.favorites.single.id, 'song-1');
    expect(restored.bilibiliFavorites.single.id, 'BV1test');
    expect(restored.favoritePlaylists.single.id, 'playlist-1');
    expect(result.playlistsAdded, 1);
    expect(result.bilibiliAdded, 1);
    expect(result.apiKeyPresent, isTrue);
    expect(result.apiKey, 'api-key-for-backup');
  });

  test(
    'legacy song-only replacement keeps current playlist favorites',
    () async {
      final service = FavoriteService();
      await service.togglePlaylist(
        MusicPlatform.qq,
        PlaylistInfo(
          id: 'keep-playlist',
          name: 'Keep Playlist',
          trackCount: 1,
          tracks: const [],
        ),
      );

      await service.importJson(
        jsonEncode([_song(MusicPlatform.kugou, 'legacy', 'Legacy').toJson()]),
        mode: FavoriteImportMode.replace,
      );

      expect(service.favorites.single.id, 'legacy');
      expect(service.favoritePlaylists.single.id, 'keep-playlist');
    },
  );

  test('legacy backup migrates Bilibili entries out of songs', () async {
    final service = FavoriteService();
    final raw = jsonEncode({
      'format': FavoriteService.exportFormat,
      'version': 2,
      'songs': [
        _song(MusicPlatform.qq, 'song-1', 'Song One').toJson(),
        _song(MusicPlatform.bilibili, 'BV1legacy', 'Legacy Video').toJson(),
      ],
    });

    final result = await service.importJson(
      raw,
      mode: FavoriteImportMode.replace,
    );

    expect(service.favorites.single.id, 'song-1');
    expect(service.bilibiliFavorites.single.id, 'BV1legacy');
    expect(result.added, 1);
    expect(result.bilibiliAdded, 1);
  });

  test(
    'saving playlists adds multiple entries and updates duplicates',
    () async {
      final service = FavoriteService();
      final first = PlaylistInfo(
        id: 'playlist-1',
        name: 'Playlist One',
        trackCount: 10,
        tracks: const [],
      );
      final second = PlaylistInfo(
        id: 'playlist-2',
        name: 'Playlist Two',
        trackCount: 20,
        tracks: const [],
      );

      expect(await service.savePlaylist(MusicPlatform.qq, first), isTrue);
      expect(await service.savePlaylist(MusicPlatform.netease, second), isTrue);
      expect(service.favoritePlaylists, hasLength(2));

      expect(
        await service.savePlaylist(
          MusicPlatform.qq,
          PlaylistInfo(
            id: first.id,
            name: 'Playlist One Updated',
            trackCount: 12,
            tracks: const [],
          ),
        ),
        isFalse,
      );
      expect(service.favoritePlaylists, hasLength(2));
      expect(
        service.favoritePlaylists
            .firstWhere((playlist) => playlist.id == first.id)
            .playlist
            .name,
        'Playlist One Updated',
      );

      final restored = FavoriteService();
      await restored.load();
      expect(restored.favoritePlaylists, hasLength(2));
      expect(
        restored.favoritePlaylists.map((playlist) => playlist.id),
        containsAll(['playlist-1', 'playlist-2']),
      );
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
