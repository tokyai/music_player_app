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
    'new source is read and resolved entirely from the local package',
    () async {
      final catalog = await fixture.service.loadSources();
      final detail = await fixture.resolve();
      expect(catalog.sources.single.source.value, 'new_source');
      expect(detail.playbackSource, PlaybackSource.fromId('new_source'));
      expect(detail.url, 'https://audio.test/song.mp3');
      expect(fixture.requests, isEmpty);
      expect(fixture.service.activeRequestCount, 0);
    },
  );

  test(
    'unreachable updater does not stop subsequent local resolution',
    () async {
      fixture.offline = true;
      expect(await fixture.service.checkUpdate(), isFalse);
      final detail = await fixture.resolve();
      expect(detail.url, 'https://audio.test/song.mp3');
      expect(fixture.requests, ['/updates/manifest.json']);
      expect(fixture.service.updateError, isNotNull);
    },
  );

  test(
    'a hanging update request never queues local package lookup or playback',
    () async {
      fixture.manifestGate = Completer<http.Response>();
      final updating = fixture.service.checkUpdate();
      await fixture.opened.future;
      final catalog = await fixture.service.loadSources().timeout(
        const Duration(seconds: 1),
      );
      final detail = await fixture.resolve().timeout(
        const Duration(seconds: 1),
      );
      expect(catalog.sources, hasLength(1));
      expect(detail.url, 'https://audio.test/song.mp3');
      fixture.service.close();
      fixture.manifestGate!.complete(http.Response('{}', 503));
      expect(await updating, isFalse);
    },
  );

  final invalid = <Map<String, dynamic>>[
    {'url': 'file:///private/song.mp3'},
    {'url': 'https://user:password@audio.test/song.mp3'},
    {'providerId': '../source'},
    {'providerName': 'name\r\n'},
    {'format': 'cenc'},
    {'expiresAt': 1},
    {
      'playbackHeaders': {'Host': 'localhost'},
    },
    {
      'playbackHeaders': {'X-Test': 'value\r\nInjected: true'},
    },
  ];
  for (var index = 0; index < invalid.length; index++) {
    test(
      'invalid local result $index cannot enter the native player',
      () async {
        fixture.runtime.response = <String, dynamic>{
          ..._result(),
          ...invalid[index],
        };
        await expectLater(
          fixture.resolve(),
          throwsA(isA<PlaybackResolutionException>()),
        );
        expect(fixture.service.activeRequestCount, 0);
      },
    );
  }

  test(
    'closing local resolver cancels pending work and discards a late reply',
    () async {
      fixture.runtime.gate = Completer<Map<String, dynamic>>();
      final resolving = fixture.resolve();
      final assertion = expectLater(
        resolving,
        throwsA(isA<HttpRequestCancelledException>()),
      );
      await fixture.runtime.entered.future;
      fixture.service.close();
      fixture.runtime.gate!.complete(_result());
      await assertion;
      expect(fixture.service.activeRequestCount, 0);
    },
  );

  test('local work is limited without accumulating a wait queue', () async {
    fixture.runtime.gate = Completer<Map<String, dynamic>>();
    final tasks = <Future<SongDetail>>[];
    for (var index = 0; index < 4; index++) {
      tasks.add(fixture.resolve());
    }
    await expectLater(
      fixture.resolve(),
      throwsA(isA<PlaybackResolutionException>()),
    );
    expect(fixture.service.activeRequestCount, 4);
    fixture.runtime.gate!.complete(_result());
    await Future.wait(tasks);
    expect(fixture.service.activeRequestCount, 0);
  });

  test(
    'owner signal errors cancel local work without an unhandled error',
    () async {
      fixture.runtime.gate = Completer<Map<String, dynamic>>();
      final owner = Completer<void>();
      final resolving = fixture.resolve(cancelSignal: owner.future);
      final assertion = expectLater(
        resolving,
        throwsA(isA<HttpRequestCancelledException>()),
      );
      await fixture.runtime.entered.future;
      owner.completeError(StateError('owner disposed'));
      await assertion;
      fixture.runtime.gate!.complete(_result());
      expect(fixture.service.activeRequestCount, 0);
    },
  );

  test(
    'hundreds of local lookups keep no historical cancellation records',
    () async {
      for (var index = 0; index < 200; index++) {
        await fixture.service.loadSources();
        await fixture.resolve();
        expect(fixture.service.activeRequestCount, 0);
      }
      expect(fixture.requests, isEmpty);
    },
  );
}

Map<String, dynamic> _result() => <String, dynamic>{
  'protocolVersion': 1,
  'providerId': 'new_source',
  'providerName': '新音源',
  'url': 'https://audio.test/song.mp3',
  'format': 'mp3',
  'playbackHeaders': <String, String>{},
};

class _Runtime extends PlaybackScriptRuntime {
  Map<String, dynamic> response = _result();
  Completer<Map<String, dynamic>>? gate;
  final entered = Completer<void>();
  @override
  Future<void> validate(PlaybackPackage package) async {}
  @override
  Future<Map<String, dynamic>> resolve(
    PlaybackPackage package,
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
  }) async {
    if (!entered.isCompleted) entered.complete();
    if (gate == null) return response;
    return cancelSignal == null
        ? await gate!.future
        : await awaitWithCancellation(gate!.future, cancelSignal);
  }
}

class _Fixture {
  final Directory root;
  final PlaybackPackage package;
  final String publicKey;
  final runtime = _Runtime();
  final requests = <String>[];
  final opened = Completer<void>();
  late final PlaybackResolverService service;
  bool offline = false;
  Completer<http.Response>? manifestGate;

  _Fixture(this.root, this.package, this.publicKey) {
    final store = PlaybackPackageStore(
      root: root,
      publicKey: publicKey,
      bundledLoader: loadBundled,
      client: MockClient(request),
      updateServer: Uri.parse('https://update.test/updates/'),
      validator: runtime.validate,
    );
    service = PlaybackResolverService(
      packageStore: store,
      scriptRuntime: runtime,
    );
  }

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('local-parser-facade-');
    final key = await Ed25519().newKeyPairFromSeed(
      List<int>.generate(32, (index) => index + 1),
    );
    final publicKey = base64Encode((await key.extractPublicKey()).bytes);
    final bytes = utf8.encode(
      jsonEncode(<String, dynamic>{
        'packageFormat': 1,
        'packageVersion': 1,
        'minimumBridgeVersion': 1,
        'allowedOrigins': ['https://source.test'],
        'script': 'globalThis.localPackage=true;',
        'capabilities': <String, dynamic>{
          'protocolVersion': 1,
          'revision': 'local-1',
          'sources': [
            <String, dynamic>{
              'id': 'new_source',
              'name': '新音源',
              'description': '本地测试',
              'platforms': ['qq'],
              'credentials': [],
            },
          ],
        },
      }),
    );
    final payload = utf8.encode(
      jsonEncode(<String, dynamic>{
        'packageFormat': 1,
        'packageVersion': 1,
        'minimumBridgeVersion': 1,
        'packagePath': 'packages/p000001.json',
        'sha256': sha256.convert(bytes).toString(),
        'bytes': bytes.length,
      }),
    );
    final signature = await Ed25519().sign(payload, keyPair: key);
    final envelope = utf8.encode(
      jsonEncode(<String, dynamic>{
        'payloadBase64': base64Encode(payload),
        'signatureBase64': base64Encode(signature.bytes),
      }),
    );
    final package = await PlaybackPackage.verify(
      envelope,
      bytes,
      publicKey: publicKey,
    );
    return _Fixture(root, package, publicKey);
  }

  Future<PlaybackPackage> loadBundled() async => package;
  Future<SongDetail> resolve({Future<void>? cancelSignal}) =>
      service.resolve(<String, dynamic>{
        'platform': 'qq',
        'id': 'song',
        'source': 'new_source',
        'quality': '320k',
        'name': '歌曲',
        'artist': '歌手',
        'album': '专辑',
      }, cancelSignal: cancelSignal);

  Future<http.Response> request(http.Request request) async {
    requests.add(request.url.path);
    if (!opened.isCompleted) opened.complete();
    if (offline) throw const SocketException('updater offline');
    if (manifestGate != null) return manifestGate!.future;
    return http.Response('{}', 503);
  }

  Future<void> close() async {
    service.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
