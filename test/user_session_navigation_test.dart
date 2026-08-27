import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/main.dart';
import 'package:music_player_app/providers/ai_config_controller.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/providers/user_controller.dart';
import 'package:music_player_app/screens/search_screen.dart';
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/services/floating_capsule_service.dart';
import 'package:music_player_app/services/user_data_scope.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppColors.isDark = false;
  });

  for (final size in const [Size(592, 1280), Size(640, 360), Size(1280, 800)]) {
    testWidgets('switching users rebuilds cached pages at '
        '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      const floatingChannel = MethodChannel(FloatingCapsuleService.channelName);
      const secureStorageChannel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        floatingChannel,
        (call) async => call.method == 'hasPermission' ? true : null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        secureStorageChannel,
        (_) async => null,
      );

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          floatingChannel,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          secureStorageChannel,
          null,
        );
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final users = UserController();
      await users.ready;
      final second = await users.createUser(
        name: '副驾驶',
        avatarId: 'headphones',
        avatarColorIndex: 2,
      );
      final secondScope = UserDataScope(second.id);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('api_key', 'default-user-key');
      await prefs.setString(
        secondScope.preferenceKey('api_key'),
        'second-user-key',
      );
      await prefs.setStringList('search_history', ['默认用户搜索']);
      await prefs.setStringList(secondScope.preferenceKey('search_history'), [
        '新用户搜索',
      ]);
      await prefs.setBool(
        secondScope.preferenceKey(
          AiConfigController.showAssistantOnAllPagesPreferenceKey,
        ),
        false,
      );
      await prefs.setDouble(
        secondScope.preferenceKey(AiConfigController.petScalePreferenceKey),
        0.75,
      );

      final initialPlayer = PlayerProvider(
        dataScope: users.activeScope,
        activateRestoredSession: false,
      );
      PlayerProvider? systemPlayer;
      await tester.pumpWidget(
        MusicPlayerApp(
          player: initialPlayer,
          users: users,
          bindSystemPlayer: (player) => systemPlayer = player,
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      final initialMainState = tester.state(find.byType(MainScreen));
      final initialAiConfig = tester
          .element(find.byType(MainScreen))
          .read<AiConfigController>();
      await initialAiConfig.ready;
      await initialAiConfig.setShowAssistantOnAllPages(true);
      await initialAiConfig.setPetScale(1);
      await _selectDestination(tester, '设置');
      final initialSettingsState = tester.state(find.byType(SettingsScreen));

      await _selectDestination(tester, '搜索');
      final initialSearchState = tester.state(find.byType(SearchScreen));
      final initialSearch = tester
          .element(find.byType(SearchScreen))
          .read<SearchSession>();
      expect(initialSearch.searchHistory, ['默认用户搜索']);
      if (size.width >= 1000) {
        expect(
          find.byKey(const ValueKey('search-history-item-默认用户搜索')),
          findsOneWidget,
        );
      }

      await _selectDestination(tester, '发现');
      await users.switchUser(second.id);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(initialMainState.mounted, isFalse);
      expect(initialSettingsState.mounted, isFalse);
      expect(initialSearchState.mounted, isFalse);
      expect(tester.state(find.byType(MainScreen)), isNot(initialMainState));
      expect(systemPlayer?.dataScope.userId, second.id);

      await _selectDestination(tester, '搜索');
      expect(
        tester.state(find.byType(SearchScreen)),
        isNot(initialSearchState),
      );
      final switchedSearch = tester
          .element(find.byType(SearchScreen))
          .read<SearchSession>();
      expect(switchedSearch.dataScope.userId, second.id);
      expect(switchedSearch.searchHistory, ['新用户搜索']);
      if (size.width >= 1000) {
        expect(
          find.byKey(const ValueKey('search-history-item-新用户搜索')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('search-history-item-默认用户搜索')),
          findsNothing,
        );
      }

      await _selectDestination(tester, '设置');
      expect(
        tester.state(find.byType(SettingsScreen)),
        isNot(initialSettingsState),
      );
      final settingsContext = tester.element(find.byType(SettingsScreen));
      final aiConfig = settingsContext.read<AiConfigController>();
      expect(identical(aiConfig, initialAiConfig), isTrue);
      expect(aiConfig.dataScope.isDefault, isTrue);
      expect(aiConfig.showAssistantOnAllPages, isTrue);
      expect(aiConfig.petScale, 1);

      final systemScroll = size.width > size.height
          ? find
                .descendant(
                  of: find.byKey(
                    const PageStorageKey<String>('settings-landscape-system'),
                  ),
                  matching: find.byType(Scrollable),
                )
                .first
          : find
                .descendant(
                  of: find.byType(SettingsScreen),
                  matching: find.byType(Scrollable),
                )
                .first;
      final apiKeyField = find.byKey(const ValueKey('api-key-field'));
      await tester.scrollUntilVisible(
        apiKeyField,
        180,
        scrollable: systemScroll,
      );
      expect(
        tester.widget<TextField>(apiKeyField).controller?.text,
        'default-user-key',
      );

      final allPagesToggle = find.byKey(const ValueKey('ai-all-pages-toggle'));
      await tester.scrollUntilVisible(
        allPagesToggle,
        180,
        scrollable: systemScroll,
      );
      var toggle = tester.widget<SwitchListTile>(allPagesToggle);
      expect(toggle.value, isTrue);
      toggle.onChanged?.call(false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(aiConfig.showAssistantOnAllPages, isFalse);
      toggle = tester.widget<SwitchListTile>(allPagesToggle);
      expect(toggle.value, isFalse);

      final petScaleSlider = find.byKey(const ValueKey('ai-pet-scale-slider'));
      final slider = tester.widget<Slider>(petScaleSlider);
      expect(slider.value, 1);
      slider.onChanged?.call(1.5);
      slider.onChangeEnd?.call(1.5);
      await tester.pump(const Duration(milliseconds: 100));
      expect(aiConfig.petScale, 1.5);
      expect(tester.widget<Slider>(petScaleSlider).value, 1.5);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _selectDestination(WidgetTester tester, String label) async {
  final rail = find.byKey(const ValueKey('landscape-navigation'));
  final navigation = rail.evaluate().isNotEmpty
      ? rail
      : find.byType(NavigationBar);
  final destination = find
      .descendant(of: navigation, matching: find.text(label))
      .first;
  await tester.ensureVisible(destination);
  await tester.pump();
  await tester.tap(destination);
  await tester.pump(const Duration(milliseconds: 250));
}
