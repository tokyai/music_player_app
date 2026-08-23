import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/services/floating_capsule_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(FloatingCapsuleService.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FloatingCapsuleService.setEnabled(false);
    FloatingCapsuleService.onPlayPauseTap = null;
    FloatingCapsuleService.onCapsuleTap = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'restores the mini window preference and migrates the legacy key',
    () async {
      SharedPreferences.setMockInitialValues({
        FloatingCapsuleService.legacyPreferenceKey: true,
      });

      expect(await FloatingCapsuleService.restoreEnabled(), isTrue);
      expect(FloatingCapsuleService.enabled, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(FloatingCapsuleService.preferenceKey), isTrue);
    },
  );

  test('show and state updates send complete mini window payloads', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    FloatingCapsuleService.setEnabled(true);

    await FloatingCapsuleService.show(
      title: '夜曲',
      artist: '周杰伦',
      coverUrl: 'https://example.test/cover.jpg',
      isPlaying: true,
    );
    await FloatingCapsuleService.update(
      title: '晴天',
      artist: '周杰伦',
      isPlaying: false,
    );
    await FloatingCapsuleService.updatePlayState(true);
    await FloatingCapsuleService.hide();

    expect(calls.map((call) => call.method), [
      'show',
      'update',
      'updatePlayState',
      'hide',
    ]);
    expect(calls.first.arguments, {
      'title': '夜曲',
      'artist': '周杰伦',
      'coverUrl': 'https://example.test/cover.jpg',
      'isPlaying': true,
    });
    expect(calls[1].arguments, {
      'title': '晴天',
      'artist': '周杰伦',
      'coverUrl': null,
      'isPlaying': false,
    });
    expect(calls[2].arguments, {'isPlaying': true});
  });

  test('show and update stay silent while the feature is disabled', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    await FloatingCapsuleService.show(
      title: '不会显示',
      artist: '测试',
      isPlaying: false,
    );
    await FloatingCapsuleService.update(
      title: '不会显示',
      artist: '测试',
      isPlaying: false,
    );
    await FloatingCapsuleService.updatePlayState(false);

    expect(calls, isEmpty);
  });
}
