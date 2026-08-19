import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

/// A persisted playback entry. Playback URLs are deliberately excluded because
/// most platform URLs expire; clicking an entry resolves a fresh URL again.
class PlaybackHistoryEntry {
  final SongSearchResult song;
  final Duration position;
  final DateTime playedAt;

  const PlaybackHistoryEntry({
    required this.song,
    required this.position,
    required this.playedAt,
  });

  String get key => PlaybackHistoryService.keyForSong(song);

  Map<String, dynamic> toJson() => {
    'song': song.toJson(),
    'positionMs': position.inMilliseconds,
    'playedAtMs': playedAt.toUtc().millisecondsSinceEpoch,
  };

  factory PlaybackHistoryEntry.fromJson(Map<String, dynamic> json) {
    final rawSong = json['song'];
    final songMap = rawSong is Map
        ? Map<String, dynamic>.from(rawSong)
        : Map<String, dynamic>.from(json);
    final song = SongSearchResult.fromJson(songMap);
    if (song.id.trim().isEmpty || song.name.trim().isEmpty) {
      throw const FormatException('播放历史歌曲数据不完整');
    }
    final rawPosition = json['positionMs'] ?? json['position'];
    final positionMs = rawPosition is num
        ? rawPosition.toInt()
        : int.tryParse(rawPosition?.toString() ?? '') ?? 0;
    final rawPlayedAt = json['playedAtMs'] ?? json['playedAt'];
    final playedAtMs = rawPlayedAt is num
        ? rawPlayedAt.toInt()
        : int.tryParse(rawPlayedAt?.toString() ?? '') ?? 0;
    return PlaybackHistoryEntry(
      song: song,
      position: Duration(milliseconds: positionMs.clamp(0, 1 << 62).toInt()),
      playedAt: playedAtMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(
              playedAtMs,
              isUtc: true,
            ).toLocal()
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Local persistence for playback history.
class PlaybackHistoryService {
  static const preferenceKey = 'playback_history_v1';
  static const maxEntries = 100;

  const PlaybackHistoryService._();

  static String keyForSong(SongSearchResult song) {
    if (song.platform == MusicPlatform.bilibili) {
      return '${song.platform.code}:${song.id}:${song.bilibiliCid ?? 0}';
    }
    return '${song.platform.code}:${song.id}';
  }

  static Future<List<PlaybackHistoryEntry>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(preferenceKey);
      if (raw == null || raw.trim().isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final entries = <PlaybackHistoryEntry>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          entries.add(
            PlaybackHistoryEntry.fromJson(Map<String, dynamic>.from(item)),
          );
        } on FormatException {
          // Ignore one malformed entry instead of hiding the whole history.
        }
      }
      entries.sort((a, b) => b.playedAt.compareTo(a.playedAt));
      return entries.take(maxEntries).toList(growable: true);
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<PlaybackHistoryEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = entries.take(maxEntries).map((entry) => entry.toJson());
    await prefs.setString(preferenceKey, jsonEncode(normalized.toList()));
  }
}
