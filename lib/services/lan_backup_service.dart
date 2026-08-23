import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const _lanMaxBackupBytes = 5 * 1024 * 1024;
const _lanSessionDuration = Duration(minutes: 10);

/// 临时局域网备份服务。手机只需要浏览器，不需要安装客户端或调用车机文件管理器。
class LanBackupService {
  const LanBackupService._();

  static Future<LanBackupSession> start({
    required String Function() exportBackup,
  }) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final token = _randomToken();
    final pin = (Random.secure().nextInt(1000000)).toString().padLeft(6, '0');
    final host = await _findLanAddress(server);
    final session = LanBackupSession._(
      server: server,
      token: token,
      pin: pin,
      host: host,
      exportBackup: exportBackup,
    );
    session._listen();
    return session;
  }

  static bool isValidPin(String value) => RegExp(r'^\d{6}$').hasMatch(value);

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
              (address) => _LanAddressCandidate(network.name, address),
            ),
          )
          .where((candidate) => !candidate.address.isLoopback)
          .toList();
      if (candidates.isNotEmpty) {
        // Android 的 Wi-Fi 通常是 wlan0；其次选择有线网卡和私有地址，
        // 避免 VPN、蜂窝网络或虚拟网卡地址优先显示。
        candidates.sort(
          (a, b) => _candidateScore(a).compareTo(_candidateScore(b)),
        );
        return candidates.first.address.address;
      }
    } catch (_) {}
    final address = server.address.address;
    return address == '0.0.0.0' ? '127.0.0.1' : address;
  }

  static bool _isPrivate(String value) {
    final parts = value.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    final a = parts[0]!;
    final b = parts[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }

  static int _candidateScore(_LanAddressCandidate candidate) {
    final name = candidate.interfaceName.toLowerCase();
    final virtual =
        name.contains('tun') ||
        name.contains('vpn') ||
        name.contains('rmnet') ||
        name.contains('docker');
    if (virtual) return 10;
    if (name.contains('wlan') || name.contains('wifi')) return 0;
    if (name.startsWith('eth') || name.startsWith('en')) return 1;
    return _isPrivate(candidate.address.address) ? 2 : 5;
  }
}

class _LanAddressCandidate {
  final String interfaceName;
  final InternetAddress address;

  const _LanAddressCandidate(this.interfaceName, this.address);
}

class LanBackupSession {
  final HttpServer _server;
  final String _token;
  final String pin;
  final String host;
  final String Function() _exportBackup;
  final Completer<String?> _restoreCompleter = Completer<String?>();
  late final Timer _expiryTimer;
  late final DateTime expiresAt;
  bool _stopped = false;

  LanBackupSession._({
    required HttpServer server,
    required String token,
    required this.pin,
    required this.host,
    required String Function() exportBackup,
  }) : _server = server,
       _token = token,
       _exportBackup = exportBackup {
    expiresAt = DateTime.now().add(_lanSessionDuration);
    _expiryTimer = Timer(_lanSessionDuration, () {
      unawaited(stop());
    });
  }

  String get url => 'http://$host:${_server.port}/$_token/';

  /// QR code target. The PIN is scoped to this short-lived session and is
  /// filled into the browser page after scanning.
  String get qrUrl =>
      Uri.parse(url).replace(queryParameters: {'pin': pin}).toString();
  Future<String?> get restored => _restoreCompleter.future;
  bool get isActive => !_stopped;

  void _listen() {
    _server.listen(_handleRequest, onError: (_) {}, cancelOnError: false);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (_stopped) {
      await _respond(request, 410, '本次传输已结束');
      return;
    }
    if (request.method == 'OPTIONS') {
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set(
        'Access-Control-Allow-Methods',
        'GET, POST, OPTIONS',
      );
      request.response.headers.set(
        'Access-Control-Allow-Headers',
        'Content-Type',
      );
      await request.response.close();
      return;
    }

    final segments = request.uri.pathSegments;
    if (segments.isEmpty || segments.first != _token) {
      await _respond(request, 404, '地址无效');
      return;
    }
    final endpoint = segments.length == 1 ? '' : segments[1];
    try {
      if (request.method == 'GET' && endpoint.isEmpty) {
        await _serveHome(request);
      } else if (request.method == 'GET' && endpoint == 'backup') {
        await _serveBackup(request);
      } else if (request.method == 'POST' && endpoint == 'restore') {
        await _receiveRestore(request);
      } else {
        await _respond(request, 404, '请求不存在');
      }
    } catch (error) {
      try {
        await _respond(request, 500, '传输失败：$error');
      } catch (_) {}
    }
  }

  Future<void> _serveHome(HttpRequest request) async {
    const html = '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>库仔音乐备份</title><style>
body{font-family:system-ui,-apple-system,"Microsoft Yahei",sans-serif;max-width:680px;margin:0 auto;padding:24px;line-height:1.6;color:#20242b;background:#f7f8fa}
main{background:#fff;border:1px solid #e3e7ec;border-radius:16px;padding:24px;box-shadow:0 4px 16px #00000012}h1{font-size:24px;margin-top:0}
label{display:block;font-weight:600;margin:14px 0 6px}input,button,textarea{font:inherit;box-sizing:border-box;width:100%;padding:11px;border:1px solid #d8dde5;border-radius:10px}button{background:#2196f3;color:white;border:0;font-weight:700;cursor:pointer;margin-top:10px}button.secondary{background:#eef1f4;color:#20242b}small{color:#646a73}.status{margin-top:14px;white-space:pre-wrap}
</style></head><body><main><h1>库仔音乐备份</h1><p>请输入车机上显示的 6 位 PIN。备份包含收藏、播放 API Key，以及全部 AI 模型配置、中转站、选项和 Key。</p>
<label for="pin">PIN</label><input id="pin" inputmode="numeric" maxlength="6" placeholder="6 位数字">
<button class="secondary" onclick="downloadBackup()">从车机下载备份</button>
<label for="file">向车机恢复 JSON 文件</label><input id="file" type="file" accept="application/json,.json">
<button onclick="uploadBackup()">上传并在车机上确认恢复</button><div id="status" class="status"></div>
<small>本页面仅在当前局域网临时有效，传输服务将在 10 分钟后自动关闭。</small></main><script>
const initialPin=new URLSearchParams(location.search).get('pin')||'';if(/^\\d{6}\$/.test(initialPin))document.getElementById('pin').value=initialPin;
const pin=()=>document.getElementById('pin').value.trim();const status=t=>document.getElementById('status').textContent=t;
function downloadBackup(){if(!/^\\d{6}\$/.test(pin())){status('请输入 6 位 PIN');return;}location.href='backup?pin='+encodeURIComponent(pin());}
async function uploadBackup(){if(!/^\\d{6}\$/.test(pin())){status('请输入 6 位 PIN');return;}const f=document.getElementById('file').files[0];if(!f){status('请选择 JSON 文件');return;}if(f.size>5242880){status('文件不能超过 5 MB');return;}status('正在上传…');try{const r=await fetch('restore?pin='+encodeURIComponent(pin()),{method:'POST',headers:{'Content-Type':'application/json'},body:await f.text()});status(await r.text());}catch(e){status('上传失败：'+e);}}
</script></body></html>''';
    final response = request.response;
    response.headers.set('Content-Type', 'text/html; charset=utf-8');
    response.headers.set('Cache-Control', 'no-store');
    response.write(html);
    await response.close();
  }

  Future<void> _serveBackup(HttpRequest request) async {
    if (!_authorize(request)) {
      await _respond(request, 401, 'PIN 不正确');
      return;
    }
    final content = _exportBackup();
    final bytes = utf8.encode(content);
    if (bytes.length > _lanMaxBackupBytes) {
      await _respond(request, 413, '备份文件不能超过 5 MB');
      return;
    }
    final response = request.response;
    response.headers.set('Content-Type', 'application/json; charset=utf-8');
    response.headers.set(
      'Content-Disposition',
      'attachment; filename="kuzai-music-backup.json"',
    );
    response.headers.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  Future<void> _receiveRestore(HttpRequest request) async {
    if (!_authorize(request)) {
      await _respond(request, 401, 'PIN 不正确');
      return;
    }
    if (request.headers.contentLength > _lanMaxBackupBytes) {
      await _respond(request, 413, '备份文件不能超过 5 MB');
      return;
    }
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 20))) {
      bytes.addAll(chunk);
      if (bytes.length > _lanMaxBackupBytes) {
        await _respond(request, 413, '备份文件不能超过 5 MB');
        return;
      }
    }
    late final String raw;
    try {
      raw = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      await _respond(request, 400, '上传内容不是有效的 UTF-8 文本');
      return;
    }
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map && parsed is! List) throw const FormatException();
    } on FormatException {
      await _respond(request, 400, '上传内容不是有效的 JSON 备份');
      return;
    }
    if (!_restoreCompleter.isCompleted) _restoreCompleter.complete(raw);
    await _respond(request, 200, '上传成功，请回到车机选择合并或覆盖。');
  }

  bool _authorize(HttpRequest request) {
    final supplied = request.uri.queryParameters['pin'] ?? '';
    if (!LanBackupService.isValidPin(supplied) ||
        supplied.length != pin.length) {
      return false;
    }
    var different = 0;
    for (var i = 0; i < pin.length; i++) {
      different |= supplied.codeUnitAt(i) ^ pin.codeUnitAt(i);
    }
    return different == 0;
  }

  Future<void> _respond(HttpRequest request, int status, String message) async {
    try {
      final response = request.response;
      response.statusCode = status;
      response.headers.set('Content-Type', 'text/plain; charset=utf-8');
      response.write(message);
      await response.close();
    } catch (_) {
      // The phone can disconnect while a response is being written. The
      // request is already over, so there is nothing useful to propagate.
    }
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _expiryTimer.cancel();
    // Wake any page waiting for a phone upload so the session and its
    // callback closure can be collected after timeout or route disposal.
    if (!_restoreCompleter.isCompleted) _restoreCompleter.complete(null);
    try {
      await _server.close(force: true);
    } catch (_) {
      // The socket may already be closed by the platform or Activity teardown.
    }
  }
}
