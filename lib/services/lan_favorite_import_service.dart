import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'batch_favorite_import_service.dart';

const _sessionDuration = Duration(minutes: 10);
const _maxPayloadBytes = 16 * 1024;
const _maxSongNameLength = 100;

/// A short-lived LAN page that receives a bounded list of song names.
class LanFavoriteImportService {
  const LanFavoriteImportService._();

  static Future<LanFavoriteImportSession> start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    LanFavoriteImportSession? session;
    try {
      final host = await _findLanAddress(server);
      session = LanFavoriteImportSession._(
        server: server,
        host: host,
        token: _randomToken(),
      );
      session._listen();
      return session;
    } catch (_) {
      if (session != null) {
        await session.stop();
      } else {
        try {
          await server.close(force: true);
        } catch (_) {}
      }
      rethrow;
    }
  }

  static List<String> parseSongNames(String value) {
    final names = <String>[];
    final seen = <String>{};
    for (final raw in value.split('、')) {
      final name = raw.trim();
      if (name.isEmpty) continue;
      if (name.runes.length > _maxSongNameLength) {
        throw const FormatException('单个歌曲名不能超过 100 个字符');
      }
      final key = name.toLowerCase().replaceAll(RegExp(r'\s+'), '');
      if (seen.add(key)) names.add(name);
      if (names.length > BatchFavoriteImportService.maxSongCount) {
        throw const FormatException('一次最多导入 30 首歌曲');
      }
    }
    if (names.isEmpty) throw const FormatException('请输入至少一个歌曲名');
    return List.unmodifiable(names);
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

class LanFavoriteImportSession {
  final HttpServer _server;
  final String _token;
  final Completer<List<String>?> _songsCompleter = Completer<List<String>?>();
  late final Timer _expiryTimer;
  StreamSubscription<HttpRequest>? _subscription;
  final String host;
  bool _receiving = false;
  bool _stopped = false;

  LanFavoriteImportSession._({
    required HttpServer server,
    required String token,
    required this.host,
  }) : _server = server,
       _token = token {
    _expiryTimer = Timer(_sessionDuration, () => unawaited(stop()));
  }

  String get url => 'http://$host:${_server.port}/$_token/';
  Future<List<String>?> get receivedSongNames => _songsCompleter.future;
  bool get isActive => !_stopped;

  void _listen() {
    _subscription = _server.listen(
      _handleRequest,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (_stopped) {
      await _respond(request, HttpStatus.gone, '本次批量收藏已结束');
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
        await _receiveSongNames(request);
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
<meta name="referrer" content="no-referrer"><title>库仔音乐批量收藏</title><style>
body{font-family:system-ui,-apple-system,"Microsoft Yahei",sans-serif;max-width:600px;margin:0 auto;padding:24px;line-height:1.6;color:#20242b;background:#f7f8fa}
main{background:#fff;border:1px solid #e3e7ec;border-radius:12px;padding:24px;box-shadow:0 4px 16px #00000012}h1{font-size:22px;margin-top:0}
label{display:block;font-weight:600;margin:14px 0 6px}textarea,button{font:inherit;box-sizing:border-box;width:100%;padding:12px;border:1px solid #d8dde5;border-radius:8px}textarea{min-height:150px;resize:vertical}button{background:#2196f3;color:#fff;border:0;font-weight:700;margin-top:12px}.status{margin-top:14px;white-space:pre-wrap;color:#454b54}small{display:block;margin-top:18px;color:#686f79}
</style></head><body><main><h1>批量加入收藏歌曲</h1><p>歌曲之间使用“、”连接，一次最多 30 首。</p>
<label for="songs">歌曲名</label><textarea id="songs" maxlength="8000" placeholder="倒带、七里香、半岛铁盒"></textarea>
<button id="submit" onclick="submitSongs()">发送到车机并加入收藏</button><div id="status" class="status"></div>
<small>手机与车机需连接同一个 Wi-Fi。车机会依次从 QQ音乐、网易云和酷狗匹配同名歌曲。</small></main><script>
const input=document.getElementById('songs'),button=document.getElementById('submit'),status=document.getElementById('status');
async function submitSongs(){const value=input.value.trim(),names=value.split('、').map(v=>v.trim()).filter(Boolean);if(!names.length){status.textContent='请输入歌曲名';return;}if(names.length>30){status.textContent='一次最多导入 30 首歌曲';return;}button.disabled=true;status.textContent='正在发送…';try{const response=await fetch('submit',{method:'POST',headers:{'Content-Type':'text/plain;charset=UTF-8'},body:value});status.textContent=await response.text();if(response.ok){input.disabled=true;}else{button.disabled=false;}}catch(error){button.disabled=false;status.textContent='发送失败：'+error;}}
</script></body></html>''';
    final response = request.response;
    response.headers.set('Content-Type', 'text/html; charset=utf-8');
    response.headers.set('Cache-Control', 'no-store');
    response.write(html);
    await response.close();
  }

  Future<void> _receiveSongNames(HttpRequest request) async {
    if (_songsCompleter.isCompleted || _receiving) {
      await _respond(request, HttpStatus.conflict, '本次歌曲列表已经提交');
      return;
    }
    if (request.headers.contentLength > _maxPayloadBytes) {
      await _respond(request, HttpStatus.requestEntityTooLarge, '歌曲列表内容过长');
      return;
    }

    _receiving = true;
    try {
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > _maxPayloadBytes) {
          await _respond(request, HttpStatus.requestEntityTooLarge, '歌曲列表内容过长');
          return;
        }
      }
      late final String value;
      try {
        value = utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        await _respond(request, HttpStatus.badRequest, '歌曲列表编码无效');
        return;
      }
      late final List<String> names;
      try {
        names = LanFavoriteImportService.parseSongNames(value);
      } on FormatException catch (error) {
        await _respond(
          request,
          HttpStatus.badRequest,
          error.message.toString(),
        );
        return;
      }
      if (_stopped) {
        await _respond(request, HttpStatus.gone, '本次批量收藏已结束');
        return;
      }
      _songsCompleter.complete(names);
      await _respond(request, HttpStatus.ok, '发送成功，车机正在匹配并加入收藏');
    } finally {
      _receiving = false;
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
    if (!_songsCompleter.isCompleted) _songsCompleter.complete(null);
    final subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {
      // Closing the server below remains the authoritative socket cleanup.
    }
    try {
      await _server.close(force: true);
    } catch (_) {
      // The socket may already be closed by the platform or Activity teardown.
    }
  }
}
