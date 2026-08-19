import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/services/account_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('login stores a session and normalizes the API base URL', () async {
    late Uri requestedUri;
    final client = MockClient((request) async {
      requestedUri = request.url;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['username'], 'listener');
      return http.Response(
        jsonEncode({
          'token': 'a' * 48,
          'user': {
            'id': 'user-1',
            'username': 'listener',
            'role': 'user',
            'status': 'active',
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final account = AccountService(client: client);
    addTearDown(account.dispose);

    await account.login(
      serverUrl: 'https://accounts.example.com/',
      username: 'listener',
      password: 'correct-password',
    );

    expect(
      requestedUri.toString(),
      'https://accounts.example.com/api/auth/login',
    );
    expect(account.isAuthenticated, isTrue);
    expect(account.user?.username, 'listener');
    expect(
      await const FlutterSecureStorage().read(key: 'kuzai_account_session'),
      'a' * 48,
    );
  });

  test(
    'disabled response moves an authenticated account behind the gate',
    () async {
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        if (requestCount == 1) {
          return http.Response(
            jsonEncode({
              'token': 'b' * 48,
              'user': {
                'id': 'user-2',
                'username': 'blocked-user',
                'role': 'user',
                'status': 'active',
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({'error': 'USER_DISABLED', 'message': '订阅已暂停'}),
          403,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final account = AccountService(client: client);
      addTearDown(account.dispose);
      await account.login(
        serverUrl: 'https://accounts.example.com/api',
        username: 'blocked-user',
        password: 'correct-password',
      );

      await expectLater(
        account.request('GET', '/me', authenticated: true),
        throwsA(
          isA<AccountException>().having(
            (error) => error.code,
            'code',
            'USER_DISABLED',
          ),
        ),
      );
      expect(account.status, AccountStatus.disabled);
      expect(account.message, '订阅已暂停');
    },
  );
}
