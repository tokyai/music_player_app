import '../models/ai_assistant.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../utils/song_source_matcher.dart';

class AiSongResolution {
  final SongSearchResult? song;
  final String message;

  const AiSongResolution({required this.song, required this.message});

  bool get found => song != null;
}

/// 将 AI 的歌手/歌名意图交给现有音乐目录接口，避免模型直接决定资源地址。
abstract class AiSongPlaybackResolver {
  Future<AiSongResolution> resolveAndPlay(
    PlayerProvider player,
    AiPlaySongRequest request,
  );
}

class AiSongResolver implements AiSongPlaybackResolver {
  const AiSongResolver();

  @override
  Future<AiSongResolution> resolveAndPlay(
    PlayerProvider player,
    AiPlaySongRequest request,
  ) async {
    final artist = request.artist.trim();
    final title = request.title.trim();
    if (artist.isEmpty || title.isEmpty) {
      return const AiSongResolution(song: null, message: '歌曲名或歌手名不完整');
    }

    final query = '$artist $title';
    final target = SongSearchResult(
      platform: MusicPlatform.qq,
      id: 'ai-target',
      name: title,
      artist: artist,
      album: '',
    );
    String? lastPlaybackError;
    for (final platform in musicPlatformDisplayOrder) {
      List<SongSearchResult> results;
      try {
        results = await player.api.search(platform, query);
      } catch (_) {
        continue;
      }
      final unique = <String, SongSearchResult>{};
      for (final song in results) {
        unique['${song.platform.code}:${song.id}'] = song;
      }
      final candidates = unique.values
          .where((song) => _allowedVersion(song.name, title))
          .toList(growable: false);
      final matched = platform == MusicPlatform.bilibili
          ? _bestBilibiliMatch(candidates, title, artist)
          : SongSourceMatcher.bestMatch(target, candidates);
      if (matched == null) continue;
      try {
        await player.playSingle(matched);
        final current = player.currentSong;
        final selected =
            current?.platform == matched.platform && current?.id == matched.id;
        if (selected && player.errorMessage == null) {
          return AiSongResolution(
            song: matched,
            message: '正在播放《${matched.name}》',
          );
        }
        lastPlaybackError = player.errorMessage ?? '${platform.label}播放启动失败';
      } catch (error) {
        lastPlaybackError = error.toString();
      }
    }
    return AiSongResolution(
      song: null,
      message: lastPlaybackError == null
          ? '没有找到与“$artist - $title”高度匹配的歌曲，请换一个版本或补充信息。'
          : '已按 QQ音乐、网易云、酷狗和B站依次尝试，但都未能播放：$lastPlaybackError',
    );
  }

  SongSearchResult? _bestBilibiliMatch(
    Iterable<SongSearchResult> candidates,
    String requestedTitle,
    String requestedArtist,
  ) {
    final title = _normalize(requestedTitle);
    final artist = _normalize(requestedArtist);
    SongSearchResult? best;
    var bestScore = 0;
    for (final candidate in candidates) {
      final candidateTitle = _normalize(candidate.name);
      var score = 0;
      if (candidateTitle == title) {
        score = 100;
      } else if (title.isNotEmpty && candidateTitle.contains(title)) {
        score = 80;
      }
      if (score > 0 && artist.isNotEmpty && candidateTitle.contains(artist)) {
        score += 15;
      }
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return bestScore >= 80 ? best : null;
  }

  bool _allowedVersion(String candidateTitle, String requestedTitle) {
    final normalizedCandidate = _normalize(candidateTitle);
    final normalizedRequested = _normalize(requestedTitle);
    if (normalizedCandidate == normalizedRequested) return true;
    // 用户明确说出版本关键词时允许对应版本。
    final versionWords = RegExp(
      r'(dj|remix|live|现场|伴奏|翻唱|纯音乐|acoustic)',
      caseSensitive: false,
    );
    if (versionWords.hasMatch(normalizedRequested)) return true;
    return !versionWords.hasMatch(normalizedCandidate);
  }

  String _normalize(String value) => value.toLowerCase().replaceAll(
    RegExp(r'''[\s·•._\-—–,，。!！?？:：;；'"“”‘’/\\]+'''),
    '',
  );
}
