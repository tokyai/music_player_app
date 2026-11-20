import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music_player_app/services/runtime_backup.dart';
import 'package:music_player_app/services/runtime_preferences.dart';
import 'package:music_player_app/services/user_data_scope.dart';
import 'package:music_player_app/services/backup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const scope = UserDataScope.defaultScope;
  final secretValues = <String, String>{};
  var failNextWrite = false;
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'remote_business_v1': jsonEncode({
        'sources': {'qq': 'old_source'},
      }),
    });
    secretValues.clear();
    secretValues[RuntimePreferences.credentialsKey] = jsonEncode({
      'apiKey': 'old-key',
    });
    failNextWrite = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final data = Map<String, dynamic>.from(call.arguments as Map);
          final key = data['key'] as String;
          if (call.method == 'read') return secretValues[key];
          if (call.method == 'write') {
            if (failNextWrite) {
              failNextWrite = false;
              throw PlatformException(code: 'STORE_UNAVAILABLE');
            }
            secretValues[key] = data['value'] as String;
          }
          if (call.method == 'delete') secretValues.remove(key);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  const result = BackupRestoreResult(
    songsAdded: 0,
    songsSkipped: 0,
    songsTotal: 0,
    playlistsAdded: 0,
    playlistsSkipped: 0,
    apiKeyRestored: false,
  );
  String backup({String source = 'new_source', String key = 'new-key'}) =>
      jsonEncode({
        'format': 'kuzai_music_favorites',
        'songs': [],
        'remoteBusiness': {
          'values': {
            'sources': {'qq': source},
          },
          'credentials': {'apiKey': key},
        },
      });

  test('主动导出的备份包含业务选择和安全存储中的凭据', () async {
    final raw = await RuntimeBackup.attach(
      jsonEncode({'format': 'kuzai_music_favorites', 'songs': []}),
      [scope],
      full: false,
    );
    final snapshots = RuntimeBackup.inspect(raw, scope);
    expect(snapshots['default']!['credentials']['apiKey'], 'old-key');
    expect(snapshots['default']!['values']['sources']['qq'], 'old_source');
  });
  test('恢复完成后业务配置与凭据同时生效', () async {
    await RuntimeBackup.restore(backup(), scope, () async => result);
    expect(
      (await const RuntimePreferences(scope).read())['sources']['qq'],
      'new_source',
    );
    expect(
      (await const RuntimePreferences(scope).credentials())['apiKey'],
      'new-key',
    );
  });
  test('安全存储失败时回退业务配置且不开始原数据恢复', () async {
    failNextWrite = true;
    var imported = false;
    await expectLater(
      RuntimeBackup.restore(backup(), scope, () async {
        imported = true;
        return result;
      }),
      throwsA(isA<PlatformException>()),
    );
    expect(imported, isFalse);
    expect(
      (await const RuntimePreferences(scope).read())['sources']['qq'],
      'old_source',
    );
    expect(
      (await const RuntimePreferences(scope).credentials())['apiKey'],
      'old-key',
    );
  });
  test('原数据恢复失败时回退新增业务状态和凭据', () async {
    await expectLater(
      RuntimeBackup.restore(backup(), scope, () async {
        throw StateError('原备份损坏');
      }),
      throwsStateError,
    );
    expect(
      (await const RuntimePreferences(scope).read())['sources']['qq'],
      'old_source',
    );
    expect(
      (await const RuntimePreferences(scope).credentials())['apiKey'],
      'old-key',
    );
  });
  test('旧备份 API Key 覆盖安全存储，避免解析仍使用恢复前的 Key', () async {
    await RuntimeBackup.restore(
      jsonEncode({'songs': [], 'apiKey': 'legacy-key'}),
      scope,
      () async => result,
    );
    expect(
      (await const RuntimePreferences(scope).credentials())['apiKey'],
      'legacy-key',
    );
  });
  test('非法凭据在任何数据写入前拒绝', () {
    expect(
      () => RuntimeBackup.inspect(
        jsonEncode({
          'remoteBusiness': {
            'values': {},
            'credentials': {
              'apiKey': {'invalid': true},
            },
          },
        }),
        scope,
      ),
      throwsFormatException,
    );
  });
}
