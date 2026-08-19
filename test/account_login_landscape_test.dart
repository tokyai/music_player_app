import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/main.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/screens/login_screen.dart';
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/services/account_service.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final size in [const Size(640, 360), const Size(1280, 800)]) {
    testWidgets(
      'login remains fully operable at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final account = AccountService();
        addTearDown(account.dispose);

        await tester.pumpWidget(
          ChangeNotifierProvider<AccountService>.value(
            value: account,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: LoginScreen(onLogin: (_, _, _) async {}),
            ),
          ),
        );
        await tester.pump();

        expect(find.byKey(const ValueKey('account-username')), findsOneWidget);
        expect(find.byKey(const ValueKey('account-password')), findsOneWidget);
        expect(find.byKey(const ValueKey('account-server')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('account-login-submit')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const ValueKey('account-login-submit')));
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final size in [const Size(640, 360), const Size(1280, 800)]) {
    testWidgets(
      'disabled account keeps logout path visible at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var calls = 0;
        final account = AccountService(
          client: MockClient((request) async {
            calls++;
            if (calls == 1) {
              return http.Response(
                jsonEncode({
                  'token': 'c' * 48,
                  'user': {
                    'id': 'disabled-user',
                    'username': 'disabled-user',
                    'role': 'user',
                    'status': 'active',
                  },
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode({'error': 'USER_DISABLED', 'message': '管理员已暂停此账号'}),
              403,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );
        await account.login(
          serverUrl: 'https://accounts.example.com/api',
          username: 'disabled-user',
          password: 'correct-password',
        );
        try {
          await account.request('GET', '/me', authenticated: true);
        } on AccountException {
          // The state transition is asserted through the rendered gate.
        }
        final player = PlayerProvider();
        addTearDown(() {
          player.dispose();
          account.dispose();
        });

        await tester.pumpWidget(
          MusicPlayerApp(player: player, account: account),
        );
        await tester.pump();

        expect(find.text('账号不可用'), findsOneWidget);
        expect(find.text('管理员已暂停此账号'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('disabled-account-logout')),
          findsOneWidget,
        );
        expect(find.byType(MainScreen), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final size in [const Size(640, 360), const Size(1280, 800)]) {
    testWidgets(
      'account controls remain present in settings at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final account = AccountService();
        final player = PlayerProvider();
        final theme = ThemeController();
        final favorites = FavoriteService();
        await Future.wait([player.settingsReady, favorites.load()]);
        addTearDown(() {
          player.dispose();
          theme.dispose();
          favorites.dispose();
          account.dispose();
        });

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<AccountService>.value(value: account),
              ChangeNotifierProvider<PlayerProvider>.value(value: player),
              ChangeNotifierProvider<ThemeController>.value(value: theme),
              ChangeNotifierProvider<FavoriteService>.value(value: favorites),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const SettingsScreen(),
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('settings-account-summary')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('settings-sync-now')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('settings-account-logout')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
