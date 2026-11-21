import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/playback_package.dart';
import 'package:music_player_app/services/bounded_http_response.dart';
import 'package:music_player_app/services/playback_script_runtime.dart';
import 'package:music_player_app/services/playback_script_worker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture fixture;
  setUp(() async {
    fixture = await _Fixture.create();
  });
  tearDown(() {
    fixture.close();
  });

  test('trusted guard never expands sparse returns or thrown values', () async {
    final result = await _bridgeProbe(r'''
const output = {
  sparseReturn:run('new Array(1000000000)'),
  sparseThrow:run('throw new Array(1000000000)'),
  sparseReply:run('__kuzaiReply(999,{value:new Array(1000000000)})'),
  textRejected:run('new Array(1000000000)',true)
};
''');
    expect(result, {
      'sparseReturn': 'O',
      'sparseThrow': 'E',
      'sparseReply': 'O',
      'textRejected': 'E',
    });
  });

  test(
    'capability text and exceptions use the captured guarded bridge',
    () async {
      final result = await _bridgeProbe(r'''
run('globalThis.KuzaiSources={getCapabilities:function(){return {revision:"local"};}}');
const valid = run('__kuzaiCapabilities()',true);
run('JSON.stringify=function(){return new Array(1000000000);}; __kuzaiGuardedEval=function(){return new Array(1000000000);};');
const afterMutation = run('__kuzaiCapabilities()',true);
run('KuzaiSources.getCapabilities=function(){throw new Array(1000000000);}');
const thrown = run('__kuzaiCapabilities()',true);
const oversized = run('"x".repeat(128*1024+1)',true);
const errorMutation = run('Object.defineProperty(Error.prototype,"toString",{value:function(){return new Array(1000000000);}})');
const output = {valid,afterMutation,thrown,oversized,errorMutation};
''');
      expect(result, {
        'valid': 'V{"revision":"local"}',
        'afterMutation': 'V{"revision":"local"}',
        'thrown': 'E',
        'oversized': 'E',
        'errorMutation': 'E',
      });
    },
  );

  test(
    'native entry is hidden and host messages have a hard text bound',
    () async {
      final result = await _bridgeProbe(r'''
const hidden = run('typeof sendMessage',true);
const oversized = run('KuzaiHost.sha256("x".repeat(1024*1024))');
const accepted = run('KuzaiHost.sha256("small")');
const output = {hidden,oversized,accepted,calls:calls.map(function(value){return {channel:value.channel,text:value.text};})};
''');
      expect(result['hidden'], 'Vundefined');
      expect(result['oversized'], 'E');
      expect(result['accepted'], 'O');
      expect(result['calls'], [
        {'channel': 'KuzaiSync', 'text': '{"kind":"sha256","text":"small"}'},
      ]);
    },
  );

  test('resolve rejection keeps sparse errors inside JavaScript', () async {
    final result = await _bridgeProbe(r'''
run('globalThis.KuzaiSources={resolve:function(){return Promise.reject(new Array(1000000000));}}');
const rejected = run('__kuzaiResolve({},"op")');
run('KuzaiSources.resolve=function(){throw new Array(1000000000);}');
const thrown = run('__kuzaiResolve({},"op")');
const output = {rejected,thrown,errors:calls.map(function(value){return JSON.parse(value.text).error;})};
''');
    expect(result['rejected'], 'O');
    expect(result['thrown'], 'O');
    expect(result['errors'], [
      {'code': 'PACKAGE_FAILED', 'message': '解析脚本执行失败'},
      {'code': 'PACKAGE_FAILED', 'message': '解析脚本执行失败'},
    ]);
  });

  test(
    'guarded reply completes promises and preserves upstream errors',
    () async {
      final result = await _bridgeProbe(r'''
run('globalThis.KuzaiSources={resolve:function(){return KuzaiHost.delay("op",0).then(function(){return {url:"https://audio.test/song.mp3"};});}}');
run('__kuzaiResolve({},"op")');
const reply = run('__kuzaiReply(1,{value:null})');
run('__kuzaiResolve({},"op")');
const rejectedReply = run('__kuzaiReply(2,{error:{code:"UPSTREAM_TIMEOUT",message:"上游超时"}})');
const output = {reply,rejectedReply,results:calls.filter(function(value){return value.channel === "KuzaiResult";}).map(function(value){return JSON.parse(value.text);})};
''');
      expect(result['reply'], 'O');
      expect(result['rejectedReply'], 'O');
      expect(result['results'], [
        {
          'value': {'url': 'https://audio.test/song.mp3'},
        },
        {
          'error': {'code': 'UPSTREAM_TIMEOUT', 'message': '上游超时'},
        },
      ]);
    },
  );

  test(
    'built-in source package stays usable through guarded execution',
    () async {
      final bundle =
          jsonDecode(
                await File(
                  'assets/playback_sources/bundle.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final script = jsonEncode(bundle['script']);
      final result = await _bridgeProbe('''
const loaded = run($script);
const text = run('__kuzaiCapabilities()',true);
run('__kuzaiResolve({platform:"unsupported",id:"1",quality:"128",source:"automatic"},"op")');
const output = {loaded,capabilities:JSON.parse(text.substring(1)),errors:calls.filter(function(value){return value.channel === "KuzaiResult";}).map(function(value){return JSON.parse(value.text).error;})};
''');
      expect(result['loaded'], 'O');
      expect(result['capabilities'], bundle['capabilities']);
      final errors = result['errors'] as List<dynamic>;
      expect(errors, hasLength(1));
      expect(errors.single['code'], 'INVALID_SONG');
    },
  );

  test(
    'native budget-unavailable platform fails without leaving a worker',
    () async {
      if (!Platform.isWindows) return;
      final runtime = PlaybackScriptRuntime();
      try {
        await expectLater(
          runtime.resolve(fixture.package, {}),
          throwsA(
            isA<PlaybackScriptException>().having(
              _code,
              'code',
              'ENGINE_UNAVAILABLE',
            ),
          ),
        );
        expect(runtime.activeTaskCount, 0);
      } finally {
        runtime.close();
      }
    },
  );

  test(
    'controlled worker validates matching local capability metadata',
    () async {
      await fixture.runtime.validate(fixture.package);
      expect(fixture.runtime.activeTaskCount, 0);
      expect(fixture.requests, isEmpty);
    },
  );

  test('controlled worker rejects mismatched script capabilities', () async {
    final package = await _package({
      'mode': 'validateMismatch',
      'options': fixture.options,
    });
    await expectLater(
      fixture.runtime.validate(package),
      throwsA(
        isA<PlaybackScriptException>().having(_code, 'code', 'PACKAGE_INVALID'),
      ),
    );
    expect(fixture.runtime.activeTaskCount, 0);
  });

  test(
    'native HTTP bridge preserves signed body text and returns bounded response',
    () async {
      final result = await fixture.runtime.resolve(fixture.package, {});
      expect(fixture.requests.single.url.host, 'music.test');
      expect(fixture.requests.single.method, 'POST');
      expect(fixture.requests.single.bodyBytes, utf8.encode('{"name":"歌曲"}'));
      expect(fixture.requests.single.headers['X-Test'], 'signature');
      expect(result['status'], 206);
      expect(result['bodyText'], '{"url":"https://audio.test/song.mp3"}');
      expect(fixture.runtime.activeTaskCount, 0);
    },
  );

  for (final entry in <String, Map<String, dynamic>>{
    'unknown origin': {'url': 'https://unapproved.test/api'},
    'userinfo': {'url': 'https://user:password@music.test/api'},
    'unregistered port': {'url': 'https://music.test:8443/api'},
    'fragment': {'url': 'https://music.test/api#secret'},
    'header injection': {
      'headers': {'X-Test': 'bad\r\nInjected: true'},
    },
    'raised response limit': {'maxBytes': 512 * 1024 + 1},
    'raised timeout': {'timeoutMs': 7001},
  }.entries) {
    test('bridge rejects ${entry.key} before connecting', () async {
      final package = await _package({
        'options': {...fixture.options, ...entry.value},
      });
      await expectLater(
        fixture.runtime.resolve(package, {}),
        throwsA(isA<PlaybackScriptException>()),
      );
      expect(fixture.requests, isEmpty);
      expect(fixture.runtime.activeTaskCount, 0);
    });
  }

  test(
    'signed origin can enable a new source port without a client change',
    () async {
      final package = await _package(
        {
          'options': {...fixture.options, 'url': 'https://music.test:8443/api'},
        },
        origins: const ['https://music.test:8443'],
      );
      await fixture.runtime.resolve(package, {});
      expect(fixture.requests.single.url.port, 8443);
      expect(fixture.runtime.activeTaskCount, 0);
    },
  );

  test('response beyond hard limit fails without retained tasks', () async {
    fixture.response = http.Response.bytes(
      List<int>.filled(512 * 1024 + 1, 65),
      200,
    );
    await expectLater(
      fixture.runtime.resolve(fixture.package, {}),
      throwsA(
        isA<PlaybackScriptException>().having(
          _code,
          'code',
          'RESPONSE_TOO_LARGE',
        ),
      ),
    );
    expect(fixture.runtime.activeTaskCount, 0);
  });

  test('cancelled race scope cannot start a late HTTP request', () async {
    final package = await _package({
      'mode': 'cancelScope',
      'options': fixture.options,
    });
    await expectLater(
      fixture.runtime.resolve(package, {}),
      throwsA(
        isA<PlaybackScriptException>().having(
          _code,
          'code',
          'RESOLVE_CANCELLED',
        ),
      ),
    );
    expect(fixture.requests, isEmpty);
  });

  test(
    'owner cancellation waits for worker cleanup and ignores late HTTP response',
    () async {
      fixture.gate = Completer<http.Response>();
      final cancel = Completer<void>();
      final pending = fixture.runtime.resolve(
        fixture.package,
        {},
        cancelSignal: cancel.future,
      );
      final assertion = expectLater(
        pending,
        throwsA(isA<HttpRequestCancelledException>()),
      );
      await fixture.entered.future;
      cancel.complete();
      await assertion;
      expect(fixture.runtime.activeTaskCount, 0);
      fixture.gate!.complete(fixture.response);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.runtime.activeTaskCount, 0);
    },
  );

  test('closure cancels in-flight HTTP and prevents new workers', () async {
    fixture.gate = Completer<http.Response>();
    final pending = fixture.runtime.resolve(fixture.package, {});
    final assertion = expectLater(
      pending,
      throwsA(isA<HttpRequestCancelledException>()),
    );
    await fixture.entered.future;
    fixture.runtime.close();
    await assertion;
    await expectLater(
      fixture.runtime.resolve(fixture.package, {}),
      throwsA(isA<HttpRequestCancelledException>()),
    );
    expect(fixture.runtime.activeTaskCount, 0);
  });

  test('four active workers refuse extra work without a wait queue', () async {
    fixture.gate = Completer<http.Response>();
    final requests = <Future<Map<String, dynamic>>>[];
    for (var index = 0; index < 4; index++) {
      requests.add(fixture.runtime.resolve(fixture.package, {}));
    }
    await expectLater(
      fixture.runtime.resolve(fixture.package, {}),
      throwsA(
        isA<PlaybackScriptException>().having(_code, 'code', 'REQUEST_BUSY'),
      ),
    );
    expect(fixture.runtime.activeTaskCount, 4);
    await fixture.waitForRequests(4);
    fixture.gate!.complete(fixture.response);
    await Future.wait(requests);
    expect(fixture.runtime.activeTaskCount, 0);
  });

  test('operation deadline cancels native host timers and worker', () async {
    final runtime = PlaybackScriptRuntime(
      workerEntry: _controlledWorker,
      operationTimeout: const Duration(milliseconds: 100),
    );
    final package = await _package({
      'mode': 'hold',
      'options': fixture.options,
    });
    try {
      await expectLater(
        runtime.resolve(package, {}),
        throwsA(
          isA<PlaybackScriptException>().having(
            _code,
            'code',
            'RESOLVE_TIMEOUT',
          ),
        ),
      );
      expect(runtime.activeTaskCount, 0);
    } finally {
      runtime.close();
    }
  });

  test(
    'repeated controlled parsing leaves no workers or cancellation queue',
    () async {
      for (var index = 0; index < 50; index++) {
        await fixture.runtime.resolve(fixture.package, {});
        expect(fixture.runtime.activeTaskCount, 0);
      }
      expect(fixture.requests.length, 50);
    },
  );
}

String _code(PlaybackScriptException error) => error.code;

// 本机没有可用Android引擎，直接用生产桥接原文检验对象/异常不会跨FFI。
Future<Map<String, dynamic>> _bridgeProbe(String probe) async {
  final process = await Process.start('node', ['--input-type=module']);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  try {
    process.stdin.write('''
import vm from 'node:vm';
const calls = [];
const context = vm.createContext({sendMessage:function(channel,text){calls.push({channel,text}); return 'digest';}},{microtaskMode:'afterEvaluate'});
vm.runInContext(${jsonEncode(playbackScriptBootstrap)},context,{timeout:1000});
function run(code,expectText=false){return vm.runInContext('__kuzaiGuardedEval('+JSON.stringify(code)+','+expectText+')',context,{timeout:1000});}
$probe
process.stdout.write(JSON.stringify(output));
''');
    await process.stdin.close();
    final exitCode = await process.exitCode.timeout(const Duration(seconds: 5));
    expect(exitCode, 0, reason: await errors);
    return jsonDecode(await output) as Map<String, dynamic>;
  } finally {
    process.kill();
  }
}

class _Fixture {
  late final PlaybackPackage package;
  late final PlaybackScriptRuntime runtime;
  final requests = <http.Request>[];
  final entered = Completer<void>();
  Completer<http.Response>? gate;
  http.Response response = http.Response(
    '{"url":"https://audio.test/song.mp3"}',
    206,
  );
  final Map<String, dynamic> options = {
    'url': 'https://music.test/api',
    'method': 'POST',
    'headers': {'X-Test': 'signature'},
    'bodyText': '{"name":"歌曲"}',
  };

  static Future<_Fixture> create() async {
    final fixture = _Fixture();
    fixture.package = await _package({'options': fixture.options});
    fixture.runtime = PlaybackScriptRuntime(
      client: MockClient(fixture.request),
      workerEntry: _controlledWorker,
    );
    return fixture;
  }

  Future<http.Response> request(http.Request request) async {
    requests.add(request);
    if (!entered.isCompleted) entered.complete();
    return gate == null ? response : gate!.future;
  }

  Future<void> waitForRequests(int count) async {
    final stop = DateTime.now().add(const Duration(seconds: 2));
    while (requests.length < count && DateTime.now().isBefore(stop)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(requests.length, count);
  }

  void close() {
    runtime.close();
    if (gate != null && !gate!.isCompleted) gate!.complete(response);
  }
}

// 这里只替换不可在本机执行的native库，真实Host校验、isolate和清理仍完整运行。
void _controlledWorker(Map<String, dynamic> arguments) {
  final worker = _ControlledWorker(arguments);
  worker.start();
}

class _ControlledWorker {
  final Map<String, dynamic> arguments;
  final port = ReceivePort();
  late final SendPort output = arguments['output'] as SendPort;
  late final Map<String, dynamic> config =
      jsonDecode(arguments['script'] as String) as Map<String, dynamic>;
  _ControlledWorker(this.arguments);

  void start() {
    output.send({'type': 'ready', 'port': port.sendPort});
    if (arguments['mode'] == 'validate') {
      final capabilities = Map<String, dynamic>.from(_capabilities);
      if (config['mode'] == 'validateMismatch') {
        capabilities['revision'] = 'wrong';
      }
      finish({
        'type': 'result',
        'value': {'capabilities': capabilities},
      });
      return;
    }
    port.listen(onMessage);
    final scope = '${arguments['operationId']}:race1';
    if (config['mode'] == 'cancelScope') {
      output.send({
        'type': 'host',
        'command': {'kind': 'cancel', 'scope': scope},
      });
    }
    output.send({
      'type': 'host',
      'command': config['mode'] == 'hold'
          ? {
              'kind': 'delay',
              'scope': scope,
              'requestId': 1,
              'milliseconds': 10000,
            }
          : {
              'kind': 'request',
              'scope': scope,
              'requestId': 1,
              'options': config['options'],
            },
    });
  }

  void onMessage(dynamic raw) {
    if (raw is! Map) return;
    if (raw['type'] == 'cancel') {
      finish({'type': 'error', 'code': 'RESOLVE_CANCELLED', 'message': '已取消'});
    } else if (raw['type'] == 'hostResponse') {
      final error = raw['error'];
      if (error is Map) {
        finish({'type': 'error', ...error});
      } else {
        finish({'type': 'result', 'value': raw['value']});
      }
    }
  }

  void finish(Map<String, dynamic> value) {
    port.close();
    output.send(value);
  }
}

const _capabilities = <String, dynamic>{
  'protocolVersion': 1,
  'revision': 'test-local',
  'sources': [
    {
      'id': 'test_source',
      'name': '测试源',
      'description': '受控测试',
      'platforms': ['qq'],
      'credentials': [],
    },
  ],
};

Future<PlaybackPackage> _package(
  Map<String, dynamic> configuration, {
  List<String> origins = const ['https://music.test'],
}) async {
  final algorithm = Ed25519();
  final key = await algorithm.newKeyPairFromSeed(List<int>.generate(32, _seed));
  final publicKey = base64Encode((await key.extractPublicKey()).bytes);
  final bytes = utf8.encode(
    jsonEncode({
      'packageFormat': 1,
      'packageVersion': 1,
      'minimumBridgeVersion': 1,
      'capabilities': _capabilities,
      'allowedOrigins': origins,
      'script': jsonEncode(configuration),
    }),
  );
  final payload = utf8.encode(
    jsonEncode({
      'packageFormat': 1,
      'packageVersion': 1,
      'minimumBridgeVersion': 1,
      'packagePath': 'packages/p000001.json',
      'sha256': sha256.convert(bytes).toString(),
      'bytes': bytes.length,
    }),
  );
  final signature = await algorithm.sign(payload, keyPair: key);
  final envelope = utf8.encode(
    jsonEncode({
      'payloadBase64': base64Encode(payload),
      'signatureBase64': base64Encode(signature.bytes),
    }),
  );
  return PlaybackPackage.verify(envelope, bytes, publicKey: publicKey);
}

int _seed(int index) => index + 1;
