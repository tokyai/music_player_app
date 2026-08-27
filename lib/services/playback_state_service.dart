import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import 'user_data_scope.dart';

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

  Map<String, dynamic> toJson() {
    final concreteBilibiliCounts = _concreteBilibiliCounts(queue);
    return {
      'version': 1,
      'queue': queue
          .map(
            (song) => _isExpandedBilibiliItem(song, concreteBilibiliCounts)
                ? song.compactForPlaybackPersistence().toJson()
                : song.toJson(),
          )
          .toList(growable: false),
      'currentIndex': currentIndex,
      'positionMs': position.inMilliseconds,
      'isPlaying': isPlaying,
      'playMode': playMode,
    };
  }

  factory PlaybackSessionSnapshot.fromJson(Map<String, dynamic> json) {
    final rawQueue = json['queue'];
    if (rawQueue is! List) {
      throw const FormatException('播放会话队列数据无效');
    }
    final concreteBilibiliCounts = _concreteBilibiliJsonCounts(rawQueue);
    final queue = <SongSearchResult>[];
    for (final rawSong in rawQueue) {
      if (rawSong is! Map) continue;
      try {
        final songJson = Map<String, dynamic>.from(rawSong);
        final song = SongSearchResult.fromJson(
          songJson,
          includeBilibiliPages: !_isExpandedBilibiliJsonItem(
            songJson,
            concreteBilibiliCounts,
          ),
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

Map<String, int> _concreteBilibiliCounts(Iterable<SongSearchResult> queue) {
  final counts = <String, int>{};
  for (final song in queue) {
    if (song.platform != MusicPlatform.bilibili ||
        song.id.isEmpty ||
        song.bilibiliCid == null ||
        song.bilibiliCid! <= 0) {
      continue;
    }
    counts[song.id] = (counts[song.id] ?? 0) + 1;
  }
  return counts;
}

bool _isExpandedBilibiliItem(SongSearchResult song, Map<String, int> counts) {
  return song.platform == MusicPlatform.bilibili &&
      song.bilibiliCid != null &&
      song.bilibiliCid! > 0 &&
      (counts[song.id] ?? 0) > 1;
}

Map<String, int> _concreteBilibiliJsonCounts(Iterable<dynamic> queue) {
  final counts = <String, int>{};
  for (final rawSong in queue) {
    if (rawSong is! Map) continue;
    final song = Map<String, dynamic>.from(rawSong);
    if (!_hasConcreteBilibiliJsonPage(song)) continue;
    final id = song['id']?.toString() ?? '';
    if (id.isEmpty) continue;
    counts[id] = (counts[id] ?? 0) + 1;
  }
  return counts;
}

bool _isExpandedBilibiliJsonItem(
  Map<String, dynamic> song,
  Map<String, int> counts,
) {
  if (!_hasConcreteBilibiliJsonPage(song)) return false;
  return (counts[song['id']?.toString() ?? ''] ?? 0) > 1;
}

bool _hasConcreteBilibiliJsonPage(Map<String, dynamic> song) {
  if (song['platform']?.toString() != MusicPlatform.bilibili.code) return false;
  final rawCid = song['bilibiliCid'];
  final cid = rawCid is num
      ? rawCid.toInt()
      : int.tryParse(rawCid?.toString() ?? '');
  return cid != null && cid > 0;
}

/// SharedPreferences storage for the last playback session.
class PlaybackStateService {
  static const preferenceKey = 'playback_state_v1';
  static const maxQueueEntries = 500;
  static const validPlayModes = <String>{'sequence', 'repeat', 'shuffle'};

  const PlaybackStateService._();

  static Future<PlaybackSessionSnapshot?> load({
    UserDataScope scope = UserDataScope.defaultScope,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(scope.preferenceKey(preferenceKey));
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final snapshotJson = Map<String, dynamic>.from(decoded);
      final needsCompaction = _containsExpandedBilibiliPageLists(snapshotJson);
      final snapshot = PlaybackSessionSnapshot.fromJson(snapshotJson);
      if (needsCompaction && !scope.isDeleted) {
        try {
          await prefs.setString(
            scope.preferenceKey(preferenceKey),
            jsonEncode(snapshot.toJson()),
          );
        } catch (_) {
          // The valid in-memory session is still usable. A later normal
          // persistence attempt can retry replacing the legacy payload.
        }
      }
      return snapshot;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(
    PlaybackSessionSnapshot snapshot, {
    UserDataScope scope = UserDataScope.defaultScope,
  }) async {
    if (scope.isDeleted) return;
    final prefs = await SharedPreferences.getInstance();
    if (scope.isDeleted) return;
    await prefs.setString(
      scope.preferenceKey(preferenceKey),
      jsonEncode(snapshot.toJson()),
    );
  }
}

bool _containsExpandedBilibiliPageLists(Map<String, dynamic> snapshot) {
  final rawQueue = snapshot['queue'];
  if (rawQueue is! List) return false;
  final counts = _concreteBilibiliJsonCounts(rawQueue);
  for (final rawSong in rawQueue) {
    if (rawSong is! Map) continue;
    final song = Map<String, dynamic>.from(rawSong);
    if (!_isExpandedBilibiliJsonItem(song, counts)) continue;
    final pages = song['bilibiliPages'];
    if (pages is List && pages.isNotEmpty) return true;
  }
  return false;
}
