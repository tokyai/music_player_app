import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/widgets/kuzai_pet.dart';

void main() {
  testWidgets('capture Kuzai wave frames', (tester) async {
    final boundaryKey = GlobalKey();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 360);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: boundaryKey,
          child: ColoredBox(
            color: const Color(0xFFF7F2FA),
            child: Center(
              child: KuzaiPet(
                key: const ValueKey('motion-kuzai'),
                size: 240,
                mode: KuzaiPetMode.idle,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1500));
    final directory = Directory('tmp/kuzai_motion_frames');
    await directory.create(recursive: true);

    Future<void> capture(int index) async {
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${directory.path}/frame_${index.toString().padLeft(2, '0')}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
    }

    await capture(0);
    await tester.tap(find.byKey(const ValueKey('motion-kuzai')));
    for (var index = 1; index <= 14; index++) {
      await tester.pump(const Duration(milliseconds: 70));
      await capture(index);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
