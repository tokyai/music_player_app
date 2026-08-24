import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/services/doubao_ime_asr_client.dart';
import 'package:music_player_app/services/proto/doubao_ime_asr.pb.dart' as pb;

void main() {
  test('parses interim, final and server error protobuf responses', () {
    final interim = parseDoubaoImeAsrResponse(
      pb.AsrResponse(
        resultJson: jsonEncode({
          'results': [
            {'text': '正在识别', 'is_interim': true},
          ],
          'extra': <String, Object?>{},
        }),
      ).writeToBuffer(),
    );
    final finalResult = parseDoubaoImeAsrResponse(
      pb.AsrResponse(
        resultJson: jsonEncode({
          'results': [
            {'text': '最终结果', 'is_interim': false, 'is_vad_finished': true},
          ],
          'extra': <String, Object?>{},
        }),
      ).writeToBuffer(),
    );
    final failure = parseDoubaoImeAsrResponse(
      pb.AsrResponse(
        messageType: 'TaskFailed',
        statusCode: 2,
        statusMessage: 'service discovery failure',
      ).writeToBuffer(),
    );

    expect(interim.kind, DoubaoImeAsrResponseKind.interim);
    expect(interim.text, '正在识别');
    expect(finalResult.kind, DoubaoImeAsrResponseKind.finalResult);
    expect(finalResult.text, '最终结果');
    expect(failure.kind, DoubaoImeAsrResponseKind.error);
    expect(isDoubaoImeCredentialRoutingError(failure.error), isTrue);
  });

  test(
    'registers a device, requests a token and replaces rejected credentials',
    () async {
      var registerCalls = 0;
      var tokenCalls = 0;
      final store = MemoryDoubaoImeCredentialStore(
        const DoubaoImeCredentials(
          deviceId: 'stale-device',
          installId: 'stale-install',
          cdid: 'stale-cdid',
          openUdid: 'stale-open',
          clientUdid: 'stale-client',
          token: 'stale-token',
        ),
      );
      final client = DoubaoImeAsrClient(
        credentialStore: store,
        httpClient: MockClient((request) async {
          if (request.url.path.contains('device_register')) {
            registerCalls++;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['magic_tag'], 'ss_app_log');
            return http.Response(
              jsonEncode({
                'device_id': 'fresh-device',
                'install_id': 'fresh-install',
              }),
              200,
            );
          }
          if (request.url.path.contains('/settings/')) {
            tokenCalls++;
            expect(request.body, 'body=null');
            return http.Response(
              jsonEncode({
                'data': {
                  'settings': {
                    'asr_config': {'app_key': 'fresh-token'},
                  },
                },
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );
      addTearDown(client.dispose);

      await client.prepare();
      expect(registerCalls, 0);
      expect(tokenCalls, 0);

      await client.resetCredentials();
      expect(store.value, isNull);
      await client.prepare();

      expect(registerCalls, 1);
      expect(tokenCalls, 1);
      expect(store.value?.deviceId, 'fresh-device');
      expect(store.value?.token, 'fresh-token');
    },
  );

  test(
    'starts a PCM session, sends bounded frame states and closes repeatedly',
    () async {
      final socket = _FakeDoubaoSocket();
      final client = DoubaoImeAsrClient(
        credentialStore: MemoryDoubaoImeCredentialStore(
          const DoubaoImeCredentials(
            deviceId: 'device-id',
            installId: 'install-id',
            cdid: 'cdid',
            openUdid: 'open-udid',
            clientUdid: 'client-udid',
            token: 'cached-token',
          ),
        ),
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'data': {
                'settings': {
                  'asr_config': {'app_key': 'refreshed-token'},
                },
              },
            }),
            200,
          );
        }),
        socketConnector: (uri, headers, timeout) async {
          expect(uri.queryParameters['device_id'], 'device-id');
          expect(headers['proto-version'], 'v2');
          return socket;
        },
      );
      addTearDown(client.dispose);

      final session = await client.openSession();
      final startSession = socket.requests.firstWhere(
        (request) => request.methodName == 'StartSession',
      );
      final payload = jsonDecode(startSession.payload) as Map<String, dynamic>;
      expect(
        (payload['audio_info'] as Map<String, dynamic>)['format'],
        'speech_pcm',
      );
      expect(
        (payload['extra'] as Map<String, dynamic>)['app_name'],
        'com.android.chrome',
      );

      session.sendAudio(
        Uint8List(640),
        frameState: DoubaoImeAudioFrameState.first,
        timestampMilliseconds: 123,
      );
      session.sendAudio(
        Uint8List(640),
        frameState: DoubaoImeAudioFrameState.last,
        timestampMilliseconds: 143,
      );
      session.finish();
      final audioRequests = socket.requests
          .where((request) => request.methodName == 'TaskRequest')
          .toList();
      expect(audioRequests, hasLength(2));
      expect(audioRequests.first.frameState, pb.FrameState.FRAME_STATE_FIRST);
      expect(audioRequests.last.frameState, pb.FrameState.FRAME_STATE_LAST);
      expect(audioRequests.first.audioData, hasLength(640));
      expect(
        jsonDecode(audioRequests.first.payload),
        containsPair('timestamp_ms', 123),
      );

      socket.emit(
        pb.AsrResponse(messageType: 'SessionFinished').writeToBuffer(),
      );
      expect(
        (await session.nextResponse())?.kind,
        DoubaoImeAsrResponseKind.sessionFinished,
      );
      await session.close();
      await session.close();
      await client.dispose();
      await client.dispose();
      expect(socket.closeCalls, 1);
    },
  );
}

class _FakeDoubaoSocket implements DoubaoImeAsrSocket {
  final StreamController<Object?> _messages = StreamController<Object?>();
  final List<pb.AsrRequest> requests = [];
  int closeCalls = 0;
  bool _closed = false;

  @override
  Stream<Object?> get messages => _messages.stream;

  @override
  void add(Uint8List data) {
    final request = pb.AsrRequest.fromBuffer(data);
    requests.add(request);
    switch (request.methodName) {
      case 'StartTask':
        emit(pb.AsrResponse(messageType: 'TaskStarted').writeToBuffer());
        break;
      case 'StartSession':
        emit(pb.AsrResponse(messageType: 'SessionStarted').writeToBuffer());
        break;
    }
  }

  void emit(Uint8List data) {
    if (!_closed) _messages.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closeCalls++;
    await _messages.close();
  }
}
