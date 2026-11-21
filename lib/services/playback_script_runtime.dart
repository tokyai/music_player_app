import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../models/playback_package.dart';
import '../models/remote_playback.dart';
import 'bounded_http_response.dart';
import 'playback_script_host.dart';
import 'playback_script_worker.dart';

/// 测试可以替换原生worker入口，不替换网络上限或生命周期处理。
typedef PlaybackScriptWorkerEntry =
    void Function(Map<String, dynamic> arguments);

/// 本地解析的隔离运行时，SHIXIAOYANG，2026/11/21。
///
/// 原生JS只在worker中执行，主侧只处理有界HTTP与结果；不访问更新服务器。
class PlaybackScriptRuntime {
  final http.Client _client;
  final PlaybackScriptWorkerEntry _workerEntry;
  final Duration _operationTimeout;
  final Set<_ScriptTask> _tasks = {};
  int _nextOperation = 1;
  bool _closed = false;

  PlaybackScriptRuntime({
    http.Client? client,
    PlaybackScriptWorkerEntry workerEntry = playbackScriptWorkerMain,
    Duration operationTimeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client(),
       _workerEntry = workerEntry,
       _operationTimeout = operationTimeout {
    if (operationTimeout <= Duration.zero ||
        operationTimeout > const Duration(seconds: 20)) {
      throw ArgumentError.value(
        operationTimeout,
        'operationTimeout',
        '解析总时限必须不超过20秒',
      );
    }
  }

  /// 进行中worker数量，用于确认结束、取消和反复解析后的资源归零。
  int get activeTaskCount => _tasks.length;

  /// 在隔离引擎试加载候选包；失败的包不能成为本地当前版本。
  Future<void> validate(PlaybackPackage package) async {
    final value = await _run(package, const {}, mode: 'validate');
    final raw = value['capabilities'];
    if (raw is! Map) {
      throw const PlaybackScriptException('PACKAGE_INVALID', '解析包没有返回有效能力');
    }
    try {
      final actual = PlaybackSourceCatalog.fromJson(
        Map<String, dynamic>.from(raw),
      );
      if (jsonEncode(actual.toJson()) !=
          jsonEncode(package.capabilities.toJson())) {
        throw const FormatException('解析包代码与能力不一致');
      }
    } on FormatException {
      throw const PlaybackScriptException('PACKAGE_INVALID', '解析包代码与能力不一致');
    }
  }

  /// 使用捕获的包版本解析歌曲；更新包不能改变已经开始的这次解析。
  Future<Map<String, dynamic>> resolve(
    PlaybackPackage package,
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
  }) async {
    return _run(package, input, cancelSignal: cancelSignal, mode: 'resolve');
  }

  Future<Map<String, dynamic>> _run(
    PlaybackPackage package,
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    required String mode,
  }) {
    if (_closed) return Future.error(const HttpRequestCancelledException());
    if (_tasks.length >= 4) {
      return Future.error(
        const PlaybackScriptException('REQUEST_BUSY', '本地解析繁忙，请稍后重试'),
      );
    }
    // 输入只传JSON数据，不向隔离线程泄漏播放器、平台句柄或可执行回调。
    final text = jsonEncode(input);
    if (utf8.encode(text).length > 64 * 1024) {
      return Future.error(
        const PlaybackScriptException('INVALID_REQUEST', '解析请求超过上限'),
      );
    }
    final operation = 'kz${_nextOperation++}';
    final task = _ScriptTask(this, operation, package.allowedOrigins, _client);
    _tasks.add(task);
    task.listen(cancelSignal);
    unawaited(
      _spawn(task, {
        'output': task.messages.sendPort,
        'operationId': operation,
        'mode': mode,
        'script': package.script,
        'input': text,
      }),
    );
    return task.result.future;
  }

  Future<void> _spawn(_ScriptTask task, Map<String, dynamic> arguments) async {
    try {
      final isolate = await Isolate.spawn(
        _workerEntry,
        arguments,
        onError: task.errors.sendPort,
        onExit: task.exits.sendPort,
        errorsAreFatal: true,
        debugName: 'playback-script-${task.operation}',
      );
      task.attach(isolate);
    } catch (_) {
      task.fail(
        const PlaybackScriptException('ENGINE_UNAVAILABLE', '本地脚本线程启动失败'),
      );
    }
  }

  void _remove(_ScriptTask task) => _tasks.remove(task);

  /// 取消所有进行中操作并关闭网络；worker确认释放后才结束它的任务。
  void close() {
    if (_closed) return;
    _closed = true;
    for (final task in _tasks.toList()) {
      task.cancel();
    }
    _client.close();
  }
}

class _ScriptTask {
  final PlaybackScriptRuntime owner;
  final String operation;
  final ReceivePort messages = ReceivePort();
  final ReceivePort errors = ReceivePort();
  final ReceivePort exits = ReceivePort();
  final Completer<Map<String, dynamic>> result =
      Completer<Map<String, dynamic>>();
  late final PlaybackScriptHost host;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Isolate? _isolate;
  SendPort? _commands;
  Timer? _deadline;
  Timer? _grace;
  Timer? _exitCheck;
  bool _cancelled = false;
  bool _timedOut = false;
  bool _done = false;

  _ScriptTask(
    this.owner,
    this.operation,
    List<String> origins,
    http.Client client,
  ) {
    host = PlaybackScriptHost(
      operationId: operation,
      allowedOrigins: origins,
      client: client,
      send: _send,
    );
  }

  void listen(Future<void>? cancelSignal) {
    _subscriptions.add(messages.listen(_onMessage));
    _subscriptions.add(errors.listen(_onError));
    _subscriptions.add(exits.listen(_onExit));
    if (cancelSignal != null) {
      _subscriptions.add(
        cancelSignal.asStream().listen(
          _onCancellation,
          onError: _onCancellationError,
        ),
      );
    }
    _deadline = Timer(owner._operationTimeout, _timeout);
  }

  void attach(Isolate isolate) {
    _isolate = isolate;
    if (_done) isolate.kill(priority: Isolate.immediate);
  }

  void _send(Map<String, dynamic> message) {
    if (!_done && !_cancelled) _commands?.send(message);
  }

  void _onMessage(dynamic raw) {
    if (_done || raw is! Map) return;
    final type = raw['type'];
    if (type == 'ready' && raw['port'] is SendPort) {
      _commands = raw['port'] as SendPort;
      if (_cancelled) _commands!.send({'type': 'cancel'});
      return;
    }
    if (type == 'host' && raw['command'] is Map) {
      if (!_cancelled) {
        host.handle(Map<String, dynamic>.from(raw['command'] as Map));
      }
      return;
    }
    // Worker仅在native资源释放完成后发送result/error，主侧可以安全收尾。
    if (_cancelled) {
      if (type == 'result' || type == 'error') _finishCancellation();
      return;
    }
    if (type == 'result' && raw['value'] is Map) {
      final value = Map<String, dynamic>.from(raw['value'] as Map);
      _cleanup();
      result.complete(value);
    } else if (type == 'error') {
      final code = raw['code'];
      final message = raw['message'];
      fail(
        PlaybackScriptException(
          code is String ? code : 'ENGINE_FAILED',
          message is String ? message : '本地解析失败',
        ),
      );
    }
  }

  void _onError(dynamic _) {
    // 原生或Dart错误只产生有限的业务提示，不能把URL、输入或stack记录到日志。
    fail(const PlaybackScriptException('ENGINE_EXIT', '本地解析线程异常结束'));
  }

  void _onExit(dynamic _) {
    if (!_done) {
      _exitCheck = Timer(const Duration(milliseconds: 20), _checkExit);
    }
  }

  void _checkExit() {
    if (_cancelled) {
      _finishCancellation();
    } else {
      fail(const PlaybackScriptException('ENGINE_EXIT', '本地解析线程未返回结果'));
    }
  }

  void _onCancellation(void _) => cancel();
  void _onCancellationError(Object _) => cancel();
  void _timeout() {
    _timedOut = true;
    cancel();
  }

  void cancel() {
    if (_done || _cancelled) return;
    _cancelled = true;
    host.close();
    _commands?.send({'type': 'cancel'});
    // 正常取消等待worker释放确认；异常无响应时才使用最终隔离线程退出边界。
    _grace = Timer(const Duration(seconds: 2), _finishCancellation);
  }

  void _finishCancellation() {
    if (_done) return;
    _cleanup();
    if (_timedOut) {
      result.completeError(
        const PlaybackScriptException('RESOLVE_TIMEOUT', '本地解析超时'),
      );
    } else {
      result.completeError(const HttpRequestCancelledException());
    }
  }

  void fail(Object error) {
    if (_done) return;
    if (_cancelled) {
      _finishCancellation();
      return;
    }
    _cleanup();
    result.completeError(error);
  }

  void _cleanup() {
    if (_done) return;
    _done = true;
    host.close();
    _deadline?.cancel();
    _grace?.cancel();
    _exitCheck?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    messages.close();
    errors.close();
    exits.close();
    _isolate?.kill(priority: Isolate.immediate);
    owner._remove(this);
  }
}

/// 可定位的脚本错误；ENGINE/PACKAGE错误与上游业务失败分别处理。
class PlaybackScriptException implements Exception {
  final String code;
  final String message;
  const PlaybackScriptException(this.code, this.message);
  @override
  String toString() => '[$code] $message';
}
