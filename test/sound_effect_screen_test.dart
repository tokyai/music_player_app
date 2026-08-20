import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/sound_effect.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/screens/sound_effect_screen.dart';
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_layout.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sound effect page keeps controls usable in supported layouts', (
    tester,
  ) async {
    for (final size in const [
      Size(400, 800),
      Size(640, 360),
      Size(1280, 800),
    ]) {
      SharedPreferences.setMockInitialValues({});
      final player = _SoundEffectPlayer();
      await _pump(tester, player, size);

      expect(find.byKey(const ValueKey('sound-effect-back')), findsOneWidget);
      expect(find.byKey(const ValueKey('sound-effect-toggle')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sound-effect-preset-grid')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sound-effect-preset-501')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sound-effect-preset-500')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sound-effect-back')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sound-effect-toggle')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sound-effect-preset-500')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.byKey(const ValueKey('sound-effect-preset-500')).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(player.soundEffectPreset.id, 500);
      expect(player.soundEffectEnabled, isTrue);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets(
    'sound effect switch disables processing without hiding presets',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final player = _SoundEffectPlayer();
      await _pump(tester, player, const Size(640, 360));

      await tester.tap(
        find.byKey(const ValueKey('sound-effect-toggle')).hitTestable(),
      );
      await tester.pumpAndSettle();

      expect(player.soundEffectEnabled, isFalse);
      expect(find.text('关闭时保持原始声音'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sound-effect-preset-501')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );

  testWidgets('sound effect entry opens from landscape settings', (
    tester,
  ) async {
    for (final size in const [Size(640, 360), Size(1280, 800)]) {
      SharedPreferences.setMockInitialValues({});
      final player = _SoundEffectPlayer();
      final favorites = FavoriteService();
      final theme = ThemeController();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<FavoriteService>.value(value: favorites),
            ChangeNotifierProvider<ThemeController>.value(value: theme),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: AppLayout.adaptiveMediaQueryOf(context),
              child: child!,
            ),
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final entry = find.byKey(const ValueKey('sound-effect-setting'));
      final pane = find.descendant(
        of: find.byKey(const PageStorageKey('settings-landscape-preferences')),
        matching: find.byType(Scrollable),
      );
      expect(entry, findsOneWidget);
      expect(pane, findsOneWidget);
      await tester.scrollUntilVisible(entry, 220, scrollable: pane);
      await tester.pumpAndSettle();
      expect(entry.hitTestable(), findsOneWidget);
      await tester.tap(entry.hitTestable());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('sound-effect-current-panel')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('sound-effect-back')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      favorites.dispose();
      theme.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _pump(
  WidgetTester tester,
  PlayerProvider player,
  Size size,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    ChangeNotifierProvider<PlayerProvider>.value(
      value: player,
      child: MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: AppLayout.adaptiveMediaQueryOf(context),
          child: child!,
        ),
        home: const SoundEffectScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _SoundEffectPlayer extends PlayerProvider {
  static const _presets = [
    SoundEffectPreset(
      id: 501,
      type: 1,
      name: '超重低音',
      description: '加强低频下潜与力度',
      tags: ['重低音'],
    ),
    SoundEffectPreset(
      id: 500,
      type: 1,
      name: '全景环绕',
      description: '拓宽声场与空间包裹感',
      tags: ['环绕', '耳机'],
    ),
    SoundEffectPreset(
      id: 502,
      type: 1,
      name: '清澈人声',
      description: '突出清晰自然的人声',
      tags: ['人声'],
    ),
    SoundEffectPreset(
      id: 52,
      type: 1,
      name: '起居室',
      description: '模拟开阔室内空间',
      tags: ['环境模拟'],
    ),
  ];

  SoundEffectPreset _selected = _presets.first;
  bool _enabled = true;

  @override
  bool get soundEffectAvailable => true;

  @override
  bool get soundEffectEnabled => _enabled;

  @override
  String get soundEffectStatusMessage => '';

  @override
  List<SoundEffectPreset> get soundEffectPresets => _presets;

  @override
  SoundEffectPreset get soundEffectPreset => _selected;

  @override
  Future<bool> setSoundEffectEnabled(bool enabled) async {
    _enabled = enabled;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> selectSoundEffect(SoundEffectPreset preset) async {
    _selected = preset;
    _enabled = true;
    notifyListeners();
    return true;
  }
}
