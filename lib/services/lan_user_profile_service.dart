import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../models/app_user.dart';
import 'user_avatar_storage.dart';

const _userProfileSessionDuration = Duration(minutes: 10);
const _maxUserProfileBodyBytes = 560 * 1024;

class LanUserProfileSubmission {
  final String name;
  final Uint8List? avatarBytes;

  const LanUserProfileSubmission({required this.name, this.avatarBytes});
}

/// A short-lived LAN page for entering a user name and optional avatar.
class LanUserProfileService {
  const LanUserProfileService._();

  static Future<LanUserProfileSession> start({String initialName = ''}) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final host = await _findLanAddress(server);
    final session = LanUserProfileSession._(
      server: server,
      host: host,
      token: _randomToken(),
      initialName: initialName,
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

class LanUserProfileSession {
  final HttpServer _server;
  final String _token;
  final String _initialName;
  final Completer<LanUserProfileSubmission?> _submissionCompleter =
      Completer<LanUserProfileSubmission?>();
  late final Timer _expiryTimer;
  final String host;
  bool _stopped = false;

  LanUserProfileSession._({
    required HttpServer server,
    required String token,
    required String initialName,
    required this.host,
  }) : _server = server,
       _token = token,
       _initialName = initialName {
    _expiryTimer = Timer(_userProfileSessionDuration, () {
      unawaited(stop());
    });
  }

  String get url => 'http://$host:${_server.port}/$_token/';
  Future<LanUserProfileSubmission?> get receivedSubmission =>
      _submissionCompleter.future;
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
        await _receiveSubmission(request);
      } else {
        await _respond(request, HttpStatus.notFound, '请求不存在');
      }
    } on TimeoutException {
      await _respond(request, HttpStatus.requestTimeout, '上传超时，请重试');
    } catch (_) {
      await _respond(request, HttpStatus.internalServerError, '提交失败，请重试');
    }
  }

  Future<void> _serveHome(HttpRequest request) async {
    final initialName = const HtmlEscape(
      HtmlEscapeMode.attribute,
    ).convert(_initialName);
    final html =
        '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><title>库仔音乐用户资料</title><style>
body{font-family:system-ui,-apple-system,"Microsoft Yahei",sans-serif;max-width:560px;margin:0 auto;padding:20px;line-height:1.55;color:#20242b;background:#f3f5f7}
main{background:#fff;border:1px solid #dfe4e9;border-radius:12px;padding:22px;box-shadow:0 5px 18px #00000012}h1{font-size:22px;margin:0 0 8px}p{margin:0 0 16px;color:#59616b}
label{display:block;font-weight:650;margin:14px 0 7px}input,button{font:inherit;box-sizing:border-box;width:100%;padding:12px;border:1px solid #ccd3db;border-radius:8px}
input[type=file]{padding:10px;background:#fafbfc}button{background:#24745f;color:#fff;border:0;font-weight:700;margin-top:18px;min-height:48px}button:disabled{opacity:.55}
.preview{display:none;width:112px;height:112px;border-radius:56px;object-fit:cover;margin:12px auto 0;border:3px solid #e5e9ed}.status{margin-top:14px;white-space:pre-wrap;color:#454b54}small{display:block;margin-top:18px;color:#69717b}
</style></head><body><main><h1>设置用户资料</h1><p>填写名称，并可从手机相册选择一张头像。</p>
<label for="name">用户名称</label><input id="name" maxlength="20" value="$initialName" autocomplete="name" placeholder="请输入用户名称">
<label for="avatar">头像（可选）</label><input id="avatar" type="file" accept="image/*"><img id="preview" class="preview" alt="头像预览">
<button id="submit" onclick="submitProfile()">发送到车机</button><div id="status" class="status"></div>
<small>未选择新头像时，车机会保留当前头像。手机与车机需连接同一个 Wi-Fi，本页面约 10 分钟后失效。</small></main><script>
const nameInput=document.getElementById('name'),avatarInput=document.getElementById('avatar'),preview=document.getElementById('preview'),button=document.getElementById('submit'),status=document.getElementById('status');let previewUrl='';
avatarInput.addEventListener('change',()=>{if(previewUrl)URL.revokeObjectURL(previewUrl);const file=avatarInput.files[0];if(!file){preview.style.display='none';return;}previewUrl=URL.createObjectURL(file);preview.src=previewUrl;preview.style.display='block';});
function loadImage(file){return new Promise((resolve,reject)=>{const url=URL.createObjectURL(file),image=new Image();image.onload=()=>{URL.revokeObjectURL(url);resolve(image);};image.onerror=()=>{URL.revokeObjectURL(url);reject(new Error('无法读取所选图片'));};image.src=url;});}
function toJpeg(canvas){return new Promise((resolve,reject)=>canvas.toBlob(blob=>blob?resolve(blob):reject(new Error('头像压缩失败')),'image/jpeg',0.84));}
function toBase64(blob){return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(String(reader.result).split(',')[1]||'');reader.onerror=()=>reject(new Error('头像编码失败'));reader.readAsDataURL(blob);});}
async function prepareAvatar(file){if(!file)return '';if(file.size>12*1024*1024)throw new Error('原始图片不能超过 12 MB');const image=await loadImage(file),side=Math.min(image.naturalWidth,image.naturalHeight),output=Math.max(1,Math.min(512,side)),sourceX=(image.naturalWidth-side)/2,sourceY=(image.naturalHeight-side)/2,canvas=document.createElement('canvas');canvas.width=output;canvas.height=output;const context=canvas.getContext('2d',{alpha:false});context.fillStyle='#fff';context.fillRect(0,0,output,output);context.drawImage(image,sourceX,sourceY,side,side,0,0,output,output);const jpeg=await toJpeg(canvas);if(jpeg.size>384*1024)throw new Error('压缩后的头像过大，请换一张图片');return toBase64(jpeg);}
async function submitProfile(){const name=nameInput.value.trim();if(!name){status.textContent='请输入用户名称';return;}button.disabled=true;status.textContent='正在处理头像…';try{const avatarBase64=await prepareAvatar(avatarInput.files[0]);status.textContent='正在发送…';const response=await fetch('submit',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name,avatarMimeType:avatarBase64?'image/jpeg':'',avatarBase64})});status.textContent=await response.text();if(response.ok){nameInput.disabled=true;avatarInput.disabled=true;}else{button.disabled=false;}}catch(error){button.disabled=false;status.textContent=String(error.message||error);}}
</script></body></html>''';
    final response = request.response;
    response.headers.set('Content-Type', 'text/html; charset=utf-8');
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set(
      'Content-Security-Policy',
      "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src blob: data:; connect-src 'self'; base-uri 'none'",
    );
    response.write(html);
    await response.close();
  }

  Future<void> _receiveSubmission(HttpRequest request) async {
    if (_submissionCompleter.isCompleted) {
      await _respond(request, HttpStatus.conflict, '本次用户资料已经提交');
      return;
    }
    if (request.headers.contentType?.mimeType != 'application/json') {
      await _respond(request, HttpStatus.unsupportedMediaType, '提交格式无效');
      return;
    }
    if (request.headers.contentLength > _maxUserProfileBodyBytes) {
      await _respond(request, HttpStatus.requestEntityTooLarge, '用户资料内容过大');
      return;
    }
    final body = BytesBuilder(copy: false);
    await for (final chunk in request.timeout(const Duration(seconds: 25))) {
      body.add(chunk);
      if (body.length > _maxUserProfileBodyBytes) {
        await _respond(request, HttpStatus.requestEntityTooLarge, '用户资料内容过大');
        return;
      }
    }

    try {
      final decoded = jsonDecode(
        utf8.decode(body.takeBytes(), allowMalformed: false),
      );
      if (decoded is! Map) throw const FormatException('用户资料格式无效');
      final data = Map<String, dynamic>.from(decoded);
      final name = AppUserProfile.normalizeName(data['name']?.toString() ?? '');
      final encodedAvatar = data['avatarBase64']?.toString() ?? '';
      Uint8List? avatarBytes;
      if (encodedAvatar.isNotEmpty) {
        if (data['avatarMimeType'] != 'image/jpeg') {
          throw const FormatException('头像格式必须为 JPEG');
        }
        const maxEncodedLength =
            ((UserAvatarStorage.maxAvatarBytes + 2) ~/ 3) * 4;
        if (encodedAvatar.length > maxEncodedLength) {
          throw const FormatException('头像文件过大');
        }
        avatarBytes = base64Decode(encodedAvatar);
        UserAvatarStorage.validateJpeg(avatarBytes);
      }
      if (_submissionCompleter.isCompleted) {
        await _respond(request, HttpStatus.conflict, '本次用户资料已经提交');
        return;
      }
      _submissionCompleter.complete(
        LanUserProfileSubmission(name: name, avatarBytes: avatarBytes),
      );
      await _respond(request, HttpStatus.ok, '发送成功，请在车机上确认并保存');
    } on FormatException catch (error) {
      await _respond(request, HttpStatus.badRequest, '用户资料无效：${error.message}');
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
      response.headers.set('X-Content-Type-Options', 'nosniff');
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
    if (!_submissionCompleter.isCompleted) _submissionCompleter.complete(null);
    try {
      await _server.close(force: true);
    } catch (_) {
      // The socket may already be closed during Activity teardown.
    }
  }
}
