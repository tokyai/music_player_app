import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/screens/cache_list_screen.dart';
import 'package:music_player_app/services/audio_cache_service.dart';
import 'package:music_player_app/services/user_data_scope.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cache page keeps overview and list panes in landscape', (
    tester,
  ) async {
    final player = PlayerProvider();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    for (final size in const [
      Size(640, 360),
      Size(1280, 800),
      Size(1920, 1080),
    ]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        ChangeNotifierProvider<PlayerProvider>.value(
          value: player,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const CacheListScreen(),
          ),
        ),
      );
      // 缓存目录是平台异步资源；只推进首帧，不等待无限进度指示器收敛。
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byType(VerticalDivider), findsOneWidget);
      expect(find.text('已缓存歌曲'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  for (final size in const [Size(640, 360), Size(1280, 800)]) {
    testWidgets('cache management removes paired lyrics at $size', (
      tester,
    ) async {
      final root = Directory.systemTemp.createTempSync(
        'cache_management_lyrics_',
      );
      final scope = UserDataScope(
        'cache-ui-${DateTime.now().microsecondsSinceEpoch}',
      );
      final cache = Directory('${root.path}/${scope.audioCacheRelativePath}')
        ..createSync(recursive: true);
      final index = <String, dynamic>{};
      for (final id in ['one', 'two']) {
        final audio = File('${cache.path}/$id.mp3')
          ..writeAsBytesSync(List<int>.filled(16384, 0));
        index['qq_$id'] = {
          'filePath': audio.path,
          'platformCode': 'qq',
          'songId': id,
          'name': '缓存歌曲 $id',
          'artist': '歌手',
          'quality': 'flac',
        };
      }
      File('${cache.path}/_index.json').writeAsStringSync(jsonEncode(index));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => root.path);
      SharedPreferences.setMockInitialValues({});
      final player = PlayerProvider(
        dataScope: scope,
        activateRestoredSession: false,
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;

      Future<void> settleIo(bool Function() done) async {
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 30));
          if (done() &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            await tester.pump(const Duration(milliseconds: 350));
            return;
          }
        }
        fail('Cache management did not finish its filesystem operation');
      }

      try {
        await tester.runAsync(() async {
          for (final id in ['one', 'two']) {
            expect(
              await AudioCacheService.cacheLyrics(
                platformCode: 'qq',
                songId: id,
                audioPath: '${cache.path}/$id.mp3',
                lyrics: LyricData(original: '[00:00.00]歌词 $id'),
                scope: scope,
              ),
              isTrue,
            );
          }
        });
        await tester.pumpWidget(
          ChangeNotifierProvider<PlayerProvider>.value(
            value: player,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const CacheListScreen(),
            ),
          ),
        );
        await settleIo(() => find.text('缓存歌曲 two').evaluate().isNotEmpty);
        expect(find.byTooltip('返回').hitTestable(), findsOneWidget);
        expect(find.byTooltip('删除缓存').hitTestable(), findsNWidgets(2));
        await tester.tap(find.byTooltip('删除缓存').first);
        await settleIo(() => find.text('缓存歌曲 one').evaluate().isEmpty);
        expect(File('${cache.path}/one.mp3').existsSync(), isFalse);
        expect(
          cache.listSync().where(
            (file) => file.uri.pathSegments.last.startsWith('lyrics_'),
          ),
          hasLength(1),
        );
        await tester.ensureVisible(find.text('清除全部'));
        await tester.tap(find.text('清除全部'));
        await settleIo(() => find.byType(AlertDialog).evaluate().isNotEmpty);
        expect(find.textContaining('关联歌词'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(File('${cache.path}/two.mp3').existsSync(), isTrue);
        await tester.tap(find.text('清除全部'));
        await settleIo(() => find.byType(AlertDialog).evaluate().isNotEmpty);
        await tester.tap(find.widgetWithText(FilledButton, '清除'));
        await settleIo(() => find.text('还没有缓存歌曲').evaluate().isNotEmpty);
        expect(File('${cache.path}/two.mp3').existsSync(), isFalse);
        expect(
          cache.listSync().where(
            (file) => file.uri.pathSegments.last.startsWith('lyrics_'),
          ),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(
          () => player.disposeResources().timeout(const Duration(seconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(() async {
          await AudioCacheService.releaseMemoryContext(scope);
          await root.delete(recursive: true);
        });
        messenger.setMockMethodCallHandler(channel, null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  }
}
