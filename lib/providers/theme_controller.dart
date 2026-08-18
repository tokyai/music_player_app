import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  ThemeMode get mode => _mode;
  double get fontScale => _fontScale;

  ThemeController() {
    _load();
  }

  Future<void> _load() async {
    try {
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
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setMode(ThemeMode mode) async {
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
    _fontScaleChangedByUser = true;
    final normalized = _normalizeFontScale(value);
    if (_fontScale == normalized) return;
    _fontScale = normalized;
    notifyListeners();
  }

  /// 拖动结束或恢复默认值时保存最终比例。
  Future<void> setFontScale(double value) async {
    previewFontScale(value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_fontScalePrefKey, _fontScale);
    } catch (_) {}
  }

  static double _normalizeFontScale(double value) {
    if (!value.isFinite) return defaultFontScale;
    final clamped = value.clamp(minFontScale, maxFontScale).toDouble();
    return ((clamped * 20).round() / 20).toDouble();
  }
}
