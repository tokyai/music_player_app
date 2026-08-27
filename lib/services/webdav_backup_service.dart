import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bounded_http_response.dart';
import 'user_data_scope.dart';

const _maxBackupBytes = 12 * 1024 * 1024;

class WebDavConfig {
  static const defaultUrl = 'https://23.254.235.247:8443/kuzai-dav/';
  static const defaultUsername = 'kuzai_backup';
  static const defaultCertificateSha256 =
      '063FA39D741CF067D1F0B57E6CE23369FC77F13985A0BEB4012A11261A8F75CE';

  final String url;
  final String username;
  final String password;
  final String certificateSha256;
  final UserDataScope dataScope;

  const WebDavConfig({
    required this.url,
    required this.username,
    required this.password,
    required this.certificateSha256,
    this.dataScope = UserDataScope.defaultScope,
  });

  factory WebDavConfig.defaults({
    UserDataScope dataScope = UserDataScope.defaultScope,
  }) => WebDavConfig(
    url: defaultUrl,
    username: defaultUsername,
    password: '',
    certificateSha256: defaultCertificateSha256,
    dataScope: dataScope,
  );

  bool get isHttps => parsedUrl.scheme.toLowerCase() == 'https';

  bool get isConfigured =>
      username.trim().isNotEmpty &&
      password.isNotEmpty &&
      (!isHttps || normalizeFingerprint(certificateSha256).length == 64);

  Uri get parsedUrl {
    final value = url.trim();
    final parsed = Uri.tryParse(value);
    if (parsed == null || parsed.host.isEmpty) {
      throw const WebDavException('INVALID_URL', 'WebDAV 地址无效');
    }
    final scheme = parsed.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw const WebDavException('INVALID_URL', 'WebDAV 只支持 HTTP 或 HTTPS');
    }
    return parsed;
  }

  Uri fileUri([String? fileName]) {
    final base = parsedUrl;
    final basePath = base.path.isEmpty ? '/' : base.path;
    final resolvedFileName =
        fileName ??
        (dataScope.isDefault
            ? 'kuzai-music-backup.json'
            : 'kuzai-music-backup-${dataScope.userId}.json');
    final path = basePath.endsWith('/')
        ? '$basePath$resolvedFileName'
        : '$basePath/$resolvedFileName';
    return base.replace(path: path, query: null, fragment: null);
  }

  WebDavConfig copyWith({
    String? url,
    String? username,
    String? password,
    String? certificateSha256,
  }) {
    return WebDavConfig(
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
      certificateSha256: certificateSha256 ?? this.certificateSha256,
      dataScope: dataScope,
    );
  }

  static String normalizeFingerprint(String value) {
    return value.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
  }

  static Future<WebDavConfig> load({
    UserDataScope dataScope = UserDataScope.defaultScope,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final defaults = WebDavConfig.defaults(dataScope: dataScope);
    return WebDavConfig(
      url:
          prefs.getString(dataScope.preferenceKey('webdav_url')) ??
          defaults.url,
      username:
          prefs.getString(dataScope.preferenceKey('webdav_username')) ??
          defaults.username,
      password:
          prefs.getString(dataScope.preferenceKey('webdav_password')) ??
          defaults.password,
      certificateSha256:
          prefs.getString(
            dataScope.preferenceKey('webdav_certificate_sha256'),
          ) ??
          defaults.certificateSha256,
      dataScope: dataScope,
    );
  }

  Future<void> save() async {
    if (dataScope.isDeleted) return;
    final prefs = await SharedPreferences.getInstance();
    if (dataScope.isDeleted) return;
    await Future.wait([
      prefs.setString(dataScope.preferenceKey('webdav_url'), url.trim()),
      prefs.setString(
        dataScope.preferenceKey('webdav_username'),
        username.trim(),
      ),
      prefs.setString(dataScope.preferenceKey('webdav_password'), password),
      prefs.setString(
        dataScope.preferenceKey('webdav_certificate_sha256'),
        normalizeFingerprint(certificateSha256),
      ),
    ]);
  }
}

class WebDavBackupService {
  final WebDavConfig config;
  final http.Client _client;
  final bool _ownsClient;

  WebDavBackupService({required this.config, http.Client? client})
    : _client = client ?? _createPinnedClient(config),
      _ownsClient = client == null;

  Future<void> upload(String content) async {
    _validateConfig();
    _validateSize(content);
    final response = await _send(
      () => _client.put(
        config.fileUri(),
        headers: _headers(contentType: 'application/json; charset=utf-8'),
        body: utf8.encode(content),
      ),
    );
    _throwIfAuthFailed(response.statusCode);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebDavException(
        'HTTP_${response.statusCode}',
        'WebDAV 上传失败（HTTP ${response.statusCode}）',
      );
    }
  }

  Future<String> download() async {
    _validateConfig();
    final request = http.Request('GET', config.fileUri())
      ..headers.addAll(_headers());
    final http.Response response;
    try {
      response = await sendBoundedHttpRequest(
        _client,
        request,
        maxBytes: _maxBackupBytes,
        timeout: const Duration(seconds: 15),
      );
    } on HttpResponseTooLargeException {
      throw const WebDavException('TOO_LARGE', '备份文件不能超过 12 MB');
    } on TimeoutException {
      throw const WebDavException('TIMEOUT', 'WebDAV 请求超时');
    } on HandshakeException catch (error) {
      throw WebDavException('TLS_ERROR', 'TLS 证书校验失败：${error.message}');
    } on SocketException catch (error) {
      throw WebDavException('NETWORK_ERROR', '无法连接 WebDAV：${error.message}');
    } on http.ClientException catch (error) {
      throw WebDavException('NETWORK_ERROR', '无法连接 WebDAV：${error.message}');
    }
    _throwIfAuthFailed(response.statusCode);
    if (response.statusCode == 404) {
      throw const WebDavException('NOT_FOUND', '服务器上还没有备份文件');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebDavException(
        'HTTP_${response.statusCode}',
        'WebDAV 下载失败（HTTP ${response.statusCode}）',
      );
    }
    late final String content;
    try {
      content = utf8.decode(response.bodyBytes, allowMalformed: false);
    } on FormatException {
      throw const WebDavException('INVALID_ENCODING', '服务器返回的备份不是 UTF-8 文本');
    }
    if (content.trim().isEmpty) {
      throw const WebDavException('EMPTY_BACKUP', '服务器上的备份文件为空');
    }
    return content;
  }

  /// 备份文件不存在时也视为连接成功，便于首次配置。
  Future<void> testConnection() async {
    _validateConfig();
    final response = await _send(
      () => _client.head(config.fileUri(), headers: _headers()),
    );
    _throwIfAuthFailed(response.statusCode);
    if (response.statusCode != 404 &&
        (response.statusCode < 200 || response.statusCode >= 300)) {
      throw WebDavException(
        'HTTP_${response.statusCode}',
        'WebDAV 连接失败（HTTP ${response.statusCode}）',
      );
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  void _validateConfig() {
    final parsed = config.parsedUrl;
    if (config.username.trim().isEmpty || config.password.isEmpty) {
      throw const WebDavException('MISSING_AUTH', '请填写 WebDAV 用户名和密码');
    }
    if (parsed.scheme == 'https' &&
        WebDavConfig.normalizeFingerprint(config.certificateSha256).length !=
            64) {
      throw const WebDavException(
        'CERT_PIN_REQUIRED',
        'HTTPS 需要填写证书 SHA-256 指纹',
      );
    }
  }

  static void _throwIfAuthFailed(int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      throw const WebDavException('AUTH_FAILED', 'WebDAV 用户名或密码不正确');
    }
  }

  Map<String, String> _headers({String? contentType}) {
    final token = base64Encode(
      utf8.encode('${config.username.trim()}:${config.password}'),
    );
    return {
      'Authorization': 'Basic $token',
      'Accept': 'application/json',
      if (contentType != null) 'Content-Type': contentType,
    };
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(const Duration(seconds: 15));
    } on WebDavException {
      rethrow;
    } on TimeoutException {
      throw const WebDavException('TIMEOUT', 'WebDAV 请求超时');
    } on HandshakeException catch (error) {
      throw WebDavException('TLS_ERROR', 'TLS 证书校验失败：${error.message}');
    } on SocketException catch (error) {
      throw WebDavException('NETWORK_ERROR', '无法连接 WebDAV：${error.message}');
    } on http.ClientException catch (error) {
      throw WebDavException('NETWORK_ERROR', '无法连接 WebDAV：${error.message}');
    }
  }

  static http.Client _createPinnedClient(WebDavConfig config) {
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15);
    final expected = WebDavConfig.normalizeFingerprint(
      config.certificateSha256,
    );
    httpClient.badCertificateCallback = (certificate, host, port) {
      if (config.parsedUrl.scheme != 'https') return false;
      if (host != config.parsedUrl.host) return false;
      final configuredPort = config.parsedUrl.hasPort
          ? config.parsedUrl.port
          : 443;
      if (port != configuredPort || expected.length != 64) return false;
      final actual = sha256.convert(certificate.der).toString().toUpperCase();
      return actual == expected;
    };
    return IOClient(httpClient);
  }

  static void _validateSize(String content) {
    final bytes = utf8.encode(content).length;
    if (bytes > _maxBackupBytes) {
      throw const WebDavException('TOO_LARGE', '备份文件不能超过 12 MB');
    }
  }
}

class WebDavException implements Exception {
  final String code;
  final String message;

  const WebDavException(this.code, this.message);

  @override
  String toString() => message;
}
