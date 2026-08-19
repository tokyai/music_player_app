import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/services/account_service.dart';
import 'package:music_player_app/services/account_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'favorites': jsonEncode([
        {'platform': 'qq', 'id': 'song-a', 'name': 'A'},
      ]),
      'theme_mode': 'dark',
      'api_key': 'must-stay-on-device',
    });
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'first sync uploads personal domains and reuses their server baselines',
    () async {
      final pushes = <Map<String, dynamic>>[];
      final revisions = <String, int>{};
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          return _jsonResponse({
            'token': 'd' * 48,
            'user': {
              'id': 'sync-user',
              'username': 'sync-user',
              'role': 'user',
              'status': 'active',
            },
          });
        }
        if (request.method == 'GET' && request.url.path.endsWith('/sync')) {
          return _jsonResponse({'cursor': 0, 'hasMore': false, 'changes': []});
        }
        final body = Map<String, dynamic>.from(jsonDecode(request.body));
        pushes.add(body);
        final domain = body['domain'].toString();
        final revision = (revisions[domain] ?? 0) + 1;
        revisions[domain] = revision;
        return _jsonResponse({
          'domain': domain,
          'revision': revision,
          'cursor': revision,
          'payload': body['payload'],
        });
      });
      final account = AccountService(client: client);
      addTearDown(account.dispose);
      await account.login(
        serverUrl: 'https://accounts.example.com/api',
        username: 'sync-user',
        password: 'correct-password',
      );
      final sync = AccountSyncService(account);

      await sync.bootstrap();

      expect(pushes.map((body) => body['domain']).toSet(), {
        'favorites',
        'history',
        'settings',
        'search_history',
      });
      final settings = pushes.singleWhere(
        (body) => body['domain'] == 'settings',
      );
      final settingsValues = (settings['payload'] as Map)['values'] as Map;
      expect(settingsValues['theme_mode'], 'dark');
      expect(settingsValues.containsKey('api_key'), isFalse);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'favorites',
        jsonEncode([
          {'platform': 'qq', 'id': 'song-b', 'name': 'B'},
        ]),
      );
      await sync.syncDomains(const {'favorites'});

      final secondFavoritePush = pushes
          .where((body) => body['domain'] == 'favorites')
          .last;
      expect(secondFavoritePush['baseRevision'], 1);
      final baseValues =
          (secondFavoritePush['basePayload'] as Map)['values'] as Map;
      final baseFavorites =
          jsonDecode(baseValues['favorites'].toString()) as List;
      expect((baseFavorites.single as Map)['id'], 'song-a');
      final nextValues =
          (secondFavoritePush['payload'] as Map)['values'] as Map;
      final nextFavorites =
          jsonDecode(nextValues['favorites'].toString()) as List;
      expect((nextFavorites.single as Map)['id'], 'song-b');
    },
  );
}

http.Response _jsonResponse(Map<String, dynamic> body, {int status = 200}) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}
