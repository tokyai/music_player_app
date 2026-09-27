import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/screens/playback_history_screen.dart';
import 'package:music_player_app/screens/player_screen.dart';
import 'package:music_player_app/services/audio_cache_service.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/services/playback_history_service.dart';
import 'package:music_player_app/services/playback_state_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  // These UI tests need no native cache directories or pending path lookups.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          paths,
          (_) async => throw MissingPluginException(),
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
  });

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
      expect(find.textContaining('上次播放 0:35'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  for (final size in const [Size(640, 360), Size(1280, 800)]) {
    testWidgets(
      'history selection and clearing preserve session rules at $size',
      (tester) async {
        final entries = List.generate(
          2,
          (index) => PlaybackHistoryEntry(
            song: SongSearchResult(
              platform: MusicPlatform.qq,
              id: 'history-$index',
              name: '历史歌曲 $index',
              artist: '历史歌手',
              album: '历史专辑',
              duration: 240,
            ),
            position: Duration(seconds: 35 + index * 20),
            playedAt: DateTime(2026, 9, 26, 12, 1 - index),
          ),
        );
        SharedPreferences.setMockInitialValues({
          PlaybackHistoryService.preferenceKey: jsonEncode(
            entries.map((entry) => entry.toJson()).toList(),
          ),
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        final player = PlayerProvider(activateRestoredSession: false);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          final closing = player.disposeResources();
          await tester.pump(const Duration(seconds: 1));
          await closing;
          final releasing = AudioCacheService.releaseMemoryContext(
            player.dataScope,
          );
          await tester.pump(const Duration(seconds: 1));
          await releasing;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<PlayerProvider>.value(value: player),
              ChangeNotifierProvider(create: (_) => FavoriteService()),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const PlaybackHistoryScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final selection = find.byKey(
          ValueKey('playback-history-${entries.first.key}'),
        );
        expect(selection.hitTestable(), findsOneWidget);
        expect(find.textContaining('上次播放 0:35'), findsOneWidget);
        await tester.tap(selection);
        await tester.pumpAndSettle();
        expect(find.byType(PlayerScreen), findsOneWidget);
        expect(player.position, Duration.zero);
        expect(player.queue.map((song) => song.id), ['history-0', 'history-1']);
        expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
        expect(
          find.widgetWithText(TextButton, '收藏').hitTestable(),
          findsOneWidget,
        );
        expect(find.byTooltip('播放队列').hitTestable(), findsOneWidget);
        expect(
          find.byKey(const ValueKey('player-back')).hitTestable(),
          findsOneWidget,
        );

        await tester.tap(find.widgetWithText(TextButton, '收藏').hitTestable());
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.text('已收藏').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('播放队列').hitTestable());
        await tester.pumpAndSettle();
        expect(find.text('播放队列 (2)'), findsOneWidget);
        expect(
          find.widgetWithText(ListTile, '历史歌曲 1').hitTestable(),
          findsOneWidget,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        await player.seekTo(const Duration(seconds: 73));
        await tester.tap(
          find.byKey(const ValueKey('player-back')).hitTestable(),
        );
        await tester.pumpAndSettle();
        final clear = find.byKey(const ValueKey('playback-history-clear'));
        expect(clear.hitTestable(), findsOneWidget);
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(find.textContaining('当前歌曲的播放进度会保留'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, '取消').hitTestable());
        await tester.pumpAndSettle();
        expect(player.playbackHistory, hasLength(2));

        await tester.tap(clear);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '清空').hitTestable());
        await tester.pumpAndSettle();
        expect(player.playbackHistory, isEmpty);
        expect(find.text('播放过的歌曲会显示在这里，点击后从头播放'), findsOneWidget);
        expect(player.currentSong!.id, 'history-0');
        expect(player.position, const Duration(seconds: 73));
        final saved = await PlaybackStateService.load();
        expect(saved!.position, const Duration(seconds: 73));
        expect(saved.queue[saved.currentIndex].id, 'history-0');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
