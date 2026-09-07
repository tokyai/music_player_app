import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/services/global_settings_service.dart';
import 'package:music_player_app/theme/lyric_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'lyric display switches survive backup and old backups default to off',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(LyricStylePreferences.wordHighlightKey, true);
      await prefs.setBool(LyricStylePreferences.translationKey, true);
      final snapshot = await GlobalSettingsService.exportLyricDisplay();
      await prefs.clear();
      await GlobalSettingsService.restoreLyricDisplay(snapshot);
      expect(prefs.getBool(LyricStylePreferences.wordHighlightKey), isTrue);
      expect(prefs.getBool(LyricStylePreferences.translationKey), isTrue);
      snapshot.remove('wordHighlight');
      snapshot.remove('showTranslation');
      await GlobalSettingsService.restoreLyricDisplay(snapshot);
      expect(prefs.getBool(LyricStylePreferences.wordHighlightKey), isFalse);
      expect(prefs.getBool(LyricStylePreferences.translationKey), isFalse);
    },
  );

  test('invalid switches are rejected before persistence', () async {
    final snapshot = GlobalSettingsService.defaultLyricDisplay();
    snapshot['wordHighlight'] = 'invalid';
    await expectLater(
      GlobalSettingsService.restoreLyricDisplay(snapshot),
      throwsFormatException,
    );
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });
}
