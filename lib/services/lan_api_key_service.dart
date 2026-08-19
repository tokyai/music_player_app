import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const _sessionDuration = Duration(minutes: 10);
const _maxApiKeyBytes = 8 * 1024;

/// A short-lived LAN page used to enter an API Key from a phone.
class LanApiKeyService {
  const LanApiKeyService._();

  static Future<LanApiKeySession> start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final host = await _findLanAddress(server);
    final session = LanApiKeySession._(
      server: server,
      host: host,
      token: _randomToken(),
    );
    session._listen();
    return session;
  }

  static String _randomToken() {
    final bytes = List<int>.generate(18, (_) => Random.secure().nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static Future<String> _findLanAddress(HttpServer server) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final candidates = interfaces
          .expand(
            (network) => network.addresses.map(
              (address) => (name: network.name.toLowerCase(), address: address),
            ),
          )
          .where((candidate) => !candidate.address.isLoopback)
          .toList();
      candidates.sort((a, b) => _addressScore(a).compareTo(_addressScore(b)));
      if (candidates.isNotEmpty) return candidates.first.address.address;
    } catch (_) {}
    final address = server.address.address;
    return address == '0.0.0.0' ? '127.0.0.1' : address;
  }

  static int _addressScore(({String name, InternetAddress address}) candidate) {
    final name = candidate.name;
    if (name.contains('tun') ||
        name.contains('vpn') ||
        name.contains('rmnet') ||
        name.contains('docker')) {
      return 10;
    }
    if (name.contains('wlan') || name.contains('wifi')) return 0;
    if (name.startsWith('eth') || name.startsWith('en')) return 1;
    return _isPrivateIpv4(candidate.address.address) ? 2 : 5;
  }

  static bool _isPrivateIpv4(String value) {
    final parts = value.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    final first = parts[0]!;
    final second = parts[1]!;
    return first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }
}

class LanApiKeySession {
  final HttpServer _server;
  final String _token;
  final Completer<String?> _apiKeyCompleter = Completer<String?>();
  late final Timer _expiryTimer;
  final String host;
  bool _stopped = false;

  LanApiKeySession._({
    required HttpServer server,
    required String token,
    required this.host,
  }) : _server = server,
       _token = token {
    _expiryTimer = Timer(_sessionDuration, stop);
  }

  String get url => 'http://$host:${_server.port}/$_token/';
  Future<String?> get receivedApiKey => _apiKeyCompleter.future;
  bool get isActive => !_stopped;

  void _listen() {
    _server.listen(_handleRequest, onError: (_) {}, cancelOnError: false);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (_stopped) {
      await _respond(request, HttpStatus.gone, '本次扫码输入已结束');
      return;
    }
    final segments = request.uri.pathSegments;
    if (segments.isEmpty || segments.first != _token) {
      await _respond(request, HttpStatus.notFound, '地址无效');
      return;
    }
    final endpoint = segments.length == 1 ? '' : segments[1];
    try {
      if (request.method == 'GET' && endpoint.isEmpty) {
        await _serveHome(request);
      } else if (request.method == 'POST' && endpoint == 'submit') {
        await _receiveApiKey(request);
      } else {
        await _respond(request, HttpStatus.notFound, '请求不存在');
      }
    } catch (error) {
      try {
        await _respond(request, HttpStatus.internalServerError, '提交失败：$error');
      } catch (_) {}
    }
  }

  Future<void> _serveHome(HttpRequest request) async {
    const html = '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><title>库仔音乐 API Key 配置</title><style>
body{font-family:system-ui,-apple-system,"Microsoft Yahei",sans-serif;max-width:560px;margin:0 auto;padding:24px;line-height:1.6;color:#20242b;background:#f7f8fa}
main{background:#fff;border:1px solid #e3e7ec;border-radius:12px;padding:24px;box-shadow:0 4px 16px #00000012}h1{font-size:22px;margin-top:0}
label{display:block;font-weight:600;margin:14px 0 6px}input,button{font:inherit;box-sizing:border-box;width:100%;padding:12px;border:1px solid #d8dde5;border-radius:8px}button{background:#2196f3;color:#fff;border:0;font-weight:700;margin-top:12px}.status{margin-top:14px;white-space:pre-wrap;color:#454b54}small{display:block;margin-top:18px;color:#686f79}
</style></head><body><main><h1>输入 ChKSz API Key</h1><p>提交后将直接保存到车机上的库仔音乐。</p>
<label for="key">API Key</label><input id="key" type="password" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="请输入 API Key">
<button id="submit" onclick="submitKey()">发送到车机并保存</button><div id="status" class="status"></div>
<small>请确认手机与车机连接同一个 Wi-Fi。本页面仅临时有效，Key 不会显示在车机二维码中。</small></main><script>
const input=document.getElementById('key'),button=document.getElementById('submit'),status=document.getElementById('status');
async function submitKey(){const key=input.value.trim();if(!key){status.textContent='请输入 API Key';return;}button.disabled=true;status.textContent='正在发送…';try{const response=await fetch('submit',{method:'POST',headers:{'Content-Type':'text/plain;charset=UTF-8'},body:key});status.textContent=await response.text();if(response.ok){input.value='';input.disabled=true;}else{button.disabled=false;}}catch(error){button.disabled=false;status.textContent='发送失败：'+error;}}
</script></body></html>''';
    final response = request.response;
    response.headers.set('Content-Type', 'text/html; charset=utf-8');
    response.headers.set('Cache-Control', 'no-store');
    response.write(html);
    await response.close();
  }

  Future<void> _receiveApiKey(HttpRequest request) async {
    if (_apiKeyCompleter.isCompleted) {
      await _respond(request, HttpStatus.conflict, '本次 API Key 已提交');
      return;
    }
    if (request.headers.contentLength > _maxApiKeyBytes) {
      await _respond(request, HttpStatus.requestEntityTooLarge, 'API Key 内容过长');
      return;
    }
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 20))) {
      bytes.addAll(chunk);
      if (bytes.length > _maxApiKeyBytes) {
        await _respond(
          request,
          HttpStatus.requestEntityTooLarge,
          'API Key 内容过长',
        );
        return;
      }
    }
    late final String apiKey;
    try {
      apiKey = utf8.decode(bytes, allowMalformed: false).trim();
    } on FormatException {
      await _respond(request, HttpStatus.badRequest, 'API Key 编码无效');
      return;
    }
    if (apiKey.isEmpty) {
      await _respond(request, HttpStatus.badRequest, 'API Key 不能为空');
      return;
    }
    _apiKeyCompleter.complete(apiKey);
    await _respond(request, HttpStatus.ok, '发送成功，车机正在保存 API Key');
  }

  Future<void> _respond(
    HttpRequest request,
    int statusCode,
    String message,
  ) async {
    final response = request.response;
    response.statusCode = statusCode;
    response.headers.set('Content-Type', 'text/plain; charset=utf-8');
    response.headers.set('Cache-Control', 'no-store');
    response.write(message);
    await response.close();
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _expiryTimer.cancel();
    if (!_apiKeyCompleter.isCompleted) _apiKeyCompleter.complete(null);
    await _server.close(force: true);
  }
}
