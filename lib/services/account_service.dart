import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/account_user.dart';

enum AccountStatus { initializing, signedOut, authenticated, disabled }

class AccountException implements Exception {
  final String code;
  final String message;

  const AccountException(this.code, this.message);

  @override
  String toString() => message;
}

class AccountService extends ChangeNotifier {
  static const _baseUrlKey = '_account_server_url';
  static const _deviceIdKey = '_account_device_id';
  static const _cachedUserKey = '_account_cached_user';
  static const _tokenKey = 'kuzai_account_session';
  static const defaultBaseUrl = String.fromEnvironment(
    'ACCOUNT_API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8787/api',
  );

  final FlutterSecureStorage _secureStorage;
  final http.Client _client;
  final bool _ownsClient;
  AccountStatus _status = AccountStatus.initializing;
  AccountUser? _user;
  String _baseUrl = defaultBaseUrl;
  String? _token;
  String? _message;
  bool _busy = false;

  AccountStatus get status => _status;
  AccountUser? get user => _user;
  String get baseUrl => _baseUrl;
  String? get message => _message;
  bool get busy => _busy;
  bool get isAuthenticated =>
      _status == AccountStatus.authenticated && _user != null;

  AccountService({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
    http.Client? client,
  }) : _secureStorage = secureStorage,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      _baseUrl = _normalizeBaseUrl(
        prefs.getString(_baseUrlKey) ?? defaultBaseUrl,
      );
    } on AccountException {
      _baseUrl = defaultBaseUrl;
      await prefs.setString(_baseUrlKey, _baseUrl);
    }
    _token = await _secureStorage.read(key: _tokenKey);
    final cached = prefs.getString(_cachedUserKey);
    if (_token == null || cached == null) {
      _status = AccountStatus.signedOut;
      notifyListeners();
      return;
    }
    try {
      _user = AccountUser.fromJson(
        Map<String, dynamic>.from(jsonDecode(cached)),
      );
      final response = await request('GET', '/me', authenticated: true);
      _user = AccountUser.fromJson(Map<String, dynamic>.from(response['user']));
      _status = AccountStatus.authenticated;
      await prefs.setString(_cachedUserKey, jsonEncode(_user!.toJson()));
    } on AccountException catch (error) {
      if (error.code == 'USER_DISABLED') {
        _message = error.message;
        _status = AccountStatus.disabled;
      } else if (_user != null) {
        // An existing session may continue offline; the next successful
        // request still performs the server-side status check.
        _status = AccountStatus.authenticated;
        _message = '当前处于离线状态，数据将在联网后同步';
      } else {
        await _clearSession();
        _status = AccountStatus.signedOut;
      }
    } catch (_) {
      if (_user != null) {
        _status = AccountStatus.authenticated;
        _message = '当前处于离线状态，数据将在联网后同步';
      } else {
        await _clearSession();
        _status = AccountStatus.signedOut;
      }
    }
    notifyListeners();
  }

  Future<void> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    if (_busy) return;
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      _baseUrl = _normalizeBaseUrl(serverUrl);
      await prefs.setString(_baseUrlKey, _baseUrl);
      final deviceId = await _deviceId(prefs);
      final response = await request(
        'POST',
        '/auth/login',
        authenticated: false,
        body: {
          'username': username.trim(),
          'password': password,
          'deviceId': deviceId,
          'deviceName': _deviceName,
          'platform': defaultTargetPlatform.name,
          'appVersion': '2.9.8',
        },
      );
      final user = AccountUser.fromJson(
        Map<String, dynamic>.from(response['user']),
      );
      _token = response['token']?.toString();
      if (_token == null || _token!.isEmpty) {
        throw const AccountException('INVALID_RESPONSE', '服务器没有返回登录凭据');
      }
      _user = user;
      await _secureStorage.write(key: _tokenKey, value: _token);
      await prefs.setString(_cachedUserKey, jsonEncode(user.toJson()));
      _status = AccountStatus.authenticated;
    } on AccountException catch (error) {
      if (error.code == 'USER_DISABLED') {
        _status = AccountStatus.disabled;
        _message = error.message;
      }
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    try {
      await request('POST', '/auth/logout', authenticated: true);
    } catch (_) {}
    await _clearSession();
    _status = AccountStatus.signedOut;
    _message = null;
    notifyListeners();
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    required bool authenticated,
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (authenticated && _token != null) {
      headers['Authorization'] = 'Bearer $_token';
    }
    final http.Response response;
    try {
      response = await switch (method) {
        'GET' =>
          _client
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 15)),
        'POST' =>
          _client
              .post(
                uri,
                headers: headers,
                body: body == null ? null : jsonEncode(body),
              )
              .timeout(const Duration(seconds: 15)),
        'PATCH' =>
          _client
              .patch(
                uri,
                headers: headers,
                body: body == null ? null : jsonEncode(body),
              )
              .timeout(const Duration(seconds: 15)),
        _ => throw const AccountException('METHOD', '不支持的请求方法'),
      };
    } on AccountException {
      rethrow;
    } on Object catch (error) {
      throw AccountException('NETWORK_ERROR', '无法连接账号服务器：$error');
    }
    Map<String, dynamic> decoded = {};
    if (response.bodyBytes.isNotEmpty) {
      try {
        final value = jsonDecode(utf8.decode(response.bodyBytes));
        if (value is Map) decoded = Map<String, dynamic>.from(value);
      } catch (_) {
        throw const AccountException('INVALID_RESPONSE', '服务器返回内容无效');
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = AccountException(
        decoded['error']?.toString() ?? 'HTTP_${response.statusCode}',
        decoded['message']?.toString() ?? '账号服务请求失败',
      );
      if (authenticated &&
          (error.code == 'UNAUTHORIZED' || error.code == 'USER_DISABLED')) {
        if (error.code == 'USER_DISABLED') {
          _status = AccountStatus.disabled;
          _message = error.message;
        } else {
          await _clearSession();
          _status = AccountStatus.signedOut;
          _message = error.message;
        }
        notifyListeners();
      }
      throw error;
    }
    return decoded;
  }

  Future<String> _deviceId(SharedPreferences prefs) async {
    final saved = prefs.getString(_deviceIdKey);
    if (saved != null && saved.isNotEmpty) return saved;
    final value =
        '${DateTime.now().microsecondsSinceEpoch}-${Object.hash(this, DateTime.now())}';
    await prefs.setString(_deviceIdKey, value);
    return value;
  }

  String get _deviceName {
    if (Platform.isAndroid) return 'Android 设备';
    if (Platform.isIOS) return 'iPhone / iPad';
    if (Platform.isWindows) return 'Windows 设备';
    if (Platform.isMacOS) return 'macOS 设备';
    return 'Flutter 设备';
  }

  String _normalizeBaseUrl(String value) {
    var normalized = value.trim();
    if (normalized.isEmpty) normalized = defaultBaseUrl;
    if (!normalized.startsWith('http://') &&
        !normalized.startsWith('https://')) {
      throw const AccountException(
        'INVALID_SERVER_URL',
        '服务器地址必须以 http:// 或 https:// 开头',
      );
    }
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (!normalized.endsWith('/api')) normalized = '$normalized/api';
    return normalized;
  }

  Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    _token = null;
    _user = null;
    await _secureStorage.delete(key: _tokenKey);
    await prefs.remove(_cachedUserKey);
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
