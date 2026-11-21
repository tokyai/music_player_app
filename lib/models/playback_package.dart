import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import 'remote_playback.dart';

/// 解析包发布者签署的清单，SHIXIAOYANG，2026/11/21。
class PlaybackPackageManifest {
  static const publicKeyBase64 = 'ms6EKQj4Rd9CuRDUVvjGrToKNHHT80yog/tMtqw+Pb8=';
  static const maxManifestBytes = 64 * 1024;
  static const maxPackageBytes = 1024 * 1024;
  static const bridgeVersion = 1;

  final int packageVersion;
  final int minimumBridgeVersion;
  final String packagePath;
  final String sha256Digest;
  final int bytes;
  final List<int> envelopeBytes;

  const PlaybackPackageManifest._({
    required this.packageVersion,
    required this.minimumBridgeVersion,
    required this.packagePath,
    required this.sha256Digest,
    required this.bytes,
    required this.envelopeBytes,
  });

  String get id => 'p${packageVersion.toString().padLeft(6, '0')}';

  /// 先验证发布者签名，再接受版本和下载地址，不信任服务端临时公钥。
  static Future<PlaybackPackageManifest> verify(
    List<int> bytes, {
    String publicKey = publicKeyBase64,
  }) async {
    // 在解码之前限制体积，避免未经验证的数据占用大量内存。
    if (bytes.isEmpty || bytes.length > maxManifestBytes) {
      throw const FormatException('解析包清单超过大小限制');
    }
    final envelope = jsonDecode(utf8.decode(bytes));
    if (envelope is! Map<String, dynamic> ||
        envelope['payloadBase64'] is! String ||
        envelope['signatureBase64'] is! String) {
      throw const FormatException('解析包签名格式无效');
    }
    final payload = base64Decode(envelope['payloadBase64'] as String);
    final signature = base64Decode(envelope['signatureBase64'] as String);
    final key = base64Decode(publicKey);
    if (payload.length > 32 * 1024 ||
        signature.length != 64 ||
        key.length != 32) {
      throw const FormatException('解析包签名参数无效');
    }
    final valid = await Ed25519().verify(
      payload,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) throw const FormatException('解析包发布者签名不可信');

    // 资源位置必须由版本号确定，拒绝目录穿越和协议不兼容的更新。
    final data = jsonDecode(utf8.decode(payload));
    if (data is! Map<String, dynamic> || data['packageFormat'] != 1) {
      throw const FormatException('解析包清单协议无效');
    }
    final version = data['packageVersion'];
    final minimum = data['minimumBridgeVersion'];
    final size = data['bytes'];
    final digest = data['sha256'];
    if (!validVersion(version) ||
        minimum is! int ||
        minimum < 1 ||
        minimum > bridgeVersion ||
        size is! int ||
        size < 1 ||
        size > maxPackageBytes ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('解析包版本、大小或摘要无效');
    }
    final id = 'p${(version as int).toString().padLeft(6, '0')}';
    final packagePath = data['packagePath'];
    if (packagePath != 'packages/$id.json') {
      throw const FormatException('解析包资源路径无效');
    }
    return PlaybackPackageManifest._(
      packageVersion: version,
      minimumBridgeVersion: minimum,
      packagePath: packagePath as String,
      sha256Digest: digest,
      bytes: size,
      envelopeBytes: Uint8List.fromList(bytes).asUnmodifiableView(),
    );
  }

  /// 本地状态及发布清单只接受有界正整数版本号。
  static bool validVersion(dynamic value) =>
      value is int && value >= 1 && value <= 999999999;
}

/// 不可变的已验证解析包，进行中解析可继续持有旧包。SHIXIAOYANG，2026/11/21。
class PlaybackPackage {
  final PlaybackPackageManifest manifest;
  final PlaybackSourceCatalog capabilities;
  final List<String> allowedOrigins;
  final String script;
  final List<int> packageBytes;

  const PlaybackPackage._({
    required this.manifest,
    required this.capabilities,
    required this.allowedOrigins,
    required this.script,
    required this.packageBytes,
  });

  int get packageVersion => manifest.packageVersion;
  int get minimumBridgeVersion => manifest.minimumBridgeVersion;

  /// 校验签名及实际包内容，原始清单和包字节均保留以便可靠落盘。
  static Future<PlaybackPackage> verify(
    List<int> envelopeBytes,
    List<int> packageBytes, {
    String publicKey = PlaybackPackageManifest.publicKeyBase64,
  }) async {
    final manifest = await PlaybackPackageManifest.verify(
      envelopeBytes,
      publicKey: publicKey,
    );
    return fromVerifiedManifest(manifest, packageBytes);
  }

  /// 使用已验签清单核对代码、能力及网络边界；不重复下载或访问服务器。
  static PlaybackPackage fromVerifiedManifest(
    PlaybackPackageManifest manifest,
    List<int> bytes,
  ) {
    // JSON的版本和摘要必须与清单一致，不能混用不同版本的代码和能力。
    if (bytes.length != manifest.bytes ||
        bytes.length > PlaybackPackageManifest.maxPackageBytes ||
        sha256.convert(bytes).toString() != manifest.sha256Digest) {
      throw const FormatException('解析包大小或摘要校验失败');
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic> ||
        data['packageFormat'] != 1 ||
        data['packageVersion'] != manifest.packageVersion ||
        data['minimumBridgeVersion'] != manifest.minimumBridgeVersion ||
        data['script'] is! String ||
        (data['script'] as String).trim().isEmpty ||
        data['capabilities'] is! Map<String, dynamic>) {
      throw const FormatException('解析包代码或能力协议无效');
    }
    final capabilities = PlaybackSourceCatalog.fromJson(
      data['capabilities'] as Map<String, dynamic>,
    );
    final rawOrigins = data['allowedOrigins'];
    if (rawOrigins is! List || rawOrigins.isEmpty || rawOrigins.length > 32) {
      throw const FormatException('解析包上游列表无效');
    }
    final origins = <String>[];
    for (final origin in rawOrigins) {
      final uri = origin is String ? Uri.tryParse(origin) : null;
      if (uri == null ||
          origin.length > 2048 ||
          !const ['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.path.isNotEmpty && uri.path != '/') ||
          origins.contains(uri.origin)) {
        throw const FormatException('解析包上游地址无效');
      }
      origins.add(uri.origin);
    }
    return PlaybackPackage._(
      manifest: manifest,
      capabilities: capabilities,
      allowedOrigins: List<String>.unmodifiable(origins),
      script: data['script'] as String,
      packageBytes: Uint8List.fromList(bytes).asUnmodifiableView(),
    );
  }
}
