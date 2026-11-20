import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music_player_app/services/bounded_http_response.dart';
import 'package:music_player_app/services/runtime_http_client.dart';

// 以受控传输检查目录安全边界和取消行为，不依赖公网状态。
// SHIXIAOYANG，2026/11/20。
const _id = '0123456789abcdef0123456789abcdef';

Map<String, dynamic> _plan() => {
  'id': _id,
  'url': 'https://u.y.qq.com/cgi-bin/musicu.fcg',
  'method': 'POST',
  'headers': {'Referer': 'https://y.qq.com/'},
  'body': {'query': '海阔天空'},
};

http.Response _response(Map<String, dynamic> data) {
  return http.Response.bytes(
    utf8.encode(jsonEncode({'ok': true, ...data})),
    200,
  );
}

class _TrackingClient extends MockClient {
  bool closed = false;
  // 显式转发处理器，便于观察测试客户端的父构造过程。
  // ignore: use_super_parameters
  _TrackingClient(Future<http.Response> Function(http.Request) handler)
    : super(handler);

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  test('设备只传输受限目录请求，中文正文与大响应完整回传服务器', _roundtrip);
  test('目录拒绝非法地址、请求头和超大正文且不打开连接', _rejectsInvalidPlan);
  test('公共目录响应超出 512 KB 时释放连接且不回传不完整数据', _rejectsOversizedResponse);
  test('目录传输中关闭页面会释放连接并丢弃迟到响应', _ownerCancellation);
  test('目录传输中取消操作会释放连接并丢弃迟到响应', _operationCancellation);
  test('连续目录补偿最多执行三次，每次都关闭独立传输', _boundsSteps);
  test('代理输入先校验再保存，无效地址不会覆盖已有设置', _validatesProxy);
}

Future<void> _roundtrip() async {
  final upstream = {'name': '海阔天空', 'padding': '歌' * 50000};
  final public = _TrackingClient((request) async {
    expect(request.followRedirects, isFalse);
    expect(jsonDecode(utf8.decode(request.bodyBytes)), {'query': '海阔天空'});
    expect(request.headers.containsKey('Authorization'), isFalse);
    expect(request.headers.containsKey('Cookie'), isFalse);
    return http.Response.bytes(utf8.encode(jsonEncode(upstream)), 200);
  });
  var completed = false;
  final server = MockClient((request) async {
    if (request.url.path == '/api/search') {
      return _response({'clientRequest': _plan()});
    }
    final receipt = jsonDecode(request.body) as Map;
    expect(request.url.path, '/api/catalog_result');
    expect(receipt['id'], _id);
    expect(receipt['status'], 200);
    expect(
      jsonDecode(utf8.decode(base64Decode(receipt['bodyBase64']))),
      upstream,
    );
    completed = true;
    return _response({
      'songs': [
        {'id': 'mid1'},
      ],
    });
  });
  final client = RuntimeHttpClient(
    base: Uri.parse('https://runtime.test/'),
    client: server,
    publicCatalogClientFactory: () => public,
  );
  try {
    final result = await client.api('search', {'keyword': '海阔天空'});
    expect(result['songs'], [
      {'id': 'mid1'},
    ]);
    expect(completed, isTrue);
    expect(public.closed, isTrue);
  } finally {
    client.close();
  }
}

Future<void> _rejectsInvalidPlan() async {
  final invalid = <Map<String, dynamic>>[];
  for (final url in [
    'file:///private/password',
    'https://y.qq.com.evil.test/catalog',
    'https://user:secret@y.qq.com/catalog',
    'https://127.0.0.1/catalog',
    'https://y.qq.com:8443/catalog',
    'https://y.qq.com/catalog#fragment',
  ]) {
    invalid.add({..._plan(), 'url': url});
  }
  for (final headers in [
    {'Authorization': 'secret'},
    {'Cookie': 'secret'},
    {'Referer': 'https://y.qq.com/\r\nInjected: yes'},
  ]) {
    invalid.add({..._plan(), 'headers': headers});
  }
  invalid.add({..._plan(), 'method': 'DELETE'});
  invalid.add({..._plan(), 'method': 'GET'});
  invalid.add({..._plan(), 'id': 'not-a-request-id'});
  invalid.add({
    ..._plan(),
    'body': {'query': '歌' * 64000},
  });
  for (final plan in invalid) {
    var opened = false;
    final server = MockClient((request) async {
      return _response({'clientRequest': plan});
    });
    http.Client publicFactory() {
      opened = true;
      return MockClient((request) async => http.Response('{}', 200));
    }

    final client = RuntimeHttpClient(
      base: Uri.parse('https://runtime.test/'),
      client: server,
      publicCatalogClientFactory: publicFactory,
    );
    try {
      await expectLater(client.api('search', {}), throwsA(isA<Exception>()));
      expect(opened, isFalse);
    } finally {
      client.close();
    }
  }
}

Future<void> _rejectsOversizedResponse() async {
  var receipts = 0;
  final server = MockClient((request) async {
    if (request.url.path == '/api/catalog_result') receipts++;
    return _response({'clientRequest': _plan()});
  });
  final public = _TrackingClient((request) async {
    return http.Response.bytes(List<int>.filled(512 * 1024 + 1, 65), 200);
  });
  final client = RuntimeHttpClient(
    base: Uri.parse('https://runtime.test/'),
    client: server,
    publicCatalogClientFactory: () => public,
  );
  try {
    await expectLater(
      client.api('search', {}),
      throwsA(isA<HttpResponseTooLargeException>()),
    );
    expect(receipts, 0);
    expect(public.closed, isTrue);
  } finally {
    client.close();
  }
}

Future<void> _ownerCancellation() => _cancelsDirectory(true);
Future<void> _operationCancellation() => _cancelsDirectory(false);

Future<void> _cancelsDirectory(bool ownerClosed) async {
  final response = Completer<http.Response>();
  final started = Completer<void>();
  final cancellation = Completer<void>();
  var receipts = 0;
  final public = _TrackingClient((request) {
    started.complete();
    return response.future;
  });
  final server = MockClient((request) async {
    if (request.url.path == '/api/catalog_result') receipts++;
    return _response({'clientRequest': _plan()});
  });
  final client = RuntimeHttpClient(
    base: Uri.parse('https://runtime.test/'),
    client: server,
    publicCatalogClientFactory: () => public,
  );
  final operation = client.api('search', {}, cancelSignal: cancellation.future);
  final expectation = expectLater(
    operation,
    throwsA(isA<HttpRequestCancelledException>()),
  );
  try {
    await started.future;
    if (ownerClosed) {
      client.close();
    } else {
      cancellation.complete();
    }
    await expectation;
    expect(public.closed, isTrue);
    expect(receipts, 0);
    response.complete(http.Response('{}', 200));
    await Future<void>.delayed(Duration.zero);
  } finally {
    client.close();
    if (!response.isCompleted) response.complete(http.Response('{}', 200));
  }
}

Future<void> _boundsSteps() async {
  final transports = <_TrackingClient>[];
  http.Client publicFactory() {
    final client = _TrackingClient((request) async => http.Response('{}', 200));
    transports.add(client);
    return client;
  }

  final server = MockClient((request) async {
    return _response({'clientRequest': _plan()});
  });
  final client = RuntimeHttpClient(
    base: Uri.parse('https://runtime.test/'),
    client: server,
    publicCatalogClientFactory: publicFactory,
  );
  try {
    await expectLater(
      client.api('search', {}),
      throwsA(
        isA<RuntimeException>().having(
          (error) => error.code,
          'code',
          'CATALOG_STEPS_EXCEEDED',
        ),
      ),
    );
    expect(transports, hasLength(3));
    expect(transports.every((transport) => transport.closed), isTrue);
  } finally {
    client.close();
  }
}

Future<void> _validatesProxy() async {
  await RuntimeHttpClient.setProxy('http://127.0.0.1:10808');
  for (final value in [
    'user:secret@host:80',
    'host:0',
    'host:65536',
    'host:80/path',
  ]) {
    await expectLater(RuntimeHttpClient.setProxy(value), throwsFormatException);
    expect(await RuntimeHttpClient.proxy(), '127.0.0.1:10808');
  }
  await RuntimeHttpClient.setProxy('');
  expect(await RuntimeHttpClient.proxy(), '');
}
