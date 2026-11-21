import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/playback_package.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/api_service.dart';
import 'package:music_player_app/services/bounded_http_response.dart';
import 'package:music_player_app/services/playback_package_store.dart';
import 'package:music_player_app/services/playback_resolver_service.dart';
import 'package:music_player_app/services/playback_script_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture fixture;
  setUp(() async {
    fixture = await _Fixture.create();
  });
  tearDown(() async {
    await fixture.close();
  });

  test(
    'first launch resolves using actual bundled assets without checking server',
    () async {
      final runtime = _FakeRuntime();
      final store = PlaybackPackageStore(
        root: fixture.root,
        client: MockClient(fixture.updateRequest),
      );
      final service = PlaybackResolverService(
        packageStore: store,
        scriptRuntime: runtime,
      );
      try {
        final catalog = await service.loadSources();
        final result = await service.resolve(_input('first'));
        expect(catalog.sources.length, 5);
        expect(
          result.url,
          contains('/p${store.current!.packageVersion}/first.mp3'),
        );
        expect(fixture.requests, isEmpty);
        expect(service.activeRequestCount, 0);
      } finally {
        service.close();
      }
    },
  );

  test(
    'unreachable update interface never becomes a playback prerequisite',
    () async {
      fixture.offline = true;
      final updating = fixture.service.checkUpdate();
      final result = await fixture
          .resolve('song')
          .timeout(const Duration(seconds: 1));
      expect(result.url, 'https://cdn.test/p1/song.mp3');
      expect(await updating, isFalse);
      expect(fixture.service.packageVersion, 1);
      expect(fixture.requests, ['/updates/manifest.json']);
      expect(fixture.unexpectedNetworkRequests, 0);
    },
  );

  test(
    'permanently hanging update still permits local sources and repeated parsing',
    () async {
      fixture.manifestGate = Completer<http.Response>();
      final updating = fixture.service.checkUpdate();
      await fixture.updateOpened.future;
      expect(fixture.service.checkingUpdate, isTrue);
      final sources = await fixture.service.loadSources().timeout(
        const Duration(seconds: 1),
      );
      expect(sources.sources.single.source.value, 'test_source_1');
      for (final id in ['one', 'two', 'three']) {
        final result = await fixture
            .resolve(id)
            .timeout(const Duration(seconds: 1));
        expect(result.url, 'https://cdn.test/p1/$id.mp3');
      }
      expect(fixture.requests, ['/updates/manifest.json']);
      expect(fixture.unexpectedNetworkRequests, 0);
      fixture.service.close();
      expect(await updating, isFalse);
    },
  );

  test(
    'new package changes only later parses while an earlier parse keeps its version',
    () async {
      fixture.runtime.firstGate = Completer<void>();
      final earlier = fixture.resolve('earlier');
      await fixture.runtime.firstEntered.future;
      expect(fixture.runtime.versions, [1]);
      expect(await fixture.service.checkUpdate(), isTrue);
      expect(fixture.service.packageVersion, 2);
      final later = await fixture.resolve('later');
      expect(later.url, 'https://cdn.test/p2/later.mp3');
      expect(later.playbackSource?.value, 'test_source_2');
      fixture.runtime.firstGate!.complete();
      final original = await earlier;
      expect(original.url, 'https://cdn.test/p1/earlier.mp3');
      expect(original.playbackSource?.value, 'test_source_1');
      expect(fixture.runtime.versions, [1, 2]);
      expect(fixture.unexpectedNetworkRequests, 0);
      expect(fixture.service.activeRequestCount, 0);
    },
  );

  test(
    'close cancels background check and active parse without publishing late results',
    () async {
      fixture.manifestGate = Completer<http.Response>();
      fixture.runtime.firstGate = Completer<void>();
      final updating = fixture.service.checkUpdate();
      await fixture.updateOpened.future;
      final parsing = fixture.resolve('closing');
      final assertion = expectLater(
        parsing,
        throwsA(isA<HttpRequestCancelledException>()),
      );
      await fixture.runtime.firstEntered.future;
      fixture.service.close();
      await assertion;
      expect(await updating, isFalse);
      fixture.manifestGate!.complete(
        http.Response.bytes(fixture.release.envelope, 200),
      );
      fixture.runtime.firstGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(fixture.service.packageVersion, 1);
      expect(fixture.service.activeRequestCount, 0);
      expect(fixture.runtime.closed, isTrue);
      expect(await Directory('${fixture.root.path}/p000002').exists(), isFalse);
    },
  );

  test(
    'package runtime failure rolls back locally and never asks server to parse',
    () async {
      expect(await fixture.service.checkUpdate(), isTrue);
      fixture.runtime.failedVersion = 2;
      final result = await fixture.resolve('recovered');
      expect(result.url, 'https://cdn.test/p1/recovered.mp3');
      expect(fixture.runtime.versions, [2, 1]);
      expect(fixture.service.packageVersion, 1);
      expect(fixture.unexpectedNetworkRequests, 0);
      expect(fixture.requests, [
        '/updates/manifest.json',
        '/updates/packages/p000002.json',
      ]);
    },
  );

  test(
    'unregistered provider result is rejected without network fallback',
    () async {
      fixture.runtime.providerId = 'unregistered_source';
      await expectLater(
        fixture.resolve('invalid-provider'),
        throwsA(
          isA<PlaybackResolutionException>().having(
            (error) => error.code,
            'code',
            'INVALID_RESULT',
          ),
        ),
      );
      expect(fixture.requests, isEmpty);
      expect(fixture.unexpectedNetworkRequests, 0);
    },
  );

  test('provider result for an unsupported platform is rejected', () async {
    final input = _input('unsupported')..['platform'] = '163';
    await expectLater(
      fixture.service.resolve(input),
      throwsA(
        isA<PlaybackResolutionException>().having(
          (error) => error.code,
          'code',
          'INVALID_RESULT',
        ),
      ),
    );
    expect(fixture.requests, isEmpty);
  });

  test('API publishes restored local catalog after runtime rollback', () async {
    final api = ApiService(apiKey: '', playbackResolver: fixture.service);
    final notifications = <String>[];
    api.onPlaybackPackageChanged = (catalog) {
      notifications.add(catalog.sources.single.source.value);
    };
    try {
      final initial = await api.loadPlaybackSources();
      expect(initial.sources.single.source.value, 'test_source_1');
      expect(notifications, isEmpty);
      await api.checkPlaybackPackageUpdate();
      expect(api.playbackPackageVersion, 2);
      expect(notifications, ['test_source_2']);
      fixture.runtime.failedVersion = 2;
      Future<SongDetail> parse() => api.resolvePlayback(
        source: PlaybackSource.automatic,
        platform: MusicPlatform.qq,
        id: 'api-recovered',
        quality: '320k',
      );
      http.Client client() => MockClient(fixture.rejectUnexpectedNetwork);
      final result = await http.runWithClient(parse, client);
      expect(result.url, 'https://cdn.test/p1/api-recovered.mp3');
      expect(api.playbackPackageVersion, 1);
      expect(
        api.playbackSourceCatalog!.sources.single.source.value,
        'test_source_1',
      );
      expect(notifications, ['test_source_2', 'test_source_1']);
      expect(fixture.runtime.versions, [2, 1]);
      expect(fixture.requests, [
        '/updates/manifest.json',
        '/updates/packages/p000002.json',
      ]);
      expect(fixture.unexpectedNetworkRequests, 0);
    } finally {
      api.close();
    }
  });
}

Map<String, dynamic> _input(String id) => {
  'platform': 'qq',
  'id': id,
  'source': 'automatic',
  'quality': '320k',
  'name': '测试歌曲',
  'artist': '测试歌手',
  'album': '测试专辑',
};

bool _isPackageFailure(Object error) =>
    error is FormatException ||
    (error is PlaybackScriptException && error.code.startsWith('PACKAGE_'));

Future<http.Response> _rejectRuntimeNetwork(http.Request request) async =>
    throw StateError('unexpected runtime network: ${request.url.path}');

class _FakeRuntime extends PlaybackScriptRuntime {
  final versions = <int>[];
  final firstEntered = Completer<void>();
  Completer<void>? firstGate;
  int? failedVersion;
  String? providerId;
  bool closed = false;
  _FakeRuntime() : super(client: MockClient(_rejectRuntimeNetwork));

  @override
  Future<void> validate(PlaybackPackage package) async {}

  @override
  Future<Map<String, dynamic>> resolve(
    PlaybackPackage package,
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
  }) async {
    if (closed) throw const HttpRequestCancelledException();
    final version = package.packageVersion;
    versions.add(version);
    if (version == failedVersion) {
      throw const PlaybackScriptException('PACKAGE_EXECUTION', '测试包代码故障');
    }
    if (firstGate != null && versions.length == 1) {
      firstEntered.complete();
      await awaitWithCancellation(firstGate!.future, cancelSignal!);
    }
    if (closed) throw const HttpRequestCancelledException();
    final supported = package.capabilities.sources.where(
      (source) => source.platforms.contains(input['platform']),
    );
    final descriptor = supported.isEmpty
        ? package.capabilities.sources.first
        : supported.first;
    return {
      'protocolVersion': 1,
      'providerId': providerId ?? descriptor.source.value,
      'providerName': descriptor.source.label,
      'url': 'https://cdn.test/p$version/${input['id']}.mp3',
      'format': 'mp3',
      'playbackHeaders': {},
    };
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _Release {
  final List<int> envelope;
  final List<int> bytes;
  const _Release(this.envelope, this.bytes);
}

class _Fixture {
  final Directory root;
  final SimpleKeyPair key;
  final String publicKey;
  final runtime = _FakeRuntime();
  final requests = <String>[];
  final updateOpened = Completer<void>();
  late _Release builtin;
  late _Release release;
  late PlaybackPackageStore store;
  late PlaybackResolverService service;
  Completer<http.Response>? manifestGate;
  bool offline = false;
  int unexpectedNetworkRequests = 0;
  _Fixture(this.root, this.key, this.publicKey);

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp('parser-offline-');
    final key = await Ed25519().newKeyPairFromSeed(
      List<int>.generate(32, (index) => index + 2),
    );
    final result = _Fixture(
      directory,
      key,
      base64Encode((await key.extractPublicKey()).bytes),
    );
    result.builtin = await result.sign(1);
    result.release = await result.sign(2);
    result.store = PlaybackPackageStore(
      root: directory,
      publicKey: result.publicKey,
      bundledLoader: result.loadBuiltin,
      client: MockClient(result.updateRequest),
      updateServer: Uri.parse('https://update.test/updates/'),
      validator: result.runtime.validate,
      isPackageFailure: _isPackageFailure,
    );
    result.service = PlaybackResolverService(
      packageStore: result.store,
      scriptRuntime: result.runtime,
    );
    return result;
  }

  Future<PlaybackPackage> loadBuiltin() => PlaybackPackage.verify(
    builtin.envelope,
    builtin.bytes,
    publicKey: publicKey,
  );

  Future<SongDetail> resolve(String id) {
    Future<SongDetail> perform() => service.resolve(_input(id));
    http.Client client() => MockClient(rejectUnexpectedNetwork);
    return http.runWithClient(perform, client);
  }

  Future<http.Response> rejectUnexpectedNetwork(http.Request request) async {
    unexpectedNetworkRequests++;
    throw StateError('unexpected parser network: ${request.url.path}');
  }

  Future<http.Response> updateRequest(http.Request request) async {
    requests.add(request.url.path);
    if (offline) throw const SocketException('offline');
    if (request.url.path.endsWith('/manifest.json')) {
      if (!updateOpened.isCompleted) updateOpened.complete();
      if (manifestGate != null) return manifestGate!.future;
      return http.Response.bytes(release.envelope, 200);
    }
    return http.Response.bytes(release.bytes, 200);
  }

  Future<_Release> sign(int version) async {
    final bytes = utf8.encode(
      jsonEncode({
        'packageFormat': 1,
        'packageVersion': version,
        'minimumBridgeVersion': 1,
        'capabilities': {
          'protocolVersion': 1,
          'revision': 'local-$version',
          'sources': [
            {
              'id': 'test_source_$version',
              'name': '测试音源',
              'description': '',
              'platforms': ['qq'],
              'credentials': [],
            },
          ],
        },
        'allowedOrigins': ['https://cdn.test'],
        'script': 'globalThis.version=$version;',
      }),
    );
    final payload = utf8.encode(
      jsonEncode({
        'packageFormat': 1,
        'packageVersion': version,
        'minimumBridgeVersion': 1,
        'packagePath': 'packages/p${version.toString().padLeft(6, '0')}.json',
        'sha256': sha256.convert(bytes).toString(),
        'bytes': bytes.length,
      }),
    );
    final signature = await Ed25519().sign(payload, keyPair: key);
    final envelope = utf8.encode(
      jsonEncode({
        'payloadBase64': base64Encode(payload),
        'signatureBase64': base64Encode(signature.bytes),
      }),
    );
    return _Release(envelope, bytes);
  }

  Future<void> close() async {
    service.close();
    if (manifestGate != null && !manifestGate!.isCompleted) {
      manifestGate!.complete(http.Response.bytes(release.envelope, 200));
    }
    if (runtime.firstGate != null && !runtime.firstGate!.isCompleted) {
      runtime.firstGate!.complete();
    }
    if (await root.exists()) await root.delete(recursive: true);
  }
}
