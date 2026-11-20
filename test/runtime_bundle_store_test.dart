import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/services/runtime_bundle_store.dart';
import 'package:music_player_app/services/runtime_http_client.dart';
import 'package:music_player_app/services/runtime_release.dart';
import 'package:music_player_app/services/bounded_http_response.dart';

// 测试使用独立发布密钥，不读取实际部署私钥。SHIXIAOYANG，2026/11/19。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SimpleKeyPair key;
  late String publicKey;
  late RuntimeBundleStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('music-runtime-test-');
    key = await Ed25519().newKeyPairFromSeed(
      List<int>.generate(32, (index) => index + 1),
    );
    publicKey = base64Encode((await key.extractPublicKey()).bytes);
    store = RuntimeBundleStore(root, publicKey: publicKey);
  });
  tearDown(() async {
    store.close();
    await root.delete(recursive: true);
  });

  Future<_ReleaseFixture> release(
    int version, {
    Map<String, String>? files,
    int minimumFramework = 1,
    String? signedId,
  }) async {
    final id = 'r${version.toString().padLeft(6, '0')}';
    final contents =
        files ??
        {
          'index.html': '<html>version $version</html>',
          'app.js': 'window.version=$version;',
        };
    final rows = contents.entries
        .map(
          (entry) => {
            'path': entry.key,
            'data': base64Encode(utf8.encode(entry.value)),
          },
        )
        .toList();
    final blob = utf8.encode(jsonEncode({'id': id, 'files': rows}));
    final payload = utf8.encode(
      jsonEncode({
        'schema': 1,
        'id': signedId ?? id,
        'version': version,
        'minimumFramework': minimumFramework,
        'bundlePath': 'releases/${signedId ?? id}/bundle.json',
        'bundleBytes': blob.length,
        'bundleSha256': sha256.convert(blob).toString(),
        'notes': '测试版本',
      }),
    );
    final signature = await Ed25519().sign(payload, keyPair: key);
    final envelope = utf8.encode(
      jsonEncode({
        'payload': base64Encode(payload),
        'signature': base64Encode(signature.bytes),
      }),
    );
    return _ReleaseFixture(id, envelope, blob);
  }

  RuntimeHttpClient clientFor(
    _ReleaseFixture fixture, {
    void Function(String)? observe,
  }) {
    return RuntimeHttpClient(
      base: Uri.parse('https://runtime.test/'),
      client: MockClient((request) async {
        observe?.call(request.url.path);
        return http.Response.bytes(
          request.url.path == '/manifest.json'
              ? fixture.envelope
              : fixture.blob,
          200,
        );
      }),
    );
  }

  test('首次离线使用内置签名版本，重新启动仍校验实际文件', () async {
    final first = await release(1);
    final installed = await store.seed(first.envelope, first.blob);
    expect(installed?.release.version, 1);
    expect(await installed!.entry.readAsString(), contains('version 1'));
    expect((await store.current())?.release.version, 1);
  });

  test('安装包内置业务资产能由当前框架公钥验签并完整离线加载', () async {
    final builtin = RuntimeBundleStore(root);
    try {
      final installed = await builtin.seed(
        await File('assets/runtime/manifest.json').readAsBytes(),
        await File('assets/runtime/bundle.json').readAsBytes(),
      );
      expect(installed, isNotNull);
      expect(await installed!.entry.exists(), isTrue);
      expect(
        (await builtin.current())?.release.id,
        installed.release.id,
      );
    } finally {
      builtin.close();
    }
  });

  test('连续更新只保留当前与上一版本，并清理残留暂存目录', () async {
    final first = await release(1);
    await store.seed(first.envelope, first.blob);
    await Directory('${root.path}/.staging-r999999').create();
    for (final version in [2, 3, 4]) {
      final client = clientFor(await release(version));
      try {
        await store.check(client);
      } finally {
        client.close();
      }
    }
    final directories = await root
        .list()
        .where((entry) => entry is Directory)
        .toList();
    expect(directories.length, 2);
    expect(await Directory('${root.path}/r000003').exists(), isTrue);
    expect(await Directory('${root.path}/r000004').exists(), isTrue);
    expect((await store.current())?.release.version, 4);
  });

  test('并发重复检查只下载一次，不重复切换状态', () async {
    final second = await release(2);
    var manifests = 0;
    final client = clientFor(
      second,
      observe: (path) {
        if (path == '/manifest.json') manifests++;
      },
    );
    final firstCheck = store.check(client);
    final secondCheck = store.check(client);
    expect(identical(firstCheck, secondCheck), isTrue);
    await Future.wait([firstCheck, secondCheck]);
    client.close();
    expect(manifests, 1);
    expect((await store.current())?.release.version, 2);
  });

  test('篡改签名的更新被拒绝，旧版本和入口保持有效', () async {
    final first = await release(1);
    await store.seed(first.envelope, first.blob);
    final second = await release(2);
    final envelope = jsonDecode(utf8.decode(second.envelope)) as Map;
    envelope['signature'] = base64Encode(List<int>.filled(64, 0));
    final client = clientFor(
      _ReleaseFixture(
        second.id,
        utf8.encode(jsonEncode(envelope)),
        second.blob,
      ),
    );
    await expectLater(store.check(client), throwsFormatException);
    client.close();
    expect((await store.current())?.release.version, 1);
  });

  test('篡改业务内容的更新被拒绝，不覆盖当前版本', () async {
    final first = await release(1);
    await store.seed(first.envelope, first.blob);
    final second = await release(2);
    final client = clientFor(
      _ReleaseFixture(second.id, second.envelope, [...second.blob, 0]),
    );
    await expectLater(store.check(client), throwsA(anything));
    client.close();
    expect((await store.current())?.release.version, 1);
  });

  test('已缓存脚本被篡改时自动恢复上一签名版本', () async {
    final first = await release(1);
    await store.seed(first.envelope, first.blob);
    final client = clientFor(await release(2));
    await store.check(client);
    client.close();
    await File('${root.path}/r000002/app.js').writeAsString('tampered');
    expect((await store.current())?.release.version, 1);
    expect(await Directory('${root.path}/r000002').exists(), isFalse);
  });

  test('页面启动失败后回滚，坏版本高水位阻止反复安装', () async {
    final first = await release(1);
    await store.seed(first.envelope, first.blob);
    final second = await release(2);
    final client = clientFor(second);
    await store.check(client);
    expect((await store.rollback(second.id))?.release.version, 1);
    expect((await store.check(client))?.release.version, 1);
    client.close();
    final thirdClient = clientFor(await release(3));
    expect((await store.check(thirdClient))?.release.version, 3);
    thirdClient.close();
  });

  test('框架不兼容的包拒绝激活且保留旧版本', () async {
    final first = await release(1);
    await store.seed(first.envelope, first.blob);
    final client = clientFor(await release(2, minimumFramework: 2));
    await expectLater(store.check(client), throwsA(isA<RuntimeException>()));
    client.close();
    expect((await store.current())?.release.version, 1);
  });

  test('签名中的版本号和目录标识必须一致', () async {
    final invalid = await release(2, signedId: 'r000003');
    await expectLater(
      RuntimeRelease.verify(invalid.envelope, publicKey: publicKey),
      throwsFormatException,
    );
  });

  for (final name in [
    '../escape.js',
    '/absolute.js',
    'folder/../escape.js',
    'a//b.js',
    'manifest.json',
  ]) {
    test('拒绝业务路径 $name，写入前完成校验', () async {
      final invalid = await release(
        1,
        files: {'index.html': 'safe', name: 'invalid'},
      );
      await expectLater(
        store.seed(invalid.envelope, invalid.blob),
        throwsFormatException,
      );
      expect(await File('${root.path}/active.json').exists(), isFalse);
    });
  }

  test('拒绝文件与父目录路径冲突，不留下半个业务包', () async {
    final invalid = await release(
      1,
      files: {'index.html': 'safe', 'assets': 'file', 'assets/app.js': 'child'},
    );
    await expectLater(
      store.seed(invalid.envelope, invalid.blob),
      throwsFormatException,
    );
    expect(await Directory('${root.path}/r000001').exists(), isFalse);
  });

  test('单文件超过上限时拒绝并保留有效数据', () async {
    final invalid = await release(
      1,
      files: {'index.html': 'x' * (2 * 1024 * 1024 + 1)},
    );
    await expectLater(
      store.seed(invalid.envelope, invalid.blob),
      throwsFormatException,
    );
  });

  test('状态文件损坏时只能从仍能验签的缓存恢复', () async {
    final first = await release(1);
    await store.seed(first.envelope, first.blob);
    await File('${root.path}/active.json').writeAsString('{broken');
    expect((await store.current())?.release.version, 1);
  });

  test('关闭期间取消下载，迟到响应不能激活业务版本', () async {
    final first = await release(1);
    await store.seed(first.envelope, first.blob);
    final response = Completer<http.Response>();
    final opened = Completer<void>();
    final client = RuntimeHttpClient(
      base: Uri.parse('https://runtime.test/'),
      client: MockClient((request) {
        opened.complete();
        return response.future;
      }),
    );
    final checking = store.check(client);
    final expectation = expectLater(
      checking,
      throwsA(isA<HttpRequestCancelledException>()),
    );
    await opened.future;
    store.close();
    await expectation;
    response.complete(http.Response.bytes((await release(2)).envelope, 200));
    client.close();
    final restarted = RuntimeBundleStore(root, publicKey: publicKey);
    expect((await restarted.current())?.release.version, 1);
    restarted.close();
  });
}

class _ReleaseFixture {
  final String id;
  final List<int> envelope;
  final List<int> blob;
  const _ReleaseFixture(this.id, this.envelope, this.blob);
}
