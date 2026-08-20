import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_assistant.dart';

abstract class AiSecretStore {
  Future<String?> read();
  Future<void> write(String value);
}

class SecureAiSecretStore implements AiSecretStore {
  static const _key = 'ai_assistant_api_key';
  static const _storage = FlutterSecureStorage();

  const SecureAiSecretStore();

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
}

class MemoryAiSecretStore implements AiSecretStore {
  String? value;

  MemoryAiSecretStore([this.value]);

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

class AiConfigController extends ChangeNotifier {
  static const _preferencesKey = 'ai_assistant_config_v1';
  static const showPetOnPlayerPagePreferenceKey =
      'ai_assistant_show_pet_on_player_page';

  final AiSecretStore _secretStore;
  AiAssistantConfig _config = AiAssistantConfig.defaults();
  bool _showPetOnPlayerPage = true;
  bool _disposed = false;

  AiConfigController({AiSecretStore? secretStore})
    : _secretStore = secretStore ?? const SecureAiSecretStore() {
    ready = _load();
  }

  late final Future<void> ready;

  AiAssistantConfig get config => _config;
  bool get showPetOnPlayerPage => _showPetOnPlayerPage;

  Future<void> _load() async {
    try {
      final results = await Future.wait<dynamic>([
        SharedPreferences.getInstance(),
        _secretStore.read(),
      ]);
      final prefs = results[0] as SharedPreferences;
      final apiKey = results[1] as String? ?? '';
      _showPetOnPlayerPage =
          prefs.getBool(showPetOnPlayerPagePreferenceKey) ?? true;
      final raw = prefs.getString(_preferencesKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _config = AiAssistantConfig.fromJson(
            Map<String, dynamic>.from(decoded),
            apiKey: apiKey,
          );
        }
      } else {
        _config = _config.copyWith(apiKey: apiKey);
      }
    } catch (error) {
      debugPrint('读取 AI 助理配置失败: $error');
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> save(AiAssistantConfig config) async {
    await ready;
    final normalized = config.copyWith(
      baseUrl: config.baseUrl.trim(),
      apiKey: config.apiKey.trim(),
      model: config.model.trim(),
    );
    final uri = Uri.tryParse(normalized.baseUrl);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('中转站 URL 必须是 http 或 https 地址');
    }
    await _secretStore.write(normalized.apiKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _preferencesKey,
      jsonEncode(normalized.toPreferencesJson()),
    );
    if (_disposed) return;
    _config = normalized;
    notifyListeners();
  }

  Future<void> setShowPetOnPlayerPage(bool value) async {
    await ready;
    if (_disposed || _showPetOnPlayerPage == value) return;
    _showPetOnPlayerPage = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(showPetOnPlayerPagePreferenceKey, value);
    } catch (error) {
      debugPrint('保存播放页 AI 宠物显示设置失败: $error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
