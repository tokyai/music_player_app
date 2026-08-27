import 'dart:async';

import '../models/song.dart';
import '../utils/song_source_matcher.dart';
import 'api_service.dart';
import 'favorite_service.dart';

class BatchFavoriteImportResult {
  final int requested;
  final int matched;
  final int added;
  final int alreadyFavorite;
  final List<String> notFound;
  final bool cancelled;

  const BatchFavoriteImportResult({
    required this.requested,
    required this.matched,
    required this.added,
    required this.alreadyFavorite,
    required this.notFound,
    this.cancelled = false,
  });
}

/// Resolves plain song names against standard music platforms and adds the
/// exact matches to the current user's favorites with bounded concurrency.
class BatchFavoriteImportService {
  static const maxSongCount = 30;
  static const _parallelSearches = 3;
  static const _searchTimeout = Duration(seconds: 12);
  static const _platforms = [
    MusicPlatform.qq,
    MusicPlatform.netease,
    MusicPlatform.kugou,
  ];

  const BatchFavoriteImportService._();

  static Future<BatchFavoriteImportResult> import({
    required ApiService api,
    required FavoriteService favorites,
    required Iterable<String> songNames,
    bool Function()? isCancelled,
  }) async {
    final names = _normalizeNames(songNames);
    if (names.length > maxSongCount) {
      throw const FormatException('一次最多导入 30 首歌曲');
    }
    if (names.isEmpty) {
      throw const FormatException('没有可导入的歌曲名');
    }

    final matches = <SongSearchResult>[];
    final notFound = <String>[];
    for (var offset = 0; offset < names.length; offset += _parallelSearches) {
      if (_isCancelled(isCancelled)) {
        return _cancelledResult(names.length, matches.length, notFound);
      }
      final nextOffset = offset + _parallelSearches;
      final end = nextOffset < names.length ? nextOffset : names.length;
      final chunk = names.sublist(offset, end);
      final resolved = await Future.wait(
        chunk.map((name) => _resolveExactMatch(api, name, isCancelled)),
      );
      if (_isCancelled(isCancelled)) {
        return _cancelledResult(names.length, matches.length, notFound);
      }
      for (var index = 0; index < chunk.length; index++) {
        final song = resolved[index];
        if (song == null) {
          notFound.add(chunk[index]);
        } else {
          matches.add(song);
        }
      }
    }

    if (_isCancelled(isCancelled)) {
      return _cancelledResult(names.length, matches.length, notFound);
    }
    final added = await favorites.addMany(matches);
    return BatchFavoriteImportResult(
      requested: names.length,
      matched: matches.length,
      added: added.added,
      alreadyFavorite: added.skipped,
      notFound: List.unmodifiable(notFound),
    );
  }

  static Future<SongSearchResult?> _resolveExactMatch(
    ApiService api,
    String title,
    bool Function()? isCancelled,
  ) async {
    final target = SongSearchResult(
      platform: MusicPlatform.qq,
      id: 'batch-favorite-target',
      name: title,
      artist: '',
      album: '',
    );
    for (final platform in _platforms) {
      if (_isCancelled(isCancelled)) return null;
      try {
        final candidates = await api
            .search(platform, title)
            .timeout(_searchTimeout);
        if (_isCancelled(isCancelled)) return null;
        final match = SongSourceMatcher.bestMatch(target, candidates);
        if (match != null) return match;
      } catch (_) {
        // A failed catalog falls through to the next standard platform.
      }
    }
    return null;
  }

  static List<String> _normalizeNames(Iterable<String> values) {
    final names = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final name = value.trim();
      if (name.isEmpty) continue;
      final key = name.toLowerCase().replaceAll(RegExp(r'\s+'), '');
      if (seen.add(key)) names.add(name);
      if (names.length > maxSongCount) break;
    }
    return names;
  }

  static bool _isCancelled(bool Function()? callback) {
    if (callback == null) return false;
    try {
      return callback();
    } catch (_) {
      return true;
    }
  }

  static BatchFavoriteImportResult _cancelledResult(
    int requested,
    int matched,
    List<String> notFound,
  ) {
    return BatchFavoriteImportResult(
      requested: requested,
      matched: matched,
      added: 0,
      alreadyFavorite: 0,
      notFound: List.unmodifiable(notFound),
      cancelled: true,
    );
  }
}
