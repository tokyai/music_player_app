import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/ai_assistant.dart';
import 'package:music_player_app/widgets/assistant_pet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled sprite strips decode with the expected frame count', () async {
    const assets = <String, int>{
      'assets/pets/moomew/rest.webp': 1,
      'assets/pets/moomew/idle.webp': 6,
      'assets/pets/moomew/idle-blink.webp': 3,
      'assets/pets/moomew/idle-glance.webp': 3,
      'assets/pets/moomew/yarn.webp': 6,
      'assets/pets/xiaohei/rest.webp': 1,
      'assets/pets/xiaohei/lounge.webp': 12,
      'assets/pets/xiaohei/idle-tail-flick.webp': 3,
      'assets/pets/xiaohei/idle-settle.webp': 5,
      'assets/pets/xiaohei/lounge-awake.webp': 8,
      'assets/pets/xiaohei/lounge-curious.webp': 9,
      'assets/pets/xiaohei/lounge-stretch.webp': 4,
      'assets/pets/xiaohei/guitar.webp': 6,
      'assets/pets/xiaohei/groom.webp': 16,
      'assets/pets/xiaohei/error-shake.webp': 10,
      'assets/pets/xiaohei/play.webp': 5,
      'assets/pets/xiaohei/walk.webp': 7,
      'assets/pets/xiaohei/eat-burger.webp': 22,
      'assets/pets/xiaohei/eat-watermelon.webp': 21,
      'assets/pets/xiaohei/idle-cloud.webp': 5,
      'assets/pets/xiaohei/idle-sun.webp': 5,
      'assets/pets/whale_girl/rest.webp': 1,
      'assets/pets/whale_girl/idle.webp': 3,
      'assets/pets/whale_girl/idle-blink.webp': 3,
      'assets/pets/whale_girl/celebrate.webp': 3,
      'assets/pets/whale_girl/disappointed.webp': 2,
      'assets/pets/whale_girl/drag.webp': 1,
      'assets/pets/whale_girl/error.webp': 2,
      'assets/pets/whale_girl/joy.webp': 2,
      'assets/pets/whale_girl/sleep.webp': 2,
      'assets/pets/whale_girl/think.webp': 1,
      'assets/pets/whale_girl/wait.webp': 1,
      'assets/pets/whale_girl/wake.webp': 2,
      'assets/pets/whale_girl/welcome.webp': 2,
      'assets/pets/whale_girl/working.webp': 3,
    };

    for (final MapEntry(key: asset, value: frameCount) in assets.entries) {
      ui.Codec? codec;
      ui.FrameInfo? frame;
      try {
        final data = await rootBundle.load(asset);
        codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        frame = await codec.getNextFrame();
        expect(frame.image.width, 256 * frameCount, reason: asset);
        expect(frame.image.height, 256, reason: asset);
      } finally {
        frame?.image.dispose();
        codec?.dispose();
      }
    }
  });

  testWidgets('sprite transition keeps a valid clip during hand-off', (
    tester,
  ) async {
    await tester.pumpWidget(_pet(AiPetAppearance.moomew));
    await _pumpUntilFound(tester, _clip('moomew', 'rest'));

    await tester.pumpWidget(
      _pet(
        AiPetAppearance.moomew,
        interaction: AssistantPetInteraction.wave,
        interactionRevision: 1,
      ),
    );
    await _pumpUntilFound(tester, _clip('moomew', 'wave'));

    for (var index = 0; index < 16; index++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(AssistantPet), findsOneWidget);
      expect(_clip('moomew', 'wave'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('sprite survives rapid switches, lifecycle pauses and disposal', (
    tester,
  ) async {
    await tester.pumpWidget(_pet(AiPetAppearance.xiaohei));
    await _pumpLoaded(tester);

    const sequence = <(AiPetAppearance, AssistantPetMode)>[
      (AiPetAppearance.xiaohei, AssistantPetMode.waking),
      (AiPetAppearance.moomew, AssistantPetMode.thinking),
      (AiPetAppearance.whaleGirl, AssistantPetMode.speaking),
      (AiPetAppearance.xiaohei, AssistantPetMode.textOnly),
      (AiPetAppearance.moomew, AssistantPetMode.error),
      (AiPetAppearance.xiaohei, AssistantPetMode.stopping),
    ];
    for (final (appearance, mode) in sequence) {
      await tester.pumpWidget(_pet(appearance, mode: mode));
      await tester.pump(const Duration(milliseconds: 12));
    }

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });

  testWidgets('XiaoHei uses the relaxed action set for daily states', (
    tester,
  ) async {
    await tester.pumpWidget(_pet(AiPetAppearance.xiaohei));
    await _pumpUntilFound(tester, _clip('xiaohei', 'rest'));

    const states = <(AssistantPetMode, String)>[
      (AssistantPetMode.listening, 'listen'),
      (AssistantPetMode.thinking, 'text-wait'),
      (AssistantPetMode.speaking, 'guitar'),
      (AssistantPetMode.error, 'error-shake'),
      (AssistantPetMode.stopping, 'idle-roll'),
    ];
    for (final (mode, clip) in states) {
      await tester.pumpWidget(_pet(AiPetAppearance.xiaohei, mode: mode));
      await _pumpUntilFound(tester, _clip('xiaohei', clip));
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(
      _pet(
        AiPetAppearance.xiaohei,
        interaction: AssistantPetInteraction.petting,
        interactionRevision: 1,
      ),
    );
    await _pumpUntilFound(tester, _clip('xiaohei', 'groom'));

    await tester.pumpWidget(
      _pet(
        AiPetAppearance.xiaohei,
        dragging: true,
        dragDirection: AssistantPetDragDirection.right,
      ),
    );
    await _pumpUntilFound(tester, _clip('xiaohei', 'drag'));
    expect(tester.takeException(), isNull);
  });

  const pets = <(AiPetAppearance, String)>[
    (AiPetAppearance.moomew, 'moomew'),
    (AiPetAppearance.xiaohei, 'xiaohei'),
    (AiPetAppearance.whaleGirl, 'whale'),
  ];

  testWidgets('sprite pet idle behavior stays stable and lifecycle safe', (
    tester,
  ) async {
    for (final (appearance, name) in pets) {
      await tester.pumpWidget(_pet(appearance));
      await _pumpLoaded(tester);

      await _pumpUntilFound(tester, _clip(name, 'rest'));
      expect(_clip(name, 'rest'), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      expect(_idleAction(name), findsNothing);

      await tester.pump(const Duration(seconds: 1, milliseconds: 100));
      await _pumpUntilFound(tester, _idleAction(name));
      expect(_idleAction(name), findsOneWidget);

      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 2));
      await _pumpUntilFound(tester, _clip(name, 'rest'));
      expect(_clip(name, 'rest'), findsOneWidget);
      expect(_idleAction(name), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    await tester.pumpWidget(_pet(AiPetAppearance.moomew));
    await _pumpLoaded(tester);
    await tester.pump(const Duration(seconds: 2));

    await tester.pumpWidget(
      _pet(AiPetAppearance.moomew, interaction: AssistantPetInteraction.wave),
    );
    await _pumpUntilFound(tester, _clip('moomew', 'wave'));
    expect(_clip('moomew', 'wave'), findsOneWidget);

    await tester.pump(const Duration(seconds: 7));
    expect(_idleAction('moomew'), findsNothing);

    await tester.pumpWidget(_pet(AiPetAppearance.moomew));
    await _pumpLoaded(tester);
    await _pumpUntilFound(tester, _clip('moomew', 'rest'));
    expect(_clip('moomew', 'rest'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await tester.pumpWidget(_pet(AiPetAppearance.moomew));
    await _pumpLoaded(tester);
    await _pumpUntilFound(tester, _clip('moomew', 'rest'));
    await tester.pump(const Duration(seconds: 2));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    expect(_idleAction('moomew'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(_idleAction('moomew'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sprite interaction completes after the full clip', (
    tester,
  ) async {
    var completions = 0;
    await tester.pumpWidget(
      _pet(AiPetAppearance.moomew, onInteractionComplete: () => completions++),
    );
    await _pumpLoaded(tester);
    await _pumpUntilFound(tester, _clip('moomew', 'rest'));

    await tester.pumpWidget(
      _pet(
        AiPetAppearance.moomew,
        interaction: AssistantPetInteraction.wave,
        interactionRevision: 1,
        onInteractionComplete: () => completions++,
      ),
    );
    await _pumpUntilFound(tester, _clip('moomew', 'wave'));
    expect(completions, 0);
    await tester.pump(const Duration(milliseconds: 700));
    expect(completions, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(completions, 1);

    await tester.pumpWidget(
      _pet(AiPetAppearance.moomew, onInteractionComplete: () => completions++),
    );
    await _pumpUntilFound(tester, _clip('moomew', 'rest'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated sprite interaction ignores stale completion', (
    tester,
  ) async {
    var completions = 0;
    await tester.pumpWidget(_pet(AiPetAppearance.moomew));
    await _pumpLoaded(tester);
    await _pumpUntilFound(tester, _clip('moomew', 'rest'));

    await tester.pumpWidget(
      _pet(
        AiPetAppearance.moomew,
        interaction: AssistantPetInteraction.wave,
        interactionRevision: 1,
        onInteractionComplete: () => completions++,
      ),
    );
    await _pumpUntilFound(tester, _clip('moomew', 'wave'));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.pumpWidget(
      _pet(
        AiPetAppearance.moomew,
        interaction: AssistantPetInteraction.wave,
        interactionRevision: 2,
        onInteractionComplete: () => completions++,
      ),
    );
    await _pumpLoaded(tester);
    await tester.pump(const Duration(milliseconds: 700));
    expect(completions, 0);
    await tester.pump(const Duration(milliseconds: 700));
    expect(completions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MooMew waits for drag direction before running', (tester) async {
    await tester.pumpWidget(_pet(AiPetAppearance.moomew));
    await _pumpLoaded(tester);
    await _pumpUntilFound(tester, _clip('moomew', 'rest'));

    await tester.pumpWidget(_pet(AiPetAppearance.moomew, dragging: true));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_clip('moomew', 'rest'), findsOneWidget);

    await tester.pumpWidget(
      _pet(
        AiPetAppearance.moomew,
        dragging: true,
        dragDirection: AssistantPetDragDirection.right,
      ),
    );
    await _pumpUntilFound(tester, _clip('moomew', 'drag-right'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Kuzai resumes idle actions after petting', (tester) async {
    await tester.pumpWidget(_pet(AiPetAppearance.kuzai));
    await tester.pump();
    await tester.longPress(find.byKey(const ValueKey('kuzai-pet-canvas')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('kuzai-pet-petting-active')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 1700));
    expect(
      find.byKey(const ValueKey('kuzai-pet-petting-active')),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 13));
    expect(_kuzaiIdleAction(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sprite idle scheduling follows TickerMode', (tester) async {
    await tester.pumpWidget(
      TickerMode(enabled: false, child: _pet(AiPetAppearance.whaleGirl)),
    );
    await _pumpLoaded(tester);
    await tester.pump(const Duration(seconds: 12));
    expect(_idleAction('whale'), findsNothing);

    await tester.pumpWidget(
      TickerMode(enabled: true, child: _pet(AiPetAppearance.whaleGirl)),
    );
    await tester.pump(const Duration(seconds: 7));
    expect(_idleAction('whale'), findsNothing);
    await tester.pump(const Duration(seconds: 1, milliseconds: 100));
    await _pumpUntilFound(tester, _idleAction('whale'));
    expect(tester.takeException(), isNull);
  });
}

Widget _pet(
  AiPetAppearance appearance, {
  AssistantPetMode mode = AssistantPetMode.idle,
  AssistantPetInteraction interaction = AssistantPetInteraction.none,
  int interactionRevision = 0,
  bool dragging = false,
  AssistantPetDragDirection dragDirection = AssistantPetDragDirection.none,
  VoidCallback? onInteractionComplete,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: AssistantPet(
        appearance: appearance,
        size: 96,
        mode: mode,
        interaction: interaction,
        interactionRevision: interactionRevision,
        dragging: dragging,
        dragDirection: dragDirection,
        onTap: _noop,
        onLongPressStart: _noopLongPress,
        onInteractionComplete: onInteractionComplete,
      ),
    ),
  ),
);

void _noop() {}

void _noopLongPress(LongPressStartDetails _) {}

Finder _clip(String name, String clip) =>
    find.byKey(ValueKey('assistant-pet-clip-$name-$clip'));

Finder _idleAction(String name) => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> &&
      key.value.startsWith('assistant-pet-clip-$name-idle-');
});

Finder _kuzaiIdleAction() => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> && key.value.startsWith('kuzai-pet-idle-');
});

Future<void> _pumpLoaded(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(finder, findsOneWidget);
}
