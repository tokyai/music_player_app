import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'user_data_scope.dart';

/// 业务包自己的有界存储，凭据单独进入系统安全存储。SHIXIAOYANG，2026/11/19。
class RuntimePreferences {
  static const _storage = FlutterSecureStorage();
  static const _valueKey = 'remote_business_v1';
  static const credentialsKey = 'remote_business_credentials_v1';
  final UserDataScope scope;

  const RuntimePreferences(this.scope);

  Map<String, dynamic> _decode(String? value) {
    if (value == null || value.isEmpty) return {};
    if (value.length > 64 * 1024) throw const FormatException('业务配置过大');
    final data = jsonDecode(value);
    if (data is! Map) throw const FormatException('业务配置格式无效');
    return Map<String, dynamic>.from(data);
  }

  /// 读取当前用户的业务状态；不允许访问其他应用偏好键。
  Future<Map<String, dynamic>> read() async {
    if (scope.isDeleted) throw StateError('用户已删除');
    final prefs = await SharedPreferences.getInstance();
    return _decode(prefs.getString(scope.preferenceKey(_valueKey)));
  }

  /// 替换业务状态，先完成编码及大小校验再落盘。
  Future<void> write(Map<String, dynamic> values) async {
    final encoded = jsonEncode(values);
    if (utf8.encode(encoded).length > 64 * 1024) {
      throw const FormatException('业务配置超过 64 KB');
    }
    final prefs = await SharedPreferences.getInstance();
    if (scope.isDeleted) throw StateError('用户已删除');
    if (!await prefs.setString(scope.preferenceKey(_valueKey), encoded)) {
      throw StateError('保存业务配置失败');
    }
  }

  /// 凭据只供固定 HTTPS 服务使用，不写入普通偏好或日志。
  Future<Map<String, dynamic>> credentials() async {
    if (scope.isDeleted) throw StateError('用户已删除');
    return _decode(
      await _storage.read(key: scope.secureStorageKey(credentialsKey)),
    );
  }

  /// 保存个人线路凭据；安全存储失败时直接报告，不回退成明文。
  Future<void> writeCredentials(Map<String, dynamic> values) async {
    if (values.length > 16) throw const FormatException('凭据数量过多');
    for (final entry in values.entries) {
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(entry.key) ||
          entry.value is! String ||
          (entry.value as String).length > 2048) {
        throw const FormatException('线路凭据格式无效');
      }
    }
    if (scope.isDeleted) throw StateError('用户已删除');
    await _storage.write(
      key: scope.secureStorageKey(credentialsKey),
      value: jsonEncode(values),
    );
  }
}
