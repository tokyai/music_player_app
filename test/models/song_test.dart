import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/playback_source_config.dart';
import 'package:music_player_app/models/song.dart';

void main() {
  group('SongSearchResult', () {
    test('normalizes Netease cover and duration', () {
      final song = SongSearchResult.fromNetease({
        'id': 42,
        'name': 'Example',
        'ar': [
          {'name': 'Singer'},
        ],
        'al': {'name': 'Album', 'picUrl': 'http://music.126.net/cover.jpg'},
        'dt': 215000,
      });

      expect(song.id, '42');
      expect(song.artist, 'Singer');
      expect(song.coverUrl, 'https://music.126.net/cover.jpg');
      expect(song.duration, 215);
    });

    test('preserves album identifiers for aggregators', () {
      final qq = SongSearchResult.fromQQMusicu({
        'mid': 'qq-mid',
        'name': 'QQ 歌曲',
        'singer': [
          {'name': '歌手'},
        ],
        'album': {'name': '专辑', 'mid': 'album-mid'},
      });
      expect(qq.albumId, 'album-mid');

      final netease = SongSearchResult.fromNetease({
        'id': 163,
        'name': '网易歌曲',
        'ar': [
          {'name': '歌手'},
        ],
        'al': {'name': '专辑', 'id': 2468},
      });
      expect(netease.albumId, '2468');
    });

    test('parses official Kugou search response', () {
      final song = SongSearchResult.fromKugouSearchSong({
        'hash': 'ABC',
        'songname': 'Search Song',
        'singername': 'Singer',
        'album_name': 'Album',
        'album_id': 'album-123',
        'album_sizable_cover': 'http://imge.kugou.com/{size}/cover.jpg',
        'duration': '189',
      });

      expect(song.id, 'ABC');
      expect(song.coverUrl, 'http://imge.kugou.com/500/cover.jpg');
      expect(song.duration, 189);
      expect(song.albumId, 'album-123');
      expect(SongSearchResult.fromJson(song.toJson()).albumId, 'album-123');
    });

    test('parses official Kugou rank response authors', () {
      final song = SongSearchResult.fromKugouRankSong({
        'hash': 'DEF',
        'songname': 'Rank Song',
        'authors': [
          {'author_name': 'First'},
          {'author_name': 'Second'},
        ],
        'duration': 201,
      });

      expect(song.artist, 'First / Second');
      expect(song.duration, 201);
    });
  });

  group('PlaybackSourceConfig', () {
    test('exposes the analyzed JS defaults and round-trips them', () {
      final defaults = PlaybackSourceConfig.defaults();

      expect(defaults.chkszBaseUrl, PlaybackSourceConfig.defaultChkszBaseUrl);
      expect(defaults.qingMusicUrl, PlaybackSourceConfig.defaultQingMusicUrl);
      expect(defaults.hywBaseUrl, PlaybackSourceConfig.defaultHywBaseUrl);
      expect(defaults.hywCardKey, PlaybackSourceConfig.defaultHywCardKey);
      expect(defaults.xinghaiUrl, PlaybackSourceConfig.defaultXinghaiUrl);
      expect(defaults.gdStudioUrl, PlaybackSourceConfig.defaultGdStudioUrl);
      expect(defaults.xinghaiDeviceId, startsWith('lx-online-'));
      expect(PlaybackSourceConfig.fromJson(defaults.toJson()), defaults);
    });

    test('migrates shipped endpoints and retains user credentials', () {
      final legacy = PlaybackSourceConfig.defaults().toJson();
      legacy['chkszBaseUrl'] = 'http://161.118.252.183/api-chksz';
      legacy['xinghaiUrl'] = 'https://yy.zddyr.top/lx/api/';
      legacy['xinghaiIpUrl'] = 'https://yy.zddyr.top/ip.php';
      legacy['xinghaiClient'] = 'XingHaiMusicSource/v3.2.13 (Android)';
      legacy['xinghaiDeviceId'] = 'existing-device';
      legacy['xinghaiLicenseKey'] = 'user-license';
      legacy['hywCardKey'] = 'user-card-key';
      final migrated = PlaybackSourceConfig.fromJson(legacy);

      expect(migrated.chkszBaseUrl, 'https://api.chksz.com');
      expect(migrated.xinghaiUrl, 'https://yy1.zddyr.top/lx/api/');
      expect(migrated.xinghaiIpUrl, isEmpty);
      expect(migrated.xinghaiClient, PlaybackSourceConfig.defaultXinghaiClient);
      expect(migrated.xinghaiDeviceId, 'existing-device');
      expect(migrated.xinghaiLicenseKey, 'user-license');
      expect(migrated.hywCardKey, 'user-card-key');
      expect(PlaybackSourceConfig.fromJson(migrated.toJson()), migrated);
    });

    test('retains custom routes and rejects invalid license headers', () {
      final custom = PlaybackSourceConfig.defaults()
          .copyWith(
            chkszBaseUrl: 'https://proxy.test/chksz?tenant=a',
            xinghaiUrl: 'https://proxy.test/xinghai/?tenant=b',
            xinghaiIpUrl: 'https://proxy.test/legacy-ip',
            xinghaiClient: 'custom-client',
            xinghaiLicenseKey: '  user-license  ',
          )
          .validated();
      expect(PlaybackSourceConfig.fromJson(custom.toJson()), custom);
      expect(custom.xinghaiLicenseKey, 'user-license');
      expect(
        () => custom
            .copyWith(xinghaiLicenseKey: 'key\r\nInjected: value')
            .validated(),
        throwsFormatException,
      );
      expect(
        () => custom.copyWith(xinghaiLicenseKey: '中文卡密').validated(),
        throwsFormatException,
      );
    });

    test('updates only the legacy public HYW card', () {
      // 旧公益服务迁移到新卡密，启停状态保持原样。
      final legacy = PlaybackSourceConfig.defaults().toJson();
      legacy['hywCardKey'] = 'PYPW-QFRL-3DBF-95O6';
      legacy['hywEnabled'] = false;
      final updated = PlaybackSourceConfig.fromJson(legacy);
      expect(updated.hywCardKey, PlaybackSourceConfig.defaultHywCardKey);
      expect(updated.hywEnabled, isFalse);
      expect(updated.usesHywPublicSource, isTrue);

      // 自建服务和用户独立卡密不能被公益配置覆盖。
      legacy['hywBaseUrl'] = 'https://custom-hyw.test';
      expect(
        PlaybackSourceConfig.fromJson(legacy).hywCardKey,
        'PYPW-QFRL-3DBF-95O6',
      );
      legacy['hywBaseUrl'] = PlaybackSourceConfig.defaultHywBaseUrl;
      legacy['hywCardKey'] = 'personal-card';
      expect(PlaybackSourceConfig.fromJson(legacy).hywCardKey, 'personal-card');
    });

    test('permits Unicode HYW query keys but rejects control characters', () {
      // 中文卡密只用于 query；换行和控制字符仍然拒绝保存。
      final defaults = PlaybackSourceConfig.defaults();
      expect(
        defaults.copyWith(hywCardKey: '  中文卡密  ').validated().hywCardKey,
        '中文卡密',
      );
      for (final invalid in ['key\r\nInjected: value', 'key\u0000value']) {
        expect(
          () => defaults.copyWith(hywCardKey: invalid).validated(),
          throwsFormatException,
        );
      }
    });

    test('an HTTP 200 business error is reachable but unsuccessful', () {
      const result = PlaybackSourceTestResult(
        source: PlaybackSource.qingMusic,
        reachable: true,
        latencyMs: 20,
        statusCode: 200,
        message: '官方网关要求签名',
        errorCode: 'QING_UPGRADE_REQUIRED',
      );
      expect(result.reachable, isTrue);
      expect(result.successful, isFalse);
    });

    test(
      'rejects invalid enabled endpoints but permits blank disabled ones',
      () {
        final defaults = PlaybackSourceConfig.defaults();
        expect(
          () => defaults.copyWith(qingMusicUrl: 'javascript:bad').validated(),
          throwsFormatException,
        );
        expect(
          defaults
              .copyWith(qingMusicEnabled: false, qingMusicUrl: '')
              .validated()
              .qingMusicUrl,
          isEmpty,
        );
      },
    );
  });

  test('PlayQueueItem can clear a previous error', () {
    final item = PlayQueueItem(
      platform: MusicPlatform.qq,
      id: 'id',
      name: 'Song',
      artist: 'Singer',
      album: 'Album',
      error: 'failed',
    );

    expect(item.copyWith(loading: true).error, 'failed');
    expect(item.copyWith(clearError: true).error, isNull);
  });

  test('PlayQueueItem preserves and clears playback headers explicitly', () {
    final item = PlayQueueItem(
      platform: MusicPlatform.qq,
      id: 'mid',
      name: 'Song',
      artist: 'Singer',
      album: 'Album',
      playbackHeaders: const {'Referer': 'https://player.test/'},
    );

    expect(item.copyWith(loading: true).playbackHeaders, isNotNull);
    expect(item.copyWith(clearPlaybackHeaders: true).playbackHeaders, isNull);
  });

  test('PlayQueueItem can clear lyrics when a B站 page changes', () {
    final item = PlayQueueItem(
      platform: MusicPlatform.bilibili,
      id: 'BV1lyrics',
      name: '第一P',
      artist: '测试UP主',
      album: '测试视频',
      bilibiliCid: 101,
      lyric: '[00:00.00]第一P歌词',
    );

    final nextPage = item.copyWith(
      name: '第二P',
      bilibiliCid: 102,
      clearLyric: true,
    );
    expect(nextPage.lyric, isNull);
    expect(nextPage.bilibiliCid, 102);
  });
}
