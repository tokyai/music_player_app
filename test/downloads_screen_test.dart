import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/download_entry.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/screens/downloads_screen.dart';
import 'package:music_player_app/services/download_manager.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    final song = SongSearchResult(
      platform: MusicPlatform.qq,
      id: 'downloaded',
      name: '下载测试歌曲',
      artist: '测试歌手',
      album: '测试专辑',
    );
    SharedPreferences.setMockInitialValues({
      DownloadManager.preferenceKey: jsonEncode({
        'version': 1,
        'wifiOnly': true,
        'entries': [
          DownloadEntry(
            id: 'a' * 24,
            song: song,
            quality: 'flac',
            status: DownloadStatus.completed,
            fileName: '${'a' * 24}.mp3',
          ).toJson(),
          DownloadEntry(
            id: 'b' * 24,
            song: song,
            quality: '320k',
            status: DownloadStatus.paused,
          ).toJson(),
        ],
      }),
    });
    messenger.setMockMethodCallHandler(
      DownloadManager.channel,
      (_) async => false,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('music_player/download_network'),
      (_) async => null,
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(DownloadManager.channel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('music_player/download_network'),
      null,
    );
  });
  for (final size in const [Size(640, 360), Size(1280, 800), Size(390, 844)]) {
    testWidgets(
      'download controls fit, retain state and play offline at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        final player = _DownloadsPlayer();
        final favorites = FavoriteService();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          // Drain plugin callbacks scheduled in the widget test's fake clock.
          final disposing = player.disposeResources();
          await tester.pump();
          await disposing;
          favorites.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<PlayerProvider>.value(value: player),
              ChangeNotifierProvider<FavoriteService>.value(value: favorites),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const DownloadsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('downloads-wifi-only')).hitTestable(),
          findsOneWidget,
        );
        expect(find.byTooltip('播放下载').hitTestable(), findsOneWidget);
        expect(find.byTooltip('移除下载').hitTestable(), findsNWidgets(2));
        await tester.tap(find.byTooltip('重试下载'));
        await tester.pumpAndSettle();
        expect(player.downloads.entries.last.status, DownloadStatus.queued);
        expect(find.byTooltip('暂停下载').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('暂停下载'));
        await tester.pumpAndSettle();
        expect(player.downloads.entries.last.status, DownloadStatus.paused);
        await tester.tap(find.byTooltip('播放下载'));
        await tester.pumpAndSettle();
        expect(player.played!.downloadId, 'a' * 24);
        tester.view.physicalSize = size.width > size.height
            ? const Size(390, 844)
            : const Size(640, 360);
        await tester.pumpAndSettle();
        expect(find.byTooltip('播放下载').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _DownloadsPlayer extends PlayerProvider {
  SongSearchResult? played;
  @override
  Future<void> playSingle(SongSearchResult result) async {
    played = result;
  }
}
