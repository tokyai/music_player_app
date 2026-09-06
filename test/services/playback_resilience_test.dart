import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/playback_source_config.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final platform in configurableMusicPlatforms) {
    test(
      'highest $platform quality can fall back to standard without duplicate requests',
      () async {
        final levels = <String>[];
        await http.runWithClient(
          () async {
            final api = ApiService(
              apiKey: '',
              playbackSourceConfig: _onlyQing(),
            );
            try {
              final detail = await _resolve(api, platform: platform);
              expect(detail.url, 'https://audio.test/standard.mp3');
            } finally {
              api.close();
            }
          },
          () => MockClient((request) async {
            final level = (jsonDecode(request.body) as Map)['level'] as String;
            levels.add(level);
            return level == 'standard'
                ? _json({
                    'code': 0,
                    'data': {'url': 'https://audio.test/standard.mp3'},
                  })
                : _json({'code': 404, 'message': 'quality unavailable'});
          }),
        );
        expect(levels, switch (platform) {
          MusicPlatform.netease => [
            'jymaster',
            'lossless',
            'exhigh',
            'standard',
          ],
          MusicPlatform.qq => ['lossless', 'exhigh', 'standard'],
          _ => ['clear', 'lossless', 'exhigh', 'standard'],
        });
      },
    );
  }

  test(
    'manual resolution cancels while waiting for response headers',
    () async {
      final started = Completer<void>();
      final reply = Completer<http.Response>();
      var cancelled = false;
      await http.runWithClient(
        () async {
          final api = ApiService(apiKey: '', playbackSourceConfig: _onlyQing());
          try {
            final result = _resolve(
              api,
              source: PlaybackSource.qingMusic,
              isCancelled: () => cancelled,
            );
            final rejection = expectLater(result, throwsA(_cancelledError));
            await started.future;
            cancelled = true;
            await rejection.timeout(const Duration(seconds: 1));
            reply.complete(
              _json({
                'code': 0,
                'data': {'url': 'https://audio.test/late.mp3'},
              }),
            );
            await Future<void>.delayed(Duration.zero);
          } finally {
            api.close();
          }
        },
        () => MockClient((_) {
          started.complete();
          return reply.future;
        }),
      );
    },
  );

  test(
    'automatic failures do not retain unbounded backend error codes',
    () async {
      final oversizedCode = List.filled(4096, 'x').join();
      await http.runWithClient(() async {
        final api = ApiService(apiKey: '', playbackSourceConfig: _onlyQing());
        try {
          await expectLater(
            _resolve(api),
            throwsA(
              isA<ApiException>()
                  .having(
                    (error) => error.code,
                    'code',
                    'ALL_PLAYBACK_SOURCES_FAILED',
                  )
                  .having(
                    (error) => error.message.length,
                    'message length',
                    lessThan(1024),
                  ),
            ),
          );
        } finally {
          api.close();
        }
      }, () => MockClient((_) async => _json({'code': oversizedCode})));
    },
  );

  test(
    'a new song reuses the IP lookup without inheriting the old cancellation',
    () async {
      final ipStarted = Completer<void>();
      final ipReply = Completer<http.Response>();
      final resolvedIds = <String>[];
      var ipRequests = 0;
      await http.runWithClient(
        () async {
          final config = PlaybackSourceConfig.defaults().copyWith(
            xinghaiUrl: 'https://xinghai.test/api/',
            xinghaiIpUrl: 'https://xinghai.test/ip.php',
          );
          final api = ApiService(apiKey: '', playbackSourceConfig: config);
          try {
            final old = _resolve(
              api,
              source: PlaybackSource.xinghai,
              id: 'old',
            );
            final rejection = expectLater(old, throwsA(_cancelledError));
            await ipStarted.future;
            final latest = _resolve(
              api,
              source: PlaybackSource.xinghai,
              id: 'latest',
            );
            await rejection;
            ipReply.complete(_json({'ip': '203.0.113.8'}));
            expect((await latest).url, 'https://audio.test/latest.mp3');
          } finally {
            api.close();
          }
        },
        () => MockClient((request) {
          if (request.url.path == '/ip.php') {
            ipRequests++;
            ipStarted.complete();
            return ipReply.future;
          }
          resolvedIds.add(request.url.queryParameters['songmid']!);
          return Future.value(
            _json({'code': 200, 'url': 'https://audio.test/latest.mp3'}),
          );
        }),
      );
      expect(ipRequests, 1);
      expect(resolvedIds, ['latest']);
    },
  );

  test('cancelling a source batch does not launch remaining probes', () async {
    final started = Completer<void>();
    final reply = Completer<http.Response>();
    final cancel = Completer<void>();
    var sends = 0;
    await http.runWithClient(
      () async {
        final api = ApiService(apiKey: 'test-key');
        try {
          final results = api.testPlaybackSources(
            maxConcurrent: 1,
            cancelSignal: cancel.future,
          );
          final rejection = expectLater(results, throwsA(_cancelledError));
          await started.future;
          cancel.complete();
          await rejection;
          reply.complete(_json({}));
          await Future<void>.delayed(Duration.zero);
        } finally {
          api.close();
        }
      },
      () => MockClient((_) {
        sends++;
        started.complete();
        return reply.future;
      }),
    );
    expect(sends, 1);
  });

  test(
    'base URLs retain their path prefix and custom query parameters',
    () async {
      final urls = <Uri>[];
      await http.runWithClient(
        () async {
          final api = ApiService(
            apiKey: 'test',
            playbackSourceConfig: PlaybackSourceConfig.defaults().copyWith(
              chkszBaseUrl: 'https://custom.test/proxy/?tenant=a',
              hywBaseUrl: 'https://custom.test/hyw/?tenant=b',
            ),
          );
          try {
            await api.testPlaybackSource(PlaybackSource.chksz);
            await api.testPlaybackSource(PlaybackSource.hyw);
          } finally {
            api.close();
          }
        },
        () => MockClient((request) async {
          urls.add(request.url);
          return _json({});
        }),
      );
      expect(urls.map((url) => url.path), [
        '/proxy/api/qq_music',
        '/hyw/api/music/url',
      ]);
      expect(urls.map((url) => url.queryParameters['tenant']), ['a', 'b']);
    },
  );

  test(
    'configuration rejects unsafe header values and credential-bearing URLs',
    () {
      final config = PlaybackSourceConfig.defaults();
      for (final invalid in [
        config.copyWith(hywCardKey: 'key\r\nInjected: header'),
        config.copyWith(xinghaiClient: 'client\nextra'),
        config.copyWith(xinghaiClient: '非 ASCII'),
        config.copyWith(chkszBaseUrl: 'https://user:secret@resolver.test'),
        config.copyWith(hywBaseUrl: 'https://resolver.test/#fragment'),
      ]) {
        expect(invalid.validated, throwsFormatException);
      }
    },
  );
}

final _cancelledError = isA<ApiException>().having(
  (error) => error.code,
  'code',
  'RESOLVE_CANCELLED',
);

PlaybackSourceConfig _onlyQing() => PlaybackSourceConfig.defaults().copyWith(
  chkszEnabled: false,
  qingMusicUrl: 'https://qing.test/resolve',
  hywEnabled: false,
  xinghaiEnabled: false,
  gdStudioEnabled: false,
);

Future<SongDetail> _resolve(
  ApiService api, {
  PlaybackSource source = PlaybackSource.automatic,
  MusicPlatform platform = MusicPlatform.qq,
  String id = 'test-song',
  bool Function()? isCancelled,
}) => api.resolvePlayback(
  source: source,
  platform: platform,
  id: id,
  quality: platform == MusicPlatform.netease ? 'jymaster' : 'master',
  name: 'song',
  artist: 'artist',
  album: 'album',
  isCancelled: isCancelled,
);

http.Response _json(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
