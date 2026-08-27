import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:music_player_app/services/lan_user_profile_service.dart';

import '../test_avatar_fixture.dart';

void main() {
  test(
    'LAN user page receives a normalized name and compressed avatar',
    () async {
      final session = await LanUserProfileService.start(initialName: '驾驶员&甲');
      addTearDown(session.stop);
      expect(session.url, isNot(contains('驾驶员')));
      final localUri = Uri.parse(session.url).replace(host: '127.0.0.1');

      final home = await http.get(localUri).timeout(const Duration(seconds: 5));
      expect(home.statusCode, 200);
      expect(home.body, contains('设置用户资料'));
      expect(home.body, contains('驾驶员&amp;甲'));
      expect(home.body, contains('type="file"'));
      expect(home.headers['cache-control'], 'no-store');

      final received = session.receivedSubmission.timeout(
        const Duration(seconds: 5),
      );
      final response = await http
          .post(
            localUri.resolve('submit'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'name': '  手机  用户  ',
              'avatarMimeType': 'image/jpeg',
              'avatarBase64': base64Encode(testAvatarJpeg),
            }),
          )
          .timeout(const Duration(seconds: 5));
      expect(response.statusCode, 200);
      final submission = await received;
      expect(submission, isNotNull);
      expect(submission!.name, '手机 用户');
      expect(submission.avatarBytes, testAvatarJpeg);

      final duplicate = await http.post(
        localUri.resolve('submit'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'name': '其他用户'}),
      );
      expect(duplicate.statusCode, 409);
    },
  );

  test('LAN user page rejects invalid and oversized avatar payloads', () async {
    final session = await LanUserProfileService.start();
    addTearDown(session.stop);
    final submit = Uri.parse(
      session.url,
    ).replace(host: '127.0.0.1').resolve('submit');

    final wrongMime = await http.post(
      submit,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': '测试用户',
        'avatarMimeType': 'image/png',
        'avatarBase64': base64Encode(testAvatarJpeg),
      }),
    );
    expect(wrongMime.statusCode, 400);

    final invalidBase64 = await http.post(
      submit,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': '测试用户',
        'avatarMimeType': 'image/jpeg',
        'avatarBase64': '%%%invalid%%%',
      }),
    );
    expect(invalidBase64.statusCode, 400);

    final excessiveDimensions = await http.post(
      submit,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': '测试用户',
        'avatarMimeType': 'image/jpeg',
        'avatarBase64': base64Encode(jpegHeaderWithDimensions(513, 512)),
      }),
    );
    expect(excessiveDimensions.statusCode, 400);

    final nonSquare = await http.post(
      submit,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': '测试用户',
        'avatarMimeType': 'image/jpeg',
        'avatarBase64': base64Encode(jpegHeaderWithDimensions(400, 300)),
      }),
    );
    expect(nonSquare.statusCode, 400);

    final oversized = await http.post(
      submit,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': '测试用户',
        'avatarMimeType': 'image/jpeg',
        'avatarBase64': List.filled(570 * 1024, 'A').join(),
      }),
    );
    expect(oversized.statusCode, 413);
  });

  test('stopping an unused LAN user session completes without data', () async {
    final session = await LanUserProfileService.start();
    final received = session.receivedSubmission;
    await session.stop();
    expect(await received, isNull);
  });
}
