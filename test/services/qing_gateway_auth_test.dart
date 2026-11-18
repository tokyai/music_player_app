import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/services/qing_gateway_auth.dart';

/// 最新包签名协议与请求头边界，SHIXIAOYANG，2026/11/18。
void main() {
  final uri = Uri.parse('https://musicserver.haitangw.cc/v1/music/resolve-url');
  final body = jsonEncode({'source': 'wy', 'rid': '347230', 'level': 'exhigh'});
  final time = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  const nonce = '00112233445566778899aabbccddeeff';

  test('matches the independently calculated latest-package signature', () {
    // 样例摘要由最新包的基串和独立 Node HMAC 实现预先计算。
    final headers = QingGatewayAuth.headersFor(
      uri,
      body,
      deviceId: 'sample-device',
      time: time,
      nonce: nonce,
    );
    expect(
      headers['X-Qing-Sign'],
      'db45107cfd8d12c28119e204ba072dbbed264d788971225f2bb9e697bdc01323',
    );
    expect(headers['X-Qing-Ts'], '1700000000000');
    expect(headers['X-Qing-App-Version-Code'], '25');
    expect(headers['X-Qing-App-Package'], 'com.qingmusic.changqing');
  });

  test('binds the body and excludes query values from the signed path', () {
    // 同一基串只忽略 query；任何 JSON 字节变化都必须改变签名。
    final original = QingGatewayAuth.headersFor(
      uri,
      body,
      deviceId: 'sample-device',
      time: time,
      nonce: nonce,
    );
    final query = QingGatewayAuth.headersFor(
      uri.replace(query: 'tenant=a'),
      body,
      deviceId: 'sample-device',
      time: time,
      nonce: nonce,
    );
    final changed = QingGatewayAuth.headersFor(
      uri,
      '$body ',
      deviceId: 'sample-device',
      time: time,
      nonce: nonce,
    );
    expect(query['X-Qing-Sign'], original['X-Qing-Sign']);
    expect(changed['X-Qing-Sign'], isNot(original['X-Qing-Sign']));
  });

  test('never signs custom origins or ambiguous gateway URLs', () {
    // 自定义接口继续原来的 POST 契约，不附带官方网关认证头。
    final rejected = [
      'https://custom.test/v1/music/resolve-url',
      'http://musicserver.haitangw.cc/v1/music/resolve-url',
      'https://musicserver.haitangw.cc.evil.test/v1/music/resolve-url',
      'https://musicserver.haitangw.cc:4443/v1/music/resolve-url',
      'https://user:pass@musicserver.haitangw.cc/v1/music/resolve-url',
      'https://musicserver.haitangw.cc/v1/music/resolve-url#fragment',
    ];
    for (final address in rejected) {
      expect(
        QingGatewayAuth.headersFor(
          Uri.parse(address),
          body,
          deviceId: 'sample-device',
        ),
        isEmpty,
      );
    }
    expect(
      QingGatewayAuth.supports(
        Uri.parse('https://qt.haitangw.net/v1/music/resolve-url'),
      ),
      isTrue,
    );
  });

  test('uses a fresh secure nonce for each request', () {
    // 同一设备每次生成新 nonce，状态只保留一个匿名设备标识。
    final device = QingGatewayAuth.createDeviceId();
    final first = QingGatewayAuth.headersFor(uri, body, deviceId: device);
    final second = QingGatewayAuth.headersFor(uri, body, deviceId: device);
    expect(device, matches(r'^qt-[a-f0-9]{32}$'));
    expect(first['X-Qing-Device-Id'], second['X-Qing-Device-Id']);
    expect(first['X-Qing-Nonce'], isNot(second['X-Qing-Nonce']));
  });

  test('rejects invalid header inputs before making a native request', () {
    // 非法输入在计算阶段失败，不进入原生 HTTP 请求头。
    expect(
      () => QingGatewayAuth.headersFor(uri, body, deviceId: 'id\r\nvalue'),
      throwsFormatException,
    );
    expect(
      () => QingGatewayAuth.headersFor(
        uri,
        body,
        deviceId: 'sample-device',
        nonce: 'invalid',
      ),
      throwsFormatException,
    );
  });
}
