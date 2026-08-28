import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_assistant.dart';
import '../services/global_settings_service.dart';
import '../services/user_data_scope.dart';

abstract class AiSecretStore {
  Future<String?> read();
  Future<void> write(String value);
}

class SecureAiSecretStore implements AiSecretStore {
  static const _key = 'ai_assistant_api_key';
  static const _storage = FlutterSecureStorage();

  final UserDataScope dataScope;
  final UserDataScope? _legacyScope;

  SecureAiSecretStore({UserDataScope? dataScope})
    : dataScope = UserDataScope.defaultScope,
      _legacyScope = dataScope != null && !dataScope.isDefault
          ? dataScope
          : null;

  @override
  Future<String?> read() async {
    try {
      final current = await _storage.read(key: _key);
      if (current != null || _legacyScope == null) return current;
      final legacy = await _storage.read(
        key: _legacyScope.secureStorageKey(_key),
      );
      if (legacy != null) {
        try {
          await _storage.write(key: _key, value: legacy);
        } catch (_) {}
      }
      return legacy;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> write(String value) async {
    try {
      await _storage.write(key: _key, value: value);
    } on MissingPluginException {
      // Secure storage is optional on test/desktop targets.
    }
  }
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
  static const petAppearancePreferenceKey = 'ai_assistant_pet_appearance_v1';
  static const petPositionXPreferenceKey = 'ai_assistant_pet_position_x';
  static const petPositionYPreferenceKey = 'ai_assistant_pet_position_y';
  static const voiceModelPreferenceKey = 'ai_voice_model_global_v1';
  static const voiceLoadModePreferenceKey = 'ai_voice_load_mode_global_v1';
  static const bargeInModePreferenceKey = 'ai_voice_barge_in_global_v1';
  static const assistantPlaybackModePreferenceKey =
      'ai_voice_playback_mode_global_v1';
  static const duckingReductionPercentPreferenceKey =
      'ai_voice_ducking_reduction_percent_global_v1';

  static const minPetScale = 0.65;
  static const maxPetScale = 2.0;
  static const minDuckingReductionPercent = 10;
  static const maxDuckingReductionPercent = 90;
  static const defaultDuckingReductionPercent = 70;

  final AiSecretStore _secretStore;
  final UserDataScope dataScope;
  final UserDataScope? _legacyScope;
  final List<AiAssistantProfile> _profiles = [];
  final Map<String, String> _apiKeys = {};
  AiAssistantConfig _config = AiAssistantConfig.defaults();
  String _activeProfileId = '';
  bool _showAssistantOnAllPages = true;
  bool _showPetOnPlayerPage = true;
  double _petScale = 1;
  AiPetAppearance _petAppearance = AiPetAppearance.kuzai;
  AiPetPosition _petPosition = AiPetPosition.centered;
  AiVoiceModelKind _voiceModel = AiVoiceModelKind.zipformerChinese;
  AiVoiceLoadMode _voiceLoadMode = AiVoiceLoadMode.onDemand;
  AiBargeInMode _bargeInMode = AiBargeInMode.disabled;
  AiAssistantPlaybackMode _assistantPlaybackMode =
      AiAssistantPlaybackMode.pause;
  int _duckingReductionPercent = defaultDuckingReductionPercent;
  bool _disposed = false;

  AiConfigController({AiSecretStore? secretStore, UserDataScope? dataScope})
    : dataScope = UserDataScope.defaultScope,
      _legacyScope = dataScope != null && !dataScope.isDefault
          ? dataScope
          : null,
      _secretStore = secretStore ?? SecureAiSecretStore(dataScope: dataScope) {
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
  AiPetAppearance get petAppearance => _petAppearance;
  AiPetPosition get petPosition => _petPosition;
  AiVoiceModelKind get voiceModel => _voiceModel;
  AiVoiceLoadMode get voiceLoadMode => _voiceLoadMode;
  AiBargeInMode get bargeInMode => _bargeInMode;
  AiAssistantPlaybackMode get assistantPlaybackMode => _assistantPlaybackMode;
  int get duckingReductionPercent => _duckingReductionPercent;

  /// Serializes all AI settings for an explicit user-created backup.
  ///
  /// API keys are intentionally included here because a backup is the user's
  /// chosen portable copy. They remain absent from ordinary preferences.
  Map<String, dynamic> toBackupJson() => {
    'version': 3,
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
    'petAppearance': _petAppearance.value,
    'petPosition': _petPosition.toJson(),
  };

  Map<String, dynamic> toVoiceBackupJson() => {
    'version': 3,
    'model': _voiceModel.value,
    'loadMode': _voiceLoadMode.value,
    'bargeInMode': _bargeInMode.value,
    'playbackMode': _assistantPlaybackMode.value,
    'duckingReductionPercent': _duckingReductionPercent,
  };

  void validateVoiceBackupJson(Map<String, dynamic> json) {
    final model = json['model'];
    final loadMode = json['loadMode'];
    final bargeInMode = json['bargeInMode'];
    final playbackMode = json['playbackMode'];
    final duckingReduction = json['duckingReductionPercent'];
    if (model is! String ||
        !AiVoiceModelKind.values.any((item) => item.value == model)) {
      throw const FormatException('备份文件中的语音模型无效');
    }
    if (loadMode is! String ||
        !AiVoiceLoadMode.values.any((item) => item.value == loadMode)) {
      throw const FormatException('备份文件中的语音加载方式无效');
    }
    if (bargeInMode != null &&
        (bargeInMode is! String ||
            !AiBargeInMode.values.any((item) => item.value == bargeInMode))) {
      throw const FormatException('备份文件中的语音自动打断设置无效');
    }
    if (playbackMode != null &&
        (playbackMode is! String ||
            !AiAssistantPlaybackMode.values.any(
              (item) => item.value == playbackMode,
            ))) {
      throw const FormatException('备份文件中的助手播放方式无效');
    }
    if (duckingReduction != null &&
        (duckingReduction is! num ||
            !duckingReduction.isFinite ||
            duckingReduction.round() != duckingReduction ||
            duckingReduction < minDuckingReductionPercent ||
            duckingReduction > maxDuckingReductionPercent)) {
      throw const FormatException('备份文件中的后台音量降低比例无效');
    }
  }

  Future<void> restoreVoiceBackupJson(Map<String, dynamic> json) async {
    await ready;
    if (_disposed) return;
    validateVoiceBackupJson(json);
    final model = AiVoiceModelKind.fromValue(json['model'] as String);
    final loadMode = AiVoiceLoadMode.fromValue(json['loadMode'] as String);
    final bargeInMode = AiBargeInMode.fromValue(
      json['bargeInMode']?.toString(),
    );
    final playbackMode = AiAssistantPlaybackMode.fromValue(
      json['playbackMode']?.toString(),
    );
    final duckingReduction = _normalizeDuckingReductionPercent(
      json['duckingReductionPercent'],
    );
    final prefs = await SharedPreferences.getInstance();
    final previous = <String, Object?>{
      voiceModelPreferenceKey: prefs.getString(voiceModelPreferenceKey),
      voiceLoadModePreferenceKey: prefs.getString(voiceLoadModePreferenceKey),
      bargeInModePreferenceKey: prefs.getString(bargeInModePreferenceKey),
      assistantPlaybackModePreferenceKey: prefs.getString(
        assistantPlaybackModePreferenceKey,
      ),
      duckingReductionPercentPreferenceKey: prefs.get(
        duckingReductionPercentPreferenceKey,
      ),
    };
    try {
      for (final entry in {
        voiceModelPreferenceKey: model.value,
        voiceLoadModePreferenceKey: loadMode.value,
        bargeInModePreferenceKey: bargeInMode.value,
        assistantPlaybackModePreferenceKey: playbackMode.value,
      }.entries) {
        if (!await prefs.setString(entry.key, entry.value)) {
          throw StateError('保存全局语音设置失败');
        }
      }
      if (!await prefs.setInt(
        duckingReductionPercentPreferenceKey,
        duckingReduction,
      )) {
        throw StateError('保存全局语音设置失败');
      }
    } catch (error) {
      // SharedPreferences normally persists atomically per key, but restoring
      // three settings is a multi-step operation. Best-effort rollback keeps a
      // failed import from leaving a mixed voice configuration behind.
      for (final entry in previous.entries) {
        try {
          final value = entry.value;
          if (value == null) {
            await prefs.remove(entry.key);
          } else if (value is int) {
            await prefs.setInt(entry.key, value);
          } else {
            await prefs.setString(entry.key, value as String);
          }
        } catch (_) {}
      }
      rethrow;
    }
    _voiceModel = model;
    _voiceLoadMode = loadMode;
    _bargeInMode = bargeInMode;
    _assistantPlaybackMode = playbackMode;
    _duckingReductionPercent = duckingReduction;
    if (!_disposed) notifyListeners();
  }

  /// Validates a portable AI configuration before another backup section is
  /// changed. Restore callers use this as a preflight for all-or-nothing input
  /// validation across favorites, player credentials and AI credentials.
  Future<void> validateBackupJson(Map<String, dynamic> json) async {
    await ready;
    if (_disposed) throw StateError('AI 助手配置已释放');
    _parseBackupJson(json);
  }

  Future<void> restoreBackupJson(
    Map<String, dynamic> json, {
    bool requirePersistence = false,
  }) async {
    await ready;
    if (_disposed) throw StateError('AI 助手配置已释放');
    final restored = _parseBackupJson(json);

    _profiles
      ..clear()
      ..addAll(restored.profiles);
    _apiKeys
      ..clear()
      ..addAll(restored.apiKeys);
    _activeProfileId = restored.activeProfileId;
    _syncActiveConfig();
    _showAssistantOnAllPages = restored.showAssistantOnAllPages;
    _showPetOnPlayerPage = restored.showPetOnPlayerPage;
    _petScale = restored.petScale;
    _petAppearance = restored.petAppearance;
    _petPosition = restored.petPosition;
    await _persist(propagateErrors: requirePersistence);
    if (!_disposed) notifyListeners();
  }

  _AiConfigBackupState _parseBackupJson(Map<String, dynamic> json) {
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
        final profileMap = Map<String, dynamic>.from(raw);
        final rawConfig = profileMap['config'];
        if (rawConfig != null && rawConfig is! Map) {
          throw const FormatException('备份文件中的 AI 模型配置格式错误');
        }
        final configMap = rawConfig is Map
            ? Map<String, dynamic>.from(rawConfig)
            : profileMap;
        _validateBackupApiKey(configMap);
        final profile = AiAssistantProfile.fromJson(profileMap);
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
      _validateBackupApiKey(configMap);
      final rawApiKey = configMap['apiKey'];
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
    final activeProfileId =
        restoredProfiles.any((item) => item.id == requestedActive)
        ? requestedActive!
        : restoredProfiles.first.id;
    final showAssistantOnAllPages =
        _readOptionalBool(json, 'showAssistantOnAllPages') ??
        _showAssistantOnAllPages;
    final showPetOnPlayerPage =
        _readOptionalBool(json, 'showPetOnPlayerPage') ?? _showPetOnPlayerPage;
    final rawScale = json['petScale'];
    if (rawScale != null && rawScale is! num) {
      throw const FormatException('备份文件中的 petScale 格式错误');
    }
    final petScale = rawScale is num
        ? _normalizePetScale(rawScale.toDouble())
        : _petScale;
    final rawAppearance = json['petAppearance'];
    if (rawAppearance != null &&
        (rawAppearance is! String ||
            !AiPetAppearance.values.any(
              (appearance) => appearance.value == rawAppearance,
            ))) {
      throw const FormatException('备份文件中的 petAppearance 格式错误');
    }
    final petAppearance = rawAppearance is String
        ? AiPetAppearance.fromValue(rawAppearance)
        : _petAppearance;
    final petPosition = json.containsKey('petPosition')
        ? AiPetPosition.fromJson(json['petPosition'])
        : _petPosition;

    return _AiConfigBackupState(
      profiles: restoredProfiles,
      apiKeys: restoredKeys,
      activeProfileId: activeProfileId,
      showAssistantOnAllPages: showAssistantOnAllPages,
      showPetOnPlayerPage: showPetOnPlayerPage,
      petScale: petScale,
      petAppearance: petAppearance,
      petPosition: petPosition,
    );
  }

  Future<AiAssistantProfile> createProfile({
    String name = '新模型配置',
    AiAssistantConfig? config,
  }) async {
    await ready;
    if (_disposed) throw StateError('AI 助手配置已释放');
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
    if (_disposed) return;
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
    if (_disposed) return;
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
    if (_disposed) return;
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
    if (_disposed) return;
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

  Future<void> setPetAppearance(AiPetAppearance appearance) async {
    await ready;
    if (_disposed || _petAppearance == appearance) return;
    _petAppearance = appearance;
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

  Future<void> setVoiceModel(AiVoiceModelKind model) async {
    await ready;
    if (_disposed || _voiceModel == model) return;
    await _persistGlobalVoiceSetting(voiceModel: model);
    if (_disposed) return;
    _voiceModel = model;
    notifyListeners();
  }

  Future<void> setVoiceLoadMode(AiVoiceLoadMode mode) async {
    await ready;
    if (_disposed || _voiceLoadMode == mode) return;
    await _persistGlobalVoiceSetting(loadMode: mode);
    if (_disposed) return;
    _voiceLoadMode = mode;
    notifyListeners();
  }

  Future<void> setBargeInMode(AiBargeInMode mode) async {
    await ready;
    if (_disposed || _bargeInMode == mode) return;
    await _persistGlobalVoiceSetting(bargeInMode: mode);
    if (_disposed) return;
    _bargeInMode = mode;
    notifyListeners();
  }

  Future<void> setAssistantPlaybackMode(AiAssistantPlaybackMode mode) async {
    await ready;
    if (_disposed || _assistantPlaybackMode == mode) return;
    await _persistGlobalVoiceSetting(assistantPlaybackMode: mode);
    if (_disposed) return;
    _assistantPlaybackMode = mode;
    notifyListeners();
  }

  Future<void> setDuckingReductionPercent(int percent) async {
    await ready;
    final normalized = _normalizeDuckingReductionPercent(percent);
    if (_disposed || _duckingReductionPercent == normalized) return;
    await _persistGlobalVoiceSetting(duckingReductionPercent: normalized);
    if (_disposed) return;
    _duckingReductionPercent = normalized;
    notifyListeners();
  }

  Future<void> resetPetPosition() => setPetPosition(AiPetPosition.centered);

  Future<void> _load() async {
    try {
      await GlobalSettingsService.migrateLegacyScopedSettings(
        _legacyScope ?? UserDataScope.defaultScope,
      );
      final results = await Future.wait<dynamic>([
        SharedPreferences.getInstance(),
        _secretStore.read(),
      ]);
      final prefs = results[0] as SharedPreferences;
      final persistedVoiceModel = prefs.getString(voiceModelPreferenceKey);
      final legacyVoiceModels = <String, AiVoiceModelKind>{};
      _voiceLoadMode = AiVoiceLoadMode.fromValue(
        prefs.getString(voiceLoadModePreferenceKey),
      );
      _bargeInMode = AiBargeInMode.fromValue(
        prefs.getString(bargeInModePreferenceKey),
      );
      _assistantPlaybackMode = AiAssistantPlaybackMode.fromValue(
        prefs.getString(assistantPlaybackModePreferenceKey),
      );
      _duckingReductionPercent = _normalizeDuckingReductionPercent(
        prefs.get(duckingReductionPercentPreferenceKey),
      );
      _apiKeys.addAll(_decodeSecretMap(results[1] as String?));
      _showAssistantOnAllPages =
          prefs.getBool(showAssistantOnAllPagesPreferenceKey) ?? true;
      _showPetOnPlayerPage =
          prefs.getBool(showPetOnPlayerPagePreferenceKey) ?? true;
      _petScale = _normalizePetScale(
        prefs.getDouble(petScalePreferenceKey) ?? 1,
      );
      _petAppearance = AiPetAppearance.fromValue(
        prefs.getString(petAppearancePreferenceKey),
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
            final profileMap = Map<String, dynamic>.from(raw);
            final parsed = AiAssistantProfile.fromJson(profileMap);
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
            final rawConfig = profileMap['config'];
            final configMap = rawConfig is Map
                ? Map<String, dynamic>.from(rawConfig)
                : profileMap;
            final legacyVoice = configMap['voiceModel'];
            if (legacyVoice != null) {
              legacyVoiceModels[profile.id] = AiVoiceModelKind.fromValue(
                legacyVoice.toString(),
              );
            }
          }
        }
      }

      if (_profiles.isEmpty) {
        final legacyRaw = prefs.getString(_legacyPreferencesKey);
        if (legacyRaw != null) {
          final decoded = jsonDecode(legacyRaw);
          if (decoded is Map) {
            final legacyMap = Map<String, dynamic>.from(decoded);
            final legacy = AiAssistantProfile.fromJson(
              legacyMap,
              apiKey:
                  _apiKeys[_legacyProfileId] ?? _apiKeys['__legacy__'] ?? '',
            ).copyWith(id: _legacyProfileId, name: '默认配置');
            _profiles.add(legacy);
            _apiKeys[_legacyProfileId] = legacy.config.apiKey;
            final rawConfig = legacyMap['config'];
            final configMap = rawConfig is Map
                ? Map<String, dynamic>.from(rawConfig)
                : legacyMap;
            final legacyVoice = configMap['voiceModel'];
            if (legacyVoice != null) {
              legacyVoiceModels[_legacyProfileId] = AiVoiceModelKind.fromValue(
                legacyVoice.toString(),
              );
            }
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
      _voiceModel = persistedVoiceModel == null
          ? legacyVoiceModels[_activeProfileId] ??
                AiVoiceModelKind.zipformerChinese
          : AiVoiceModelKind.fromValue(persistedVoiceModel);
      if (persistedVoiceModel == null) {
        try {
          await prefs.setString(voiceModelPreferenceKey, _voiceModel.value);
        } catch (error, stackTrace) {
          debugPrint('迁移全局语音引擎失败: $error\n$stackTrace');
        }
      }
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

  Future<void> _persistGlobalVoiceSetting({
    AiVoiceModelKind? voiceModel,
    AiVoiceLoadMode? loadMode,
    AiBargeInMode? bargeInMode,
    AiAssistantPlaybackMode? assistantPlaybackMode,
    int? duckingReductionPercent,
  }) async {
    if (_disposed) return;
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    final saved = switch ((
      voiceModel,
      loadMode,
      bargeInMode,
      assistantPlaybackMode,
      duckingReductionPercent,
    )) {
      (final model?, _, _, _, _) => prefs.setString(
        voiceModelPreferenceKey,
        model.value,
      ),
      (_, final mode?, _, _, _) => prefs.setString(
        voiceLoadModePreferenceKey,
        mode.value,
      ),
      (_, _, final mode?, _, _) => prefs.setString(
        bargeInModePreferenceKey,
        mode.value,
      ),
      (_, _, _, final mode?, _) => prefs.setString(
        assistantPlaybackModePreferenceKey,
        mode.value,
      ),
      (_, _, _, _, final percent?) => prefs.setInt(
        duckingReductionPercentPreferenceKey,
        percent,
      ),
      _ => Future<bool>.value(false),
    };
    final persisted = await saved;
    if (!persisted) throw StateError('保存全局语音设置失败');
  }

  static int _normalizeDuckingReductionPercent(Object? value) {
    final parsed = value is num && value.isFinite
        ? value.round()
        : int.tryParse(value?.toString() ?? '');
    return (parsed ?? defaultDuckingReductionPercent)
        .clamp(minDuckingReductionPercent, maxDuckingReductionPercent)
        .toInt();
  }

  Future<void> _persist({bool propagateErrors = false}) async {
    if (_disposed) return;
    // Settings callbacks are allowed to return a Future, but Flutter does
    // not await callback results. A storage/plugin failure must therefore be
    // contained here instead of becoming an uncaught async error.
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (error, stackTrace) {
      if (propagateErrors) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      debugPrint('保存 AI 助理偏好失败: $error\n$stackTrace');
      return;
    }

    try {
      await _secretStore.write(jsonEncode(_apiKeys));
    } catch (error, stackTrace) {
      if (propagateErrors) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      debugPrint('保存 AI 助理密钥失败: $error\n$stackTrace');
    }

    try {
      final saved = await Future.wait([
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
        prefs.setString(petAppearancePreferenceKey, _petAppearance.value),
        prefs.setDouble(petPositionXPreferenceKey, _petPosition.x),
        prefs.setDouble(petPositionYPreferenceKey, _petPosition.y),
      ]);
      if (saved.any((value) => !value)) {
        throw StateError('保存 AI 助理偏好失败');
      }
    } catch (error, stackTrace) {
      if (propagateErrors) {
        Error.throwWithStackTrace(error, stackTrace);
      }
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

  static void _validateBackupApiKey(Map<String, dynamic> config) {
    final value = config['apiKey'];
    if (value != null && value is! String) {
      throw const FormatException('备份文件中的 AI API Key 格式错误');
    }
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

class _AiConfigBackupState {
  final List<AiAssistantProfile> profiles;
  final Map<String, String> apiKeys;
  final String activeProfileId;
  final bool showAssistantOnAllPages;
  final bool showPetOnPlayerPage;
  final double petScale;
  final AiPetAppearance petAppearance;
  final AiPetPosition petPosition;

  const _AiConfigBackupState({
    required this.profiles,
    required this.apiKeys,
    required this.activeProfileId,
    required this.showAssistantOnAllPages,
    required this.showPetOnPlayerPage,
    required this.petScale,
    required this.petAppearance,
    required this.petPosition,
  });
}
