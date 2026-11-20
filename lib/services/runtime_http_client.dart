import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'bounded_http_response.dart';
import 'runtime_config.dart';

/// 只访问部署服务器的受限 HTTPS 客户端。SHIXIAOYANG，2026/11/19。
class RuntimeHttpClient {
  final http.Client _client;
  final bool _usesPinnedClient;
  final http.Client Function() _publicCatalogClientFactory;
  final Uri base;
  final StreamController<void> _cancel = StreamController<void>.broadcast(
    sync: true,
  );
  static String _proxyAddress = '';
  static const _proxyKey = 'runtime_http_proxy_v1';
  bool _closed = false;

  /// 注入客户端仅供定向网络测试；实际运行使用固定证书和设备直连传输。
  RuntimeHttpClient({
    http.Client? client,
    Uri? base,
    http.Client Function()? publicCatalogClientFactory,
  }) : base = base ?? Uri.parse(RuntimeConfig.baseUrl),
       _usesPinnedClient = client == null,
       _publicCatalogClientFactory =
           publicCatalogClientFactory ?? _directPublicClient,
       _client = client ?? _pinnedClient();

  static String _validateProxy(String value) {
    final address = value.trim().replaceFirst(RegExp(r'^http://'), '');
    if (address.isEmpty) return '';
    final match = RegExp(
      r'^(?:\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]{1,253}):([0-9]{1,5})$',
    ).firstMatch(address);
    final port = match == null ? 0 : int.parse(match.group(1)!);
    if (port < 1 || port > 65535) {
      throw const FormatException('HTTP 代理请填写主机:端口，不包含账号或密码');
    }
    return address;
  }

  /// 网络代理属于框架设置，首次离线启动也可读取，不参与业务包替换。
  static Future<String> proxy() async {
    final prefs = await SharedPreferences.getInstance();
    _proxyAddress = _validateProxy(prefs.getString(_proxyKey) ?? '');
    return _proxyAddress;
  }

  /// 先校验并成功落盘，再切换连接路由；TLS 指纹校验始终保持开启。
  static Future<void> setProxy(String value) async {
    final address = _validateProxy(value);
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_proxyKey, address)) {
      throw StateError('保存网络代理失败');
    }
    _proxyAddress = address;
  }

  static http.Client _pinnedClient() {
    // 复用项目已有的证书指纹校验模式，并校验证书有效期。
    final uri = Uri.parse(RuntimeConfig.baseUrl);
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 8);
    client.findProxy = (_) =>
        _proxyAddress.isEmpty ? 'DIRECT' : 'PROXY $_proxyAddress';
    client.badCertificateCallback = (certificate, host, port) {
      final now = DateTime.now();
      if (host != uri.host ||
          port != uri.port ||
          now.isBefore(certificate.startValidity) ||
          now.isAfter(certificate.endValidity)) {
        return false;
      }
      return sha256.convert(certificate.der).toString().toUpperCase() ==
          RuntimeConfig.certificateSha256;
    };
    return IOClient(client);
  }

  static http.Client _directPublicClient() {
    final transport = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    // 公共目录沿用设备出口，代理设置只用于固定更新服务。
    transport.findProxy = (_) => 'DIRECT';
    return IOClient(transport);
  }

  /// 获取同一部署源下的资源，响应体大小由业务包或接口上限约束。
  Future<http.Response> get(
    String relative, {
    int maxBytes = 64 * 1024,
    Future<void>? cancelSignal,
  }) {
    return _send(
      'GET',
      relative,
      maxBytes: maxBytes,
      cancelSignal: cancelSignal,
    );
  }

  /// 将业务参数发送给固定服务端接口，不在客户端执行远程适配脚本。
  Future<Map<String, dynamic>> api(
    String operation,
    Map<String, dynamic> data, {
    Future<void>? cancelSignal,
  }) async {
    if (!RegExp(r'^[a-z_]{1,32}$').hasMatch(operation)) {
      throw const FormatException('接口名无效');
    }
    final body = jsonEncode(data);
    if (utf8.encode(body).length > 256 * 1024) {
      throw const FormatException('接口参数过大');
    }
    var response = await _send(
      'POST',
      'api/$operation',
      body: body,
      maxBytes: 5 * 1024 * 1024,
      cancelSignal: cancelSignal,
    );
    var result = _result(response);
    // 目录协议由服务器维护。只在出口受限时执行公共目录请求，再回传给服务器解析。
    for (var step = 0; step < 3 && result['clientRequest'] is Map; step++) {
      final plan = Map<String, dynamic>.from(result['clientRequest'] as Map);
      final receipt = await _publicCatalog(plan, cancelSignal);
      response = await _send(
        'POST',
        'api/catalog_result',
        body: jsonEncode(receipt),
        maxBytes: 5 * 1024 * 1024,
        cancelSignal: cancelSignal,
      );
      result = _result(response);
    }
    if (result['clientRequest'] != null) {
      throw const RuntimeException('CATALOG_STEPS_EXCEEDED', '目录请求步骤过多');
    }
    return result;
  }

  Map<String, dynamic> _result(http.Response response) {
    if (_closed) throw const RuntimeException('CANCELLED', '请求已取消');
    final value = jsonDecode(utf8.decode(response.bodyBytes));
    if (value is! Map) throw const FormatException('服务端响应格式无效');
    final result = Map<String, dynamic>.from(value);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        result['ok'] != true) {
      final code = result['code'];
      final message = result['message'];
      throw RuntimeException(
        code is String && RegExp(r'^[A-Z0-9_]{1,64}$').hasMatch(code)
            ? code
            : 'SERVER_ERROR',
        message is String && message.length <= 512 ? message : '远程服务不可用',
      );
    }
    return result;
  }

  // 在打开连接前限制地址、方法、请求头和正文，不接受远程传入的凭据。
  http.Request _catalogRequest(Map<String, dynamic> plan) {
    final id = plan['id'];
    final url = plan['url'] is String
        ? Uri.tryParse(plan['url'] as String)
        : null;
    final method = plan['method'];
    final validHost =
        url != null &&
        [
          'music.163.com',
          'y.qq.com',
          'kugou.com',
        ].any((host) => url.host == host || url.host.endsWith('.$host'));
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        url == null ||
        !validHost ||
        !['http', 'https'].contains(url.scheme) ||
        url.userInfo.isNotEmpty ||
        url.hasFragment ||
        ![80, 443].contains(url.port) ||
        !['GET', 'POST'].contains(method) ||
        (method == 'GET' && plan['body'] != null)) {
      throw const RuntimeException('CATALOG_PLAN_INVALID', '公共目录请求无效');
    }
    final request = http.Request(method as String, url)
      ..followRedirects = false;
    final rawHeaders = plan['headers'];
    if (rawHeaders is! Map || rawHeaders.length > 16) {
      throw const FormatException('目录请求头无效');
    }
    const allowed = {
      'accept',
      'content-type',
      'referer',
      'origin',
      'user-agent',
    };
    for (final entry in rawHeaders.entries) {
      if (entry.key is! String ||
          entry.value is! String ||
          !allowed.contains((entry.key as String).toLowerCase()) ||
          (entry.value as String).length > 4096 ||
          (entry.value as String).contains(RegExp(r'[\r\n]'))) {
        throw const FormatException('目录请求头无效');
      }
      request.headers[entry.key as String] = entry.value as String;
    }
    if (plan['body'] != null) {
      final body = jsonEncode(plan['body']);
      final bodyBytes = utf8.encode(body);
      if (bodyBytes.length > 64 * 1024) {
        throw const FormatException('目录请求体过大');
      }
      request.headers['Content-Type'] = 'application/json';
      request.bodyBytes = bodyBytes;
    }
    return request;
  }

  // 每次目录传输使用独立客户端，取消或超时后完整关闭连接。
  Future<Map<String, dynamic>> _publicCatalog(
    Map<String, dynamic> plan,
    Future<void>? cancelSignal,
  ) async {
    final request = _catalogRequest(plan);
    if (_closed) throw const RuntimeException('CANCELLED', '目录请求已取消');
    final client = _publicCatalogClientFactory();
    final cancel = Completer<void>();
    void stop() {
      if (!cancel.isCompleted) cancel.complete();
    }

    final owner = _cancel.stream.listen((_) => stop());
    final operation = cancelSignal?.asStream().listen(
      (_) => stop(),
      onError: (Object _) => stop(),
    );
    try {
      final response = await sendBoundedHttpRequest(
        client,
        request,
        maxBytes: 512 * 1024,
        timeout: const Duration(seconds: 10),
        totalTimeout: const Duration(seconds: 14),
        cancelSignal: cancel.future,
      );
      return {
        'id': plan['id'],
        'status': response.statusCode,
        'bodyBase64': base64Encode(response.bodyBytes),
      };
    } finally {
      client.close();
      unawaited(owner.cancel());
      unawaited(operation?.cancel());
    }
  }

  Future<http.Response> _send(
    String method,
    String relative, {
    String? body,
    required int maxBytes,
    Future<void>? cancelSignal,
  }) async {
    if (_closed) throw const RuntimeException('CANCELLED', '请求已取消');
    if (_usesPinnedClient) await proxy();
    if (_closed) throw const RuntimeException('CANCELLED', '请求已取消');
    final uri = base.resolve(relative);
    if (uri.origin != base.origin ||
        relative.contains('..') ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('只能访问部署服务器');
    }
    final request = http.Request(method, uri)..followRedirects = false;
    request.headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.bodyBytes = utf8.encode(body);
    }
    // 所有者取消和单次操作取消均释放 HTTP 流，不能仅忽略迟到的结果。
    final cancellation = Completer<void>();
    void cancel() {
      if (!cancellation.isCompleted) cancellation.complete();
    }

    final owner = _cancel.stream.listen((_) => cancel());
    final operation = cancelSignal?.asStream().listen(
      (_) => cancel(),
      onError: (Object _) => cancel(),
    );
    try {
      return await sendBoundedHttpRequest(
        _client,
        request,
        maxBytes: maxBytes,
        timeout: Duration(seconds: method == 'POST' ? 22 : 10),
        totalTimeout: const Duration(seconds: 22),
        cancelSignal: cancellation.future,
      );
    } finally {
      unawaited(owner.cancel());
      unawaited(operation?.cancel());
    }
  }

  /// 页面或应用释放时中止尚未完成的网络操作。
  void close() {
    if (_closed) return;
    _closed = true;
    _cancel.add(null);
    unawaited(_cancel.close());
    _client.close();
  }
}

class RuntimeException implements Exception {
  final String code;
  final String message;
  const RuntimeException(this.code, this.message);
  @override
  String toString() => '$code: $message';
}
