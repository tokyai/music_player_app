import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/ai_assistant.dart';
import 'package:music_player_app/providers/ai_assistant_controller.dart';
import 'package:music_player_app/providers/ai_config_controller.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/screens/search_screen.dart';
import 'package:music_player_app/services/ai_punctuation_service.dart';
import 'package:music_player_app/services/ai_voice_service.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppColors.isDark = false;
  });

  for (final size in const [Size(640, 360), Size(1280, 800)]) {
    testWidgets('voice candidate can be edited and searched at '
        '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      await http.runWithClient(() async {
        final speech = _VoiceSpeech();
        final fixture = await _VoiceSearchFixture.create(speech);
        try {
          await fixture.pump(tester, size);

          final voiceButton = find.byKey(const ValueKey('search-voice-input'));
          expect(voiceButton.hitTestable(), findsOneWidget);
          await tester.tap(voiceButton);
          await tester.pumpAndSettle();

          final dialog = find.byKey(const ValueKey('search-voice-dialog'));
          final candidate = find.byKey(
            const ValueKey('search-voice-candidate'),
          );
          expect(dialog, findsOneWidget);
          expect(candidate, findsOneWidget);
          expect(find.text('正在听…'), findsOneWidget);
          final dialogRect = tester.getRect(dialog);
          expect(dialogRect.left, greaterThanOrEqualTo(0));
          expect(dialogRect.right, lessThanOrEqualTo(size.width));
          expect(dialogRect.top, greaterThanOrEqualTo(0));
          expect(dialogRect.bottom, lessThanOrEqualTo(size.height));
          expect(
            dialogRect.width,
            greaterThan(size == const Size(640, 360) ? 560 : 780),
          );
          final statusRect = tester.getRect(
            find.byKey(const ValueKey('search-voice-status')),
          );
          final candidateRect = tester.getRect(candidate);
          if (size.width > size.height) {
            expect(candidateRect.left, greaterThan(statusRect.right));
          } else {
            expect(statusRect.top, greaterThan(candidateRect.bottom));
          }
          expect(tester.takeException(), isNull);

          speech.emitResult('七里', false);
          await tester.pump();
          expect(tester.widget<TextField>(candidate).controller?.text, '七里');

          await tester.tap(candidate);
          await tester.pumpAndSettle();
          await tester.enterText(candidate, '七里香');
          await tester.pump();
          expect(speech.cancelCalls, greaterThanOrEqualTo(1));
          final confirm = find.byKey(const ValueKey('search-voice-confirm'));
          expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

          speech.emitResult('迟到的识别结果', true);
          await tester.pump();
          expect(tester.widget<TextField>(candidate).controller?.text, '七里香');

          await tester.tap(confirm);
          await tester.pumpAndSettle();

          expect(dialog, findsNothing);
          expect(fixture.session.keyword, '七里香');
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('search-field')))
                .controller
                ?.text,
            '七里香',
          );
          expect(speech.releaseCalls, 1);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.dispose(tester);
        }
      }, _voiceSearchClient);
    });
  }

  testWidgets('closing while speech initializes never starts recording', (
    tester,
  ) async {
    await http.runWithClient(() async {
      final initialization = Completer<bool>();
      final speech = _VoiceSpeech(initialization: initialization);
      final fixture = await _VoiceSearchFixture.create(speech);
      try {
        await fixture.pump(tester, const Size(640, 360));
        await tester.tap(find.byKey(const ValueKey('search-voice-input')));
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(const ValueKey('search-voice-dialog')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const ValueKey('search-voice-cancel')));
        await tester.pump();
        initialization.complete(true);
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('search-voice-dialog')), findsNothing);
        expect(speech.listenCalls, 0);
        expect(speech.cancelCalls, greaterThanOrEqualTo(1));
        expect(speech.releaseCalls, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    }, _voiceSearchClient);
  });

  testWidgets('stopping during listen startup ignores the stale start result', (
    tester,
  ) async {
    await http.runWithClient(() async {
      final listenCompletion = Completer<void>();
      final speech = _VoiceSpeech(listenCompletion: listenCompletion);
      final fixture = await _VoiceSearchFixture.create(speech);
      try {
        await fixture.pump(tester, const Size(640, 360));
        await tester.tap(find.byKey(const ValueKey('search-voice-input')));
        await tester.pumpAndSettle();
        expect(find.text('正在听…'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('search-voice-retry')));
        await tester.pumpAndSettle();

        expect(find.text('未识别到内容'), findsOneWidget);
        expect(find.text('语音输入未能启动，请重试'), findsNothing);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const ValueKey('search-voice-cancel')));
        await tester.pumpAndSettle();
      } finally {
        await fixture.dispose(tester);
      }
    }, _voiceSearchClient);
  });

  testWidgets('disposing the search page closes active voice resources', (
    tester,
  ) async {
    await http.runWithClient(() async {
      final listenCompletion = Completer<void>();
      final speech = _VoiceSpeech(listenCompletion: listenCompletion);
      final fixture = await _VoiceSearchFixture.create(speech);
      try {
        await fixture.pump(tester, const Size(640, 360));
        await tester.tap(find.byKey(const ValueKey('search-voice-input')));
        await tester.pumpAndSettle();
        expect(find.text('正在听…'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();

        expect(speech.cancelCalls, greaterThanOrEqualTo(1));
        expect(speech.releaseCalls, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    }, _voiceSearchClient);
  });
}

class _VoiceSearchFixture {
  final PlayerProvider player;
  final SearchSession session;
  final FavoriteService favorites;
  final AiConfigController config;
  final AiAssistantController assistant;

  _VoiceSearchFixture._({
    required this.player,
    required this.session,
    required this.favorites,
    required this.config,
    required this.assistant,
  });

  static Future<_VoiceSearchFixture> create(_VoiceSpeech speech) async {
    final player = PlayerProvider();
    final session = SearchSession();
    final favorites = FavoriteService();
    final config = AiConfigController(secretStore: MemoryAiSecretStore());
    await config.ready;
    final assistant = AiAssistantController(
      player: player,
      configController: config,
      speech: speech,
      punctuation: const NoopAiPunctuationService(),
      textToSpeech: _SilentTts(),
    );
    return _VoiceSearchFixture._(
      player: player,
      session: session,
      favorites: favorites,
      config: config,
      assistant: assistant,
    );
  }

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider<SearchSession>.value(value: session),
          ChangeNotifierProvider<FavoriteService>.value(value: favorites),
          ChangeNotifierProvider<AiConfigController>.value(value: config),
          ChangeNotifierProvider<AiAssistantController>.value(value: assistant),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const SearchScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    assistant.dispose();
    config.dispose();
    player.dispose();
    session.dispose();
    favorites.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

class _VoiceSpeech
    implements AiSpeechEngine, AiVoiceModelSelector, AiSpeechIdleResourceOwner {
  final Completer<bool>? initialization;
  final Completer<void>? listenCompletion;
  AiSpeechResultCallback? _onResult;
  void Function(String status)? _onStatus;
  AiVoiceModelKind? voiceModel;
  int listenCalls = 0;
  int cancelCalls = 0;
  int releaseCalls = 0;

  _VoiceSpeech({this.initialization, this.listenCompletion});

  @override
  void setVoiceModel(AiVoiceModelKind model) => voiceModel = model;

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async {
    _onStatus = onStatus;
    if (initialization != null) return initialization!.future;
    return true;
  }

  @override
  Future<void> listen(AiSpeechResultCallback onResult) async {
    listenCalls++;
    _onResult = onResult;
    _onStatus?.call('listening');
    await listenCompletion?.future;
  }

  @override
  Future<void> stop() async {
    _onStatus?.call('done');
    final completion = listenCompletion;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    final completion = listenCompletion;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  @override
  Future<void> releaseIdleResources() async {
    releaseCalls++;
  }

  void emitResult(String text, bool isFinal) => _onResult?.call(text, isFinal);
}

class _SilentTts implements AiTextToSpeechEngine {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}
}

http.Client _voiceSearchClient() {
  return MockClient((request) async {
    if (request.url.host != 'u.y.qq.com' || request.method != 'POST') {
      return _jsonResponse(<String, dynamic>{});
    }
    final payload = jsonDecode(request.body) as Map<String, dynamic>;
    final rawRequest = payload['req_1'];
    final params = rawRequest is Map ? rawRequest['param'] : null;
    final searchType = params is Map ? params['search_type'] : null;
    final keyword = params is Map ? params['query']?.toString() ?? '' : '';
    return _jsonResponse({
      'req_1': {
        'code': 0,
        'data': {
          'body': {
            'song': {
              'list': searchType == 3
                  ? <Object>[]
                  : [
                      {
                        'mid': 'voice-search-result',
                        'name': keyword,
                        'singer': [
                          {'name': '测试歌手'},
                        ],
                        'album': {'name': '测试专辑'},
                      },
                    ],
            },
            'songlist': {'list': <Object>[]},
          },
        },
      },
    });
  });
}

http.Response _jsonResponse(Map<String, dynamic> body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
