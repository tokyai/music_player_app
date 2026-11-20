import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/remote_playback.dart';
import '../models/song.dart';
import 'bounded_http_response.dart';

/// 统一音源接口的客户端；只传输参数并校验结果，不执行第三方协议。
class PlaybackResolverService {
  static const baseUrl = 'https://137.175.62.3:8443/music-player-api/';
  final http.Client _client;
  final Uri _base;
  final Set<Completer<void>> _activeRequests = {};
  bool _closed = false;

  /// 当前网络任务数量，用于确认取消和资源释放；不累计历史请求。
  int get activeRequestCount => _activeRequests.length;

  PlaybackResolverService({http.Client? client, Uri? server})
    : _client = client ?? _createClient(),
      _base = server ?? Uri.parse(baseUrl);

  static http.Client _createClient() {
    final scopedClient = http.Client();
    if (scopedClient is! IOClient) return scopedClient;
    scopedClient.close();
    // 固定HTTPS入口使用公开可信证书，续期不需要重新发布客户端。
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 7);
    client.idleTimeout = const Duration(seconds: 15);
    client.maxConnectionsPerHost = 4;
    return IOClient(client);
  }

  /// 获取当前音源列表和凭据定义；调用失败不替换已验证的本地快照。
  Future<PlaybackSourceCatalog> loadSources({
    Future<void>? cancelSignal,
  }) async {
    final json = await _request(
      '/api/sources',
      cancelSignal: cancelSignal,
      timeout: const Duration(seconds: 8),
    );
    return PlaybackSourceCatalog.fromJson(json);
  }

  /// 请求服务器解析，返回可交给本地播放器的统一结果。
  Future<SongDetail> resolve(
    Map<String, dynamic> parameters, {
    Future<void>? cancelSignal,
  }) async {
    final json = await _request(
      '/api/resolve',
      body: parameters,
      cancelSignal: cancelSignal,
      timeout: const Duration(seconds: 22),
    );
    // 只接受约定的协议和音源身份，拒绝不完整或被替换的解析结果。
    if (json['protocolVersion'] != 1) {
      throw const PlaybackServerException('PROTOCOL_VERSION', '音源服务协议不兼容');
    }
    final url = json['url'];
    final providerId = json['providerId'];
    final providerName = json['providerName'];
    if (url is! String ||
        url.length > 8192 ||
        providerId is! String ||
        !PlaybackSource.isValidId(providerId) ||
        providerId == 'automatic' ||
        providerName is! String ||
        providerName.isEmpty ||
        providerName.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(providerName)) {
      throw const PlaybackServerException('INVALID_RESULT', '音源服务返回了无效结果');
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const PlaybackServerException('INVALID_AUDIO_URL', '音频地址无效');
    }
    final rawFormat = json['format'];
    if (rawFormat != null && rawFormat is! String) {
      throw const PlaybackServerException('INVALID_FORMAT', '音频格式无效');
    }
    final format = rawFormat is String ? rawFormat.toLowerCase() : null;
    if (const ['mgg', 'mflac', 'cenc'].contains(format)) {
      throw const PlaybackServerException('ENCRYPTED_AUDIO', '音源返回了加密音频');
    }
    if (format != null && !RegExp(r'^[a-z0-9]{1,12}$').hasMatch(format)) {
      throw const PlaybackServerException('INVALID_FORMAT', '音频格式无效');
    }
    final expiresAt = json['expiresAt'];
    if (expiresAt != null &&
        (expiresAt is! int ||
            expiresAt > 8640000000000000 ||
            expiresAt <= DateTime.now().millisecondsSinceEpoch)) {
      throw const PlaybackServerException('EXPIRED_URL', '音频地址已过期，请重试');
    }
    // 转成播放器已有模型，必要请求头和有效期一起交给播放/下载流程。
    return SongDetail(
      name: parameters['name'] as String? ?? '',
      artist: parameters['artist'] as String? ?? '',
      album: parameters['album'] as String? ?? '',
      url: url,
      format: format,
      playbackHeaders: _headers(json['playbackHeaders']),
      playbackSource: PlaybackSource.fromId(providerId, label: providerName),
      playbackExpiresAt: expiresAt is int
          ? DateTime.fromMillisecondsSinceEpoch(expiresAt)
          : null,
    );
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, dynamic>? body,
    Future<void>? cancelSignal,
    required Duration timeout,
  }) async {
    if (_closed) throw const HttpRequestCancelledException();
    // 请求不排队，避免重复操作产生不断增长的等待任务。
    if (_activeRequests.length >= 4) {
      throw const PlaybackServerException('REQUEST_BUSY', '音源请求繁忙，请稍后重试');
    }
    final endpoint = _base.resolve(
      path.startsWith('/') ? path.substring(1) : path,
    );
    final request = http.Request(body == null ? 'GET' : 'POST', endpoint);
    request.followRedirects = false;
    request.headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
      if (utf8.encode(request.body).length > 64 * 1024) {
        throw const PlaybackServerException('REQUEST_TOO_LARGE', '音源配置超过上限');
      }
    }
    // 只记录进行中请求；完成后移除，不向长期Future累积历史监听回调。
    final cancellation = Completer<void>();
    _activeRequests.add(cancellation);
    final subscriptions = <StreamSubscription<void>>[];
    void cancel() {
      if (!cancellation.isCompleted) cancellation.complete();
    }

    if (cancelSignal != null) {
      subscriptions.add(cancelSignal.asStream().listen((_) => cancel()));
    }
    try {
      // 发送和接收共用大小、时间、取消上限，断连时释放底层网络流。
      final response = await sendBoundedHttpRequest(
        _client,
        request,
        maxBytes: path == '/api/sources' ? 512 * 1024 : 128 * 1024,
        timeout: timeout,
        totalTimeout: timeout,
        cancelSignal: cancellation.future,
      );
      if (_closed || cancellation.isCompleted) {
        throw const HttpRequestCancelledException();
      }
      final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const PlaybackServerException('INVALID_RESPONSE', '音源服务响应无效');
      }
      if (response.statusCode != 200) {
        final code = decoded['code'];
        final message = decoded['message'];
        throw PlaybackServerException(
          code is String && code.length <= 80 ? code : 'SERVER_UNAVAILABLE',
          message is String && message.length <= 512 ? message : '音源服务暂时不可用',
        );
      }
      return decoded;
    } on HttpRequestCancelledException {
      rethrow;
    } on PlaybackServerException {
      rethrow;
    } on FormatException {
      throw const PlaybackServerException('INVALID_RESPONSE', '音源服务响应无效');
    } on Exception {
      throw const PlaybackServerException(
        'SERVER_NETWORK',
        '无法连接音源服务器，请检查网络后重试',
      );
    } finally {
      _activeRequests.remove(cancellation);
      cancel();
      for (final subscription in subscriptions) {
        // 请求结果不等待尚未结束的生命周期信号，取消订阅仍立即启动。
        unawaited(subscription.cancel());
      }
    }
  }

  static Map<String, String> _headers(dynamic raw) {
    if (raw == null) return const {};
    if (raw is! Map || raw.length > 16) {
      throw const PlaybackServerException('INVALID_HEADERS', '音频请求头无效');
    }
    final result = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String ||
          !RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(key) ||
          const [
            'host',
            'connection',
            'content-length',
            'transfer-encoding',
          ].contains(key.toLowerCase()) ||
          value is! String ||
          value.length > 4096 ||
          RegExp(r'[^\x20-\x7e]').hasMatch(value)) {
        throw const PlaybackServerException('INVALID_HEADERS', '音频请求头无效');
      }
      result[key] = value;
    }
    return Map.unmodifiable(result);
  }

  /// 取消未完成的请求并释放HTTP连接；关闭后禁止迟到结果发布。
  void close() {
    if (_closed) return;
    _closed = true;
    for (final cancellation in _activeRequests) {
      if (!cancellation.isCompleted) cancellation.complete();
    }
    _activeRequests.clear();
    _client.close();
  }
}

class PlaybackServerException implements Exception {
  final String code;
  final String message;
  const PlaybackServerException(this.code, this.message);

  @override
  String toString() => '[$code] $message';
}
