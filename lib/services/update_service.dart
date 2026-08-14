import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// 更新信息（对应服务器 update.json 的字段）。
class UpdateInfo {
  final String versionName;
  final int versionCode;
  final String apkUrl;
  final int apkSize;
  final String md5;
  final String sha256;
  final bool forceUpdate;
  final String updateLog;
  final String publishTime;

  UpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.apkUrl,
    required this.apkSize,
    required this.md5,
    required this.sha256,
    required this.forceUpdate,
    required this.updateLog,
    required this.publishTime,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      versionName: (json['versionName'] as String?) ?? '',
      versionCode: _toInt(json['versionCode']),
      apkUrl: (json['apkUrl'] as String?) ?? '',
      apkSize: _toInt(json['apkSize']),
      md5: (json['md5'] as String?)?.toLowerCase() ?? '',
      sha256: (json['sha256'] as String?)?.toLowerCase() ?? '',
      forceUpdate: (json['forceUpdate'] as bool?) ?? false,
      updateLog: (json['updateLog'] ?? json['updateContent'])?.toString() ?? '',
      publishTime: (json['publishTime'] as String?) ?? '',
    );
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

/// 在线更新服务：拉取更新信息、下载 APK、调用系统安装。
class UpdateService {
  /// 服务器更新描述文件地址（momo 站点 IP 下的 /music 路径别名）。
  static const String updateUrl = 'http://161.118.252.183/music/update.json';

  /// 检查是否有新版本。
  /// 返回 [UpdateInfo] 表示有新版本；返回 null 表示已是最新或请求失败。
  static Future<UpdateInfo?> checkUpdate({
    String? currentVersionCode,
    bool throwOnError = false,
  }) async {
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 12),
        ),
      );
      final resp = await dio.get<Map<String, dynamic>>(updateUrl);
      if (resp.statusCode != 200 || resp.data == null) {
        throw Exception('更新服务返回异常');
      }
      final info = UpdateInfo.fromJson(resp.data!);
      final apkUri = Uri.tryParse(info.apkUrl);
      if (info.versionCode <= 0 ||
          info.versionName.isEmpty ||
          apkUri == null ||
          !apkUri.hasAuthority ||
          (apkUri.scheme != 'http' && apkUri.scheme != 'https')) {
        throw Exception('更新信息格式错误');
      }

      final int localCode;
      if (currentVersionCode != null) {
        localCode = int.tryParse(currentVersionCode) ?? 0;
      } else {
        final pkg = await PackageInfo.fromPlatform();
        localCode = int.tryParse(pkg.buildNumber) ?? 0;
      }

      if (info.versionCode > localCode) return info;
      return null;
    } catch (_) {
      if (throwOnError) rethrow;
      // 网络异常时静默失败，不影响主流程。
      return null;
    }
  }

  /// 下载 APK 到应用外部存储目录下的 updates 文件夹，返回本地文件路径。
  static Future<String> downloadApk(
    UpdateInfo info,
    ProgressCallback onProgress,
  ) async {
    final dir = await getExternalStorageDirectory();
    if (dir == null) {
      throw Exception('无法获取外部存储目录');
    }
    final saveDir = Directory('${dir.path}/updates');
    if (!await saveDir.exists()) {
      await saveDir.create(recursive: true);
    }
    final safeVersion = info.versionName.replaceAll(
      RegExp(r'[^0-9A-Za-z._-]'),
      '_',
    );
    final filePath = '${saveDir.path}/music_player_$safeVersion.apk';
    final file = File(filePath);
    if (await file.exists()) await file.delete();
    final partialFile = File('$filePath.part');
    if (await partialFile.exists()) await partialFile.delete();

    try {
      await Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(minutes: 5),
        ),
      ).download(
        info.apkUrl,
        partialFile.path,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress(received, total);
        },
      );

      final actualSize = await partialFile.length();
      if (info.apkSize > 0 && actualSize != info.apkSize) {
        throw Exception('安装包大小校验失败');
      }
      if (info.sha256.isNotEmpty) {
        await _verifyDigest(partialFile, sha256, info.sha256, 'SHA-256');
      } else if (info.md5.isNotEmpty) {
        await _verifyDigest(partialFile, md5, info.md5, 'MD5');
      }

      await partialFile.rename(filePath);
    } catch (_) {
      if (await partialFile.exists()) await partialFile.delete();
      rethrow;
    }
    return filePath;
  }

  static Future<void> _verifyDigest(
    File file,
    Hash algorithm,
    String expected,
    String label,
  ) async {
    final actual = (await algorithm.bind(file.openRead()).first).toString();
    if (actual.toLowerCase() != expected.toLowerCase()) {
      throw Exception('安装包 $label 校验失败');
    }
  }

  /// 调用系统安装器安装 APK。
  /// 原生侧会校验包名、版本号和签名证书，再交给系统安装器。
  static const MethodChannel _installChannel =
      MethodChannel('music_player/install');

  static Future<void> installApk(
    String filePath, {
    required int versionCode,
  }) async {
    try {
      await _installChannel.invokeMethod('installApk', {
        'path': filePath,
        'versionCode': versionCode,
      });
    } on PlatformException catch (e) {
      throw Exception('安装失败：${e.message ?? e.code}');
    } on MissingPluginException {
      throw Exception('安装组件未就绪，请重启应用后重试');
    }
  }
}
