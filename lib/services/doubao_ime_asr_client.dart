import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'proto/doubao_ime_asr.pb.dart' as pb;

const _doubaoAid = '401734';
const _doubaoAppName = 'oime';
const _doubaoVersionCode = '100102018';
const _doubaoVersionName = '1.1.2';
const _doubaoPackageName = 'com.bytedance.android.doubaoime';
const _doubaoUserAgent =
    'com.bytedance.android.doubaoime/100102018 '
    '(Linux; U; Android 16; en_US; Pixel 7 Pro; '
    'Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a '
    '2025-11-17 QuicVersion:1f89f732 2025-05-08)';

class DoubaoImeAsrEndpoints {
  final Uri register;
  final Uri settings;
  final Uri websocket;

  const DoubaoImeAsrEndpoints({
    required this.register,
    required this.settings,
    required this.websocket,
  });

  static final production = DoubaoImeAsrEndpoints(
    register: Uri.parse('https://log.snssdk.com/service/2/device_register/'),
    settings: Uri.parse('https://is.snssdk.com/service/settings/v3/'),
    websocket: Uri.parse(
      'wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws',
    ),
  );
}

class DoubaoImeCredentials {
  final String deviceId;
  final String installId;
  final String cdid;
  final String openUdid;
  final String clientUdid;
  final String token;

  const DoubaoImeCredentials({
    required this.deviceId,
    required this.installId,
    required this.cdid,
    required this.openUdid,
    required this.clientUdid,
    this.token = '',
  });

  DoubaoImeCredentials copyWith({String? token}) => DoubaoImeCredentials(
    deviceId: deviceId,
    installId: installId,
    cdid: cdid,
    openUdid: openUdid,
    clientUdid: clientUdid,
    token: token ?? this.token,
  );

  Map<String, Object?> toJson() => {
    'device_id': deviceId,
    'install_id': installId,
    'cdid': cdid,
    'openudid': openUdid,
    'clientudid': clientUdid,
    'token': token,
  };

  factory DoubaoImeCredentials.fromJson(Map<String, Object?> json) {
    String requiredString(String key) {
      final value = json[key]?.toString().trim() ?? '';
      if (value.isEmpty) throw FormatException('missing $key');
      return value;
    }

    return DoubaoImeCredentials(
      deviceId: requiredString('device_id'),
      installId: requiredString('install_id'),
      cdid: requiredString('cdid'),
      openUdid: requiredString('openudid'),
      clientUdid: requiredString('clientudid'),
      token: json['token']?.toString().trim() ?? '',
    );
  }
}

abstract interface class DoubaoImeCredentialStore {
  Future<DoubaoImeCredentials?> read();
  Future<void> write(DoubaoImeCredentials credentials);
  Future<void> clear();
}

class SecureDoubaoImeCredentialStore implements DoubaoImeCredentialStore {
  static const _key = 'doubao_ime_asr_credentials_v1';
  static const _storage = FlutterSecureStorage();

  const SecureDoubaoImeCredentialStore();

  @override
  Future<DoubaoImeCredentials?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty || raw.length > 16 * 1024) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return DoubaoImeCredentials.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(DoubaoImeCredentials credentials) =>
      _storage.write(key: _key, value: jsonEncode(credentials.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class MemoryDoubaoImeCredentialStore implements DoubaoImeCredentialStore {
  DoubaoImeCredentials? value;

  MemoryDoubaoImeCredentialStore([this.value]);

  @override
  Future<DoubaoImeCredentials?> read() async => value;

  @override
  Future<void> write(DoubaoImeCredentials credentials) async {
    value = credentials;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class DoubaoImeAsrException implements Exception {
  final String message;

  const DoubaoImeAsrException(this.message);

  @override
  String toString() => message;
}

enum DoubaoImeAsrResponseKind {
  taskStarted,
  sessionStarted,
  sessionFinished,
  vadStarted,
  interim,
  finalResult,
  heartbeat,
  error,
  unknown,
}

enum DoubaoImeAudioFrameState { first, middle, last }

class DoubaoImeAsrResponse {
  final DoubaoImeAsrResponseKind kind;
  final String text;
  final String error;

  const DoubaoImeAsrResponse({
    required this.kind,
    this.text = '',
    this.error = '',
  });
}

abstract interface class DoubaoImeAsrConnection {
  void sendAudio(
    Uint8List bytes, {
    required DoubaoImeAudioFrameState frameState,
    required int timestampMilliseconds,
  });
  void finish();
  Future<DoubaoImeAsrResponse?> nextResponse();
  Future<void> close();
}

abstract interface class DoubaoImeAsrGateway {
  Future<void> prepare();
  Future<DoubaoImeAsrConnection> openSession();
  Future<void> refreshToken();
  Future<void> resetCredentials();
  Future<void> dispose();
}

abstract interface class DoubaoImeAsrSocket {
  Stream<Object?> get messages;
  void add(Uint8List data);
  Future<void> close();
}

typedef DoubaoImeAsrSocketConnector =
    Future<DoubaoImeAsrSocket> Function(
      Uri uri,
      Map<String, String> headers,
      Duration timeout,
    );

class _IoDoubaoImeAsrSocket implements DoubaoImeAsrSocket {
  final WebSocket _socket;

  _IoDoubaoImeAsrSocket(this._socket);

  @override
  Stream<Object?> get messages => _socket;

  @override
  void add(Uint8List data) => _socket.add(data);

  @override
  Future<void> close() async {
    await _socket
        .close(WebSocketStatus.normalClosure)
        .timeout(const Duration(seconds: 2));
  }
}

Future<DoubaoImeAsrSocket> _connectDoubaoSocket(
  Uri uri,
  Map<String, String> headers,
  Duration timeout,
) async {
  final socket = await WebSocket.connect(
    uri.toString(),
    headers: headers,
  ).timeout(timeout);
  socket.pingInterval = const Duration(seconds: 10);
  return _IoDoubaoImeAsrSocket(socket);
}

class DoubaoImeAsrClient implements DoubaoImeAsrGateway {
  static const _httpTimeout = Duration(seconds: 12);
  static const _socketTimeout = Duration(seconds: 10);
  static const _maxResponseBytes = 256 * 1024;

  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final DoubaoImeCredentialStore _credentialStore;
  final DoubaoImeAsrEndpoints _endpoints;
  final DoubaoImeAsrSocketConnector _socketConnector;
  final Set<DoubaoImeAsrSession> _sessions = {};

  DoubaoImeCredentials? _credentials;
  Future<DoubaoImeCredentials>? _credentialOperation;
  Future<void>? _refreshOperation;
  DateTime? _tokenRefreshedAt;
  bool _disposed = false;

  DoubaoImeAsrClient({
    http.Client? httpClient,
    DoubaoImeCredentialStore? credentialStore,
    DoubaoImeAsrEndpoints? endpoints,
    DoubaoImeAsrSocketConnector? socketConnector,
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _credentialStore =
           credentialStore ?? const SecureDoubaoImeCredentialStore(),
       _endpoints = endpoints ?? DoubaoImeAsrEndpoints.production,
       _socketConnector = socketConnector ?? _connectDoubaoSocket;

  @override
  Future<void> prepare() async {
    await _ensureCredentials(refreshToken: false);
  }

  @override
  Future<DoubaoImeAsrSession> openSession({
    String appName = 'com.android.chrome',
  }) async {
    try {
      return await _openSessionOnce(appName: appName);
    } catch (error) {
      if (!isDoubaoImeCredentialRoutingError(error.toString())) rethrow;
    }

    // A routing rejection can be caused by an expired token. Refresh the
    // existing device first; only if the provider still rejects it do we
    // discard the device identity and register a new one. This mirrors the
    // reference implementation and avoids needless anonymous registrations.
    try {
      await refreshToken();
    } catch (_) {
      await resetCredentials();
    }
    try {
      return await _openSessionOnce(appName: appName);
    } catch (error) {
      if (!isDoubaoImeCredentialRoutingError(error.toString())) rethrow;
      await resetCredentials();
    }
    return _openSessionOnce(appName: appName);
  }

  Future<DoubaoImeAsrSession> _openSessionOnce({
    required String appName,
  }) async {
    _checkNotDisposed();
    final credentials = await _ensureCredentials(refreshToken: true);
    _checkNotDisposed();
    final uri = _endpoints.websocket.replace(
      queryParameters: {
        ..._endpoints.websocket.queryParameters,
        'aid': _doubaoAid,
        'device_id': credentials.deviceId,
      },
    );
    final socket = await _socketConnector(uri, const {
      'User-Agent': _doubaoUserAgent,
      'proto-version': 'v2',
      'x-custom-keepalive': 'true',
    }, _socketTimeout);
    if (_disposed) {
      await socket.close();
      _checkNotDisposed();
    }
    final iterator = StreamIterator<Object?>(socket.messages);
    try {
      final requestId = _newUuid();
      socket.add(
        pb.AsrRequest(
          token: credentials.token,
          serviceName: 'ASR',
          methodName: 'StartTask',
          requestId: requestId,
        ).writeToBuffer(),
      );
      final task = await _nextStartupResponse(iterator);
      if (task.kind != DoubaoImeAsrResponseKind.taskStarted) {
        throw DoubaoImeAsrException(
          task.error.isNotEmpty ? task.error : '豆包语音任务启动失败',
        );
      }

      socket.add(
        pb.AsrRequest(
          token: credentials.token,
          serviceName: 'ASR',
          methodName: 'StartSession',
          requestId: requestId,
          payload: jsonEncode(
            _buildStartSessionPayload(
              deviceId: credentials.deviceId,
              appName: appName,
            ),
          ),
        ).writeToBuffer(),
      );
      final started = await _nextStartupResponse(iterator);
      if (started.kind != DoubaoImeAsrResponseKind.sessionStarted) {
        throw DoubaoImeAsrException(
          started.error.isNotEmpty ? started.error : '豆包语音会话启动失败',
        );
      }

      late final DoubaoImeAsrSession session;
      session = DoubaoImeAsrSession._(
        socket: socket,
        iterator: iterator,
        requestId: requestId,
        token: credentials.token,
        onClosed: () => _sessions.remove(session),
      );
      _sessions.add(session);
      return session;
    } catch (_) {
      try {
        await iterator.cancel().timeout(const Duration(seconds: 2));
      } catch (_) {}
      try {
        await socket.close();
      } catch (_) {}
      rethrow;
    }
  }

  // The provider accepts the short session payload during the handshake but
  // routes audio to a worker only when the IME's full two/three-pass options
  // are present. Keep this in one place so protocol changes do not get split
  // between the client and recognizer layers.
  Map<String, Object?> _buildStartSessionPayload({
    required String deviceId,
    required String appName,
  }) => {
    'audio_info': {'channel': 1, 'format': 'speech_pcm', 'sample_rate': 16000},
    'enable_punctuation': true,
    'enable_speech_rejection': false,
    'extra': {
      'app_name': appName,
      'app_version': '1.3.11',
      'cell_compress_rate': 8,
      'device_brand': 'xiaomi',
      'device_model': 'Redmi Note 7',
      'did': deviceId,
      'disable_user_words': false,
      'enable_asr_threepass': true,
      'enable_asr_twopass': true,
      'enable_print_chinese': false,
      'end_smooth_window_ms': 800,
      'finish_wait_offline_time': 1000,
      'input_mode': 'tool',
      'join_user_experience_improve_program': false,
      'max_wait_switch_offline_time': 1000,
      'network_change': {
        'switch_network_ping_timeout': 2000,
        'switch_network_quality_threshold': 4,
        'switch_network_rtt_threshold': 273,
      },
      'offline_wait_online_interval_time': 5000,
      'offline_wait_online_time': 5000,
      'os': 'Android',
      'os_version': '9',
      'remove_space_between_han_eng': false,
      'remove_space_between_han_num': false,
      'retry_server_code': [40100000, 40100004, 50000104, 50700000],
      's2a_send_commands': ['帮我发送'],
      's2a_send_enable': false,
      'strong_ddc': false,
      'use_twopass_retry': true,
    },
  };

  Future<DoubaoImeAsrResponse> _nextStartupResponse(
    StreamIterator<Object?> iterator,
  ) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final hasNext = await iterator.moveNext().timeout(_socketTimeout);
      if (!hasNext) {
        throw const DoubaoImeAsrException('豆包语音连接已关闭');
      }
      final response = parseDoubaoImeAsrResponse(
        _binaryMessage(iterator.current),
        maxBytes: _maxResponseBytes,
      );
      if (response.kind == DoubaoImeAsrResponseKind.heartbeat ||
          response.kind == DoubaoImeAsrResponseKind.unknown) {
        continue;
      }
      if (response.kind == DoubaoImeAsrResponseKind.error) return response;
      return response;
    }
    throw const DoubaoImeAsrException('豆包语音启动响应无效');
  }

  Future<DoubaoImeCredentials> _ensureCredentials({
    required bool refreshToken,
  }) {
    final pending = _credentialOperation;
    if (pending != null) return pending;
    late final Future<DoubaoImeCredentials> operation;
    operation = _ensureCredentialsInternal(refreshToken: refreshToken)
        .whenComplete(() {
          if (identical(_credentialOperation, operation)) {
            _credentialOperation = null;
          }
        });
    _credentialOperation = operation;
    return operation;
  }

  Future<DoubaoImeCredentials> _ensureCredentialsInternal({
    required bool refreshToken,
  }) async {
    _checkNotDisposed();
    DoubaoImeCredentials? storedCredentials = _credentials;
    if (storedCredentials == null) {
      try {
        storedCredentials = await _credentialStore.read().timeout(
          const Duration(seconds: 5),
        );
      } catch (_) {
        storedCredentials = null;
      }
    }
    _checkNotDisposed();
    var credentials = storedCredentials ?? await _registerDevice();
    _checkNotDisposed();

    final recentlyRefreshed =
        _tokenRefreshedAt != null &&
        DateTime.now().difference(_tokenRefreshedAt!) <
            const Duration(seconds: 30);
    if (credentials.token.isEmpty || (refreshToken && !recentlyRefreshed)) {
      try {
        final token = await _requestToken(credentials);
        credentials = credentials.copyWith(token: token);
        _tokenRefreshedAt = DateTime.now();
      } catch (_) {
        if (credentials.token.isEmpty) rethrow;
      }
    }
    _checkNotDisposed();
    _credentials = credentials;
    try {
      await _credentialStore
          .write(credentials)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Keep the in-memory credential usable for the current app process.
    }
    return credentials;
  }

  @override
  Future<void> refreshToken() {
    final pending = _refreshOperation;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _refreshTokenInternal().whenComplete(() {
      if (identical(_refreshOperation, operation)) _refreshOperation = null;
    });
    _refreshOperation = operation;
    return operation;
  }

  Future<void> _refreshTokenInternal() async {
    _checkNotDisposed();
    final pending = _credentialOperation;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    _checkNotDisposed();
    DoubaoImeCredentials? current = _credentials;
    if (current == null) {
      try {
        current = await _credentialStore.read().timeout(
          const Duration(seconds: 5),
        );
      } catch (_) {
        current = null;
      }
    }
    if (current == null) {
      await _ensureCredentials(refreshToken: true);
      return;
    }
    final token = await _requestToken(current);
    final refreshed = current.copyWith(token: token);
    _credentials = refreshed;
    _tokenRefreshedAt = DateTime.now();
    try {
      await _credentialStore
          .write(refreshed)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // The refreshed in-memory token remains usable for this process.
    }
  }

  @override
  Future<void> resetCredentials() async {
    _checkNotDisposed();
    final refreshing = _refreshOperation;
    if (refreshing != null) {
      try {
        await refreshing;
      } catch (_) {}
    }
    final pending = _credentialOperation;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    _checkNotDisposed();
    _credentials = null;
    _tokenRefreshedAt = null;
    try {
      await _credentialStore.clear().timeout(const Duration(seconds: 5));
    } catch (_) {
      // A secure-storage failure must not keep a rejected in-memory device.
    }
  }

  Future<DoubaoImeCredentials> _registerDevice() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cdid = _newUuid();
    final openUdid = _randomHex(8);
    final clientUdid = _newUuid();
    final query = <String, String>{
      'device_platform': 'android',
      'os': 'android',
      'ssmix': 'a',
      '_rticket': '$now',
      'cdid': cdid,
      'channel': 'official',
      'aid': _doubaoAid,
      'app_name': _doubaoAppName,
      'version_code': _doubaoVersionCode,
      'version_name': _doubaoVersionName,
      'manifest_version_code': _doubaoVersionCode,
      'update_version_code': _doubaoVersionCode,
      'resolution': '1080*2400',
      'dpi': '420',
      'device_type': 'Pixel 7 Pro',
      'device_brand': 'google',
      'language': 'zh',
      'os_api': '34',
      'os_version': '16',
      'ac': 'wifi',
    };
    final response = await _httpClient
        .post(
          _endpoints.register.replace(
            queryParameters: {..._endpoints.register.queryParameters, ...query},
          ),
          headers: const {
            'User-Agent': _doubaoUserAgent,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'magic_tag': 'ss_app_log',
            'header': {
              'device_id': 0,
              'install_id': 0,
              'aid': int.parse(_doubaoAid),
              'app_name': _doubaoAppName,
              'version_code': int.parse(_doubaoVersionCode),
              'version_name': _doubaoVersionName,
              'manifest_version_code': int.parse(_doubaoVersionCode),
              'update_version_code': int.parse(_doubaoVersionCode),
              'channel': 'official',
              'package': _doubaoPackageName,
              'device_platform': 'android',
              'os': 'android',
              'os_api': '34',
              'os_version': '16',
              'device_type': 'Pixel 7 Pro',
              'device_brand': 'google',
              'device_model': 'Pixel 7 Pro',
              'resolution': '1080*2400',
              'dpi': '420',
              'language': 'zh',
              'timezone': 8,
              'access': 'wifi',
              'rom': 'UP1A.231005.007',
              'rom_version': 'UP1A.231005.007',
              'openudid': openUdid,
              'clientudid': clientUdid,
              'cdid': cdid,
              'region': 'CN',
              'tz_name': 'Asia/Shanghai',
              'tz_offset': 28800,
              'sim_region': 'cn',
              'carrier_region': 'cn',
              'cpu_abi': 'arm64-v8a',
              'build_serial': 'unknown',
              'not_request_sender': 0,
              'sig_hash': '',
              'google_aid': '',
              'mc': '',
              'serial_number': '',
            },
            '_gen_time': now,
          }),
        )
        .timeout(_httpTimeout);
    final json = _decodeResponse(response, '豆包语音设备注册');
    final deviceId = json['device_id']?.toString().trim() ?? '';
    final installId = json['install_id']?.toString().trim() ?? '';
    if (deviceId.isEmpty || deviceId == '0' || installId.isEmpty) {
      throw const DoubaoImeAsrException('豆包语音设备注册返回无效');
    }
    return DoubaoImeCredentials(
      deviceId: deviceId,
      installId: installId,
      cdid: cdid,
      openUdid: openUdid,
      clientUdid: clientUdid,
    );
  }

  Future<String> _requestToken(DoubaoImeCredentials credentials) async {
    const body = 'body=null';
    final response = await _httpClient
        .post(
          _endpoints.settings.replace(
            queryParameters: {
              ..._endpoints.settings.queryParameters,
              'device_platform': 'android',
              'os': 'android',
              'ssmix': 'a',
              '_rticket': '${DateTime.now().millisecondsSinceEpoch}',
              'cdid': credentials.cdid,
              'channel': 'official',
              'aid': _doubaoAid,
              'app_name': _doubaoAppName,
              'version_code': _doubaoVersionCode,
              'version_name': _doubaoVersionName,
              'device_id': credentials.deviceId,
            },
          ),
          headers: {
            'User-Agent': _doubaoUserAgent,
            'Content-Type': 'application/x-www-form-urlencoded',
            'x-ss-stub': md5
                .convert(utf8.encode(body))
                .toString()
                .toUpperCase(),
          },
          body: body,
        )
        .timeout(_httpTimeout);
    final json = _decodeResponse(response, '豆包语音凭据刷新');
    final data = json['data'];
    final settings = data is Map ? data['settings'] : null;
    final asrConfig = settings is Map ? settings['asr_config'] : null;
    final token = asrConfig is Map
        ? asrConfig['app_key']?.toString().trim() ?? ''
        : '';
    if (token.isEmpty) {
      throw const DoubaoImeAsrException('豆包语音凭据返回无效');
    }
    return token;
  }

  Map<String, Object?> _decodeResponse(http.Response response, String action) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DoubaoImeAsrException('$action失败（HTTP ${response.statusCode}）');
    }
    if (response.bodyBytes.length > 64 * 1024) {
      throw DoubaoImeAsrException('$action响应过大');
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) throw const FormatException();
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      throw DoubaoImeAsrException('$action响应格式错误');
    }
  }

  void _checkNotDisposed() {
    if (_disposed) throw const DoubaoImeAsrException('豆包语音服务已释放');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final sessions = _sessions.toList(growable: false);
    _sessions.clear();
    await Future.wait(sessions.map((session) => session.close()));
    if (_ownsHttpClient) _httpClient.close();
  }
}

class DoubaoImeAsrSession implements DoubaoImeAsrConnection {
  static const _maxAudioFrameBytes = 64 * 1024;

  final DoubaoImeAsrSocket _socket;
  final StreamIterator<Object?> _iterator;
  final String _requestId;
  final String _token;
  final void Function() _onClosed;
  bool _closed = false;
  bool _finishSent = false;

  DoubaoImeAsrSession._({
    required DoubaoImeAsrSocket socket,
    required StreamIterator<Object?> iterator,
    required String requestId,
    required String token,
    required void Function() onClosed,
  }) : _socket = socket,
       _iterator = iterator,
       _requestId = requestId,
       _token = token,
       _onClosed = onClosed;

  @override
  void sendAudio(
    Uint8List bytes, {
    required DoubaoImeAudioFrameState frameState,
    required int timestampMilliseconds,
  }) {
    if (_closed || _finishSent || bytes.isEmpty) return;
    if (bytes.length > _maxAudioFrameBytes) {
      throw const DoubaoImeAsrException('豆包语音音频帧过大');
    }
    _socket.add(
      pb.AsrRequest(
        serviceName: 'ASR',
        methodName: 'TaskRequest',
        payload: jsonEncode({
          'extra': <String, Object?>{},
          'timestamp_ms': timestampMilliseconds,
        }),
        audioData: bytes,
        requestId: _requestId,
        frameState: switch (frameState) {
          DoubaoImeAudioFrameState.first => pb.FrameState.FRAME_STATE_FIRST,
          DoubaoImeAudioFrameState.middle => pb.FrameState.FRAME_STATE_MIDDLE,
          DoubaoImeAudioFrameState.last => pb.FrameState.FRAME_STATE_LAST,
        },
      ).writeToBuffer(),
    );
  }

  @override
  void finish() {
    if (_closed || _finishSent) return;
    _finishSent = true;
    _socket.add(
      pb.AsrRequest(
        token: _token,
        serviceName: 'ASR',
        methodName: 'FinishSession',
        requestId: _requestId,
      ).writeToBuffer(),
    );
  }

  @override
  Future<DoubaoImeAsrResponse?> nextResponse() async {
    if (_closed) return null;
    // The socket ping interval detects a dead peer. Avoid timing out a valid
    // quiet recognition period and leaving StreamIterator.moveNext pending.
    final hasNext = await _iterator.moveNext();
    if (!hasNext) return null;
    return parseDoubaoImeAsrResponse(_binaryMessage(_iterator.current));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _onClosed();
    try {
      await _iterator.cancel().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await _socket.close();
    } catch (_) {}
  }
}

bool isDoubaoImeCredentialRoutingError(String message) {
  final normalized = message.toLowerCase();
  if (normalized.contains('service discovery failure')) return true;
  // Some gateway responses contain only the numeric status code. These are
  // the provider's documented retry/routing codes from the IME payload.
  const retryCodes = <String>{'40100000', '40100004', '50000104', '50700000'};
  return retryCodes.any(normalized.contains);
}

DoubaoImeAsrResponse parseDoubaoImeAsrResponse(
  Uint8List bytes, {
  int maxBytes = 256 * 1024,
}) {
  if (bytes.length > maxBytes) {
    throw const DoubaoImeAsrException('豆包语音响应过大');
  }
  final response = pb.AsrResponse.fromBuffer(bytes);
  switch (response.messageType) {
    case 'TaskStarted':
      return const DoubaoImeAsrResponse(
        kind: DoubaoImeAsrResponseKind.taskStarted,
      );
    case 'SessionStarted':
      return const DoubaoImeAsrResponse(
        kind: DoubaoImeAsrResponseKind.sessionStarted,
      );
    case 'SessionFinished':
      return const DoubaoImeAsrResponse(
        kind: DoubaoImeAsrResponseKind.sessionFinished,
      );
    case 'TaskFailed':
    case 'SessionFailed':
      return DoubaoImeAsrResponse(
        kind: DoubaoImeAsrResponseKind.error,
        error: response.statusMessage.trim().isEmpty
            ? '豆包语音服务返回错误（${response.statusCode}）'
            : response.statusMessage.trim(),
      );
  }
  if (response.resultJson.isEmpty) {
    return const DoubaoImeAsrResponse(kind: DoubaoImeAsrResponseKind.unknown);
  }
  if (response.resultJson.length > maxBytes) {
    throw const DoubaoImeAsrException('豆包语音结果过大');
  }
  try {
    final decoded = jsonDecode(response.resultJson);
    if (decoded is! Map) throw const FormatException();
    final extra = decoded['extra'];
    if (extra is Map && extra['vad_start'] == true) {
      return const DoubaoImeAsrResponse(
        kind: DoubaoImeAsrResponseKind.vadStarted,
      );
    }
    final results = decoded['results'];
    if (results == null) {
      return const DoubaoImeAsrResponse(
        kind: DoubaoImeAsrResponseKind.heartbeat,
      );
    }
    if (results is! List) throw const FormatException();
    var text = '';
    var interim = true;
    var vadFinished = false;
    var nonstreamResult = false;
    for (final item in results) {
      if (item is! Map) continue;
      final candidate = item['text']?.toString().trim() ?? '';
      if (candidate.isNotEmpty) text = candidate;
      if (item['is_interim'] == false) interim = false;
      if (item['is_vad_finished'] == true) vadFinished = true;
      final itemExtra = item['extra'];
      if (itemExtra is Map && itemExtra['nonstream_result'] == true) {
        nonstreamResult = true;
      }
    }
    final isFinal = nonstreamResult || (!interim && vadFinished);
    return DoubaoImeAsrResponse(
      kind: isFinal
          ? DoubaoImeAsrResponseKind.finalResult
          : DoubaoImeAsrResponseKind.interim,
      text: text,
    );
  } on FormatException {
    throw const DoubaoImeAsrException('豆包语音结果格式错误');
  }
}

Uint8List _binaryMessage(Object? message) {
  if (message is Uint8List) return message;
  if (message is List<int>) return Uint8List.fromList(message);
  throw const DoubaoImeAsrException('豆包语音返回了非二进制响应');
}

final Random _secureRandom = Random.secure();

String _randomHex(int byteCount) {
  final bytes = List<int>.generate(
    byteCount,
    (_) => _secureRandom.nextInt(256),
    growable: false,
  );
  return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}

String _newUuid() {
  final bytes = List<int>.generate(
    16,
    (_) => _secureRandom.nextInt(256),
    growable: false,
  );
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
