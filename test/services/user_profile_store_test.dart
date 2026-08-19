import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/services/user_profile_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'favorites': jsonEncode([
        {'platform': 'qq', 'id': 'old-song', 'name': '旧收藏'},
      ]),
      'theme_mode': 'dark',
      'api_key': 'device-secret',
    });
  });

  test(
    'personal preferences are isolated while device secrets remain local',
    () async {
      final prefs = await SharedPreferences.getInstance();

      await UserProfileStore.activate('user-a');
      await prefs.setString(
        'favorites',
        jsonEncode([
          {'platform': 'qq', 'id': 'a-song', 'name': 'A 的收藏'},
        ]),
      );

      await UserProfileStore.activate('user-b');
      expect(prefs.getString('favorites'), isNull);
      expect(prefs.getString('theme_mode'), isNull);
      expect(prefs.getString('api_key'), 'device-secret');

      await prefs.setString(
        'favorites',
        jsonEncode([
          {'platform': 'netease', 'id': 'b-song', 'name': 'B 的收藏'},
        ]),
      );
      await UserProfileStore.activate('user-a');

      final restored = jsonDecode(prefs.getString('favorites')!) as List;
      expect((restored.single as Map)['id'], 'a-song');
      expect(prefs.getString('theme_mode'), 'dark');
      expect(prefs.getString('api_key'), 'device-secret');
    },
  );
}
