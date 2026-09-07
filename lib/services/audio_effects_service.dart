import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/audio_effects.dart';

/// One owner per music player; the native plugin is owned by the Flutter engine.
class AudioEffectsService extends ChangeNotifier {
  static const channel = MethodChannel('music_player/audio_effects');
  static int _nextOwner = DateTime.now().microsecondsSinceEpoch;
  final int _owner = ++_nextOwner;
  late final Future<void> ready = _load();
  AudioEffectsSettings _settings = const AudioEffectsSettings();
  int? _sessionId;
  bool _disposed = false;
  bool _dirty = false;
  bool _saving = false;
  bool _nativeOwned = false;
  Completer<void>? _saveCompletion;
  Future<void>? _applying;
  Future<void>? _closing;
  List<String> _failures = const [];

  AudioEffectsSettings get settings => _settings;
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get saving => _saving;
  bool get applying => _applying != null;
  List<String> get failures => _failures;
  bool get hasSession => _sessionId != null;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;
      final raw = prefs.getString(AudioEffectsSettings.preferenceKey);
      if (raw != null) {
        if (raw.length > 4096) throw const FormatException('音效设置过大');
        final json = jsonDecode(raw);
        if (json is! Map<String, dynamic>) {
          throw const FormatException('音效设置格式无效');
        }
        _settings = AudioEffectsSettings.fromJson(json);
      }
    } catch (error) {
      debugPrint('读取音效设置失败，使用原声: $error');
    }
    if (_disposed) return;
    notifyListeners();
    unawaited(_scheduleApply());
  }

  Future<void> setSettings(AudioEffectsSettings value) async {
    // Validate and freeze even caller-created lists before storing anything.
    final next = AudioEffectsSettings.fromJson(value.toJson());
    await ready;
    if (_disposed) return;
    if (_saving) throw StateError('音效正在保存');
    _saving = true;
    final completion = _saveCompletion = Completer<void>();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;
      final previous = prefs.getString(AudioEffectsSettings.preferenceKey);
      try {
        if (!await prefs.setString(
          AudioEffectsSettings.preferenceKey,
          jsonEncode(next.toJson()),
        )) {
          throw StateError('保存音效失败');
        }
      } catch (error) {
        // SharedPreferences updates its local cache before the platform write.
        try {
          if (previous == null) {
            await prefs.remove(AudioEffectsSettings.preferenceKey);
          } else {
            await prefs.setString(AudioEffectsSettings.preferenceKey, previous);
          }
        } catch (rollbackError) {
          debugPrint('回退音效存储失败: $rollbackError');
        }
        rethrow;
      }
      if (_disposed) return;
      _settings = next;
      unawaited(_scheduleApply());
    } finally {
      _saving = false;
      completion.complete();
      _saveCompletion = null;
      if (!_disposed) notifyListeners();
    }
  }

  void setSessionId(int? id) {
    if (_disposed) return;
    final next = id != null && id > 0 ? id : null;
    if (_sessionId == next) return;
    _sessionId = next;
    unawaited(_scheduleApply());
  }

  Future<void> _scheduleApply() {
    if (_disposed || !supported || (_sessionId == null && !_nativeOwned)) {
      return Future.value();
    }
    _dirty = true;
    // Keep only the latest config/session while a platform call is in flight.
    return _applying ??= _drain().whenComplete(() {
      _applying = null;
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _drain() async {
    while (_dirty && !_disposed) {
      _dirty = false;
      final session = _sessionId;
      final settings = _settings;
      try {
        _nativeOwned = true;
        final result = await channel
            .invokeMapMethod<String, dynamic>('apply', {
              'owner': _owner,
              'sessionId': session,
              ...settings.toJson(),
            })
            .timeout(const Duration(seconds: 3));
        if (_disposed || _dirty) continue;
        final failures = result?['failures'];
        _failures = failures is List
            ? List.unmodifiable(failures.whereType<String>().take(4))
            : const ['音效引擎不可用'];
      } on MissingPluginException {
        if (!_disposed) _failures = const ['当前平台没有音效引擎'];
      } catch (error) {
        debugPrint('应用音效失败: $error');
        if (!_disposed) _failures = const ['设备无法应用音效'];
      }
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    dispose();
    await _saveCompletion?.future;
    await _applying;
    if (!supported || !_nativeOwned) return;
    try {
      await channel
          .invokeMethod<void>('release', {'owner': _owner})
          .timeout(const Duration(seconds: 3));
    } on MissingPluginException {
      // No native resources exist on test/unsupported targets.
    } catch (error) {
      debugPrint('释放音效失败: $error');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _dirty = false;
    super.dispose();
  }
}
