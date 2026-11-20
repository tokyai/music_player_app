import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/api_service.dart';
import 'package:music_player_app/services/runtime_http_client.dart';
import 'package:music_player_app/services/runtime_bridge_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'remote_business_v1': jsonEncode({
        'sources': {'163': 'future_source'},
        'qualities': {'163': 'future_quality'},
      }),
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, (call) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, null);
  });

  Future<SongDetail> resolve(ApiService api) => api.resolvePlayback(
    source: PlaybackSource.automatic,
    platform: MusicPlatform.netease,
    id: '347230',
    quality: 'exhigh',
    name: '海阔天空',
    artist: 'Beyond',
    album: '海阔天空',
    duration: 326,
  );

  test('新增服务端音源和音质不依赖原生枚举，恢复时仍排除实际失败源', () async {
    final requests = <Map<String, dynamic>>[];
    final client = RuntimeHttpClient(
      base: Uri.parse('https://runtime.test/'),
      client: MockClient((request) async {
        requests.add(
          Map<String, dynamic>.from(jsonDecode(request.body) as Map),
        );
        return http.Response(
          jsonEncode({
            'ok': true,
            'result': {
              'url': 'https://example.com/audio.mp3',
              'format': 'mp3',
              'providerId': 'future_source',
            },
          }),
          200,
        );
      }),
    );
    final api = ApiService(
      apiKey: '',
      runtimeClient: client,
      remoteEnabled: true,
    );
    try {
      final detail = await resolve(api);
      expect(detail.providerId, 'future_source');
      expect(detail.playbackSource, isNull);
      expect(requests.first['song']['source'], 'future_source');
      expect(requests.first['song']['quality'], 'future_quality');
      api.recordRemotePlaybackFailure(detail.providerId);
      await resolve(api);
      expect(
        requests.last['song']['excludedSources'],
        contains('future_source'),
      );
    } finally {
      api.close();
    }
  });

  test('用户会话关闭会取消远程解析，迟到响应不返回播放地址', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    final client = RuntimeHttpClient(
      base: Uri.parse('https://runtime.test/'),
      client: MockClient((request) {
        started.complete();
        return response.future;
      }),
    );
    final api = ApiService(
      apiKey: '',
      runtimeClient: client,
      remoteEnabled: true,
    );
    final operation = resolve(api);
    final expectation = expectLater(
      operation,
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'RESOLVE_CANCELLED',
        ),
      ),
    );
    await started.future;
    api.close();
    await expectation;
    response.complete(
      http.Response(
        jsonEncode({
          'ok': true,
          'result': {
            'url': 'https://example.com/audio.mp3',
            'providerId': 'future_source',
          },
        }),
        200,
      ),
    );
  });

  test('页面歌曲输入拒绝未知平台、任意本地文件和超大列表', () {
    for (final song in [
      {'platform': 'unknown', 'id': '1', 'name': 'test'},
      {'platform': 'local', 'id': 'file:///private/password', 'name': 'test'},
      {
        'platform': 'qq',
        'id': 'mid',
        'name': 'test',
        'bilibiliPages': List<dynamic>.filled(501, {}),
      },
    ]) {
      expect(() => RuntimeBridgeProtocol.song(song), throwsFormatException);
    }
  });

  test('原生媒体地址拒绝脚本协议和嵌入身份信息', () {
    for (final url in [
      'javascript:alert(1)',
      'file:///private',
      'https://user:secret@example.com/a.mp4',
    ]) {
      expect(() => RuntimeBridgeProtocol.mediaUrl(url), throwsFormatException);
    }
  });
}
