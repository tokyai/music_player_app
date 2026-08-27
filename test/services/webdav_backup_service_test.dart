import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/services/webdav_backup_service.dart';

void main() {
  const fingerprint =
      '00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF';

  test('normalizes certificate fingerprint and backup URI', () {
    const config = WebDavConfig(
      url: 'https://example.com:8443/dav',
      username: 'backup',
      password: 'password',
      certificateSha256: '00:11:22:33',
    );

    expect(
      config.fileUri().toString(),
      'https://example.com:8443/dav/kuzai-music-backup.json',
    );
    expect(WebDavConfig.normalizeFingerprint('aa:bb cc'), 'AABBCC');
  });

  test('uploads JSON with basic authentication', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response('', 201);
    });
    const config = WebDavConfig(
      url: 'https://example.com:8443/dav/',
      username: 'backup',
      password: 'separate-password',
      certificateSha256: fingerprint,
    );
    final service = WebDavBackupService(config: config, client: client);

    await service.upload('{"format":"backup"}');

    expect(captured.method, 'PUT');
    expect(captured.url.path, '/dav/kuzai-music-backup.json');
    expect(
      captured.headers['Authorization'],
      'Basic ${base64Encode(utf8.encode('backup:separate-password'))}',
    );
    expect(captured.body, '{"format":"backup"}');
  });

  test('requires a certificate fingerprint for HTTPS', () async {
    final client = MockClient((_) async => http.Response('', 404));
    const config = WebDavConfig(
      url: 'https://example.com/dav/',
      username: 'backup',
      password: 'password',
      certificateSha256: '',
    );
    final service = WebDavBackupService(config: config, client: client);

    await expectLater(
      service.testConnection(),
      throwsA(
        isA<WebDavException>().having(
          (error) => error.code,
          'code',
          'CERT_PIN_REQUIRED',
        ),
      ),
    );
  });

  test('reports a missing remote backup clearly', () async {
    final client = MockClient((_) async => http.Response('', 404));
    const config = WebDavConfig(
      url: 'https://example.com/dav/',
      username: 'backup',
      password: 'password',
      certificateSha256: fingerprint,
    );
    final service = WebDavBackupService(config: config, client: client);

    await expectLater(
      service.download(),
      throwsA(
        isA<WebDavException>().having(
          (error) => error.code,
          'code',
          'NOT_FOUND',
        ),
      ),
    );
  });

  test(
    'rejects an oversized download while reading the response stream',
    () async {
      final client = MockClient(
        (_) async => http.Response.bytes(Uint8List(12 * 1024 * 1024 + 1), 200),
      );
      const config = WebDavConfig(
        url: 'https://example.com/dav/',
        username: 'backup',
        password: 'password',
        certificateSha256: fingerprint,
      );
      final service = WebDavBackupService(config: config, client: client);

      await expectLater(
        service.download(),
        throwsA(
          isA<WebDavException>().having(
            (error) => error.code,
            'code',
            'TOO_LARGE',
          ),
        ),
      );
    },
  );
}
