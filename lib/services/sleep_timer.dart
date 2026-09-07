import 'dart:async';

import 'package:flutter/foundation.dart';

enum SleepTimerMode { off, duration, endOfTrack }

class SleepTimer extends ChangeNotifier {
  SleepTimer({
    required Future<void> Function() onElapsed,
    DateTime Function()? now,
  }) : _onElapsed = onElapsed,
       _now = now ?? DateTime.now;

  final Future<void> Function() _onElapsed;
  final DateTime Function() _now;
  Timer? _ticker;
  DateTime? _deadline;
  SleepTimerMode _mode = SleepTimerMode.off;
  bool _disposed = false;
  bool _firing = false;
  String? _error;

  SleepTimerMode get mode => _mode;
  bool get active => _mode != SleepTimerMode.off;
  String? get error => _error;
  Duration get remaining {
    final deadline = _deadline;
    if (deadline == null) return Duration.zero;
    final value = deadline.difference(_now());
    return value.isNegative ? Duration.zero : value;
  }

  void start(Duration duration) {
    if (_disposed || _firing) return;
    if (duration <= Duration.zero || duration > const Duration(hours: 12)) {
      throw ArgumentError.value(duration, 'duration');
    }
    _ticker?.cancel();
    _error = null;
    _mode = SleepTimerMode.duration;
    _deadline = _now().add(duration);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) return;
      if (remaining == Duration.zero) {
        unawaited(_fire());
      } else {
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void stopAfterTrack() {
    if (_disposed || _firing) return;
    _ticker?.cancel();
    _ticker = null;
    _deadline = null;
    _mode = SleepTimerMode.endOfTrack;
    _error = null;
    notifyListeners();
  }

  /// Called before automatic queue advancement, including repeat-one mode.
  bool consumeTrackEnd() {
    if (_disposed || _mode != SleepTimerMode.endOfTrack) return false;
    unawaited(_fire());
    return true;
  }

  void cancel() {
    if (_disposed) return;
    _ticker?.cancel();
    _ticker = null;
    _deadline = null;
    _mode = SleepTimerMode.off;
    _error = null;
    notifyListeners();
  }

  Future<void> _fire() async {
    if (_disposed || !active || _firing) return;
    _firing = true;
    cancel();
    try {
      await _onElapsed();
    } catch (error) {
      debugPrint('睡眠定时停止播放失败: $error');
      if (!_disposed) _error = '定时停止失败，请手动暂停';
    } finally {
      _firing = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }
}

String formatSleepRemaining(Duration remaining) {
  final seconds = (remaining.inMilliseconds / 1000).ceil();
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
