import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/widgets/runtime_status_view.dart';

void main() {
  for (final size in [const Size(640, 360), const Size(1280, 800)]) {
    testWidgets('横屏 ${size.width}x${size.height} 错误说明可滚动且重试始终可见', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var retries = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeArea(
              child: RuntimeStatusView(
                status: '打开失败',
                error: List<String>.filled(12, '业务包加载失败，继续保留本地数据。').join('\n'),
                onRetry: () {
                  retries++;
                },
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final retry = find.text('重试并恢复本地版本');
      expect(tester.getRect(retry).bottom, lessThan(size.height));
      await tester.tap(retry);
      await tester.pump();
      expect(retries, 1);
    });
  }
}
