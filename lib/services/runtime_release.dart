import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'runtime_config.dart';

/// 已验证发布者身份的业务版本描述。SHIXIAOYANG，2026/11/19。
class RuntimeRelease {
  final String id;
  final int version;
  final int minimumFramework;
  final String bundlePath;
  final int bundleBytes;
  final String bundleSha256;
  final String notes;
  final List<int> envelopeBytes;
  const RuntimeRelease({
    required this.id,
    required this.version,
    required this.minimumFramework,
    required this.bundlePath,
    required this.bundleBytes,
    required this.bundleSha256,
    required this.notes,
    required this.envelopeBytes,
  });

  /// 先校验原始签名字节，再读取版本和资源位置；公钥只来自原生框架。
  static Future<RuntimeRelease> verify(
    List<int> envelopeBytes, {
    String? publicKey,
  }) async {
    if (envelopeBytes.length > 64 * 1024) throw const FormatException('版本描述过大');
    final envelope = jsonDecode(utf8.decode(envelopeBytes));
    if (envelope is! Map ||
        envelope['payload'] is! String ||
        envelope['signature'] is! String) {
      throw const FormatException('版本签名格式无效');
    }
    final payload = base64Decode(envelope['payload'] as String);
    final signature = base64Decode(envelope['signature'] as String);
    final key = base64Decode(publicKey ?? RuntimeConfig.publicKeyBase64);
    if (payload.length > 32 * 1024 ||
        signature.length != 64 ||
        key.length != 32) {
      throw const FormatException('发布者签名参数无效');
    }
    final valid = await Ed25519().verify(
      payload,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) throw const FormatException('业务包签名不可信');

    // 版本号单调增加，资源路径限定在该版本目录。
    final data = jsonDecode(utf8.decode(payload));
    if (data is! Map ||
        data['schema'] != 1 ||
        data['id'] is! String ||
        data['version'] is! int ||
        data['minimumFramework'] is! int ||
        data['bundleBytes'] is! int) {
      throw const FormatException('版本描述字段无效');
    }
    final id = data['id'] as String;
    final version = data['version'] as int;
    final bytes = data['bundleBytes'] as int;
    final minimumFramework = data['minimumFramework'] as int;
    final notes = data['notes'];
    final digest = data['bundleSha256']?.toString() ?? '';
    if (!RegExp(r'^r[0-9]{6,12}$').hasMatch(id) ||
        version < 1 ||
        id != 'r${version.toString().padLeft(6, '0')}' ||
        minimumFramework < 1 ||
        minimumFramework > 1000000 ||
        (notes != null && (notes is! String || notes.length > 2048)) ||
        data['bundlePath'] != 'releases/$id/bundle.json' ||
        bytes < 1 ||
        bytes > RuntimeConfig.maxBundleBytes ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('业务包大小或路径无效');
    }
    return RuntimeRelease(
      id: id,
      version: version,
      minimumFramework: minimumFramework,
      bundlePath: data['bundlePath'] as String,
      bundleBytes: bytes,
      bundleSha256: digest,
      notes: notes as String? ?? '',
      envelopeBytes: List<int>.unmodifiable(envelopeBytes),
    );
  }
}
