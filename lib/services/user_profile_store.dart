import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Keeps the legacy SharedPreferences keys isolated per application account.
/// Existing services can continue using their current keys while account
/// switching archives and restores one user's complete personal profile.
class UserProfileStore {
  const UserProfileStore._();

  static const _activeUserKey = '_account_active_profile';
  static const _snapshotPrefix = '_account_profile_';

  static const personalKeys = <String>{
    'favorites',
    'favorite_playlists',
    'playback_history_v1',
    'search_history',
    'theme_mode',
    'font_scale',
    'netease_level',
    'common_level',
    'bilibili_audio_quality',
    'bilibili_video_quality',
    'playback_source_netease',
    'playback_source_qq',
    'playback_source_kugou',
    'bilibili_lyric_platform_order',
    'lyric_offset_step_ms',
    'video_player_mode',
    'lyric_font_size',
    'lyric_line_spacing',
    'lyric_font_family',
    'lyric_font_weight',
  };

  static Future<void> activate(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(_activeUserKey);
    if (previous == userId) return;

    if (previous != null && previous.isNotEmpty) {
      await _saveSnapshot(prefs, previous);
      await _clearPersonalKeys(prefs);
      await _restoreSnapshot(prefs, userId);
    } else {
      // The first account after upgrading claims the existing unscoped data.
      // This is the least surprising migration for current installations.
      await _saveSnapshot(prefs, userId);
    }
    await prefs.setString(_activeUserKey, userId);
  }

  static Future<void> checkpoint(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_activeUserKey) != userId) return;
    await _saveSnapshot(prefs, userId);
  }

  static Future<void> _saveSnapshot(
    SharedPreferences prefs,
    String userId,
  ) async {
    final values = <String, dynamic>{};
    for (final key in personalKeys) {
      final value = prefs.get(key);
      if (value is String || value is bool || value is int || value is double) {
        values[key] = value;
      } else if (value is List<String>) {
        values[key] = {'type': 'stringList', 'value': value};
      }
    }
    await prefs.setString('$_snapshotPrefix$userId', jsonEncode(values));
  }

  static Future<void> _restoreSnapshot(
    SharedPreferences prefs,
    String userId,
  ) async {
    final raw = prefs.getString('$_snapshotPrefix$userId');
    if (raw == null || raw.isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    for (final entry in decoded.entries) {
      final key = entry.key.toString();
      if (!personalKeys.contains(key)) continue;
      final value = entry.value;
      if (value is String) await prefs.setString(key, value);
      if (value is bool) await prefs.setBool(key, value);
      if (value is int) await prefs.setInt(key, value);
      if (value is double) await prefs.setDouble(key, value);
      if (value is Map && value['type'] == 'stringList') {
        final items = value['value'];
        if (items is List) {
          await prefs.setStringList(
            key,
            items.map((item) => item.toString()).toList(),
          );
        }
      }
    }
  }

  static Future<void> _clearPersonalKeys(SharedPreferences prefs) async {
    for (final key in personalKeys) {
      await prefs.remove(key);
    }
  }
}
