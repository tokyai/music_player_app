import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import 'user_data_scope.dart';

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
    'song': song.compactForPlaybackPersistence().toJson(),
    'positionMs': position.inMilliseconds,
    'playedAtMs': playedAt.toUtc().millisecondsSinceEpoch,
  };

  factory PlaybackHistoryEntry.fromJson(Map<String, dynamic> json) {
    final rawSong = json['song'];
    final songMap = rawSong is Map
        ? Map<String, dynamic>.from(rawSong)
        : Map<String, dynamic>.from(json);
    final rawCid = songMap['bilibiliCid'];
    final cid = rawCid is num
        ? rawCid.toInt()
        : int.tryParse(rawCid?.toString() ?? '');
    final concreteBilibiliPage =
        songMap['platform']?.toString() == MusicPlatform.bilibili.code &&
        cid != null &&
        cid > 0;
    final song = SongSearchResult.fromJson(
      songMap,
      includeBilibiliPages: !concreteBilibiliPage,
    );
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

  static Future<List<PlaybackHistoryEntry>> load({
    UserDataScope scope = UserDataScope.defaultScope,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(scope.preferenceKey(preferenceKey));
      if (raw == null || raw.trim().isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      var needsCompaction = false;
      final entries = <PlaybackHistoryEntry>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          final rawEntry = Map<String, dynamic>.from(item);
          final rawSong = rawEntry['song'];
          final songMap = rawSong is Map
              ? Map<String, dynamic>.from(rawSong)
              : rawEntry;
          final pages = songMap['bilibiliPages'];
          final rawCid = songMap['bilibiliCid'];
          final cid = rawCid is num
              ? rawCid.toInt()
              : int.tryParse(rawCid?.toString() ?? '');
          if (songMap['platform']?.toString() == MusicPlatform.bilibili.code &&
              cid != null &&
              cid > 0 &&
              pages is List &&
              pages.isNotEmpty) {
            needsCompaction = true;
          }
          entries.add(PlaybackHistoryEntry.fromJson(rawEntry));
        } on FormatException {
          // Ignore one malformed entry instead of hiding the whole history.
        }
      }
      entries.sort((a, b) => b.playedAt.compareTo(a.playedAt));
      final normalized = entries.take(maxEntries).toList(growable: true);
      if (needsCompaction && !scope.isDeleted) {
        try {
          await prefs.setString(
            scope.preferenceKey(preferenceKey),
            jsonEncode(
              normalized.map((entry) => entry.toJson()).toList(growable: false),
            ),
          );
        } catch (_) {
          // Keep the successfully restored history available in memory.
        }
      }
      return normalized;
    } catch (_) {
      return [];
    }
  }

  static Map<String, dynamic> toBackupJson(
    Iterable<PlaybackHistoryEntry> entries,
  ) => {
    'version': 1,
    'items': entries
        .take(maxEntries)
        .map((entry) => entry.toJson())
        .toList(growable: false),
  };

  static List<PlaybackHistoryEntry> decodeBackupJson(
    Map<String, dynamic> json,
  ) {
    final rawItems = json['items'];
    if (rawItems is! List || rawItems.length > maxEntries) {
      throw const FormatException('备份文件中的播放历史格式错误');
    }
    final entries = <PlaybackHistoryEntry>[];
    final seen = <String>{};
    for (final raw in rawItems) {
      if (raw is! Map) {
        throw const FormatException('备份文件中的播放历史格式错误');
      }
      final entry = PlaybackHistoryEntry.fromJson(
        Map<String, dynamic>.from(raw),
      );
      if (seen.add(entry.key)) entries.add(entry);
    }
    entries.sort((a, b) => b.playedAt.compareTo(a.playedAt));
    return entries;
  }

  static Future<void> save(
    List<PlaybackHistoryEntry> entries, {
    UserDataScope scope = UserDataScope.defaultScope,
  }) async {
    if (scope.isDeleted) return;
    final prefs = await SharedPreferences.getInstance();
    if (scope.isDeleted) return;
    final normalized = entries.take(maxEntries).map((entry) => entry.toJson());
    await prefs.setString(
      scope.preferenceKey(preferenceKey),
      jsonEncode(normalized.toList()),
    );
  }
}
