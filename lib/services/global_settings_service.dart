import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/lyric_style.dart';
import 'user_data_scope.dart';

/// Owns preference keys that apply to the whole app rather than one profile.
abstract final class GlobalSettingsService {
  static const aiSecretKey = 'ai_assistant_api_key';
  static const landscapeSplitRatioKey = 'player_landscape_split_ratio';

  static const _globalPreferenceKeys = <String>[
    'theme_mode',
    'font_scale',
    'floating_mini_window_enabled',
    'floating_capsule_enabled',
    LyricStylePreferences.fontSizeKey,
    LyricStylePreferences.lineSpacingKey,
    LyricStylePreferences.fontFamilyKey,
    LyricStylePreferences.fontWeightKey,
    landscapeSplitRatioKey,
    'api_key',
    'netease_level',
    'common_level',
    'playback_source_netease',
    'playback_source_qq',
    'playback_source_kugou',
    'bilibili_audio_quality',
    'bilibili_video_quality',
    'bilibili_lyric_platform_order',
    'lyric_offset_step_ms',
    'video_player_mode',
    'bilibili_cookie',
    'ai_assistant_config_v1',
    'ai_assistant_profiles_v1',
    'ai_assistant_active_profile_v1',
    'ai_assistant_show_on_all_pages',
    'ai_assistant_show_pet_on_player_page',
    'ai_assistant_pet_scale',
    'ai_assistant_pet_appearance_v1',
    'ai_assistant_pet_position_x',
    'ai_assistant_pet_position_y',
    'ai_voice_model_global_v1',
    'ai_voice_load_mode_global_v1',
  ];

  /// Defaults used when an export is requested before SharedPreferences has
  /// finished loading. The UI export paths replace these with the live values.
  static Map<String, dynamic> defaultLyricDisplay() => {
    'version': 1,
    'fontSize': 42,
    'lineSpacing': 44,
    'fontFamily': 'system',
    'fontWeight': 500,
    'landscapeSplitRatio': 0.42,
  };

  /// Upgrades installations that last ran while a non-default user's settings
  /// were still namespaced. Existing global values always win.
  static Future<void> migrateLegacyScopedSettings(UserDataScope source) async {
    if (source.isDefault) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in _globalPreferenceKeys) {
        if (prefs.containsKey(key)) continue;
        final scopedKey = source.preferenceKey(key);
        if (!prefs.containsKey(scopedKey)) continue;
        await _copyPreference(prefs, from: scopedKey, to: key);
      }
    } catch (error, stackTrace) {
      _logMigrationFailure('迁移全局设置失败', error, stackTrace);
    }

    try {
      const storage = FlutterSecureStorage();
      final current = await storage.read(key: aiSecretKey);
      if (current != null) return;
      final legacy = await storage.read(
        key: source.secureStorageKey(aiSecretKey),
      );
      if (legacy != null) await storage.write(key: aiSecretKey, value: legacy);
    } catch (error, stackTrace) {
      _logMigrationFailure('迁移全局 AI 密钥失败', error, stackTrace);
    }
  }

  static Future<void> _copyPreference(
    SharedPreferences prefs, {
    required String from,
    required String to,
  }) async {
    final value = prefs.get(from);
    switch (value) {
      case final bool value:
        await prefs.setBool(to, value);
      case final int value:
        await prefs.setInt(to, value);
      case final double value:
        await prefs.setDouble(to, value);
      case final String value:
        await prefs.setString(to, value);
      case final List<String> value:
        await prefs.setStringList(to, value);
    }
  }

  static Future<Map<String, dynamic>> exportLyricDisplay() async {
    final prefs = await SharedPreferences.getInstance();
    final defaults = defaultLyricDisplay();
    return {
      'version': 1,
      'fontSize':
          _number(prefs.get(LyricStylePreferences.fontSizeKey)) ??
          defaults['fontSize'],
      'lineSpacing':
          _number(prefs.get(LyricStylePreferences.lineSpacingKey)) ??
          defaults['lineSpacing'],
      'fontFamily':
          prefs.getString(LyricStylePreferences.fontFamilyKey) ??
          defaults['fontFamily'],
      'fontWeight':
          prefs.getInt(LyricStylePreferences.fontWeightKey) ??
          defaults['fontWeight'],
      'landscapeSplitRatio':
          _number(prefs.get(landscapeSplitRatioKey)) ??
          defaults['landscapeSplitRatio'],
    };
  }

  static void validateLyricDisplay(Map<String, dynamic> json) {
    final fontSize = _requiredFiniteNumber(json, 'fontSize', '歌词字号');
    final spacing = _requiredFiniteNumber(json, 'lineSpacing', '歌词行距');
    final split = _requiredFiniteNumber(json, 'landscapeSplitRatio', '横屏歌词布局');
    final family = json['fontFamily'];
    final weight = json['fontWeight'];
    if (fontSize < 24 || fontSize > 80) {
      throw const FormatException('备份文件中的歌词字号无效');
    }
    if (spacing < 20 || spacing > 160) {
      throw const FormatException('备份文件中的歌词行距无效');
    }
    if (split < 0.32 || split > 0.62) {
      throw const FormatException('备份文件中的横屏歌词布局无效');
    }
    if (family is! String ||
        !LyricFontFamilyPreset.values.any((item) => item.value == family)) {
      throw const FormatException('备份文件中的歌词字体无效');
    }
    if (weight is! num ||
        !LyricFontWeightPreset.values.any(
          (item) => item.value == weight.toInt(),
        )) {
      throw const FormatException('备份文件中的歌词字重无效');
    }
  }

  static Future<void> restoreLyricDisplay(Map<String, dynamic> json) async {
    validateLyricDisplay(json);
    final prefs = await SharedPreferences.getInstance();
    final writes = await Future.wait([
      prefs.setDouble(
        LyricStylePreferences.fontSizeKey,
        (json['fontSize'] as num).toDouble(),
      ),
      prefs.setDouble(
        LyricStylePreferences.lineSpacingKey,
        (json['lineSpacing'] as num).toDouble(),
      ),
      prefs.setString(
        LyricStylePreferences.fontFamilyKey,
        json['fontFamily'] as String,
      ),
      prefs.setInt(
        LyricStylePreferences.fontWeightKey,
        (json['fontWeight'] as num).toInt(),
      ),
      prefs.setDouble(
        landscapeSplitRatioKey,
        (json['landscapeSplitRatio'] as num).toDouble(),
      ),
    ]);
    if (writes.any((saved) => !saved)) {
      throw StateError('保存歌词显示设置失败');
    }
  }

  static double? _number(Object? value) =>
      value is num && value.isFinite ? value.toDouble() : null;

  static double _requiredFiniteNumber(
    Map<String, dynamic> json,
    String key,
    String label,
  ) {
    final value = _number(json[key]);
    if (value == null) throw FormatException('备份文件中的$label格式错误');
    return value;
  }

  static void _logMigrationFailure(
    String message,
    Object error,
    StackTrace stackTrace,
  ) {
    // Secure storage has no implementation in Flutter widget tests and on a
    // few desktop targets. That is an expected portability condition, not a
    // recoverable application error worth printing as a stack trace.
    if (error is MissingPluginException) return;
    debugPrint('$message: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}
