import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/ai_assistant.dart';

const _aiConfigSessionDuration = Duration(minutes: 10);
const _maxAiConfigBytes = 32 * 1024;

/// 在同一局域网内临时接收完整 AI 配置。Key 只通过一次 POST 传输，
/// 不会出现在二维码 URL 或日志中。
class LanAiConfigService {
  const LanAiConfigService._();

  static Future<LanAiConfigSession> start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final host = await _findLanAddress();
    final session = LanAiConfigSession._(
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

  static Future<String> _findLanAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = interfaces
          .expand((network) => network.addresses)
          .where((address) => !address.isLoopback)
          .toList();
      addresses.sort((a, b) {
        final aPrivate = _isPrivateIpv4(a.address);
        final bPrivate = _isPrivateIpv4(b.address);
        return (bPrivate ? 0 : 1).compareTo(aPrivate ? 0 : 1);
      });
      if (addresses.isNotEmpty) return addresses.first.address;
    } catch (_) {}
    return '127.0.0.1';
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

class LanAiConfigSession {
  final HttpServer _server;
  final String _token;
  final Completer<AiAssistantConfig?> _configCompleter =
      Completer<AiAssistantConfig?>();
  late final Timer _expiryTimer;
  final String host;
  bool _stopped = false;

  LanAiConfigSession._({
    required HttpServer server,
    required String token,
    required this.host,
  }) : _server = server,
       _token = token {
    _expiryTimer = Timer(_aiConfigSessionDuration, () {
      unawaited(stop());
    });
  }

  String get url => 'http://$host:${_server.port}/$_token/';
  Future<AiAssistantConfig?> get receivedConfig => _configCompleter.future;
  bool get isActive => !_stopped;

  void _listen() {
    _server.listen(_handleRequest, onError: (_) {}, cancelOnError: false);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (_stopped) {
      await _respond(request, HttpStatus.gone, '本次扫码配置已结束');
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
        await _receiveConfig(request);
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
<title>库仔音乐 AI 助理配置</title><style>
body{font-family:system-ui,-apple-system,"Microsoft Yahei",sans-serif;max-width:560px;margin:0 auto;padding:24px;line-height:1.6;color:#20242b;background:#f7f8fa}
main{background:#fff;border:1px solid #e3e7ec;border-radius:12px;padding:24px;box-shadow:0 4px 16px #00000012}h1{font-size:22px;margin-top:0}
label{display:block;font-weight:600;margin:14px 0 6px}input,select,button{font:inherit;box-sizing:border-box;width:100%;padding:12px;border:1px solid #d8dde5;border-radius:8px}button{background:#2196f3;color:#fff;border:0;font-weight:700;margin-top:16px}.status{margin-top:14px;white-space:pre-wrap;color:#454b54}small{display:block;margin-top:18px;color:#686f79}
</style></head><body><main><h1>配置 AI 音乐助理</h1>
<label for="provider">厂商</label><select id="provider"><option value="openai">OpenAI</option><option value="anthropic">Claude</option><option value="gemini">Gemini</option><option value="xai">Grok</option><option value="deepseek">DeepSeek</option><option value="glm">GLM</option><option value="mimo">小米 MiMo</option><option value="qwen">Qwen</option><option value="custom">自定义中转站</option></select>
<label for="protocol">请求协议</label><select id="protocol"><option value="openai_responses">OpenAI Responses</option><option value="openai_chat">OpenAI Chat Completions</option><option value="anthropic_messages">Anthropic Messages</option><option value="gemini_generate_content">Gemini GenerateContent</option></select>
<label for="url">中转站 URL</label><input id="url" type="url" autocomplete="off" placeholder="https://example.com/v1">
<label for="key">API Key</label><input id="key" type="password" autocomplete="off" placeholder="请输入 API Key">
<label for="model">模型</label><input id="model" autocomplete="off" placeholder="例如 gpt-5.5">
<label for="reasoning">推理等级</label><select id="reasoning"><option value="default">平台默认</option><option value="off">关闭</option><option value="minimal">极低</option><option value="low">低</option><option value="medium">中</option><option value="high">高</option><option value="maximum">极高</option></select>
<label for="search">联网搜索</label><select id="search"><option value="automatic">按需使用</option><option value="disabled">关闭</option><option value="always">尽量强制</option></select>
<button id="submit" onclick="submitConfig()">发送到车机并保存</button><div id="status" class="status"></div>
<small>手机与车机需连接同一个 Wi-Fi。本页面约 10 分钟后失效，Key 不会写入二维码。</small></main><script>
const ids=['provider','protocol','url','key','model','reasoning','search'];const status=document.getElementById('status'),button=document.getElementById('submit');
async function submitConfig(){const payload={provider:provider.value,protocol:protocol.value,baseUrl:url.value.trim(),apiKey:key.value.trim(),model:model.value.trim(),reasoningEffort:reasoning.value,webSearchMode:search.value};if(!payload.baseUrl||!payload.apiKey||!payload.model){status.textContent='请完整填写 URL、Key 和模型';return;}button.disabled=true;status.textContent='正在发送…';try{const response=await fetch('submit',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});status.textContent=await response.text();if(response.ok){ids.forEach(id=>document.getElementById(id).disabled=true);}else{button.disabled=false;}}catch(error){button.disabled=false;status.textContent='发送失败：'+error;}}
</script></body></html>''';
    final response = request.response;
    response.headers.set('Content-Type', 'text/html; charset=utf-8');
    response.headers.set('Cache-Control', 'no-store');
    response.write(html);
    await response.close();
  }

  Future<void> _receiveConfig(HttpRequest request) async {
    if (_configCompleter.isCompleted) {
      await _respond(request, HttpStatus.conflict, '本次配置已经提交');
      return;
    }
    if (request.headers.contentLength > _maxAiConfigBytes) {
      await _respond(request, HttpStatus.requestEntityTooLarge, '配置内容过长');
      return;
    }
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 20))) {
      bytes.addAll(chunk);
      if (bytes.length > _maxAiConfigBytes) {
        await _respond(request, HttpStatus.requestEntityTooLarge, '配置内容过长');
        return;
      }
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) throw const FormatException('配置格式无效');
      final data = Map<String, dynamic>.from(decoded);
      final config = AiAssistantConfig.fromJson(
        data,
        apiKey: data['apiKey']?.toString() ?? '',
      );
      final uri = Uri.tryParse(config.baseUrl);
      if (config.apiKey.trim().isEmpty ||
          config.model.trim().isEmpty ||
          uri == null ||
          !uri.hasScheme ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        throw const FormatException('URL、Key 或模型无效');
      }
      _configCompleter.complete(config);
      await _respond(request, HttpStatus.ok, '发送成功，车机正在保存 AI 配置');
    } catch (error) {
      await _respond(request, HttpStatus.badRequest, '配置无效：$error');
    }
  }

  Future<void> _respond(
    HttpRequest request,
    int statusCode,
    String message,
  ) async {
    try {
      final response = request.response;
      response.statusCode = statusCode;
      response.headers.set('Content-Type', 'text/plain; charset=utf-8');
      response.headers.set('Cache-Control', 'no-store');
      response.write(message);
      await response.close();
    } catch (_) {
      // The phone can disconnect while the response is being written.
    }
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _expiryTimer.cancel();
    if (!_configCompleter.isCompleted) _configCompleter.complete(null);
    try {
      await _server.close(force: true);
    } catch (_) {
      // The socket may already be closed by the platform or Activity teardown.
    }
  }
}
