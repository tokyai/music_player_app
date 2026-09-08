import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/screens/playback_source_config_screen.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _DelayedApiKeyPlayer player;
  final field = find.byKey(const ValueKey('api-key-field'));
  final save = find.byKey(const ValueKey('api-key-save'));

  setUp(() {
    SharedPreferences.setMockInitialValues({'api_key': 'existing-key'});
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    player = _DelayedApiKeyPlayer();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(640, 360);
    addTearDown(() async {
      if (!player.writeGate.isCompleted) player.writeGate.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await player.disposeResources();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await player.settingsReady;
    await tester.pumpWidget(
      ChangeNotifierProvider<PlayerProvider>.value(
        value: player,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const PlaybackSourceConfigScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('API key draft survives rotation and is discarded on exit', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.ensureVisible(field);
    await tester.enterText(field, 'unsaved-key');
    await tester.pumpAndSettle();
    for (final size in const [
      Size(1280, 800),
      Size(390, 844),
      Size(640, 360),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      await tester.ensureVisible(field);
      expect(tester.widget<TextField>(field).controller?.text, 'unsaved-key');
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      expect(field.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(player.apiKey, 'existing-key');
    expect(
      (await SharedPreferences.getInstance()).getString('api_key'),
      'existing-key',
    );
  });

  testWidgets(
    'API key save blocks duplicates and permits retry after failure',
    (tester) async {
      await pumpScreen(tester);
      await tester.ensureVisible(field);
      await tester.enterText(field, 'replacement-key');
      await tester.pumpAndSettle();
      await tester.ensureVisible(save);
      final saveAction = tester.widget<FilledButton>(save).onPressed!;
      saveAction();
      saveAction();
      await tester.pump();
      expect(player.saveCalls, 1);
      expect(tester.widget<TextField>(field).enabled, isFalse);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('save-playback-source-config')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('api-key-qr-input')),
            )
            .onPressed,
        isNull,
      );

      player.writeGate.completeError(StateError('store unavailable'));
      await tester.pumpAndSettle();
      expect(find.textContaining('store unavailable'), findsOneWidget);
      expect(player.apiKey, 'existing-key');
      expect(
        tester.widget<TextField>(field).controller?.text,
        'replacement-key',
      );
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

      player.writeGate = Completer<void>()..complete();
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(player.saveCalls, 2);
      expect(player.apiKey, 'replacement-key');
      expect(
        (await SharedPreferences.getInstance()).getString('api_key'),
        'replacement-key',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pending API key save does not update a disposed page', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.ensureVisible(field);
    await tester.enterText(field, 'replacement-key');
    await tester.pumpAndSettle();
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();
    expect(player.saveCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    player.writeGate.completeError(StateError('store unavailable'));
    await tester.pumpAndSettle();
    expect(player.apiKey, 'existing-key');
    expect(tester.takeException(), isNull);
  });
}

class _DelayedApiKeyPlayer extends PlayerProvider {
  Completer<void> writeGate = Completer<void>();
  int saveCalls = 0;

  @override
  Future<void> setApiKey(String key) async {
    saveCalls++;
    await writeGate.future;
    await super.setApiKey(key);
  }
}
