import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/screens/cache_list_screen.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';

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
}
