import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

/// The local playback session that should survive an app restart.
///
/// Only stable song metadata is persisted. Resolved URLs and request headers
/// are intentionally left out because platform playback links expire.
class PlaybackSessionSnapshot {
  final List<SongSearchResult> queue;
  final int currentIndex;
  final Duration position;
  final bool isPlaying;
  final String playMode;

  const PlaybackSessionSnapshot({
    required this.queue,
    required this.currentIndex,
    required this.position,
    required this.isPlaying,
    required this.playMode,
  });

  Map<String, dynamic> toJson() => {
    'version': 1,
    'queue': queue.map((song) => song.toJson()).toList(growable: false),
    'currentIndex': currentIndex,
    'positionMs': position.inMilliseconds,
    'isPlaying': isPlaying,
    'playMode': playMode,
  };

  factory PlaybackSessionSnapshot.fromJson(Map<String, dynamic> json) {
    final rawQueue = json['queue'];
    if (rawQueue is! List) {
      throw const FormatException('播放会话队列数据无效');
    }
    final queue = <SongSearchResult>[];
    for (final rawSong in rawQueue) {
      if (rawSong is! Map) continue;
      try {
        final song = SongSearchResult.fromJson(
          Map<String, dynamic>.from(rawSong),
        );
        if (song.id.trim().isEmpty || song.name.trim().isEmpty) continue;
        queue.add(song);
      } on FormatException {
        // One malformed queue item should not hide the remaining session.
      }
      if (queue.length >= PlaybackStateService.maxQueueEntries) break;
    }
    if (queue.isEmpty) {
      throw const FormatException('播放会话队列为空');
    }

    final rawIndex = json['currentIndex'];
    final parsedIndex = rawIndex is num
        ? rawIndex.toInt()
        : int.tryParse(rawIndex?.toString() ?? '') ?? 0;
    final currentIndex = parsedIndex.clamp(0, queue.length - 1).toInt();
    final rawPosition = json['positionMs'] ?? json['position'];
    final positionMs = rawPosition is num
        ? rawPosition.toInt()
        : int.tryParse(rawPosition?.toString() ?? '') ?? 0;
    final rawPlaying = json['isPlaying'] ?? json['playing'];
    final isPlaying = rawPlaying is bool
        ? rawPlaying
        : rawPlaying?.toString().toLowerCase() == 'true';
    final rawMode = json['playMode']?.toString();
    final playMode = PlaybackStateService.validPlayModes.contains(rawMode)
        ? rawMode!
        : 'sequence';
    return PlaybackSessionSnapshot(
      queue: queue,
      currentIndex: currentIndex,
      position: Duration(milliseconds: positionMs.clamp(0, 1 << 62).toInt()),
      isPlaying: isPlaying,
      playMode: playMode,
    );
  }
}

/// SharedPreferences storage for the last playback session.
class PlaybackStateService {
  static const preferenceKey = 'playback_state_v1';
  static const maxQueueEntries = 500;
  static const validPlayModes = <String>{'sequence', 'repeat', 'shuffle'};

  const PlaybackStateService._();

  static Future<PlaybackSessionSnapshot?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(preferenceKey);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return PlaybackSessionSnapshot.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(PlaybackSessionSnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(preferenceKey, jsonEncode(snapshot.toJson()));
  }
}
