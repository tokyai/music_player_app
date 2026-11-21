import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/playback_package.dart';
import 'package:music_player_app/services/playback_package_store.dart';
import 'package:music_player_app/services/bounded_http_response.dart';

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
    'actual bundled assets verify offline with the application publisher key',
    () async {
      final store = PlaybackPackageStore(root: fixture.root);
      try {
        final package = await store.ready;
        expect(package.script, isNotEmpty);
        expect(package.capabilities.sources.length, 5);
        expect(store.activeRequestCount, 0);
      } finally {
        store.close();
      }
    },
  );

  test(
    'first offline launch uses bundled package without network or disk seed',
    () async {
      final current = await fixture.store.ready;
      expect(current.packageVersion, 1);
      expect(fixture.paths, isEmpty);
      expect(await fixture.root.list().toList(), isEmpty);
      expect(current.packageBytes, isA<Uint8List>());
      void mutateBytes() {
        current.packageBytes[0] = 0;
      }

      expect(mutateBytes, throwsUnsupportedError);
    },
  );

  test(
    'unreachable update server leaves the local parser immediately available',
    () async {
      fixture.offline = true;
      expect(await fixture.store.checkUpdate(), isFalse);
      expect(fixture.store.updateError, isNotNull);
      expect((await fixture.store.ready).packageVersion, 1);
      expect(fixture.store.current?.packageVersion, 1);
    },
  );

  test(
    'hanging update does not block ready and repeated checks share one request',
    () async {
      fixture.manifestGate = Completer<http.Response>();
      final first = fixture.store.checkUpdate();
      final second = fixture.store.checkUpdate();
      expect(identical(first, second), isTrue);
      await fixture.opened.future;
      expect((await fixture.store.ready).packageVersion, 1);
      expect(fixture.paths.length, 1);
      fixture.manifestGate!.complete(
        http.Response.bytes(fixture.release.envelope, 200),
      );
      expect(await first, isTrue);
      expect(fixture.store.current?.packageVersion, 2);
      expect(fixture.store.activeRequestCount, 0);
    },
  );

  test('a half downloaded bundle cannot replace valid bundled code', () async {
    fixture.truncate = true;
    expect(await fixture.store.checkUpdate(), isFalse);
    expect(fixture.store.current?.packageVersion, 1);
    expect(await fixture.root.list().toList(), isEmpty);
  });

  test(
    'untrusted manifest is rejected before downloading the package',
    () async {
      final envelope =
          jsonDecode(utf8.decode(fixture.release.envelope))
              as Map<String, dynamic>;
      envelope['signatureBase64'] = base64Encode(List<int>.filled(64, 0));
      fixture.manifestOverride = utf8.encode(jsonEncode(envelope));
      expect(await fixture.store.checkUpdate(), isFalse);
      expect(fixture.paths.length, 1);
      expect(fixture.store.current?.packageVersion, 1);
    },
  );

  test(
    'invalid signed package path and bridge version are rejected before download',
    () async {
      fixture.release = await fixture.sign(2, packagePath: '../escape.json');
      expect(await fixture.store.checkUpdate(), isFalse);
      expect(fixture.paths.length, 1);
      fixture.paths.clear();
      fixture.release = await fixture.sign(2, minimumBridge: 2);
      expect(await fixture.store.checkUpdate(), isFalse);
      expect(fixture.paths.length, 1);
    },
  );

  test(
    'successful updates retain only current and previous disk versions',
    () async {
      for (final version in [2, 3, 4, 5]) {
        fixture.release = await fixture.sign(version);
        expect(await fixture.store.checkUpdate(), isTrue);
      }
      final directories = await fixture.root
          .list()
          .where(_isDirectory)
          .toList();
      expect(directories.map(_name).toSet(), {'p000004', 'p000005'});
      expect((await fixture.store.ready).packageVersion, 5);
      expect(fixture.store.current?.packageVersion, 5);
    },
  );

  test(
    'cache corruption restores the previous signed package without network',
    () async {
      expect(await fixture.store.checkUpdate(), isTrue);
      fixture.release = await fixture.sign(3);
      expect(await fixture.store.checkUpdate(), isTrue);
      await File(
        '${fixture.root.path}/p000003/bundle.json',
      ).writeAsString('tampered');
      final restarted = fixture.anotherStore();
      try {
        final count = fixture.paths.length;
        expect((await restarted.ready).packageVersion, 2);
        expect(fixture.paths.length, count);
      } finally {
        restarted.close();
      }
    },
  );

  test(
    'broken pointer is recovered from signed cache without a server call',
    () async {
      expect(await fixture.store.checkUpdate(), isTrue);
      await File('${fixture.root.path}/active.json').writeAsString('{broken');
      final restarted = fixture.anotherStore();
      try {
        expect((await restarted.ready).packageVersion, 2);
        fixture.release = await fixture.sign(3);
        expect(await restarted.checkUpdate(), isTrue);
      } finally {
        restarted.close();
      }
    },
  );

  test('a newer bundled version wins over older disk data', () async {
    expect(await fixture.store.checkUpdate(), isTrue);
    fixture.builtin = await fixture.sign(4);
    final restarted = fixture.anotherStore();
    try {
      expect((await restarted.ready).packageVersion, 4);
    } finally {
      restarted.close();
    }
  });

  test(
    'write failure preserves current pointer and existing parser package',
    () async {
      expect(await fixture.store.checkUpdate(), isTrue);
      final pointer = await File(
        '${fixture.root.path}/active.json',
      ).readAsString();
      await File(
        '${fixture.root.path}/p000003',
      ).writeAsString('blocks-directory');
      fixture.release = await fixture.sign(3);
      expect(await fixture.store.checkUpdate(), isFalse);
      expect(fixture.store.current?.packageVersion, 2);
      expect(
        await File('${fixture.root.path}/active.json').readAsString(),
        pointer,
      );
      expect(await Directory('${fixture.root.path}/p000002').exists(), isTrue);
    },
  );

  test('no writable disk root still permits first bundled launch', () async {
    final blocker = File('${fixture.root.path}/blocked')
      ..writeAsStringSync('file');
    final store = fixture.anotherStore(directory: Directory(blocker.path));
    try {
      expect((await store.ready).packageVersion, 1);
      expect(await store.checkUpdate(), isFalse);
      expect(store.current?.packageVersion, 1);
    } finally {
      store.close();
    }
  });

  test(
    'failed runtime validation remembers bad version and keeps old package',
    () async {
      final store = fixture.anotherStore(validator: _rejectRuntime);
      try {
        expect(await store.checkUpdate(), isFalse);
        expect(store.current?.packageVersion, 1);
        final count = fixture.paths.length;
        expect(await store.checkUpdate(), isFalse);
        expect(fixture.paths.length, count + 1);
      } finally {
        store.close();
      }
    },
  );

  test(
    'temporary runtime failure never permanently rejects a valid package',
    () async {
      final store = fixture.anotherStore(validator: _busyRuntime);
      try {
        expect(await store.checkUpdate(), isFalse);
        final count = fixture.paths.length;
        expect(await store.checkUpdate(), isFalse);
        expect(fixture.paths.length, count + 2);
        expect(store.current?.packageVersion, 1);
      } finally {
        store.close();
      }
      expect(await fixture.store.checkUpdate(), isTrue);
    },
  );

  test(
    'unresponsive platform directory lookup falls back to bundled memory',
    () async {
      final gate = _DirectoryGate();
      final store = PlaybackPackageStore(
        publicKey: fixture.publicKey,
        bundledLoader: fixture.loadBuiltin,
        directoryLoader: gate.load,
        client: MockClient(fixture.request),
      );
      try {
        final package = await store.ready.timeout(const Duration(seconds: 2));
        expect(package.packageVersion, 1);
        expect(fixture.paths, isEmpty);
        gate.done.complete(fixture.root);
        expect(await store.checkUpdate(), isFalse);
        expect(store.current?.packageVersion, 1);
      } finally {
        store.close();
      }
    },
  );

  test(
    'closing during network wait stops check and never publishes late response',
    () async {
      fixture.manifestGate = Completer<http.Response>();
      final check = fixture.store.checkUpdate();
      await fixture.opened.future;
      fixture.store.close();
      expect(await check, isFalse);
      fixture.manifestGate!.complete(
        http.Response.bytes(fixture.release.envelope, 200),
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.store.current?.packageVersion, 1);
      expect(fixture.store.activeRequestCount, 0);
    },
  );

  for (final lateFailure in [false, true]) {
    testWidgets(
      'closing a pending directory lookup cancels timer and ignores late ${lateFailure ? 'error' : 'result'}',
      (tester) async {
        final package = await tester.runAsync(fixture.loadBuiltin);
        final gate = _DirectoryGate();
        Future<PlaybackPackage> loadPackage() async => package!;
        final store = PlaybackPackageStore(
          publicKey: fixture.publicKey,
          bundledLoader: loadPackage,
          directoryLoader: gate.load,
          client: MockClient(fixture.request),
        );
        final ready = store.ready;
        final assertion = expectLater(
          ready,
          throwsA(isA<HttpRequestCancelledException>()),
        );
        await tester.pump();
        expect(gate.entered.isCompleted, isTrue);
        store.close();
        store.close();
        await tester.pump();
        await assertion;
        if (lateFailure) {
          gate.done.completeError(const FileSystemException('late failure'));
        } else {
          gate.done.complete(fixture.root);
        }
        await tester.pump();
        expect(store.current, isNull);
        expect(fixture.paths, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'closing during candidate validation cancels activation and leaves no new directory',
    () async {
      final gate = _ValidationGate();
      final store = fixture.anotherStore(validator: gate.validate);
      final checking = store.checkUpdate();
      await gate.entered.future;
      store.close();
      expect(await checking, isFalse);
      gate.done.complete();
      expect(store.current?.packageVersion, 1);
      expect(await Directory('${fixture.root.path}/p000002').exists(), isFalse);
    },
  );

  test(
    'two stores sharing one directory cannot delete an already committed version',
    () async {
      final other = fixture.anotherStore();
      try {
        await other.ready;
        expect(await fixture.store.checkUpdate(), isTrue);
        expect(await other.checkUpdate(), isFalse);
        expect(
          await Directory('${fixture.root.path}/p000002').exists(),
          isTrue,
        );
        final restarted = fixture.anotherStore();
        try {
          expect((await restarted.ready).packageVersion, 2);
        } finally {
          restarted.close();
        }
      } finally {
        other.close();
      }
    },
  );

  test(
    'runtime failure restores previous package and prevents reinstallation of the bad version',
    () async {
      expect(await fixture.store.checkUpdate(), isTrue);
      fixture.release = await fixture.sign(3);
      expect(await fixture.store.checkUpdate(), isTrue);
      expect(await fixture.store.rollback(3), isTrue);
      expect(fixture.store.current?.packageVersion, 2);
      expect(await fixture.store.checkUpdate(), isFalse);
      final restarted = fixture.anotherStore();
      try {
        expect((await restarted.ready).packageVersion, 2);
      } finally {
        restarted.close();
      }
    },
  );

  test(
    'runtime failure with no previous disk package restores bundled code',
    () async {
      expect(await fixture.store.checkUpdate(), isTrue);
      expect(await fixture.store.rollback(2), isTrue);
      expect((await fixture.store.ready).packageVersion, 1);
      expect(await fixture.store.rollback(2), isFalse);
      expect(await fixture.store.checkUpdate(), isFalse);
    },
  );

  test('package and origins limits are enforced before activation', () async {
    final tooLarge = List<int>.filled(
      PlaybackPackageManifest.maxPackageBytes + 1,
      0,
    );
    await expectLater(
      PlaybackPackage.verify(
        fixture.release.envelope,
        tooLarge,
        publicKey: fixture.publicKey,
      ),
      throwsFormatException,
    );
    final badOrigin = await fixture.sign(
      2,
      origins: ['https://music.test/extra-path'],
    );
    await expectLater(
      badOrigin.package(fixture.publicKey),
      throwsFormatException,
    );
    final noScript = await fixture.sign(2, script: '');
    await expectLater(
      noScript.package(fixture.publicKey),
      throwsFormatException,
    );
  });
}

String _name(FileSystemEntity entry) =>
    entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
bool _isDirectory(FileSystemEntity entry) => entry is Directory;
Future<void> _rejectRuntime(PlaybackPackage package) async =>
    throw const FormatException('invalid script');
Future<void> _busyRuntime(PlaybackPackage package) async =>
    throw StateError('temporary workload');

class _ValidationGate {
  final entered = Completer<void>();
  final done = Completer<void>();
  Future<void> validate(PlaybackPackage package) {
    entered.complete();
    return done.future;
  }
}

class _DirectoryGate {
  final entered = Completer<void>();
  final done = Completer<Directory>();
  Future<Directory> load() {
    entered.complete();
    return done.future;
  }
}

class _Release {
  final List<int> envelope;
  final List<int> bytes;
  const _Release(this.envelope, this.bytes);
  Future<PlaybackPackage> package(String publicKey) =>
      PlaybackPackage.verify(envelope, bytes, publicKey: publicKey);
}

class _Fixture {
  final Directory root;
  final SimpleKeyPair key;
  final String publicKey;
  final paths = <String>[];
  final opened = Completer<void>();
  late _Release release;
  late _Release builtin;
  late PlaybackPackageStore store;
  bool offline = false;
  bool truncate = false;
  List<int>? manifestOverride;
  Completer<http.Response>? manifestGate;
  _Fixture(this.root, this.key, this.publicKey);

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'local-parser-package-',
    );
    final key = await Ed25519().newKeyPairFromSeed(
      List<int>.generate(32, (index) => index + 1),
    );
    final publicKey = base64Encode((await key.extractPublicKey()).bytes);
    final result = _Fixture(directory, key, publicKey);
    result.builtin = await result.sign(1);
    result.release = await result.sign(2);
    result.store = result.anotherStore();
    return result;
  }

  Future<_Release> sign(
    int version, {
    String? packagePath,
    int minimumBridge = 1,
    List<String> origins = const ['https://music.test'],
    String? script,
  }) async {
    final bytes = utf8.encode(
      jsonEncode({
        'packageFormat': 1,
        'packageVersion': version,
        'minimumBridgeVersion': minimumBridge,
        'capabilities': {
          'protocolVersion': 1,
          'revision': 'test-$version',
          'sources': [
            {
              'id': 'test_source',
              'name': '测试音源',
              'description': '',
              'platforms': ['qq'],
              'credentials': [],
            },
          ],
        },
        'allowedOrigins': origins,
        'script': script ?? 'globalThis.version=$version;',
      }),
    );
    final payload = utf8.encode(
      jsonEncode({
        'packageFormat': 1,
        'packageVersion': version,
        'minimumBridgeVersion': minimumBridge,
        'packagePath':
            packagePath ??
            'packages/p${version.toString().padLeft(6, '0')}.json',
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

  Future<PlaybackPackage> loadBuiltin() => builtin.package(publicKey);

  PlaybackPackageStore anotherStore({
    Directory? directory,
    Future<void> Function(PlaybackPackage)? validator,
  }) => PlaybackPackageStore(
    root: directory ?? root,
    publicKey: publicKey,
    bundledLoader: loadBuiltin,
    client: MockClient(request),
    updateServer: Uri.parse('https://update.test/updates/'),
    validator: validator,
  );

  Future<http.Response> request(http.Request request) async {
    paths.add(request.url.path);
    if (offline) throw const SocketException('offline');
    if (request.url.path.endsWith('/manifest.json')) {
      if (!opened.isCompleted) opened.complete();
      if (manifestGate != null) return manifestGate!.future;
      return http.Response.bytes(manifestOverride ?? release.envelope, 200);
    }
    return http.Response.bytes(
      truncate ? release.bytes.sublist(0, 5) : release.bytes,
      200,
    );
  }

  Future<void> close() async {
    store.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
