import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:music_player_app/widgets/user_profile_editor_dialog.dart';

void main() {
  for (final size in const [Size(640, 360), Size(1280, 800)]) {
    testWidgets('user profile QR dialog fits at $size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final received = Completer<bool>();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: UserProfileQrDialog(
            url: 'http://192.168.1.8:12345/test-token/',
            receivedFuture: received.future,
          ),
        ),
      );
      await tester.pump();

      final qrCode = find.byKey(const ValueKey('user-profile-qr-code'));
      final close = find.byKey(const ValueKey('user-profile-qr-close'));
      expect(qrCode, findsOneWidget);
      expect(close.hitTestable(), findsOneWidget);
      final qrRect = tester.getRect(qrCode);
      expect(qrRect.left, greaterThanOrEqualTo(0));
      expect(qrRect.top, greaterThanOrEqualTo(0));
      expect(qrRect.right, lessThanOrEqualTo(size.width));
      expect(qrRect.bottom, lessThanOrEqualTo(size.height));
      expect(tester.getRect(close).height, greaterThanOrEqualTo(40));
      expect(tester.takeException(), isNull);

      received.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('资料已接收，关闭后确认保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
