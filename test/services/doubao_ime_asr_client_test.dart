import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/services/doubao_ime_asr_client.dart';
import 'package:music_player_app/services/proto/doubao_ime_asr.pb.dart' as pb;

int _nowEpochSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  test('marks legacy and expired credentials for refresh', () {
    final now = DateTime(2026, 8, 26, 12);
    const legacy = DoubaoImeCredentials(
      deviceId: 'device',
      installId: 'install',
      cdid: 'cdid',
      openUdid: 'open',
      clientUdid: 'client',
      token: 'token',
    );
    final decodedLegacy = DoubaoImeCredentials.fromJson(const {
      'device_id': 'device',
      'install_id': 'install',
      'cdid': 'cdid',
      'openudid': 'open',
      'clientudid': 'client',
      'token': 'token',
    });
    final fresh = legacy.copyWith(
      refreshedAtEpochSeconds:
          now.millisecondsSinceEpoch ~/ 1000 - 6 * 60 * 60 + 1,
    );
    final expired = legacy.copyWith(
      refreshedAtEpochSeconds: now.millisecondsSinceEpoch ~/ 1000 - 6 * 60 * 60,
    );

    expect(isDoubaoImeCredentialRefreshDue(legacy, now: now), isTrue);
    expect(decodedLegacy.refreshedAtEpochSeconds, 0);
    expect(isDoubaoImeCredentialRefreshDue(fresh, now: now), isFalse);
    expect(isDoubaoImeCredentialRefreshDue(expired, now: now), isTrue);
    expect(
      DoubaoImeCredentials.fromJson(fresh.toJson()).refreshedAtEpochSeconds,
      fresh.refreshedAtEpochSeconds,
    );
  });

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
    final numericFailure = parseDoubaoImeAsrResponse(
      pb.AsrResponse(
        messageType: 'SessionFailed',
        statusCode: 50700000,
      ).writeToBuffer(),
    );

    expect(interim.kind, DoubaoImeAsrResponseKind.interim);
    expect(interim.text, '正在识别');
    expect(finalResult.kind, DoubaoImeAsrResponseKind.finalResult);
    expect(finalResult.text, '最终结果');
    expect(failure.kind, DoubaoImeAsrResponseKind.error);
    expect(failure.messageType, 'TaskFailed');
    expect(failure.statusCode, 2);
    expect(failure.statusMessage, 'service discovery failure');
    expect(isDoubaoImeCredentialRoutingError(failure.error), isTrue);
    expect(isDoubaoImeCredentialRoutingError(numericFailure.error), isTrue);
    expect(
      isDoubaoImeCredentialRoutingError(
        'backend read failed',
        statusCode: 50700000,
      ),
      isTrue,
    );
    expect(isDoubaoImeCredentialRoutingError('read backend response'), isTrue);
  });

  test(
    'refreshes a legacy credential and persists the refresh timestamp',
    () async {
      final store = MemoryDoubaoImeCredentialStore(
        const DoubaoImeCredentials(
          deviceId: 'device-id',
          installId: 'install-id',
          cdid: 'cdid',
          openUdid: 'open-udid',
          clientUdid: 'client-udid',
          token: 'legacy-token',
        ),
      );
      var tokenCalls = 0;
      http.Response tokenResponse() => http.Response(
        jsonEncode({
          'data': {
            'settings': {
              'asr_config': {'app_key': 'fresh-token'},
            },
          },
        }),
        200,
      );
      final first = DoubaoImeAsrClient(
        credentialStore: store,
        httpClient: MockClient((_) async {
          tokenCalls++;
          return tokenResponse();
        }),
      );
      addTearDown(first.dispose);

      await first.prepare();
      expect(tokenCalls, 1);
      expect(store.value?.refreshedAtEpochSeconds, greaterThan(0));

      final second = DoubaoImeAsrClient(
        credentialStore: store,
        httpClient: MockClient((_) async {
          tokenCalls++;
          return tokenResponse();
        }),
      );
      addTearDown(second.dispose);
      await second.prepare();
      expect(tokenCalls, 1);
    },
  );

  test(
    'keeps a cached token when proactive refresh temporarily fails',
    () async {
      final store = MemoryDoubaoImeCredentialStore(
        const DoubaoImeCredentials(
          deviceId: 'device-id',
          installId: 'install-id',
          cdid: 'cdid',
          openUdid: 'open-udid',
          clientUdid: 'client-udid',
          token: 'cached-token',
        ),
      );
      var tokenCalls = 0;
      final client = DoubaoImeAsrClient(
        credentialStore: store,
        httpClient: MockClient((_) async {
          tokenCalls++;
          return http.Response('temporarily unavailable', 503);
        }),
      );
      addTearDown(client.dispose);

      await client.prepare();
      await client.prepare();

      expect(tokenCalls, 1);
      expect(store.value?.token, 'cached-token');
      expect(store.value?.refreshedAtEpochSeconds, 0);
    },
  );

  test('does not publish a token refresh after disposal', () async {
    final store = MemoryDoubaoImeCredentialStore(
      const DoubaoImeCredentials(
        deviceId: 'device-id',
        installId: 'install-id',
        cdid: 'cdid',
        openUdid: 'open-udid',
        clientUdid: 'client-udid',
        token: 'cached-token',
      ),
    );
    final requestStarted = Completer<void>();
    final response = Completer<http.Response>();
    final client = DoubaoImeAsrClient(
      credentialStore: store,
      httpClient: MockClient((_) {
        if (!requestStarted.isCompleted) requestStarted.complete();
        return response.future;
      }),
    );
    final refresh = expectLater(
      client.refreshToken(),
      throwsA(isA<DoubaoImeAsrException>()),
    );
    await requestStarted.future;

    await client.dispose();
    response.complete(
      http.Response(
        jsonEncode({
          'data': {
            'settings': {
              'asr_config': {'app_key': 'late-token'},
            },
          },
        }),
        200,
      ),
    );
    await refresh;

    expect(store.value?.token, 'cached-token');
    expect(store.value?.refreshedAtEpochSeconds, 0);
  });

  test(
    'registers a device, requests a token and replaces rejected credentials',
    () async {
      var registerCalls = 0;
      var tokenCalls = 0;
      final store = MemoryDoubaoImeCredentialStore(
        DoubaoImeCredentials(
          deviceId: 'stale-device',
          installId: 'stale-install',
          cdid: 'stale-cdid',
          openUdid: 'stale-open',
          clientUdid: 'stale-client',
          token: 'stale-token',
          refreshedAtEpochSeconds: _nowEpochSeconds(),
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
      var tokenCalls = 0;
      final store = _CountingCredentialStore(
        DoubaoImeCredentials(
          deviceId: 'device-id',
          installId: 'install-id',
          cdid: 'cdid',
          openUdid: 'open-udid',
          clientUdid: 'client-udid',
          token: 'cached-token',
          refreshedAtEpochSeconds: _nowEpochSeconds(),
        ),
      );
      final client = DoubaoImeAsrClient(
        credentialStore: store,
        httpClient: MockClient((request) async {
          tokenCalls++;
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
      expect(tokenCalls, 0);
      expect(store.readCalls, 1);
      expect(store.writeCalls, 0);
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
      final extra = payload['extra'] as Map<String, dynamic>;
      expect(extra['enable_asr_twopass'], isTrue);
      expect(extra['enable_asr_threepass'], isTrue);
      expect(extra['use_twopass_retry'], isTrue);
      expect(extra['finish_wait_offline_time'], 1000);

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

  test('refreshes a rejected token before retrying the session', () async {
    final store = MemoryDoubaoImeCredentialStore(
      DoubaoImeCredentials(
        deviceId: 'device-id',
        installId: 'install-id',
        cdid: 'cdid',
        openUdid: 'open-udid',
        clientUdid: 'client-udid',
        token: 'cached-token',
        refreshedAtEpochSeconds: _nowEpochSeconds(),
      ),
    );
    var socketCalls = 0;
    var tokenCalls = 0;
    final client = DoubaoImeAsrClient(
      credentialStore: store,
      httpClient: MockClient((request) async {
        tokenCalls++;
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
      }),
      socketConnector: (uri, headers, timeout) async {
        socketCalls++;
        return _FakeDoubaoSocket(failOnStartSession: socketCalls == 1);
      },
    );
    addTearDown(client.dispose);

    final recovered = await client.openSession();
    // A healthy cached credential is used directly.  Token refresh is only
    // performed after the provider rejects the first session.
    expect(socketCalls, 2);
    expect(tokenCalls, 1);
    expect(store.value?.deviceId, 'device-id');
    expect(store.value?.token, 'fresh-token');
    await recovered.close();
  });

  test(
    're-registers the device when a refreshed token is still rejected',
    () async {
      final store = MemoryDoubaoImeCredentialStore(
        DoubaoImeCredentials(
          deviceId: 'stale-device',
          installId: 'stale-install',
          cdid: 'stale-cdid',
          openUdid: 'stale-open',
          clientUdid: 'stale-client',
          token: 'stale-token',
          refreshedAtEpochSeconds: _nowEpochSeconds(),
        ),
      );
      var registerCalls = 0;
      var tokenCalls = 0;
      var socketCalls = 0;
      final client = DoubaoImeAsrClient(
        credentialStore: store,
        httpClient: MockClient((request) async {
          if (request.url.path.contains('device_register')) {
            registerCalls++;
            return http.Response(
              jsonEncode({
                'device_id': 'fresh-device',
                'install_id': 'fresh-install',
              }),
              200,
            );
          }
          tokenCalls++;
          return http.Response(
            jsonEncode({
              'data': {
                'settings': {
                  'asr_config': {'app_key': 'fresh-token-$tokenCalls'},
                },
              },
            }),
            200,
          );
        }),
        socketConnector: (uri, headers, timeout) async {
          socketCalls++;
          return _FakeDoubaoSocket(failOnStartSession: socketCalls < 3);
        },
      );
      addTearDown(client.dispose);

      final recovered = await client.openSession();

      expect(socketCalls, 3);
      // The first rejected session uses the cached token; subsequent retries
      // refresh only when the provider explicitly rejects the session.
      expect(tokenCalls, 2);
      expect(registerCalls, 1);
      expect(store.value?.deviceId, 'fresh-device');
      expect(store.value?.installId, 'fresh-install');
      await recovered.close();
    },
  );
}

class _CountingCredentialStore implements DoubaoImeCredentialStore {
  _CountingCredentialStore(this.value);

  DoubaoImeCredentials? value;
  int readCalls = 0;
  int writeCalls = 0;

  @override
  Future<DoubaoImeCredentials?> read() async {
    readCalls++;
    return value;
  }

  @override
  Future<void> write(DoubaoImeCredentials credentials) async {
    writeCalls++;
    value = credentials;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class _FakeDoubaoSocket implements DoubaoImeAsrSocket {
  final bool failOnStartSession;
  final StreamController<Object?> _messages = StreamController<Object?>();
  final List<pb.AsrRequest> requests = [];
  int closeCalls = 0;
  bool _closed = false;

  _FakeDoubaoSocket({this.failOnStartSession = false});

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
        emit(
          (failOnStartSession
                  ? pb.AsrResponse(
                      messageType: 'SessionFailed',
                      statusCode: 50700000,
                      statusMessage: 'service discovery failure',
                    )
                  : pb.AsrResponse(messageType: 'SessionStarted'))
              .writeToBuffer(),
        );
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
