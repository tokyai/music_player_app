import '../models/song.dart';

/// 在其他平台的搜索结果中找同一首歌，避免仅按列表顺序盲目换源。
class SongSourceMatcher {
  static final RegExp _noise = RegExp(r'''[\s·•._\-—–,，。!！?？:：;；'"“”‘’/\\]+''');
  static final RegExp _artistSeparator = RegExp(
    r'\s*(?:/|、|,|，|&|feat\.?|ft\.?|with)\s*',
    caseSensitive: false,
  );

  static SongSearchResult? bestMatch(
    SongSearchResult original,
    Iterable<SongSearchResult> candidates,
  ) {
    SongSearchResult? best;
    var bestScore = 0;
    for (final candidate in candidates) {
      final candidateScore = score(original, candidate);
      if (candidateScore > bestScore) {
        best = candidate;
        bestScore = candidateScore;
      }
    }
    return bestScore >= 65 ? best : null;
  }

  static int score(SongSearchResult original, SongSearchResult candidate) {
    final originalTitle = _normalize(original.name);
    final candidateTitle = _normalize(candidate.name);
    if (originalTitle.isEmpty || candidateTitle.isEmpty) return 0;

    var score = 0;
    if (originalTitle == candidateTitle) {
      score += 70;
    } else if (originalTitle.length >= 2 &&
        candidateTitle.length >= 2 &&
        (originalTitle.contains(candidateTitle) ||
            candidateTitle.contains(originalTitle))) {
      score += 50;
    } else {
      return 0;
    }

    final originalArtists = _artistTokens(original.artist);
    final candidateArtists = _artistTokens(candidate.artist);
    final artistsKnown =
        originalArtists.isNotEmpty && candidateArtists.isNotEmpty;
    var artistScore = 0;
    if (artistsKnown) {
      if (_normalize(original.artist) == _normalize(candidate.artist)) {
        artistScore = 25;
      } else if (originalArtists.any(
        (artist) => candidateArtists.any(
          (candidateArtist) =>
              artist == candidateArtist ||
              artist.contains(candidateArtist) ||
              candidateArtist.contains(artist),
        ),
      )) {
        artistScore = 20;
      }
      if (artistScore == 0) return 0;
    }
    score += artistScore;

    if (original.duration != null && candidate.duration != null) {
      final difference = (original.duration! - candidate.duration!).abs();
      if (difference <= 2) {
        score += 10;
      } else if (difference <= 5) {
        score += 6;
      } else if (difference > 20) {
        score -= 15;
      }
    }

    final originalAlbum = _normalize(original.album);
    final candidateAlbum = _normalize(candidate.album);
    if (originalAlbum.isNotEmpty && originalAlbum == candidateAlbum) {
      score += 5;
    }
    return score;
  }

  static Set<String> _artistTokens(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty || normalized == '未知歌手' || normalized == 'unknown') {
      return {};
    }
    return normalized
        .split(_artistSeparator)
        .map(_normalize)
        .where((token) => token.isNotEmpty)
        .toSet();
  }

  static String _normalize(String value) {
    return value.toLowerCase().replaceAll(_noise, '');
  }
}
