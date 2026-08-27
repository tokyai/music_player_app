import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:music_player_app/services/lan_backup_service.dart';

void main() {
  test(
    'temporary LAN server protects download and accepts restore by PIN',
    () async {
      final session = await LanBackupService.start(
        exportBackup: () => '{"format":"kuzai_music_favorites","songs":[]}',
      );
      addTearDown(session.stop);
      final publicUri = Uri.parse(session.url);
      final localUri = publicUri.replace(host: '127.0.0.1');

      final home = await http.get(localUri).timeout(const Duration(seconds: 5));
      expect(home.statusCode, 200);
      expect(home.body, contains('库仔音乐备份'));
      expect(home.body, contains('备份包含全部用户资料'));
      expect(home.body, contains('文件不能超过 12 MB'));
      expect(Uri.parse(session.qrUrl).queryParameters['pin'], session.pin);
      expect(home.body, contains('initialPin'));

      final denied = await http
          .get(localUri.resolve('backup?pin=000000'))
          .timeout(const Duration(seconds: 5));
      expect(denied.statusCode, 401);

      final downloaded = await http
          .get(localUri.resolve('backup?pin=${session.pin}'))
          .timeout(const Duration(seconds: 5));
      expect(downloaded.statusCode, 200);
      expect(downloaded.body, contains('kuzai_music_favorites'));

      final restoredFuture = session.restored.timeout(
        const Duration(seconds: 5),
      );
      final upload = await http
          .post(
            localUri.resolve('restore?pin=${session.pin}'),
            headers: const {'Content-Type': 'application/json'},
            body: '{"songs":[]}',
          )
          .timeout(const Duration(seconds: 5));
      expect(upload.statusCode, 200);
      expect(await restoredFuture, '{"songs":[]}');
    },
  );

  test('PIN validation only accepts six digits', () {
    expect(LanBackupService.isValidPin('123456'), isTrue);
    expect(LanBackupService.isValidPin('12345'), isFalse);
    expect(LanBackupService.isValidPin('12A456'), isFalse);
  });
}
