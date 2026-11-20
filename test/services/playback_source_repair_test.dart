import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/playback_source_config.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放解析协议及异常路径回归；作者 SHIXIAOYANG，2026/11/18。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_resetPreferences);
  test(
    'reuses server-issued tokens and forwards the configured license',
    _serverToken,
  );
  test(
    'refreshes a rejected token once before retrying playback',
    _refreshToken,
  );
  test(
    'stops refreshing when the server rejects the new token',
    _repeatedTokenFailure,
  );
  test(
    'rejects malformed tokens without sending a music request',
    _invalidTokens,
  );
  test('closing the service cancels an unfinished token request', _cancelToken);
  test(
    'reports HTTP 200 authentication failures without leaking credentials',
    _probeFailures,
  );
  test(
    'unavailable sources are skipped while usable quality fallback continues',
    _qualityFallback,
  );
  test(
    'a premium quality rejection still permits standard quality fallback',
    _qualityPermission,
  );
  test(
    'encrypted audio is rejected before falling back to a playable quality',
    _encryptedAudio,
  );
  test('GD matches the same recording for QQ and Kugou', _gdMatch);
  test(
    'GD searches once per playback while downgrading quality',
    _gdSearchReuse,
  );
  test(
    'GD refuses covers, live versions and duration mismatches',
    _gdRejectMismatch,
  );
  test(
    'cancelling GD search prevents the subsequent URL request',
    _cancelGdSearch,
  );
  test('public HYW requests the declared 24-bit quality', _hywPublicQuality);
  test(
    'GD retries unavailable premium streams at playable bitrates',
    _gdUnavailable,
  );
  test(
    'GD never repeats a failed fallback bitrate in one playback',
    _gdBitrateReuse,
  );
  test('public HYW skips unsupported Kugou without networking', _hywKugou);
  test('Unicode HYW keys stay in encoded query parameters', _hywUnicodeKey);
  test(
    'Xinghai distinguishes missing and rejected authorization',
    _xinghaiAuth,
  );
  test(
    'HTTP 401 probes report authorization even without JSON',
    _httpAuthProbe,
  );
  test(
    'Qing reports HTTP 401 signature rejection and encrypted data',
    _qingAuth,
  );
  test(
    'Qing attaches gateway authentication only to known origins',
    _qingWireAuth,
  );
  test('Qing rejects declared CENC streams before native playback', _qingCenc);
}

void _resetPreferences() {
  SharedPreferences.setMockInitialValues({});
}

Future<void> _serverToken() async {
  // 模拟令牌和播放端点，记录取令牌次数及后续请求头。
  final requests = <http.Request>[];
  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    if (request.url.path.endsWith('/token.php')) {
      return _json({
        'code': 0,
        'data': {'token': 'xh3.server-issued'},
      });
    }
    return _json({'code': 200, 'url': 'https://audio.test/song.mp3'});
  }

  Future<void> scenario(ApiService api) async {
    await _resolve(api, id: 'first');
    await _resolve(api, id: 'second');
  }

  // 连续播放两首歌，核对同一配置复用令牌且保留路径、设备和卡密。
  await _withApi(
    scenario,
    respond,
    config: PlaybackSourceConfig.defaults().copyWith(
      xinghaiUrl: 'https://xinghai.test/proxy/lx/api/?tenant=a',
      xinghaiIpUrl: 'https://legacy-ip.test/ip.php',
      xinghaiDeviceId: 'existing-device',
      xinghaiLicenseKey: 'user-license',
    ),
  );
  expect(requests, hasLength(3));
  expect(requests.first.url.path, '/proxy/lx/api/token.php');
  expect(requests.first.url.queryParameters['device_id'], 'existing-device');
  expect(requests.first.url.queryParameters['tenant'], 'a');
  for (final request in requests.skip(1)) {
    expect(request.headers['X-Token'], 'xh3.server-issued');
    expect(request.headers['X-License'], 'user-license');
    expect(request.url.queryParameters['source'], 'wy');
  }
}

Future<void> _refreshToken() async {
  // 首次播放返回明确的令牌错误，第二次使用新签发的令牌成功。
  var tokenRequests = 0;
  var musicRequests = 0;
  final usedTokens = <String?>[];
  Future<http.Response> respond(http.Request request) async {
    if (request.url.path.endsWith('/token.php')) {
      tokenRequests++;
      return _json({
        'code': 0,
        'data': {'token': 'xh3.token-$tokenRequests'},
      });
    }
    usedTokens.add(request.headers['X-Token']);
    musicRequests++;
    if (musicRequests == 1) {
      return _json({
        'code': 403,
        'auth': {'tk_mismatch': true},
      }, status: 403);
    }
    return _json({'code': 200, 'url': 'https://audio.test/refreshed.mp3'});
  }

  Future<void> scenario(ApiService api) async {
    expect((await _resolve(api)).url, 'https://audio.test/refreshed.mp3');
  }

  // 执行一次解析，验证刷新只发生一次且旧令牌不会继续使用。
  await _withApi(scenario, respond);
  expect(tokenRequests, 2);
  expect(musicRequests, 2);
  expect(usedTokens, ['xh3.token-1', 'xh3.token-2']);
}

Future<void> _invalidTokens() async {
  // 换行、空令牌和过长令牌都不能进入原生 HTTP 请求头。
  final tokens = [
    '',
    'xh3.token\r\nInjected: value',
    List.filled(4097, 'a').join(),
  ];
  for (final token in tokens) {
    var sends = 0;
    Future<http.Response> respond(http.Request request) async {
      sends++;
      expect(request.url.path.endsWith('/token.php'), isTrue);
      return _json({
        'code': 0,
        'data': {'token': token},
      });
    }

    Future<void> scenario(ApiService api) async {
      await _expectCode(_resolve(api), 'XINGHAI_TOKEN_INVALID');
    }

    await _withApi(scenario, respond);
    expect(sends, 1);
  }
  // 令牌端点使用 64 KB 上限，不能因鉴权响应异常持续占用内存。
  Future<http.Response> oversizedReply(http.Request request) async {
    return _json({
      'code': 0,
      'data': {'token': List.filled(70 * 1024, 'a').join()},
    });
  }

  Future<void> oversizedScenario(ApiService api) async {
    await _expectCode(_resolve(api), 'RESPONSE_TOO_LARGE');
  }

  await _withApi(oversizedScenario, oversizedReply);
}

Future<void> _repeatedTokenFailure() async {
  // 服务持续拒绝令牌，验证两次尝试后立即结束解析。
  var tokenRequests = 0;
  var musicRequests = 0;
  Future<http.Response> respond(http.Request request) async {
    if (request.url.path.endsWith('/token.php')) {
      tokenRequests++;
      return _json({
        'code': 0,
        'data': {'token': 'xh3.token-$tokenRequests'},
      });
    }
    musicRequests++;
    return _json({
      'code': 403,
      'auth': {'tk_mismatch': true},
    }, status: 403);
  }

  Future<void> scenario(ApiService api) async {
    await _expectCode(_resolve(api), 'XINGHAI_HTTP_403');
  }

  await _withApi(scenario, respond);
  expect(tokenRequests, 2);
  expect(musicRequests, 2);
}

Future<void> _cancelToken() async {
  // 暂停服务器响应，在取令牌期间关闭服务，再补发迟到结果。
  final started = Completer<void>();
  final reply = Completer<http.Response>();
  var sends = 0;
  Future<http.Response> respond(http.Request request) {
    sends++;
    started.complete();
    return reply.future;
  }

  Future<void> scenario(ApiService api) async {
    final pending = _resolve(api);
    final rejection = _expectCode(pending, 'RESOLVE_CANCELLED');
    await started.future;
    api.close();
    await rejection;
    reply.complete(
      _json({
        'code': 0,
        'data': {'token': 'xh3.late'},
      }),
    );
    await Future<void>.delayed(Duration.zero);
  }

  await _withApi(scenario, respond);
  expect(sends, 1);
}

Future<void> _probeFailures() async {
  // 使用 HTTP 200 承载升级和卡密错误，核对探测失败且不泄露服务端数据。
  Future<http.Response> respond(http.Request request) async {
    if (request.method == 'POST') {
      return _json({
        'code': 'APP_UPGRADE_REQUIRED',
        'message': 'server-private-data',
      });
    }
    return _json({'code': 401, 'message': 'expired: server-private-data'});
  }

  Future<void> scenario(ApiService api) async {
    final qing = await api.testPlaybackSource(PlaybackSource.qingMusic);
    final hyw = await api.testPlaybackSource(PlaybackSource.hyw);
    for (final result in [qing, hyw]) {
      expect(result.reachable, isTrue);
      expect(result.successful, isFalse);
      expect(result.statusCode, 200);
      expect(result.message, isNot(contains('server-private-data')));
    }
    expect(qing.errorCode, 'QING_UPGRADE_REQUIRED');
    expect(hyw.errorCode, 'HYW_KEY_INVALID');
    expect(hyw.message, contains('过期'));
  }

  await _withApi(scenario, respond);
}

Future<void> _qualityFallback() async {
  // 主源因升级和过期卡密失败，备用源只在最低音质返回播放地址。
  var qingRequests = 0;
  var hywRequests = 0;
  final bitrates = <String?>[];
  Future<http.Response> respond(http.Request request) async {
    if (request.method == 'POST') {
      qingRequests++;
      return _json({'code': 'APP_UPGRADE_REQUIRED'});
    }
    if (request.url.path.endsWith('/api/music/url')) {
      hywRequests++;
      return _json({'code': 401}, status: 401);
    }
    final bitrate = request.url.queryParameters['br'];
    bitrates.add(bitrate);
    if (bitrate == '128') {
      return _json({'url': 'https://audio.test/standard.mp3'});
    }
    return _json({'url': ''});
  }

  Future<void> scenario(ApiService api) async {
    final detail = await _resolve(api, source: PlaybackSource.automatic);
    expect(detail.url, 'https://audio.test/standard.mp3');
    expect(detail.playbackSource, PlaybackSource.gdStudio);
  }

  await _withApi(
    scenario,
    respond,
    config: PlaybackSourceConfig.defaults().copyWith(
      chkszEnabled: false,
      xinghaiEnabled: false,
    ),
  );
  // 与音质无关的源只尝试一次，备用源继续逐档降级。
  expect(qingRequests, 1);
  expect(hywRequests, 1);
  expect(bitrates, ['999', '740', '320', '128']);
}

Future<void> _gdMatch() async {
  // 构造翻唱、现场版、时长不符和正确版本，核对仅使用同曲 ID。
  final playbackIds = <String?>[];
  Future<http.Response> respond(http.Request request) async {
    expect(request.url.queryParameters['source'], 'netease');
    if (request.url.queryParameters['types'] == 'search') {
      return _json([
        _candidate('1', '海阔天空', '翻唱歌手', 319),
        _candidate('2', '海阔天空 (Live)', 'Beyond', 319),
        _candidate('3', '海阔天空', 'Beyond', 400),
        _candidate('347230', '海阔天空', 'Beyond', 319),
      ]);
    }
    playbackIds.add(request.url.queryParameters['id']);
    return _json({'url': 'https://audio.test/matched.flac'});
  }

  Future<void> scenario(ApiService api) async {
    for (final platform in [MusicPlatform.qq, MusicPlatform.kugou]) {
      final detail = await api.gdStudioMusic(
        platform,
        'original-platform-id',
        quality: 'flac',
        name: '海阔天空',
        artist: 'Beyond',
        album: '海阔天空',
        duration: 319,
      );
      expect(detail.url, 'https://audio.test/matched.flac');
    }
  }

  await _withApi(scenario, respond);
  expect(playbackIds, ['347230', '347230']);
}

Future<void> _qualityPermission() async {
  // 高音质返回权限拒绝，标准音质仍可播放，不能直接跳过整个源。
  final qualities = <String?>[];
  Future<http.Response> respond(http.Request request) async {
    final quality = request.url.queryParameters['quality'];
    qualities.add(quality);
    if (quality == '128k') {
      return _json({'code': 200, 'url': 'https://audio.test/basic.mp3'});
    }
    return _json({'code': 403}, status: 403);
  }

  Future<void> scenario(ApiService api) async {
    final detail = await _resolve(api, source: PlaybackSource.automatic);
    expect(detail.url, 'https://audio.test/basic.mp3');
  }

  await _withApi(
    scenario,
    respond,
    config: PlaybackSourceConfig.defaults().copyWith(
      chkszEnabled: false,
      qingMusicEnabled: false,
      xinghaiEnabled: false,
      gdStudioEnabled: false,
    ),
  );
  expect(qualities, ['flac24bit', 'flac', '320k', '128k']);
}

Future<void> _gdRejectMismatch() async {
  // 分别只返回错误歌手、现场版和错误时长，验证不会请求播放 URL。
  final candidates = [
    _candidate('1', '海阔天空', '翻唱歌手', 319),
    _candidate('2', '海阔天空 (Live)', 'Beyond', 319),
    _candidate('3', '海阔天空', 'Beyond', 400),
  ];
  for (final candidate in candidates) {
    var sends = 0;
    Future<http.Response> respond(http.Request request) async {
      sends++;
      expect(request.url.queryParameters['types'], 'search');
      return _json([candidate]);
    }

    Future<void> scenario(ApiService api) async {
      await _expectCode(
        api.gdStudioMusic(
          MusicPlatform.qq,
          'qq-id',
          quality: 'flac',
          name: '海阔天空',
          artist: 'Beyond',
          album: '海阔天空',
          duration: 319,
        ),
        'GD_MATCH_NOT_FOUND',
      );
    }

    await _withApi(scenario, respond);
    expect(sends, 1);
  }
}

Future<void> _gdSearchReuse() async {
  // 最高码率没有资源，两次播放各降级一次，匹配搜索仅在每次播放开始时执行。
  var searches = 0;
  final bitrates = <String?>[];
  Future<http.Response> respond(http.Request request) async {
    if (request.url.queryParameters['types'] == 'search') {
      searches++;
      return _json([_candidate('347230', '海阔天空', 'Beyond', 319)]);
    }
    final bitrate = request.url.queryParameters['br'];
    bitrates.add(bitrate);
    return _json({
      'url': bitrate == '740' ? 'https://audio.test/song.flac' : '',
    });
  }

  Future<void> scenario(ApiService api) async {
    for (var play = 0; play < 2; play++) {
      final detail = await api.resolvePlayback(
        source: PlaybackSource.automatic,
        platform: MusicPlatform.qq,
        id: 'qq-id',
        quality: 'master',
        name: '海阔天空',
        artist: 'Beyond',
        album: '海阔天空',
        duration: 319,
      );
      expect(detail.url, 'https://audio.test/song.flac');
    }
  }

  await _withApi(
    scenario,
    respond,
    config: PlaybackSourceConfig.defaults().copyWith(
      chkszEnabled: false,
      qingMusicEnabled: false,
      hywEnabled: false,
      xinghaiEnabled: false,
    ),
  );
  expect(searches, 2);
  expect(bitrates, ['999', '740', '999', '740']);
}

Future<void> _encryptedAudio() async {
  // 依次模拟加密标记、加密格式和加密扩展名，最低音质返回普通 MP3。
  var sends = 0;
  Future<http.Response> respond(http.Request request) async {
    sends++;
    final quality = request.url.queryParameters['quality'];
    if (quality == 'flac24bit') {
      return _json({
        'code': 200,
        'url': 'https://audio.test/opaque',
        'encrypted': true,
      });
    }
    if (quality == 'flac') {
      return _json({
        'code': 200,
        'url': 'https://audio.test/opaque',
        'format': 'mflac',
      });
    }
    if (quality == '320k') {
      return _json({'code': 200, 'url': 'https://audio.test/encrypted.mgg'});
    }
    return _json({'code': 200, 'url': 'https://audio.test/playable.mp3'});
  }

  Future<void> scenario(ApiService api) async {
    final detail = await _resolve(api, source: PlaybackSource.automatic);
    expect(detail.url, 'https://audio.test/playable.mp3');
  }

  await _withApi(
    scenario,
    respond,
    config: PlaybackSourceConfig.defaults().copyWith(
      chkszEnabled: false,
      qingMusicEnabled: false,
      xinghaiEnabled: false,
      gdStudioEnabled: false,
    ),
  );
  expect(sends, 4);
}

Future<void> _cancelGdSearch() async {
  // 搜索完成前取消解析，验证候选结果不会继续触发播放地址请求。
  final cancel = Completer<void>();
  var sends = 0;
  Future<http.Response> respond(http.Request request) async {
    sends++;
    expect(request.url.queryParameters['types'], 'search');
    cancel.complete();
    return _json([_candidate('347230', '海阔天空', 'Beyond', 319)]);
  }

  Future<void> scenario(ApiService api) async {
    await _expectCode(
      api.gdStudioMusic(
        MusicPlatform.qq,
        'qq-id',
        quality: 'flac',
        name: '海阔天空',
        artist: 'Beyond',
        album: '海阔天空',
        duration: 319,
        cancelSignal: cancel.future,
      ),
      'RESOLVE_CANCELLED',
    );
  }

  await _withApi(scenario, respond);
  expect(sends, 1);
}

Future<void> _gdUnavailable() async {
  // 官方协议允许高档请求失败后回到 FLAC，不能把 503 当成所有音质停服。
  for (final status in [503, 504]) {
    final bitrates = <String?>[];
    Future<http.Response> respond(http.Request request) async {
      final bitrate = request.url.queryParameters['br'];
      bitrates.add(bitrate);
      if (bitrate == '740') {
        return _json({'url': 'https://audio.test/fallback.flac'});
      }
      return http.Response('Premium stream unavailable', status);
    }

    Future<void> scenario(ApiService api) async {
      final detail = await _resolve(api, source: PlaybackSource.automatic);
      expect(detail.url, 'https://audio.test/fallback.flac');
    }

    await _withApi(
      scenario,
      respond,
      config: PlaybackSourceConfig.defaults().copyWith(
        chkszEnabled: false,
        qingMusicEnabled: false,
        hywEnabled: false,
        xinghaiEnabled: false,
      ),
    );
    expect(bitrates, ['999', '740']);
  }
}

Future<void> _gdBitrateReuse() async {
  // 高档和 FLAC 都失败时继续降低音质；再次播放重新尝试，不保留负缓存。
  final bitrates = <String?>[];
  Future<http.Response> respond(http.Request request) async {
    final bitrate = request.url.queryParameters['br'];
    bitrates.add(bitrate);
    if (bitrate == '128') {
      return _json({'url': 'https://audio.test/standard.mp3'});
    }
    return http.Response('Quality unavailable', 503);
  }

  Future<void> scenario(ApiService api) async {
    for (var play = 0; play < 2; play++) {
      expect(
        (await _resolve(api, source: PlaybackSource.automatic)).url,
        'https://audio.test/standard.mp3',
      );
    }
  }

  await _withApi(
    scenario,
    respond,
    config: PlaybackSourceConfig.defaults().copyWith(
      chkszEnabled: false,
      qingMusicEnabled: false,
      hywEnabled: false,
      xinghaiEnabled: false,
    ),
  );
  expect(bitrates, ['999', '740', '320', '128', '999', '740', '320', '128']);
}

Future<void> _hywPublicQuality() async {
  // 官方公益配置只发送其声明的最高音质，不重复请求相同映射档位。
  final qualities = <String?>[];
  Future<http.Response> respond(http.Request request) async {
    qualities.add(request.url.queryParameters['quality']);
    expect(request.headers['User-Agent'], 'lx-music-request/1.0.0');
    return _json({'code': 200, 'url': 'https://audio.test/public.flac'});
  }

  Future<void> scenario(ApiService api) async {
    final detail = await _resolve(api, source: PlaybackSource.hyw);
    expect(detail.url, 'https://audio.test/public.flac');
  }

  await _withApi(scenario, respond);
  expect(qualities, ['flac24bit']);
}

Future<void> _hywKugou() async {
  // 公益版不支持酷狗；播放与探测都应立即结束且不发送请求。
  var sends = 0;
  Future<http.Response> respond(http.Request request) async {
    sends++;
    return _json({'code': 200, 'url': 'https://audio.test/song.mp3'});
  }

  Future<void> scenario(ApiService api) async {
    await _expectCode(
      api.resolvePlayback(
        source: PlaybackSource.hyw,
        platform: MusicPlatform.kugou,
        id: 'kg-id',
        quality: '320k',
        name: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
      ),
      'HYW_SOURCE_UNSUPPORTED',
    );
    final probe = await api.testPlaybackSource(
      PlaybackSource.hyw,
      platform: MusicPlatform.kugou,
    );
    expect(probe.errorCode, 'HYW_SOURCE_UNSUPPORTED');
  }

  await _withApi(scenario, respond);
  expect(sends, 0);
}

Future<void> _hywUnicodeKey() async {
  // 保留中文 query 值，播放和草稿探测都不能生成非 ASCII 请求头。
  var sends = 0;
  Future<http.Response> respond(http.Request request) async {
    sends++;
    expect(request.url.queryParameters['key'], '中文卡密');
    expect(request.headers.containsKey('X-Card-Key'), isFalse);
    return _json({'code': 200, 'url': 'https://audio.test/song.mp3'});
  }

  Future<void> scenario(ApiService api) async {
    await _resolve(api, source: PlaybackSource.hyw);
    expect(
      (await api.testPlaybackSource(PlaybackSource.hyw)).successful,
      isTrue,
    );
  }

  await _withApi(
    scenario,
    respond,
    config: PlaybackSourceConfig.defaults().copyWith(hywCardKey: '中文卡密'),
  );
  expect(sends, 2);
}

Future<void> _xinghaiAuth() async {
  // 服务明确拒绝授权时只尝试一次，不刷新令牌、不重复降音质。
  for (final key in ['', 'personal-license']) {
    var tokens = 0;
    var musicRequests = 0;
    Future<http.Response> respond(http.Request request) async {
      if (request.url.path.endsWith('/token.php')) {
        tokens++;
        return _json({
          'code': 0,
          'data': {'token': 'xh3.server-issued'},
        });
      }
      musicRequests++;
      return _json({
        'code': 401,
        'message': 'private-backend-error',
      }, status: 401);
    }

    Future<void> scenario(ApiService api) async {
      await _expectCode(
        _resolve(api),
        key.isEmpty ? 'XINGHAI_LICENSE_REQUIRED' : 'XINGHAI_AUTH_FAILED',
      );
    }

    await _withApi(
      scenario,
      respond,
      config: PlaybackSourceConfig.defaults().copyWith(xinghaiLicenseKey: key),
    );
    expect(tokens, 1);
    expect(musicRequests, 1);
  }
}

Future<void> _httpAuthProbe() async {
  // 缺少 JSON 业务码时仍按 HTTP 401 显示鉴权失败。
  Future<http.Response> respond(http.Request request) async {
    return http.Response('<html>private-error</html>', 401);
  }

  Future<void> scenario(ApiService api) async {
    final chksz = await api.testPlaybackSource(PlaybackSource.chksz);
    final hyw = await api.testPlaybackSource(PlaybackSource.hyw);
    expect(chksz.errorCode, 'API_KEY_INVALID');
    expect(hyw.errorCode, 'HYW_KEY_INVALID');
    expect(chksz.message, isNot(contains('private-error')));
  }

  await _withApi(scenario, respond, apiKey: 'configured-key');
}

Future<void> _qingWireAuth() async {
  // 通过 API 入口捕获请求，核对设备复用、新 nonce 和 JSON 契约。
  final requests = <http.Request>[];
  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    return _json({
      'code': 0,
      'data': {'url': 'https://audio.test/song.mp3'},
    });
  }

  Future<void> scenario(ApiService api) async {
    await _resolve(api, source: PlaybackSource.qingMusic);
    await _resolve(api, source: PlaybackSource.qingMusic);
  }

  await _withApi(scenario, respond);
  expect(requests, hasLength(2));
  for (final request in requests) {
    expect(request.headers['X-Qing-App-Id'], 'qingmusic-android');
    expect(request.headers['X-Qing-App-Version-Code'], '25');
    expect(request.headers['X-Qing-Sign'], matches(r'^[a-f0-9]{64}$'));
    expect(jsonDecode(request.body), {
      'source': 'wy',
      'rid': '347230',
      'level': 'jymaster',
    });
  }
  expect(
    requests.first.headers['X-Qing-Device-Id'],
    requests.last.headers['X-Qing-Device-Id'],
  );
  expect(
    requests.first.headers['X-Qing-Nonce'],
    isNot(requests.last.headers['X-Qing-Nonce']),
  );

  // 自定义服务保持直接 POST，不附带客户端认证参数。
  requests.clear();
  await _withApi(
    scenario,
    respond,
    config: PlaybackSourceConfig.defaults().copyWith(
      qingMusicUrl: 'https://custom.test/resolve',
    ),
  );
  for (final request in requests) {
    for (final key in request.headers.keys) {
      expect(key.toLowerCase().startsWith('x-qing-'), isFalse);
    }
  }
}

Future<void> _qingCenc() async {
  // 最新包声明的 CENC 流同样需要解密，不能送进普通原生解码器。
  Future<http.Response> respond(http.Request request) async {
    return _json({
      'code': 0,
      'data': {'url': 'https://audio.test/opaque', 'encryption': 'cenc'},
    });
  }

  Future<void> scenario(ApiService api) async {
    await _expectCode(
      _resolve(api, source: PlaybackSource.qingMusic),
      'QING_ENCRYPTED_AUDIO',
    );
  }

  await _withApi(scenario, respond);
}

Future<void> _qingAuth() async {
  // 先返回签名错误，再返回已声明加密的音频，分别验证授权和解码边界。
  var encrypted = false;
  Future<http.Response> respond(http.Request request) async {
    if (!encrypted) return _json({'code': 'APP_SIGN_MISSING'}, status: 401);
    return _json({
      'code': 0,
      'data': {'url': 'https://audio.test/opaque', 'encrypted': true},
    });
  }

  Future<void> scenario(ApiService api) async {
    await _expectCode(
      _resolve(api, source: PlaybackSource.qingMusic),
      'QING_UPGRADE_REQUIRED',
    );
    final probe = await api.testPlaybackSource(PlaybackSource.qingMusic);
    expect(probe.errorCode, 'QING_UPGRADE_REQUIRED');
    encrypted = true;
    await _expectCode(
      _resolve(api, source: PlaybackSource.qingMusic),
      'QING_ENCRYPTED_AUDIO',
    );
  }

  await _withApi(scenario, respond);
}

Map<String, dynamic> _candidate(
  String id,
  String name,
  String artist,
  int duration,
) {
  // 按 GD 公开搜索响应构造带歌手、来源和时长的候选歌曲。
  return {
    'id': id,
    'name': name,
    'artist': [artist],
    'album': '海阔天空',
    'source': 'netease',
    'extra_data': {'duration': duration},
  };
}

Future<SongDetail> _resolve(
  ApiService api, {
  PlaybackSource source = PlaybackSource.xinghai,
  String id = '347230',
}) {
  return api.resolvePlayback(
    source: source,
    platform: MusicPlatform.netease,
    id: id,
    quality: 'jymaster',
    name: '海阔天空',
    artist: 'Beyond',
    album: '海阔天空',
    duration: 319,
  );
}

Future<void> _expectCode(Future<SongDetail> request, String code) async {
  // 等待解析结束并核对业务错误码，意外成功时使测试失败。
  try {
    await request;
    fail('Expected API error: $code');
  } on ApiException catch (error) {
    expect(error.code, code);
  }
}

http.Response _json(Object body, {int status = 200}) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<void> _withApi(
  Future<void> Function(ApiService) scenario,
  Future<http.Response> Function(http.Request) respond, {
  PlaybackSourceConfig? config,
  String apiKey = '',
}) async {
  // 受控响应替代真实网络；每项测试最终关闭服务及其所有 HTTP/令牌资源。
  http.Client createClient() => MockClient(respond);
  Future<void> run() async {
    final api = ApiService(
      useRemotePlayback: false,
      apiKey: apiKey,
      playbackSourceConfig: config,
    );
    try {
      await scenario(api);
    } finally {
      api.close();
    }
  }

  await http.runWithClient(run, createClient);
}
