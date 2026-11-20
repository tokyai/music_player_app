import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music_player_app/services/runtime_http_client.dart';
import 'package:music_player_app/services/runtime_bundle_store.dart';

// 明确开启时才联网；报告不包含播放 URL、签名或凭据。SHIXIAOYANG，2026/11/19。
const enabled = bool.fromEnvironment('RUN_RUNTIME_AUDIT');
const fixtures = {
  'qq': {
    'platform': 'qq',
    'id': '001yS0N33yPm1B',
    'name': '海阔天空',
    'artist': 'BEYOND',
    'album': '乐与怒',
    'albumId': '002qcJuX3lO3EZ',
    'duration': 324,
  },
  '163': {
    'platform': '163',
    'id': '347230',
    'name': '海阔天空',
    'artist': 'Beyond',
    'album': '海阔天空',
    'duration': 326,
  },
  'kugou': {
    'platform': 'kugou',
    'id': 'c41e80a18d1448fa47086372999c7f43',
    'name': '海阔天空',
    'artist': 'BEYOND',
    'album': '乐与怒',
    'albumId': '973001',
    'duration': 324,
  },
};
void main() {
  const proxy = String.fromEnvironment('RUNTIME_AUDIT_HTTP_PROXY');
  if (enabled) {
    SharedPreferences.setMockInitialValues({'runtime_http_proxy_v1': proxy});
    if (proxy.isNotEmpty) HttpOverrides.global = _AuditProxyOverrides(proxy);
  }
  final report = <Map<String, dynamic>>[];
  test('音频响应头超时只返回一次错误，不留下未监听的 Future', _headerTimeout);
  test('音频服务器忽略 Range 时仍只保留 4096 字节', _boundsAudioPrefix);
  test('部署地址的 TLS、签名业务包和离线缓存可用', () async {
    final client = RuntimeHttpClient();
    final directory = await Directory.systemTemp.createTemp(
      'runtime-live-audit-',
    );
    final store = RuntimeBundleStore(directory);
    try {
      final release = await store.check(client);
      expect(release, isNotNull);
      expect(await release!.entry.exists(), isTrue);
      expect((await store.current())?.release.id, release.release.id);
      report.add({
        'kind': 'runtime',
        'version': release.release.version,
        'signed': true,
        'offlineCache': true,
      });
    } finally {
      store.close();
      client.close();
      await directory.delete(recursive: true);
    }
  }, skip: !enabled);

  test('真实发布包从上一版本升级，回滚后不重复安装同一版本', () async {
    final client = RuntimeHttpClient();
    final directory = await Directory.systemTemp.createTemp(
      'runtime-live-update-',
    );
    final store = RuntimeBundleStore(directory);
    try {
      const previous = 'tmp/runtime-publish-r000003';
      final current = await store.seed(
        await File('$previous/manifest.json').readAsBytes(),
        await File('$previous/releases/r000003/bundle.json').readAsBytes(),
      );
      expect(current!.release.version, 3);
      final upgraded = await store.check(client);
      expect(upgraded!.release.version, greaterThan(current.release.version));
      final rolledBack = await store.rollback(upgraded.release.id);
      expect(rolledBack!.release.version, current.release.version);
      final checkedAgain = await store.check(client);
      expect(checkedAgain!.release.version, current.release.version);
      report.add({
        'kind': 'runtime_update',
        'from': current.release.version,
        'to': upgraded.release.version,
        'rollback': rolledBack.release.version,
        'repeatedBadVersionSkipped': true,
      });
    } finally {
      store.close();
      client.close();
      await directory.delete(recursive: true);
    }
  }, skip: !enabled);

  for (final platform in fixtures.keys) {
    test(
      '服务器目录 $platform 搜索、歌词和发现页',
      () async {
        final client = RuntimeHttpClient();
        try {
          final search = await client.api('search', {
            'platform': platform,
            'keyword': '海阔天空 Beyond',
            'limit': 20,
          });
          final songs = search['songs'] as List;
          expect(songs, isNotEmpty);
          final lyrics = await client.api('lyrics', {
            'platform': platform,
            'id': fixtures[platform]!['id'],
          });
          final discover = await client.api('discover', {
            'platform': platform,
            'limit': 10,
          });
          final records = discover['playlists'] ?? discover['songs'];
          expect(records, isA<List>());
          expect(records, isNotEmpty);
          report.add({
            'kind': 'catalog',
            'platform': platform,
            'songs': songs.length,
            'lyrics': (lyrics['lyrics'] as Map)['original'] != null,
            'discoverCount': (records as List).length,
          });
        } catch (error) {
          report.add({
            'kind': 'catalog',
            'platform': platform,
            'ok': false,
            'error': error.toString(),
          });
          rethrow;
        } finally {
          client.close();
        }
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      '服务器歌单 $platform 搜索与分页打开',
      () async {
        final client = RuntimeHttpClient();
        try {
          final result = await client.api('search', {
            'platform': platform,
            'keyword': 'Beyond',
            'kind': 'playlists',
            'limit': 5,
          });
          final records = result['playlists'] as List;
          expect(records, isNotEmpty);
          final record = Map<String, dynamic>.from(records.first as Map);
          final first = await client.api('playlist', {
            'platform': platform,
            'id': record['id'],
            'page': 1,
            'limit': 10,
          });
          final songs = first['songs'] as List;
          expect(songs, isNotEmpty);
          final total = first['total'] as num;
          var secondCount = 0;
          if (total > 10) {
            final second = await client.api('playlist', {
              'platform': platform,
              'id': record['id'],
              'page': 2,
              'limit': 10,
            });
            secondCount = (second['songs'] as List).length;
            expect(secondCount, greaterThan(0));
          }
          report.add({
            'kind': 'playlist',
            'platform': platform,
            'ok': true,
            'firstPage': songs.length,
            'secondPage': secondCount,
            'total': total,
          });
        } catch (error) {
          report.add({
            'kind': 'playlist',
            'platform': platform,
            'ok': false,
            'error': error.toString(),
          });
          rethrow;
        } finally {
          client.close();
        }
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      '服务器 MV $platform 当前歌曲的视频能力',
      () async {
        final client = RuntimeHttpClient();
        try {
          final result = await client.api('mv', fixtures[platform]!);
          final url = Uri.parse(result['url'] as String);
          expect(['http', 'https'], contains(url.scheme));
          report.add({'kind': 'mv', 'platform': platform, 'ok': true});
        } catch (error) {
          // 歌曲未收录 MV 与线路故障都写入报告，不将外部曲库状态固定为断言。
          report.add({
            'kind': 'mv',
            'platform': platform,
            'ok': false,
            'error': error.toString(),
          });
        } finally {
          client.close();
        }
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  for (final source in [
    'qing_music',
    'xinghai',
    'hyw',
    'gd_studio',
    'chksz',
    'automatic',
  ]) {
    for (final platform in fixtures.keys) {
      test(
        '服务器真实音源 $source / $platform',
        () async {
          final client = RuntimeHttpClient();
          final stopwatch = Stopwatch()..start();
          try {
            final result = await _readPlayback(client, source, platform);
            report.add({
              'kind': 'source',
              'source': source,
              'platform': platform,
              ...result,
              'ok': true,
              'resolveAndReadMs': stopwatch.elapsedMilliseconds,
            });
          } catch (error) {
            report.add({
              'kind': 'source',
              'source': source,
              'platform': platform,
              'ok': false,
              'elapsedMs': stopwatch.elapsedMilliseconds,
              'error': error.toString().replaceAll(
                RegExp(r'https?://\S+'),
                '[url]',
              ),
            });
            // 在线状态和个人授权不能写成固定断言，报告必须保留本次实际结果。
          } finally {
            client.close();
          }
        },
        skip: !enabled,
        timeout: const Timeout(Duration(seconds: 110)),
      );
    }
  }
  tearDownAll(() async {
    if (!enabled) return;
    // 定向复验写入独立报告，保留完整渠道矩阵和先前失败样本。
    const reportPath = String.fromEnvironment(
      'RUNTIME_AUDIT_REPORT',
      defaultValue: 'tmp/hot_runtime_20261119/runtime-server-audit.json',
    );
    final file = File(reportPath);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
  });
}

class _AuditProxyOverrides extends HttpOverrides {
  final String address;
  _AuditProxyOverrides(this.address);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)..findProxy = (_) => 'PROXY $address';
  }
}

Future<Map<String, dynamic>> _readPlayback(
  RuntimeHttpClient client,
  String source,
  String platform,
) async {
  final excluded = <String>[];
  final attempts = <Map<String, dynamic>>[];
  final maximum = source == 'automatic' ? 3 : 1;
  for (var index = 0; index < maximum; index++) {
    final reply = await client.api('resolve', {
      'song': {
        ...fixtures[platform]!,
        'source': source,
        'quality': platform == '163' ? 'exhigh' : '320k',
        'excludedSources': excluded,
      },
    });
    final data = Map<String, dynamic>.from(reply['result'] as Map);
    final provider = data['providerId'] as String;
    try {
      final bytes = await _audioPrefix(
        data['url'] as String,
        Map<String, String>.from(data['playbackHeaders'] as Map? ?? {}),
      );
      final format = _format(bytes);
      if (format == 'unknown') throw const FormatException('未读到可识别的音频');
      attempts.add({'source': provider, 'ok': true});
      return {
        'resolvedSource': provider,
        'audioBytes': bytes.length,
        'format': format,
        'recovered': excluded.isNotEmpty,
        'attempts': attempts,
      };
    } catch (error) {
      attempts.add({
        'source': provider,
        'ok': false,
        'error': error.toString().replaceAll(RegExp(r'https?://\S+'), '[url]'),
      });
      if (source != 'automatic' || index + 1 == maximum) rethrow;
      // 模拟原生播放器的恢复协议：排除地址无法读取的实际源，再请求自动备用。
      excluded.add(provider);
    }
  }
  throw StateError('音频审计未返回结果');
}

Future<void> _headerTimeout() async {
  Future<void> check() async {
    await expectLater(
      _audioPrefix(
        'https://audio.test/slow',
        {},
        timeout: const Duration(milliseconds: 10),
      ),
      throwsA(isA<TimeoutException>()),
    );
  }

  http.Client factory() {
    return MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      return http.Response('{}', 200);
    });
  }

  await http.runWithClient(check, factory);
}

Future<void> _boundsAudioPrefix() async {
  Future<void> check() async {
    final bytes = await _audioPrefix('https://audio.test/song', {});
    expect(bytes, hasLength(4096));
  }

  http.Client factory() {
    return MockClient((request) async {
      return http.Response.bytes(List<int>.filled(8192, 65), 200);
    });
  }

  await http.runWithClient(check, factory);
}

Future<Uint8List> _audioPrefix(
  String url,
  Map<String, String> headers, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = http.Client();
  StreamSubscription<List<int>>? subscription;
  final result = Completer<Uint8List>();
  final bytes = BytesBuilder(copy: false);
  var length = 0;
  var timedOut = false;
  final timer = Timer(timeout, () {
    timedOut = true;
    // 响应头尚未返回时还没有 await result，不能提前产生未监听的 Future 错误。
    if (subscription != null && !result.isCompleted) {
      result.completeError(TimeoutException('音频读取超时'));
    }
    client.close();
  });
  try {
    final response = await client.send(
      http.Request('GET', Uri.parse(url))
        ..headers.addAll({...headers, 'Range': 'bytes=0-4095'}),
    );
    if (timedOut) throw TimeoutException('音频读取超时');
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException('音频 HTTP ${response.statusCode}');
    }
    subscription = response.stream.listen(
      (chunk) {
        if (result.isCompleted) return;
        final take = (4096 - length).clamp(0, chunk.length);
        bytes.add(chunk.sublist(0, take));
        length += take;
        if (length >= 4096) result.complete(bytes.takeBytes());
      },
      onError: (Object error) {
        if (!result.isCompleted) result.completeError(error);
      },
      onDone: () {
        if (!result.isCompleted) result.complete(bytes.takeBytes());
      },
    );
    return await result.future;
  } catch (error) {
    if (timedOut) throw TimeoutException('音频读取超时');
    rethrow;
  } finally {
    timer.cancel();
    await subscription?.cancel();
    client.close();
  }
}

String _format(Uint8List bytes) {
  if (bytes.length < 4) return 'unknown';
  if (ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'fLaC') {
    return 'flac';
  }
  if (ascii.decode(bytes.sublist(0, 3), allowInvalid: true) == 'ID3' ||
      (bytes[0] == 255 && (bytes[1] & 224) == 224)) {
    return 'mp3';
  }
  if (bytes.length >= 8 &&
      ascii.decode(bytes.sublist(4, 8), allowInvalid: true) == 'ftyp') {
    return 'm4a';
  }
  return 'unknown';
}
