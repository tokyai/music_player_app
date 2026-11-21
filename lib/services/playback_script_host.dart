import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bounded_http_response.dart';

/// 单次解析的受限网络与计时桥接，SHIXIAOYANG，2026/11/21。
///
/// [operationId] 隔离不同歌曲；[send] 只向仍然存活的解析 worker 回传结果。
class PlaybackScriptHost {
  final String operationId;
  final Set<String> allowedOrigins;
  final http.Client client;
  final void Function(Map<String, dynamic>) send;
  final Map<int, _HostRequest> _requests = {};
  final Map<int, _HostDelay> _delays = {};
  final Set<String> _knownScopes = {};
  final Set<String> _cancelledScopes = {};
  bool _closed = false;

  PlaybackScriptHost({
    required this.operationId,
    required Iterable<String> allowedOrigins,
    required this.client,
    required this.send,
  }) : allowedOrigins = Set<String>.unmodifiable(allowedOrigins);

  /// 同步接收命令，异步IO不会在JS原生回调内重入引擎。
  void handle(Map<String, dynamic> command) {
    if (_closed) return;
    final kind = command['kind'];
    final scope = command['scope'];
    final id = command['requestId'];
    if (kind == 'cancel' && scope is String) {
      _cancelScope(scope);
      return;
    }
    if (id is! int || id < 1 || id > 0x3fffffff || scope is! String) {
      return;
    }
    // Scope数量和名称都受限，迟到任务不能复用已经取消的scope。
    if (!_acceptScope(scope)) {
      _fail(id, 'RESOLVE_CANCELLED', '播放解析已取消');
      return;
    }
    if (_requests.containsKey(id) || _delays.containsKey(id)) {
      _fail(id, 'INVALID_REQUEST', '解析任务标识重复');
      return;
    }
    if (kind == 'request') {
      unawaited(_request(id, scope, command['options']));
    } else if (kind == 'delay') {
      _delay(id, scope, command['milliseconds']);
    } else {
      _fail(id, 'INVALID_REQUEST', '解析任务类型无效');
    }
  }

  bool _acceptScope(String scope) {
    final prefix = '$operationId:';
    if (scope != operationId && !scope.startsWith(prefix)) return false;
    if (scope.length > 160 ||
        !RegExp(r'^[A-Za-z0-9_:]+$').hasMatch(scope) ||
        _cancelledScopes.contains(operationId) ||
        _cancelledScopes.contains(scope)) {
      return false;
    }
    if (_knownScopes.contains(scope)) return true;
    if (_knownScopes.length >= 32) return false;
    _knownScopes.add(scope);
    return true;
  }

  Future<void> _request(int id, String scope, dynamic raw) async {
    // 每个解析最多四条并行网络请求，超过上限直接失败而不排队。
    if (_requests.length >= 4 || raw is! Map) {
      _fail(id, 'REQUEST_LIMIT', '解析并发请求超过上限');
      return;
    }
    final uri = raw['url'] is String
        ? Uri.tryParse(raw['url'] as String)
        : null;
    if (uri == null ||
        (raw['url'] as String).length > 8192 ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        !allowedOrigins.contains(uri.origin) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535) {
      _fail(id, 'INVALID_UPSTREAM', '解析包请求了未允许的上游');
      return;
    }
    final method = raw['method'] ?? 'GET';
    final timeout = raw['timeoutMs'] ?? 6500;
    final maxBytes = raw['maxBytes'] ?? 512 * 1024;
    final body = raw['bodyText'];
    final headers = raw['headers'] ?? const <String, dynamic>{};
    if (!const ['GET', 'POST'].contains(method) ||
        timeout is! int ||
        timeout < 1 ||
        timeout > 7000 ||
        maxBytes is! int ||
        maxBytes < 1 ||
        maxBytes > 512 * 1024 ||
        (body != null && body is! String) ||
        headers is! Map ||
        headers.length > 24) {
      _fail(id, 'INVALID_REQUEST', '解析请求参数无效');
      return;
    }
    final request = http.Request(method as String, uri);
    request.followRedirects = false;
    // 请求正文保留JS原始UTF-8文本，Qing签名必须对应实际发出的字节。
    if (body is String) {
      final bytes = utf8.encode(body);
      if (bytes.length > 64 * 1024) {
        _fail(id, 'REQUEST_TOO_LARGE', '解析请求正文超过上限');
        return;
      }
      request.bodyBytes = bytes;
    }
    for (final entry in headers.entries) {
      final name = entry.key;
      final value = entry.value;
      if (name is! String ||
          !RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(name) ||
          value is! String ||
          value.length > 4096 ||
          RegExp(r'[^\x20-\x7e]').hasMatch(value) ||
          const [
            'host',
            'content-length',
            'connection',
            'transfer-encoding',
          ].contains(name.toLowerCase())) {
        _fail(id, 'INVALID_HEADERS', '解析请求头无效');
        return;
      }
      request.headers[name] = value;
    }
    final pending = _HostRequest(scope);
    _requests[id] = pending;
    try {
      final response = await sendBoundedHttpRequest(
        client,
        request,
        maxBytes: maxBytes,
        timeout: Duration(milliseconds: timeout),
        totalTimeout: Duration(milliseconds: timeout),
        cancelSignal: pending.cancelled.future,
      );
      if (_closed || pending.cancelled.isCompleted) return;
      _requests.remove(id);
      send({
        'type': 'hostResponse',
        'requestId': id,
        'value': {
          'status': response.statusCode,
          'bodyText': utf8.decode(response.bodyBytes),
        },
      });
    } on HttpRequestCancelledException {
      _fail(id, 'RESOLVE_CANCELLED', '播放解析已取消');
    } on TimeoutException {
      _fail(id, 'UPSTREAM_TIMEOUT', '上游请求超时');
    } on HttpResponseTooLargeException {
      _fail(id, 'RESPONSE_TOO_LARGE', '上游响应超过上限');
    } on Exception {
      _fail(id, 'UPSTREAM_NETWORK', '上游网络请求失败');
    } finally {
      _requests.remove(id);
      pending.cancel();
    }
  }

  void _delay(int id, String scope, dynamic milliseconds) {
    if (_delays.length >= 8 ||
        milliseconds is! int ||
        milliseconds < 0 ||
        milliseconds > 20000) {
      _fail(id, 'INVALID_DELAY', '解析计时参数超过上限');
      return;
    }
    void complete() {
      _delays.remove(id);
      if (!_closed) {
        send({'type': 'hostResponse', 'requestId': id, 'value': null});
      }
    }

    _delays[id] = _HostDelay(
      scope,
      Timer(Duration(milliseconds: milliseconds), complete),
    );
  }

  void _fail(int id, String code, String message) {
    if (!_closed) {
      send({
        'type': 'hostResponse',
        'requestId': id,
        'error': {'code': code, 'message': message},
      });
    }
  }

  void _cancelScope(String scope) {
    if (!_acceptScope(scope) && !_knownScopes.contains(scope)) return;
    _cancelledScopes.add(scope);
    for (final entry in _requests.entries.toList()) {
      if (scope == operationId || entry.value.scope == scope) {
        entry.value.cancel();
      }
    }
    for (final entry in _delays.entries.toList()) {
      if (scope != operationId && entry.value.scope != scope) continue;
      entry.value.timer.cancel();
      _delays.remove(entry.key);
      _fail(entry.key, 'RESOLVE_CANCELLED', '播放解析已取消');
    }
  }

  /// 中止全部网络和定时器，不会留下后台队列或向已关闭worker发送状态。
  void close() {
    if (_closed) return;
    _closed = true;
    for (final request in _requests.values) {
      request.cancel();
    }
    for (final delay in _delays.values) {
      delay.timer.cancel();
    }
    _requests.clear();
    _delays.clear();
    _knownScopes.clear();
    _cancelledScopes.clear();
  }
}

class _HostRequest {
  final String scope;
  final Completer<void> cancelled = Completer<void>();
  _HostRequest(this.scope);
  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
  }
}

class _HostDelay {
  final String scope;
  final Timer timer;
  _HostDelay(this.scope, this.timer);
}
