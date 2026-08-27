import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/global_settings_service.dart';
import '../services/user_data_scope.dart';

/// 外观控制器：管理主题模式和全局字号比例，并持久化到本地。
class ThemeController extends ChangeNotifier {
  static const String _prefKey = 'theme_mode';
  static const String _fontScalePrefKey = 'font_scale';
  static const String _modeSystem = 'system';
  static const String _modeLight = 'light';
  static const String _modeDark = 'dark';
  static const double minFontScale = 0.5;
  static const double maxFontScale = 1.5;
  static const double defaultFontScale = 1;

  ThemeMode _mode = ThemeMode.system;
  double _fontScale = defaultFontScale;
  bool _fontScaleChangedByUser = false;
  bool _disposed = false;
  final UserDataScope dataScope;
  final UserDataScope? _legacyScope;

  ThemeMode get mode => _mode;
  double get fontScale => _fontScale;

  ThemeController({UserDataScope? dataScope})
    : dataScope = UserDataScope.defaultScope,
      _legacyScope = dataScope != null && !dataScope.isDefault
          ? dataScope
          : null {
    ready = _load();
  }

  late final Future<void> ready;

  Future<void> _load() async {
    try {
      await GlobalSettingsService.migrateLegacyScopedSettings(
        _legacyScope ?? UserDataScope.defaultScope,
      );
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_prefKey);
      switch (v) {
        case _modeLight:
          _mode = ThemeMode.light;
          break;
        case _modeDark:
          _mode = ThemeMode.dark;
          break;
        default:
          _mode = ThemeMode.system;
      }
      final rawFontScale = prefs.get(_fontScalePrefKey);
      if (!_fontScaleChangedByUser && rawFontScale is num) {
        _fontScale = _normalizeFontScale(rawFontScale.toDouble());
      }
      if (!_disposed) notifyListeners();
    } catch (_) {}
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_disposed) return;
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      final String store;
      switch (mode) {
        case ThemeMode.light:
          store = _modeLight;
          break;
        case ThemeMode.dark:
          store = _modeDark;
          break;
        default:
          store = _modeSystem;
      }
      await prefs.setString(_prefKey, store);
    } catch (_) {}
  }

  /// 拖动过程中只更新界面，避免连续写入本地存储。
  void previewFontScale(double value) {
    if (_disposed) return;
    _fontScaleChangedByUser = true;
    final normalized = _normalizeFontScale(value);
    if (_fontScale == normalized) return;
    _fontScale = normalized;
    notifyListeners();
  }

  /// 拖动结束或恢复默认值时保存最终比例。
  Future<void> setFontScale(double value) async {
    if (_disposed) return;
    previewFontScale(value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_fontScalePrefKey, _fontScale);
    } catch (_) {}
  }

  Map<String, dynamic> toBackupJson() => {
    'mode': switch (_mode) {
      ThemeMode.light => _modeLight,
      ThemeMode.dark => _modeDark,
      ThemeMode.system => _modeSystem,
    },
    'fontScale': _fontScale,
  };

  Future<void> restoreBackupJson(Map<String, dynamic> json) async {
    await ready;
    if (_disposed) return;
    final modeValue = json['mode'];
    final fontScaleValue = json['fontScale'];
    if (modeValue is! String ||
        !const {_modeSystem, _modeLight, _modeDark}.contains(modeValue)) {
      throw const FormatException('备份文件中的外观模式无效');
    }
    if (fontScaleValue is! num || !fontScaleValue.isFinite) {
      throw const FormatException('备份文件中的整体字号无效');
    }
    final nextMode = switch (modeValue) {
      _modeLight => ThemeMode.light,
      _modeDark => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final nextScale = _normalizeFontScale(fontScaleValue.toDouble());
    _mode = nextMode;
    _fontScale = nextScale;
    _fontScaleChangedByUser = true;
    final prefs = await SharedPreferences.getInstance();
    final saved = await Future.wait([
      prefs.setString(_prefKey, modeValue),
      prefs.setDouble(_fontScalePrefKey, nextScale),
    ]);
    if (saved.any((value) => !value)) throw StateError('保存外观设置失败');
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static double _normalizeFontScale(double value) {
    if (!value.isFinite) return defaultFontScale;
    final clamped = value.clamp(minFontScale, maxFontScale).toDouble();
    return ((clamped * 20).round() / 20).toDouble();
  }
}
