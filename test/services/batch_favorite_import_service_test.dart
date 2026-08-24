import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/api_service.dart';
import 'package:music_player_app/services/batch_favorite_import_service.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'uses QQ first, falls back by platform and only adds favorites',
    () async {
      final api = _FakeApi((platform, keyword) async {
        if (keyword == '倒带' && platform == MusicPlatform.qq) {
          return [_song(platform, 'qq-dao-dai', keyword)];
        }
        if (keyword == '七里香') {
          if (platform == MusicPlatform.qq) {
            return [_song(platform, 'qq-live', '七里香 Live')];
          }
          if (platform == MusicPlatform.netease) {
            return [_song(platform, 'netease-qi-li-xiang', keyword)];
          }
        }
        if (keyword == '半岛铁盒' && platform == MusicPlatform.kugou) {
          return [_song(platform, 'kugou-ban-dao', keyword)];
        }
        return const [];
      });
      addTearDown(api.close);
      final favorites = FavoriteService();
      await favorites.toggle(_song(MusicPlatform.qq, 'qq-dao-dai', '倒带'));

      final result = await BatchFavoriteImportService.import(
        api: api,
        favorites: favorites,
        songNames: const ['倒带', '七里香', '七 里 香', '半岛铁盒', '夜曲'],
      );

      expect(result.requested, 4);
      expect(result.matched, 3);
      expect(result.added, 2);
      expect(result.alreadyFavorite, 1);
      expect(result.notFound, ['夜曲']);
      expect(
        favorites.favorites.map(FavoriteService.keyOf),
        containsAll([
          FavoriteService.songKey(MusicPlatform.qq, 'qq-dao-dai'),
          FavoriteService.songKey(MusicPlatform.netease, 'netease-qi-li-xiang'),
          FavoriteService.songKey(MusicPlatform.kugou, 'kugou-ban-dao'),
        ]),
      );
      expect(
        api.calls.where((call) => call.platform == MusicPlatform.bilibili),
        isEmpty,
      );
      expect(
        api.calls
            .where((call) => call.keyword == '倒带')
            .map((call) => call.platform),
        [MusicPlatform.qq],
      );
      expect(
        api.calls
            .where((call) => call.keyword == '七里香')
            .map((call) => call.platform),
        [MusicPlatform.qq, MusicPlatform.netease],
      );
    },
  );

  test('catalog errors fall through and oversized input is rejected', () async {
    final api = _FakeApi((platform, keyword) async {
      if (platform == MusicPlatform.qq) throw StateError('QQ unavailable');
      if (platform == MusicPlatform.netease) {
        return [_song(platform, 'fallback', keyword)];
      }
      return const [];
    });
    addTearDown(api.close);
    final favorites = FavoriteService();

    final result = await BatchFavoriteImportService.import(
      api: api,
      favorites: favorites,
      songNames: const ['晴天'],
    );
    expect(result.added, 1);
    expect(favorites.favorites.single.platform, MusicPlatform.netease);

    await expectLater(
      BatchFavoriteImportService.import(
        api: api,
        favorites: favorites,
        songNames: List<String>.generate(31, (index) => '歌曲$index'),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('bounds concurrent catalog searches to three', () async {
    final api = _FakeApi((platform, keyword) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return [_song(platform, '$keyword-id', keyword)];
    });
    addTearDown(api.close);
    final favorites = FavoriteService();

    final result = await BatchFavoriteImportService.import(
      api: api,
      favorites: favorites,
      songNames: List<String>.generate(8, (index) => '歌曲$index'),
    );

    expect(result.added, 8);
    expect(api.maxConcurrentSearches, 3);
    expect(api.calls, hasLength(8));
  });

  test('cancellation does not write a partial batch', () async {
    final api = _FakeApi((platform, keyword) async {
      return [_song(platform, '$keyword-id', keyword)];
    });
    addTearDown(api.close);
    final favorites = FavoriteService();

    final result = await BatchFavoriteImportService.import(
      api: api,
      favorites: favorites,
      songNames: const ['倒带', '七里香'],
      isCancelled: () => true,
    );

    expect(result.cancelled, isTrue);
    expect(result.added, 0);
    expect(api.calls, isEmpty);
    expect(favorites.favorites, isEmpty);
  });
}

typedef _SearchHandler =
    Future<List<SongSearchResult>> Function(
      MusicPlatform platform,
      String keyword,
    );

class _FakeApi extends ApiService {
  final _SearchHandler handler;
  final List<({MusicPlatform platform, String keyword})> calls = [];
  int activeSearches = 0;
  int maxConcurrentSearches = 0;

  _FakeApi(this.handler) : super(apiKey: '');

  @override
  Future<List<SongSearchResult>> search(
    MusicPlatform platform,
    String keyword,
  ) async {
    calls.add((platform: platform, keyword: keyword));
    activeSearches++;
    if (activeSearches > maxConcurrentSearches) {
      maxConcurrentSearches = activeSearches;
    }
    try {
      return await handler(platform, keyword);
    } finally {
      activeSearches--;
    }
  }
}

SongSearchResult _song(MusicPlatform platform, String id, String name) {
  return SongSearchResult(
    platform: platform,
    id: id,
    name: name,
    artist: '测试歌手',
    album: '测试专辑',
  );
}
