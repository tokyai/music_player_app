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

  /// Controls the assistant entry point on the app's main pages.
  static const showAssistantOnAllPagesPreferenceKey =
      'ai_assistant_show_on_all_pages';
  static const showPetOnPlayerPagePreferenceKey =
      'ai_assistant_show_pet_on_player_page';

  final AiSecretStore _secretStore;
  AiAssistantConfig _config = AiAssistantConfig.defaults();
  bool _showAssistantOnAllPages = true;
  bool _showPetOnPlayerPage = true;
  bool _disposed = false;

  AiConfigController({AiSecretStore? secretStore})
    : _secretStore = secretStore ?? const SecureAiSecretStore() {
    ready = _load();
  }

  late final Future<void> ready;

  AiAssistantConfig get config => _config;
  bool get showAssistantOnAllPages => _showAssistantOnAllPages;
  bool get showPetOnPlayerPage => _showPetOnPlayerPage;

  /// Serializes all AI settings for an explicit user-created backup.
  ///
  /// Unlike the normal preferences payload this intentionally includes the
  /// API key, because a backup is the user's chosen portable copy of settings.
  Map<String, dynamic> toBackupJson() => {
    'config': config.toLanJson(),
    'showAssistantOnAllPages': _showAssistantOnAllPages,
    'showPetOnPlayerPage': _showPetOnPlayerPage,
  };

  Future<void> restoreBackupJson(Map<String, dynamic> json) async {
    await ready;
    final rawConfig = json['config'];
    if (rawConfig is! Map) {
      throw const FormatException('备份文件中的 AI 配置格式错误');
    }
    final configMap = Map<String, dynamic>.from(rawConfig);
    final rawApiKey = configMap['apiKey'];
    if (rawApiKey != null && rawApiKey is! String) {
      throw const FormatException('备份文件中的 AI API Key 格式错误');
    }
    final restored = AiAssistantConfig.fromJson(
      configMap,
      // A hand-authored/older AI block without a key must not erase the
      // existing secure value. Explicit empty strings still restore empty.
      apiKey: rawApiKey is String ? rawApiKey : _config.apiKey,
    );
    await save(restored);

    final showAll = _readOptionalBool(json, 'showAssistantOnAllPages');
    if (showAll != null) await setShowAssistantOnAllPages(showAll);
    final showPet = _readOptionalBool(json, 'showPetOnPlayerPage');
    if (showPet != null) await setShowPetOnPlayerPage(showPet);
  }

  static bool? _readOptionalBool(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! bool) {
      throw FormatException('备份文件中的 $key 格式错误');
    }
    return value;
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<dynamic>([
        SharedPreferences.getInstance(),
        _secretStore.read(),
      ]);
      final prefs = results[0] as SharedPreferences;
      final apiKey = results[1] as String? ?? '';
      _showAssistantOnAllPages =
          prefs.getBool(showAssistantOnAllPagesPreferenceKey) ?? true;
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

  Future<void> setShowAssistantOnAllPages(bool value) async {
    await ready;
    if (_disposed || _showAssistantOnAllPages == value) return;
    _showAssistantOnAllPages = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(showAssistantOnAllPagesPreferenceKey, value);
    } catch (error) {
      debugPrint('保存全局 AI 助理显示设置失败: $error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
