import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/services/update_service.dart';

void main() {
  test('parses the current update manifest schema', () {
    final info = UpdateInfo.fromJson({
      'versionCode': 2215,
      'versionName': '2.2.15',
      'apkUrl': 'http://example.com/latest.apk',
      'forceUpdate': false,
      'updateContent': 'Fix installer',
    });

    expect(info.versionCode, 2215);
    expect(info.updateLog, 'Fix installer');
    expect(info.apkSize, 0);
    expect(info.sha256, isEmpty);
  });

  test('normalizes optional digest values', () {
    final info = UpdateInfo.fromJson({
      'versionCode': '2216',
      'versionName': '2.2.16',
      'apkUrl': 'https://example.com/latest.apk',
      'apkSize': '123',
      'md5': 'AABB',
      'sha256': 'CCDD',
      'updateLog': 'Changes',
    });

    expect(info.versionCode, 2216);
    expect(info.apkSize, 123);
    expect(info.md5, 'aabb');
    expect(info.sha256, 'ccdd');
  });
}
