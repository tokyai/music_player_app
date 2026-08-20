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
    final results = <SongSearchResult>[];
    await Future.wait(
      musicPlatformDisplayOrder
          .where((platform) => platform != MusicPlatform.bilibili)
          .map((platform) async {
            try {
              results.addAll(await player.api.search(platform, query));
            } catch (_) {
              // 单个平台不可用时继续尝试其他目录。
            }
          }),
    );
    final unique = <String, SongSearchResult>{};
    for (final song in results) {
      unique['${song.platform.code}:${song.id}'] = song;
    }
    final target = SongSearchResult(
      platform: MusicPlatform.qq,
      id: 'ai-target',
      name: title,
      artist: artist,
      album: '',
    );
    final candidates = unique.values
        .where((song) => _allowedVersion(song.name, title))
        .toList();
    final matched = SongSourceMatcher.bestMatch(target, candidates);
    if (matched == null) {
      return AiSongResolution(
        song: null,
        message: '没有找到与“$artist - $title”高度匹配的歌曲，请换一个版本或补充信息。',
      );
    }
    try {
      await player.playSingle(matched);
      return AiSongResolution(song: matched, message: '正在播放《${matched.name}》');
    } catch (error) {
      return AiSongResolution(song: null, message: '歌曲已找到，但播放失败：$error');
    }
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
