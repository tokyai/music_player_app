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
  static const _legacyPreferencesKey = 'ai_assistant_config_v1';
  static const _profilesPreferencesKey = 'ai_assistant_profiles_v1';
  static const _activeProfilePreferenceKey = 'ai_assistant_active_profile_v1';
  static const _legacyProfileId = 'legacy-ai-profile';

  /// Controls the assistant entry point on the app's main pages.
  static const showAssistantOnAllPagesPreferenceKey =
      'ai_assistant_show_on_all_pages';
  static const showPetOnPlayerPagePreferenceKey =
      'ai_assistant_show_pet_on_player_page';
  static const petScalePreferenceKey = 'ai_assistant_pet_scale';
  static const petPositionXPreferenceKey = 'ai_assistant_pet_position_x';
  static const petPositionYPreferenceKey = 'ai_assistant_pet_position_y';

  static const minPetScale = 0.65;
  static const maxPetScale = 2.0;

  final AiSecretStore _secretStore;
  final List<AiAssistantProfile> _profiles = [];
  final Map<String, String> _apiKeys = {};
  AiAssistantConfig _config = AiAssistantConfig.defaults();
  String _activeProfileId = '';
  bool _showAssistantOnAllPages = true;
  bool _showPetOnPlayerPage = true;
  double _petScale = 1;
  AiPetPosition _petPosition = AiPetPosition.centered;
  bool _disposed = false;

  AiConfigController({AiSecretStore? secretStore})
    : _secretStore = secretStore ?? const SecureAiSecretStore() {
    ready = _load();
  }

  late final Future<void> ready;

  AiAssistantConfig get config => _config;
  List<AiAssistantProfile> get profiles => List.unmodifiable(_profiles);
  String get activeProfileId => _activeProfileId;
  AiAssistantProfile? get activeProfile {
    for (final profile in _profiles) {
      if (profile.id == _activeProfileId) return profile;
    }
    return _profiles.isEmpty ? null : _profiles.first;
  }

  bool get showAssistantOnAllPages => _showAssistantOnAllPages;
  bool get showPetOnPlayerPage => _showPetOnPlayerPage;
  double get petScale => _petScale;
  AiPetPosition get petPosition => _petPosition;

  /// Serializes all AI settings for an explicit user-created backup.
  ///
  /// API keys are intentionally included here because a backup is the user's
  /// chosen portable copy. They remain absent from ordinary preferences.
  Map<String, dynamic> toBackupJson() => {
    'version': 2,
    'activeProfileId': _activeProfileId,
    'profiles': _profiles.map((profile) {
      final key = _apiKeys[profile.id] ?? profile.config.apiKey;
      return profile
          .copyWith(config: profile.config.copyWith(apiKey: key))
          .toBackupJson();
    }).toList(),
    // Keep the active config for older consumers that only understand v1.
    'config': config.toLanJson(),
    'showAssistantOnAllPages': _showAssistantOnAllPages,
    'showPetOnPlayerPage': _showPetOnPlayerPage,
    'petScale': _petScale,
    'petPosition': _petPosition.toJson(),
  };

  Future<void> restoreBackupJson(Map<String, dynamic> json) async {
    await ready;
    final restoredProfiles = <AiAssistantProfile>[];
    final restoredKeys = <String, String>{};
    final rawProfiles = json['profiles'];
    if (json.containsKey('profiles') && rawProfiles is! List) {
      throw const FormatException('备份文件中的 AI 模型配置列表格式错误');
    }
    if (rawProfiles is List) {
      for (final raw in rawProfiles) {
        if (raw is! Map) {
          throw const FormatException('备份文件中的 AI 模型配置格式错误');
        }
        final profile = AiAssistantProfile.fromJson(
          Map<String, dynamic>.from(raw),
        );
        if (profile.id.trim().isEmpty ||
            restoredProfiles.any((item) => item.id == profile.id)) {
          throw const FormatException('备份文件中的 AI 模型配置 ID 无效');
        }
        final normalized = _normalizeConfig(profile.config);
        restoredProfiles.add(profile.copyWith(config: normalized));
        restoredKeys[profile.id] = normalized.apiKey;
      }
      if (restoredProfiles.isEmpty) {
        throw const FormatException('备份文件中的 AI 模型配置列表为空');
      }
    } else {
      // v1 backup compatibility: promote the single config to one profile.
      final rawConfig = json['config'];
      if (rawConfig is! Map) {
        throw const FormatException('备份文件中的 AI 配置格式错误');
      }
      final configMap = Map<String, dynamic>.from(rawConfig);
      final rawApiKey = configMap['apiKey'];
      if (rawApiKey != null && rawApiKey is! String) {
        throw const FormatException('备份文件中的 AI API Key 格式错误');
      }
      final legacyConfig = _normalizeConfig(
        AiAssistantConfig.fromJson(
          configMap,
          apiKey: rawApiKey is String ? rawApiKey : _config.apiKey,
        ),
      );
      restoredProfiles.add(
        AiAssistantProfile(
          id: _legacyProfileId,
          name: '默认配置',
          config: legacyConfig,
        ),
      );
      restoredKeys[_legacyProfileId] = legacyConfig.apiKey;
    }

    final requestedActive = json['activeProfileId']?.toString();
    _profiles
      ..clear()
      ..addAll(restoredProfiles);
    _apiKeys
      ..clear()
      ..addAll(restoredKeys);
    _activeProfileId =
        restoredProfiles.any((item) => item.id == requestedActive)
        ? requestedActive!
        : restoredProfiles.first.id;
    _syncActiveConfig();
    _showAssistantOnAllPages =
        _readOptionalBool(json, 'showAssistantOnAllPages') ??
        _showAssistantOnAllPages;
    _showPetOnPlayerPage =
        _readOptionalBool(json, 'showPetOnPlayerPage') ?? _showPetOnPlayerPage;
    final rawScale = json['petScale'];
    if (rawScale is num) _petScale = _normalizePetScale(rawScale.toDouble());
    if (json.containsKey('petPosition')) {
      _petPosition = AiPetPosition.fromJson(json['petPosition']);
    }
    await _persist();
    if (!_disposed) notifyListeners();
  }

  Future<AiAssistantProfile> createProfile({
    String name = '新模型配置',
    AiAssistantConfig? config,
  }) async {
    await ready;
    final profile = AiAssistantProfile(
      id: _newProfileId(),
      name: name.trim().isEmpty ? '新模型配置' : name.trim(),
      config: _normalizeConfig(config ?? AiAssistantConfig.defaults()),
    );
    _profiles.add(profile);
    _apiKeys[profile.id] = profile.config.apiKey;
    _activeProfileId = profile.id;
    _syncActiveConfig();
    await _persist();
    if (!_disposed) notifyListeners();
    return profile;
  }

  Future<void> selectProfile(String id) async {
    await ready;
    if (!_profiles.any((profile) => profile.id == id) ||
        _activeProfileId == id) {
      return;
    }
    _activeProfileId = id;
    _syncActiveConfig();
    await _persist();
    if (!_disposed) notifyListeners();
  }

  Future<void> updateProfile(
    String id, {
    String? name,
    AiAssistantConfig? config,
  }) async {
    await ready;
    final index = _profiles.indexWhere((profile) => profile.id == id);
    if (index < 0) throw StateError('模型配置不存在');
    final old = _profiles[index];
    final normalized = _normalizeConfig(config ?? old.config);
    _profiles[index] = old.copyWith(
      name: name == null || name.trim().isEmpty ? old.name : name.trim(),
      config: normalized,
    );
    _apiKeys[id] = normalized.apiKey;
    if (_activeProfileId == id) _syncActiveConfig();
    await _persist();
    if (!_disposed) notifyListeners();
  }

  Future<void> renameProfile(String id, String name) =>
      updateProfile(id, name: name);

  Future<void> deleteProfile(String id) async {
    await ready;
    if (_profiles.length <= 1) {
      throw StateError('至少保留一个模型配置');
    }
    final index = _profiles.indexWhere((profile) => profile.id == id);
    if (index < 0) return;
    _profiles.removeAt(index);
    _apiKeys.remove(id);
    if (_activeProfileId == id) {
      _activeProfileId =
          _profiles[index.clamp(0, _profiles.length - 1).toInt()].id;
    }
    _syncActiveConfig();
    await _persist();
    if (!_disposed) notifyListeners();
  }

  /// Backwards-compatible save operation used by existing callers.
  Future<void> save(AiAssistantConfig config) async {
    await ready;
    if (_profiles.isEmpty) {
      await createProfile(config: config);
      return;
    }
    await updateProfile(_activeProfileId, config: config);
  }

  Future<void> setShowPetOnPlayerPage(bool value) async {
    await ready;
    if (_disposed || _showPetOnPlayerPage == value) return;
    _showPetOnPlayerPage = value;
    await _persist();
    if (!_disposed) notifyListeners();
  }

  Future<void> setShowAssistantOnAllPages(bool value) async {
    await ready;
    if (_disposed || _showAssistantOnAllPages == value) return;
    _showAssistantOnAllPages = value;
    await _persist();
    if (!_disposed) notifyListeners();
  }

  Future<void> setPetScale(double value) async {
    await ready;
    final normalized = _normalizePetScale(value);
    if (_disposed || (_petScale - normalized).abs() < 0.001) return;
    _petScale = normalized;
    await _persist();
    if (!_disposed) notifyListeners();
  }

  Future<void> setPetPosition(AiPetPosition position) async {
    await ready;
    final normalized = position.normalized();
    if (_disposed ||
        (_petPosition.x - normalized.x).abs() < 0.001 &&
            (_petPosition.y - normalized.y).abs() < 0.001) {
      return;
    }
    _petPosition = normalized;
    await _persist();
    if (!_disposed) notifyListeners();
  }

  Future<void> resetPetPosition() => setPetPosition(AiPetPosition.centered);

  Future<void> _load() async {
    try {
      final results = await Future.wait<dynamic>([
        SharedPreferences.getInstance(),
        _secretStore.read(),
      ]);
      final prefs = results[0] as SharedPreferences;
      _apiKeys.addAll(_decodeSecretMap(results[1] as String?));
      _showAssistantOnAllPages =
          prefs.getBool(showAssistantOnAllPagesPreferenceKey) ?? true;
      _showPetOnPlayerPage =
          prefs.getBool(showPetOnPlayerPagePreferenceKey) ?? true;
      _petScale = _normalizePetScale(
        prefs.getDouble(petScalePreferenceKey) ?? 1,
      );
      _petPosition = AiPetPosition(
        x: prefs.getDouble(petPositionXPreferenceKey) ?? 1,
        y: prefs.getDouble(petPositionYPreferenceKey) ?? 0,
      ).normalized();

      final profilesRaw = prefs.getString(_profilesPreferencesKey);
      if (profilesRaw != null) {
        final decoded = jsonDecode(profilesRaw);
        if (decoded is List) {
          for (final raw in decoded) {
            if (raw is! Map) continue;
            final parsed = AiAssistantProfile.fromJson(
              Map<String, dynamic>.from(raw),
            );
            if (parsed.id.trim().isEmpty ||
                _profiles.any((profile) => profile.id == parsed.id)) {
              continue;
            }
            final key = _apiKeys[parsed.id] ?? parsed.config.apiKey;
            final profile = parsed.copyWith(
              config: parsed.config.copyWith(apiKey: key),
            );
            _profiles.add(profile);
            _apiKeys[profile.id] = key;
          }
        }
      }

      if (_profiles.isEmpty) {
        final legacyRaw = prefs.getString(_legacyPreferencesKey);
        if (legacyRaw != null) {
          final decoded = jsonDecode(legacyRaw);
          if (decoded is Map) {
            final legacy = AiAssistantProfile.fromJson(
              Map<String, dynamic>.from(decoded),
              apiKey:
                  _apiKeys[_legacyProfileId] ?? _apiKeys['__legacy__'] ?? '',
            ).copyWith(id: _legacyProfileId, name: '默认配置');
            _profiles.add(legacy);
            _apiKeys[_legacyProfileId] = legacy.config.apiKey;
          }
        }
      }
      if (_profiles.isEmpty) {
        final profile = AiAssistantProfile(
          id: _legacyProfileId,
          name: '默认配置',
          config: AiAssistantConfig.defaults().copyWith(
            apiKey: _apiKeys[_legacyProfileId] ?? _apiKeys['__legacy__'] ?? '',
          ),
        );
        _profiles.add(profile);
        _apiKeys[profile.id] = profile.config.apiKey;
      }
      final requested = prefs.getString(_activeProfilePreferenceKey);
      _activeProfileId = _profiles.any((profile) => profile.id == requested)
          ? requested!
          : _profiles.first.id;
      _syncActiveConfig();
    } catch (error) {
      debugPrint('读取 AI 助理配置失败: $error');
      if (_profiles.isEmpty) {
        _profiles.add(
          const AiAssistantProfile(
            id: _legacyProfileId,
            name: '默认配置',
            config: AiAssistantConfig(
              provider: AiProviderKind.openAi,
              protocol: AiRequestProtocol.openAiResponses,
              baseUrl: 'https://api.openai.com/v1',
              apiKey: '',
              model: '',
              reasoningEffort: AiReasoningEffort.platformDefault,
              webSearchMode: AiWebSearchMode.automatic,
            ),
          ),
        );
      }
      if (!_profiles.any((profile) => profile.id == _activeProfileId)) {
        _activeProfileId = _profiles.first.id;
      }
      _syncActiveConfig();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _persist() async {
    // Settings callbacks are allowed to return a Future, but Flutter does
    // not await callback results. A storage/plugin failure must therefore be
    // contained here instead of becoming an uncaught async error.
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (error, stackTrace) {
      debugPrint('保存 AI 助理偏好失败: $error\n$stackTrace');
      return;
    }

    try {
      await _secretStore.write(jsonEncode(_apiKeys));
    } catch (error, stackTrace) {
      debugPrint('保存 AI 助理密钥失败: $error\n$stackTrace');
    }

    try {
      await Future.wait([
        prefs.setString(
          _profilesPreferencesKey,
          jsonEncode(
            _profiles.map((profile) => profile.toPreferencesJson()).toList(),
          ),
        ),
        prefs.setString(_activeProfilePreferenceKey, _activeProfileId),
        prefs.setBool(
          showAssistantOnAllPagesPreferenceKey,
          _showAssistantOnAllPages,
        ),
        prefs.setBool(showPetOnPlayerPagePreferenceKey, _showPetOnPlayerPage),
        prefs.setDouble(petScalePreferenceKey, _petScale),
        prefs.setDouble(petPositionXPreferenceKey, _petPosition.x),
        prefs.setDouble(petPositionYPreferenceKey, _petPosition.y),
      ]);
    } catch (error, stackTrace) {
      debugPrint('保存 AI 助理偏好失败: $error\n$stackTrace');
    }
  }

  void _syncActiveConfig() {
    final profile = activeProfile;
    if (profile == null) {
      _config = AiAssistantConfig.defaults();
      return;
    }
    final key = _apiKeys[profile.id] ?? profile.config.apiKey;
    _config = profile.config.copyWith(apiKey: key);
  }

  AiAssistantConfig _normalizeConfig(AiAssistantConfig config) {
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
    return normalized;
  }

  static double _normalizePetScale(double value) =>
      value.clamp(minPetScale, maxPetScale).toDouble();

  static Map<String, String> _decodeSecretMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
        );
      }
    } catch (_) {
      // The v1 store held a single plain API key.
    }
    return {'__legacy__': raw};
  }

  static bool? _readOptionalBool(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! bool) throw FormatException('备份文件中的 $key 格式错误');
    return value;
  }

  String _newProfileId() {
    final base = DateTime.now().microsecondsSinceEpoch.toString();
    var id = 'ai-$base';
    var suffix = 1;
    while (_profiles.any((profile) => profile.id == id)) {
      id = 'ai-$base-$suffix';
      suffix++;
    }
    return id;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
