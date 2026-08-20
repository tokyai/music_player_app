import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/ai_assistant.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/services/ai_song_resolver.dart';
import 'package:music_player_app/services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('prefers QQ before every later platform', () async {
    final api = _SearchApi({
      MusicPlatform.qq: [_song(MusicPlatform.qq, 'qq-night')],
      MusicPlatform.netease: [_song(MusicPlatform.netease, 'wy-night')],
      MusicPlatform.kugou: [_song(MusicPlatform.kugou, 'kg-night')],
    });
    final player = _ResolverPlayer(api);
    addTearDown(player.dispose);

    final result = await const AiSongResolver().resolveAndPlay(
      player,
      const AiPlaySongRequest(title: '夜曲', artist: '周杰伦'),
    );

    expect(result.song?.platform, MusicPlatform.qq);
    expect(api.searchCalls, [MusicPlatform.qq]);
    expect(player.playCalls, [MusicPlatform.qq]);
  });

  test('continues in fixed order after a playback failure', () async {
    final api = _SearchApi({
      MusicPlatform.netease: [_song(MusicPlatform.netease, 'wy-night')],
      MusicPlatform.kugou: [_song(MusicPlatform.kugou, 'kg-night')],
    });
    final player = _ResolverPlayer(
      api,
      failures: {MusicPlatform.netease: '网易云版权限制'},
    );
    addTearDown(player.dispose);

    final result = await const AiSongResolver().resolveAndPlay(
      player,
      const AiPlaySongRequest(title: '夜曲', artist: '周杰伦'),
    );

    expect(result.song?.platform, MusicPlatform.kugou);
    expect(api.searchCalls, [
      MusicPlatform.qq,
      MusicPlatform.netease,
      MusicPlatform.kugou,
    ]);
    expect(player.playCalls, [MusicPlatform.netease, MusicPlatform.kugou]);
  });

  test('uses Bilibili only as the final title-based fallback', () async {
    final api = _SearchApi({
      MusicPlatform.bilibili: [
        _song(
          MusicPlatform.bilibili,
          'BV1night',
          name: '周杰伦《夜曲》官方MV',
          artist: '音乐收藏UP主',
        ),
      ],
    });
    final player = _ResolverPlayer(api);
    addTearDown(player.dispose);

    final result = await const AiSongResolver().resolveAndPlay(
      player,
      const AiPlaySongRequest(title: '夜曲', artist: '周杰伦'),
    );

    expect(result.song?.platform, MusicPlatform.bilibili);
    expect(api.searchCalls, musicPlatformDisplayOrder);
    expect(player.playCalls, [MusicPlatform.bilibili]);
  });
}

class _SearchApi extends ApiService {
  final Map<MusicPlatform, List<SongSearchResult>> results;
  final List<MusicPlatform> searchCalls = [];

  _SearchApi(this.results) : super(apiKey: 'test-key');

  @override
  Future<List<SongSearchResult>> search(
    MusicPlatform platform,
    String keyword,
  ) async {
    searchCalls.add(platform);
    return results[platform] ?? const [];
  }
}

class _ResolverPlayer extends PlayerProvider {
  final _SearchApi searchApi;
  final Map<MusicPlatform, String> failures;
  final List<MusicPlatform> playCalls = [];
  PlayQueueItem? _song;
  String? _playbackError;

  _ResolverPlayer(this.searchApi, {this.failures = const {}});

  @override
  ApiService get api => searchApi;

  @override
  PlayQueueItem? get currentSong => _song;

  @override
  String? get errorMessage => _playbackError;

  @override
  Future<void> playSingle(SongSearchResult result) async {
    playCalls.add(result.platform);
    _song = PlayQueueItem.fromSearchResult(result);
    _playbackError = failures[result.platform];
  }

  @override
  void dispose() {
    searchApi.close();
    super.dispose();
  }
}

SongSearchResult _song(
  MusicPlatform platform,
  String id, {
  String name = '夜曲',
  String artist = '周杰伦',
}) => SongSearchResult(
  platform: platform,
  id: id,
  name: name,
  artist: artist,
  album: '十一月的萧邦',
);
