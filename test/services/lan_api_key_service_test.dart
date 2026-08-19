import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:music_player_app/services/lan_api_key_service.dart';

void main() {
  test('temporary LAN page accepts one non-empty API Key', () async {
    final session = await LanApiKeyService.start();
    addTearDown(session.stop);
    final localUri = Uri.parse(session.url).replace(host: '127.0.0.1');

    final home = await http.get(localUri).timeout(const Duration(seconds: 5));
    expect(home.statusCode, 200);
    expect(home.body, contains('输入 ChKSz API Key'));
    expect(home.headers['cache-control'], 'no-store');

    final empty = await http
        .post(localUri.resolve('submit'), body: '   ')
        .timeout(const Duration(seconds: 5));
    expect(empty.statusCode, 400);

    final received = session.receivedApiKey.timeout(const Duration(seconds: 5));
    final submitted = await http
        .post(localUri.resolve('submit'), body: '  test-api-key  ')
        .timeout(const Duration(seconds: 5));
    expect(submitted.statusCode, 200);
    expect(await received, 'test-api-key');

    final duplicate = await http
        .post(localUri.resolve('submit'), body: 'other-key')
        .timeout(const Duration(seconds: 5));
    expect(duplicate.statusCode, 409);
  });

  test('stopping an unused session completes without an API Key', () async {
    final session = await LanApiKeyService.start();
    final received = session.receivedApiKey;
    await session.stop();
    expect(await received, isNull);
  });
}
