import 'dart:io';

/// 原生框架部署身份，不含任何服务器登录凭据。SHIXIAOYANG，2026/11/19。
class RuntimeConfig {
  static const enabled = bool.fromEnvironment(
    'REMOTE_RUNTIME_ENABLED',
    defaultValue: true,
  );
  static const frameworkVersion = 1;
  static const baseUrl = 'https://137.175.62.3:9443/';
  static const certificateSha256 =
      'A00512C4A3D90BFC8D3540C7CAD547FDC060D9E24321A634C06627BD093FDAAF';
  static const publicKeyBase64 = String.fromEnvironment(
    'RUNTIME_PUBLIC_KEY',
    defaultValue: 'ms6EKQj4Rd9CuRDUVvjGrToKNHHT80yog/tMtqw+Pb8=',
  );
  static const maxBundleBytes = 12 * 1024 * 1024;

  // 桌面端继续使用原有页面；手机端的实际平台判断不会受测试主题覆盖影响。
  static bool get useRemote =>
      enabled && (Platform.isAndroid || Platform.isIOS);
}
