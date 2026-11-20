import 'dart:convert';
import 'backup_service.dart';
import 'runtime_preferences.dart';
import 'user_data_scope.dart';

/// 远程业务状态与凭据的备份扩展，不将数据发送给更新服务器。SHIXIAOYANG，2026/11/20。
class RuntimeBackup {
  /// 在用户主动导出的现有备份中附加业务状态，整体仍受原备份大小上限约束。
  static Future<String> attach(
    String raw,
    List<UserDataScope> scopes, {
    required bool full,
  }) async {
    final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final snapshots = <String, dynamic>{};
    for (final scope in scopes) {
      final store = RuntimePreferences(scope);
      snapshots[scope.userId] = {
        'values': await store.read(),
        'credentials': await store.credentials(),
      };
    }
    data[full ? 'remoteBusinessUsers' : 'remoteBusiness'] = full
        ? snapshots
        : snapshots[scopes.single.userId];
    final encoded = const JsonEncoder.withIndent('  ').convert(data);
    if (utf8.encode(encoded).length > BackupService.maxBackupBytes) {
      throw const FormatException('备份超过大小上限');
    }
    return encoded;
  }

  static Map<String, dynamic> _snapshot(dynamic raw) {
    if (raw is! Map || raw['values'] is! Map || raw['credentials'] is! Map) {
      throw const FormatException('远程业务备份无效');
    }
    final values = Map<String, dynamic>.from(raw['values'] as Map);
    final secrets = Map<String, dynamic>.from(raw['credentials'] as Map);
    if (utf8.encode(jsonEncode(values)).length > 64 * 1024 ||
        secrets.length > 16) {
      throw const FormatException('远程业务备份过大');
    }
    for (final entry in secrets.entries) {
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(entry.key) ||
          entry.value is! String ||
          (entry.value as String).length > 2048) {
        throw const FormatException('远程业务备份凭据无效');
      }
    }
    return {'values': values, 'credentials': secrets};
  }

  /// 在预览阶段校验扩展，不让非法状态进入持久化流程。
  static Map<String, Map<String, dynamic>> inspect(
    String raw,
    UserDataScope current,
  ) {
    final parsed = jsonDecode(raw);
    if (parsed is! Map) return {};
    final result = <String, Map<String, dynamic>>{};
    if (parsed['remoteBusiness'] != null) {
      result[current.userId] = _snapshot(parsed['remoteBusiness']);
    }
    final users = parsed['remoteBusinessUsers'];
    if (users != null) {
      if (parsed['format'] != BackupService.fullSnapshotFormat ||
          users is! Map ||
          users.length > 32 ||
          parsed['users'] is! List) {
        throw const FormatException('全部用户业务备份无效');
      }
      final allowed = <String>{};
      for (final item in parsed['users'] as List) {
        if (item is Map &&
            item['profile'] is Map &&
            item['profile']['id'] is String) {
          allowed.add(item['profile']['id'] as String);
        }
      }
      for (final entry in users.entries) {
        if (entry.key is! String ||
            !allowed.contains(entry.key) ||
            !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(entry.key as String)) {
          throw const FormatException('业务备份用户标识无效');
        }
        result[entry.key as String] = _snapshot(entry.value);
      }
    }
    return result;
  }

  /// 扩展写入失败或原备份恢复失败时，恢复原业务状态与凭据。
  static Future<BackupRestoreResult> restore(
    String raw,
    UserDataScope current,
    Future<BackupRestoreResult> Function() restoreLegacy,
  ) async {
    final targets = inspect(raw, current);
    final parsed = jsonDecode(raw);
    // 旧备份的 API Key 必须覆盖安全存储中的旧值，否则解析仍会用恢复前的 Key。
    final full =
        parsed is Map && parsed['format'] == BackupService.fullSnapshotFormat;
    dynamic legacyKey;
    if (parsed is Map) {
      if (full && parsed['global'] is Map) {
        legacyKey = parsed['global']['apiKey'];
      } else {
        legacyKey = parsed['apiKey'];
      }
    }
    if (targets.isEmpty && legacyKey is String && (current.isDefault || full)) {
      final scope = full ? UserDataScope.defaultScope : current;
      final store = RuntimePreferences(scope);
      final secrets = await store.credentials();
      secrets['apiKey'] = legacyKey;
      targets[scope.userId] = _snapshot({
        'values': await store.read(),
        'credentials': secrets,
      });
    }
    final previous = <String, Map<String, dynamic>>{};
    final deleted = <String>{};
    for (final id in targets.keys) {
      final scope = UserDataScope(id);
      if (scope.isDeleted) {
        deleted.add(id);
        previous[id] = {
          'values': <String, dynamic>{},
          'credentials': <String, dynamic>{},
        };
        continue;
      }
      final store = RuntimePreferences(scope);
      previous[id] = {
        'values': await store.read(),
        'credentials': await store.credentials(),
      };
    }
    try {
      await _writeAll(targets);
      return await restoreLegacy();
    } catch (error) {
      try {
        await _writeAll(previous);
      } catch (_) {
        throw StateError('业务备份恢复失败且回退受阻，请保留原备份文件');
      }
      for (final id in deleted) {
        UserDataScope.markDeleted(id);
      }
      rethrow;
    }
  }

  static Future<void> _writeAll(
    Map<String, Map<String, dynamic>> snapshots,
  ) async {
    for (final entry in snapshots.entries) {
      UserDataScope.markRestored(entry.key);
      final store = RuntimePreferences(UserDataScope(entry.key));
      await store.write(
        Map<String, dynamic>.from(entry.value['values'] as Map),
      );
      await store.writeCredentials(
        Map<String, dynamic>.from(entry.value['credentials'] as Map),
      );
    }
  }
}
