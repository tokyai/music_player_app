import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music_player_app/models/remote_playback.dart';
import 'package:music_player_app/models/playback_source_config.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/api_service.dart';
import 'package:music_player_app/services/bounded_http_response.dart';
import 'package:music_player_app/services/playback_resolver_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('capability HTTP response completes in a widget lifecycle', (
    tester,
  ) async {
    var completed = false;
    Object? failure;
    late ApiService api;
    http.runWithClient(() {
      api = ApiService(apiKey: '');
      unawaited(
        api
            .loadPlaybackSources()
            .then((_) {
              completed = true;
            })
            .catchError((Object error) {
              failure = error;
            }),
      );
    }, () => MockClient((_) async => _json(_catalog())));
    try {
      for (var index = 0; index < 5 && !completed; index++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(failure, isNull);
      expect(completed, isTrue);
    } finally {
      api.close();
      await tester.pump();
    }
  });
  test(
    'new server source is discovered and consumed without a local handler',
    () async {
      final sent = <Map<String, dynamic>>[];
      final api = ApiService(
        apiKey: 'personal-key',
        playbackSourceConfig: PlaybackSourceConfig.defaults().copyWith(
          remoteCredentials: {
            'new_source': {'accessKey': 'new-source-key'},
          },
        ),
        playbackResolver: PlaybackResolverService(
          client: MockClient((request) async {
            expect(request.url.host, '137.175.62.3');
            if (request.url.path.endsWith('/api/sources')) {
              return _json(_catalog());
            }
            expect(request.url.path, '/music-player-api/api/resolve');
            sent.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _json(_result());
          }),
        ),
      );
      try {
        final catalog = await api.loadPlaybackSources();
        final source = catalog.sources.single.source;
        expect(source.value, 'new_source');
        expect(source.label, '新音源');
        final detail = await api.resolvePlayback(
          source: source,
          platform: MusicPlatform.qq,
          id: 'song-id',
          quality: 'flac',
          name: '歌曲',
          artist: '歌手',
        );
        expect(detail.url, 'https://cdn.example.com/song.mp3');
        expect(detail.playbackSource, source);
        expect(detail.playbackHeaders, {
          'Referer': 'https://music.example.com/',
        });
        expect(sent.single['source'], 'new_source');
        expect(sent.single['platform'], 'qq');
        expect(sent.single['name'], '歌曲');
        expect(sent.single['credentials'], {
          'new_source': {'accessKey': 'new-source-key'},
        });
      } finally {
        api.close();
      }
    },
  );

  test(
    'old disabled IDs and credentials do not exceed active server capability bounds',
    () async {
      final config = PlaybackSourceConfig.defaults().copyWith(
        chkszEnabled: false,
        qingMusicEnabled: false,
        hywEnabled: false,
        xinghaiEnabled: false,
        gdStudioEnabled: false,
        disabledRemoteSources: List.generate(32, (index) => 'removed_$index'),
        remoteCredentials: {
          for (var index = 0; index < 32; index++)
            'removed_$index': {'key': 'value'},
        },
      );
      Map<String, dynamic>? sent;
      final api = ApiService(
        apiKey: 'personal-key',
        playbackSourceConfig: config,
        playbackResolver: PlaybackResolverService(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/api/sources')) {
              return _json(_catalog());
            }
            sent = jsonDecode(request.body) as Map<String, dynamic>;
            return _json(_result());
          }),
        ),
      );
      try {
        await _resolve(api);
        expect(sent!['disabledSources'], isEmpty);
        expect(sent!['credentials'], isEmpty);
      } finally {
        api.close();
      }
    },
  );

  test('bundled public card key never overrides future server defaults', () {
    final defaults = PlaybackSourceConfig.defaults();
    expect(defaults.credentialsForServer(apiKey: ''), isNot(contains('hyw')));
    final personal = defaults.copyWith(hywCardKey: 'my-personal-key');
    expect(personal.credentialsForServer(apiKey: '')['hyw'], {
      'hywCardKey': 'my-personal-key',
    });
    final explicit = defaults.copyWith(
      remoteCredentials: {
        'hyw': {'hywCardKey': 'explicit-key'},
      },
    );
    expect(explicit.credentialsForServer(apiKey: '')['hyw'], {
      'hywCardKey': 'explicit-key',
    });
  });

  test(
    'cancelling resolution also cancels its capability request without publishing it',
    () async {
      final gate = Completer<http.Response>();
      final entered = Completer<void>();
      final api = ApiService(
        apiKey: '',
        playbackSourceConfig: PlaybackSourceConfig.defaults().copyWith(
          disabledRemoteSources: List.generate(32, (index) => 'removed_$index'),
          chkszEnabled: false,
        ),
        playbackResolver: PlaybackResolverService(
          client: MockClient((_) async {
            entered.complete();
            return gate.future;
          }),
        ),
      );
      try {
        final resolving = _resolve(api);
        final assertion = expectLater(
          resolving,
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'RESOLVE_CANCELLED',
            ),
          ),
        );
        await entered.future;
        api.setApiKey('changed-key');
        await assertion;
        gate.complete(_json(_catalog()));
        await Future<void>.delayed(Duration.zero);
        expect(api.playbackSourceCatalog, isNull);
      } finally {
        api.close();
      }
    },
  );

  test(
    'server failure is returned without requesting a local upstream',
    () async {
      var requests = 0;
      final api = ApiService(
        apiKey: '',
        playbackResolver: PlaybackResolverService(
          client: MockClient((request) async {
            requests++;
            return _json({
              'code': 'SERVER_BUSY',
              'message': '解析服务繁忙',
            }, status: 503);
          }),
        ),
      );
      try {
        await expectLater(
          _resolve(api),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'SERVER_BUSY',
            ),
          ),
        );
        expect(requests, 1);
      } finally {
        api.close();
      }
    },
  );

  for (final invalid in <Map<String, dynamic>>[
    {'url': 'file:///private/song.mp3'},
    {'url': 'https://user:password@cdn.example.com/song.mp3'},
    {'providerId': '../new_source'},
    {'format': 'cenc'},
    {'expiresAt': 1},
    {
      'playbackHeaders': {'X-Test': 'value\r\nInjected: true'},
    },
    {
      'playbackHeaders': {'Host': 'localhost'},
    },
  ]) {
    test('rejects invalid playback result ${invalid.keys.single}', () async {
      final service = PlaybackResolverService(
        client: MockClient((_) async => _json({..._result(), ...invalid})),
      );
      try {
        await expectLater(
          service.resolve({'name': '', 'artist': '', 'album': ''}),
          throwsA(isA<PlaybackServerException>()),
        );
      } finally {
        service.close();
      }
    });
  }

  test('closing resolver cancels a response and does not publish it', () async {
    final entered = Completer<void>();
    final reply = Completer<http.Response>();
    final service = PlaybackResolverService(
      client: MockClient((_) async {
        entered.complete();
        return reply.future;
      }),
    );
    final resolving = service.resolve({'name': '', 'artist': '', 'album': ''});
    final assertion = expectLater(
      resolving,
      throwsA(isA<HttpRequestCancelledException>()),
    );
    await entered.future;
    service.close();
    reply.complete(_json(_result()));
    await assertion;
    expect(service.activeRequestCount, 0);
  });

  test('completed requests leave no retained cancellation records', () async {
    final service = PlaybackResolverService(
      client: MockClient((_) async => _json(_catalog())),
    );
    try {
      for (var index = 0; index < 200; index++) {
        await service.loadSources();
        expect(service.activeRequestCount, 0);
      }
    } finally {
      service.close();
    }
  });

  test('client refuses excess requests without growing a wait queue', () async {
    final response = Completer<http.Response>();
    final service = PlaybackResolverService(
      client: MockClient((_) => response.future),
    );
    final requests = <Future<PlaybackSourceCatalog>>[];
    for (var index = 0; index < 4; index++) {
      requests.add(service.loadSources());
    }
    await expectLater(
      service.loadSources(),
      throwsA(
        isA<PlaybackServerException>().having(
          (error) => error.code,
          'code',
          'REQUEST_BUSY',
        ),
      ),
    );
    expect(service.activeRequestCount, 4);
    response.complete(_json(_catalog()));
    await Future.wait(requests);
    expect(service.activeRequestCount, 0);
    service.close();
  });

  test('repeated resolution discards the previous response', () async {
    final entered = Completer<void>();
    final first = Completer<http.Response>();
    var calls = 0;
    final api = ApiService(
      apiKey: '',
      playbackResolver: PlaybackResolverService(
        client: MockClient((_) async {
          calls++;
          if (calls == 1) {
            entered.complete();
            return first.future;
          }
          return _json(_result());
        }),
      ),
    );
    try {
      final previous = _resolve(api);
      final assertion = expectLater(
        previous,
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'RESOLVE_CANCELLED',
          ),
        ),
      );
      await entered.future;
      final current = await _resolve(api);
      first.complete(
        _json({..._result(), 'url': 'https://cdn.example.com/old.mp3'}),
      );
      await assertion;
      expect(current.url, 'https://cdn.example.com/song.mp3');
    } finally {
      api.close();
    }
  });

  test(
    'capabilities reject incompatible versions duplicate IDs and unbounded fields',
    () {
      expect(
        () => PlaybackSourceCatalog.fromJson({
          ..._catalog(),
          'protocolVersion': 2,
        }),
        throwsFormatException,
      );
      expect(
        () => PlaybackSourceCatalog.fromJson({
          ..._catalog(),
          'sources': [_source(), _source()],
        }),
        throwsFormatException,
      );
      expect(
        () => PlaybackSourceCatalog.fromJson({
          ..._catalog(),
          'sources': [
            {
              ..._source(),
              'credentials': List.filled(17, {'key': 'key', 'label': '密钥'}),
            },
          ],
        }),
        throwsFormatException,
      );
      final source = PlaybackSource.fromId('new_source', label: '服务端名称');
      expect(source, PlaybackSource.fromId('new_source'));
      expect({source, PlaybackSource.fromId('new_source')}.length, 1);
    },
  );
}

Future<SongDetail> _resolve(ApiService api) => api.resolvePlayback(
  source: PlaybackSource.automatic,
  platform: MusicPlatform.qq,
  id: 'song-id',
  quality: '320k',
);

http.Response _json(Map<String, dynamic> value, {int status = 200}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(value)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _source() => {
  'id': 'new_source',
  'name': '新音源',
  'description': '新增解析渠道',
  'platforms': ['qq'],
  'credentials': [
    {
      'key': 'accessKey',
      'label': '访问密钥',
      'requiredPlatforms': ['qq'],
    },
  ],
};

Map<String, dynamic> _catalog() => {
  'protocolVersion': 1,
  'revision': 'test-1',
  'sources': [_source()],
};

Map<String, dynamic> _result() => {
  'protocolVersion': 1,
  'providerId': 'new_source',
  'providerName': '新音源',
  'url': 'https://cdn.example.com/song.mp3',
  'format': 'mp3',
  'playbackHeaders': {'Referer': 'https://music.example.com/'},
};
