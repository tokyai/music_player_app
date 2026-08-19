import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/screens/playback_history_screen.dart';
import 'package:music_player_app/services/playback_history_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('history list stays usable in narrow and wide landscape', (
    tester,
  ) async {
    for (final size in const [Size(640, 360), Size(1280, 800)]) {
      final song = SongSearchResult(
        platform: MusicPlatform.qq,
        id: 'history-song',
        name: '历史歌曲',
        artist: '历史歌手',
        album: '历史专辑',
        duration: 240,
      );
      final entry = PlaybackHistoryEntry(
        song: song,
        position: const Duration(seconds: 35),
        playedAt: DateTime.now(),
      );
      SharedPreferences.setMockInitialValues({
        PlaybackHistoryService.preferenceKey: jsonEncode([entry.toJson()]),
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      final player = PlayerProvider();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const PlaybackHistoryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('playback-history-list')),
        findsOneWidget,
      );
      expect(find.text('历史歌曲'), findsOneWidget);
      expect(find.textContaining('继续 0:35'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
