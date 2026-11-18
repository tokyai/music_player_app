import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// QingMusic v1.4.1 公开客户端请求协议，SHIXIAOYANG，2026/11/18。
///
/// 签名参数来自公开发行包，不包含用户的个人 API Key 或卡密。
class QingGatewayAuth {
  static const _clientKey = 'qm-gw-7c1f4e9a2b8d5360e1a7c4f9b2d8036c';
  static const _appId = 'qingmusic-android';
  static const _version = '1.4.1';
  static const _versionCode = '25';
  static const _package = 'com.qingmusic.changqing';

  /// 是否为已确认的官方 HTTPS 解析入口，防止认证头发送到自定义服务。
  static bool supports(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      !uri.hasFragment &&
      const {'musicserver.haitangw.cc', 'qt.haitangw.net'}.contains(uri.host) &&
      uri.path == '/v1/music/resolve-url';

  /// 生成当前 API 实例使用的匿名设备标识，不关联用户账号。
  static String createDeviceId() => 'qt-${_randomHex()}';

  /// 为实际发送的 [body] 生成认证头；[uri] 的路径参与签名。
  ///
  /// [deviceId] 在同一 API 实例内保持不变。[time]、[nonce] 可固定以核对
  /// 协议样例，正常请求使用当前时间和安全随机 nonce。
  static Map<String, String> headersFor(
    Uri uri,
    String body, {
    required String deviceId,
    DateTime? time,
    String? nonce,
  }) {
    if (!supports(uri)) return const {};
    // 请求头只接受有限长度的单行 ASCII，拒绝无效设备标识。
    if (deviceId.isEmpty ||
        deviceId.length > 256 ||
        RegExp(r'[^\x21-\x7e]').hasMatch(deviceId)) {
      throw const FormatException('QingMusic 设备标识无效');
    }
    final requestNonce = nonce ?? _randomHex();
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(requestNonce)) {
      throw const FormatException('QingMusic nonce 无效');
    }

    // 毫秒时间戳及六行基串与最新包一致，query 不参与路径签名。
    final timestamp = (time ?? DateTime.now()).millisecondsSinceEpoch
        .toString();
    final bodyHash = sha256.convert(utf8.encode(body)).toString();
    final signatureText = [
      _appId,
      timestamp,
      requestNonce,
      'POST',
      uri.path,
      bodyHash,
    ].join('\n');
    final signature = Hmac(
      sha256,
      utf8.encode(_clientKey),
    ).convert(utf8.encode(signatureText)).toString();

    // 每次请求使用新 nonce；仅返回认证参数，不保留响应或启动刷新任务。
    return {
      'X-Qing-App-Id': _appId,
      'X-Qing-App-Version': _version,
      'X-Qing-App-Version-Code': _versionCode,
      'X-Qing-App-Package': _package,
      'X-Qing-Device-Id': deviceId,
      'X-Qing-Ts': timestamp,
      'X-Qing-Nonce': requestNonce,
      'X-Qing-Sign': signature,
    };
  }

  static String _randomHex() {
    // 生成固定 16 字节，不在安全随机失败时退回弱随机。
    final random = Random.secure();
    final parts = <String>[];
    for (var index = 0; index < 16; index++) {
      parts.add(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return parts.join();
  }
}
