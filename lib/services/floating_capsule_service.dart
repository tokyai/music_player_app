import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'user_data_scope.dart';

/// 车机迷你窗（系统级悬浮窗）原生桥接。
///
/// Android 使用 TYPE_APPLICATION_OVERLAY，因此用户切换到其他应用后，
/// 迷你窗仍会置顶显示当前歌曲信息。保留旧类名以兼容已有播放器入口。
class FloatingCapsuleService {
  static const channelName = 'music_player/floating_capsule';
  static const preferenceKey = 'floating_mini_window_enabled';
  static const legacyPreferenceKey = 'floating_capsule_enabled';
  static const MethodChannel _channel = MethodChannel(channelName);

  /// 功能开关（设置页控制，持久化在 shared_preferences）
  static bool _enabled = false;

  static bool get enabled => _enabled;

  static void setEnabled(bool value) => _enabled = value;

  /// 恢复迷你窗开关。旧版本的胶囊开关会自动迁移到新设置键。
  static Future<bool> restoreEnabled({
    UserDataScope scope = UserDataScope.defaultScope,
  }) async {
    if (scope.isDeleted) {
      _enabled = false;
      return false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final value =
          prefs.getBool(scope.preferenceKey(preferenceKey)) ??
          prefs.getBool(scope.preferenceKey(legacyPreferenceKey)) ??
          false;
      _enabled = value;
      final scopedKey = scope.preferenceKey(preferenceKey);
      if (!prefs.containsKey(scopedKey)) {
        await prefs.setBool(scopedKey, value);
      }
      return value;
    } catch (_) {
      _enabled = false;
      return false;
    }
  }

  /// 保存开关，失败时不影响播放器或页面操作。
  static Future<void> persistEnabled(
    bool value, {
    UserDataScope scope = UserDataScope.defaultScope,
  }) async {
    _enabled = value;
    if (scope.isDeleted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (scope.isDeleted) return;
      await prefs.setBool(scope.preferenceKey(preferenceKey), value);
    } catch (_) {}
  }

  /// 原生回调（由 main.dart 注入实现）
  static FutureOr<void> Function()? onPlayPauseTap;
  static FutureOr<void> Function()? onCapsuleTap;

  static void init() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPlayPauseTap':
          await _invokeCallback(onPlayPauseTap, '悬浮胶囊播放操作');
          break;
        case 'onCapsuleTap':
          await _invokeCallback(onCapsuleTap, '悬浮胶囊打开操作');
          break;
      }
      return null;
    });
  }

  static Future<void> _invokeCallback(
    FutureOr<void> Function()? callback,
    String label,
  ) async {
    if (callback == null) return;
    try {
      await callback();
    } catch (error, stackTrace) {
      // Native overlay callbacks can arrive while Flutter is rebuilding or
      // tearing down. A failed app action must not reject the platform call.
      debugPrint('$label失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  /// 是否有悬浮窗权限
  static Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳转系统设置开启悬浮窗权限
  static Future<bool> openPermissionSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openPermissionSettings') ??
          false;
    } catch (error) {
      debugPrint('打开悬浮窗权限设置失败: $error');
      return false;
    }
  }

  /// 显示车机迷你窗（已显示则更新）。
  static Future<bool> show({
    required String title,
    required String artist,
    String? coverUrl,
    required bool isPlaying,
  }) async {
    if (!_enabled) return false;
    try {
      return await _channel.invokeMethod<bool>('show', {
            'title': title,
            'artist': artist,
            'coverUrl': coverUrl,
            'isPlaying': isPlaying,
          }) ??
          false;
    } catch (error) {
      debugPrint('显示车机迷你窗失败: $error');
      return false;
    }
  }

  /// 更新迷你窗歌曲信息。
  static Future<void> update({
    required String title,
    required String artist,
    String? coverUrl,
    required bool isPlaying,
  }) async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod('update', {
        'title': title,
        'artist': artist,
        'coverUrl': coverUrl,
        'isPlaying': isPlaying,
      });
    } catch (_) {}
  }

  /// 仅更新播放/暂停状态。
  static Future<void> updatePlayState(bool isPlaying) async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod('updatePlayState', {'isPlaying': isPlaying});
    } catch (_) {}
  }

  /// 隐藏迷你窗。
  static Future<void> hide() async {
    try {
      await _channel.invokeMethod('hide');
    } catch (_) {}
  }
}
