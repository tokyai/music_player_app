import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

enum FavoriteImportMode { merge, replace }

class FavoriteImportResult {
  final int added;
  final int skipped;
  final int total;

  const FavoriteImportResult({
    required this.added,
    required this.skipped,
    required this.total,
  });
}

/// 收藏管理（本地持久化，SharedPreferences 存 JSON）。
class FavoriteService extends ChangeNotifier {
  static const String _prefsKey = 'favorites';
  static const String _playlistPrefsKey = 'favorite_playlists';
  static const String exportFormat = 'kuzai_music_favorites';
  static const int exportVersion = 1;

  final List<SongSearchResult> _favorites = [];
  final List<FavoritePlaylist> _favoritePlaylists = [];
  bool _loaded = false;

  List<SongSearchResult> get favorites => List.unmodifiable(_favorites);
  List<FavoritePlaylist> get favoritePlaylists =>
      List.unmodifiable(_favoritePlaylists);
  bool get loaded => _loaded;

  static String songKey(MusicPlatform platform, String id) {
    return '${platform.code}\u001f$id';
  }

  static String keyOf(SongSearchResult song) {
    return songKey(song.platform, song.id);
  }

  static String playlistKey(MusicPlatform platform, String id) {
    return '${platform.code}\u001f$id';
  }

  static String playlistKeyOf(FavoritePlaylist playlist) {
    return playlistKey(playlist.platform, playlist.id);
  }

  /// 启动时加载一次，继续兼容上游使用的纯歌曲数组格式。
  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = _decodeSongs(raw);
        _favorites
          ..clear()
          ..addAll(decoded.songs);
      }
      final playlistRaw = prefs.getString(_playlistPrefsKey);
      if (playlistRaw != null && playlistRaw.isNotEmpty) {
        _favoritePlaylists
          ..clear()
          ..addAll(_decodePlaylists(playlistRaw));
      }
    } catch (_) {
      _favorites.clear();
      _favoritePlaylists.clear();
    }
    _loaded = true;
    notifyListeners();
  }

  bool isFavorite(MusicPlatform platform, String id) {
    final key = songKey(platform, id);
    return _favorites.any((song) => keyOf(song) == key);
  }

  bool isPlaylistFavorite(MusicPlatform platform, String id) {
    final key = playlistKey(platform, id);
    return _favoritePlaylists.any((playlist) => playlistKeyOf(playlist) == key);
  }

  /// 切换收藏状态，返回操作后是否已收藏。
  Future<bool> toggle(SongSearchResult song) async {
    await load();
    final key = keyOf(song);
    final index = _favorites.indexWhere((item) => keyOf(item) == key);
    if (index >= 0) {
      _favorites.removeAt(index);
      notifyListeners();
      await _save();
      return false;
    }

    _favorites.insert(0, song);
    notifyListeners();
    await _save();
    return true;
  }

  /// 切换歌单收藏状态，返回操作后是否已收藏。
  Future<bool> togglePlaylist(
    MusicPlatform platform,
    PlaylistInfo playlist,
  ) async {
    await load();
    final key = playlistKey(platform, playlist.id);
    final index = _favoritePlaylists.indexWhere(
      (item) => playlistKeyOf(item) == key,
    );
    if (index >= 0) {
      _favoritePlaylists.removeAt(index);
      notifyListeners();
      await _savePlaylists();
      return false;
    }

    _favoritePlaylists.insert(
      0,
      FavoritePlaylist(platform: platform, playlist: playlist),
    );
    notifyListeners();
    await _savePlaylists();
    return true;
  }

  Future<void> removePlaylist(MusicPlatform platform, String id) async {
    await load();
    final key = playlistKey(platform, id);
    final before = _favoritePlaylists.length;
    _favoritePlaylists.removeWhere(
      (playlist) => playlistKeyOf(playlist) == key,
    );
    if (_favoritePlaylists.length != before) {
      notifyListeners();
      await _savePlaylists();
    }
  }

  Future<void> remove(MusicPlatform platform, String id) async {
    await removeMany({songKey(platform, id)});
  }

  Future<int> removeMany(Set<String> keys) async {
    await load();
    final before = _favorites.length;
    _favorites.removeWhere((song) => keys.contains(keyOf(song)));
    final removed = before - _favorites.length;
    if (removed > 0) {
      notifyListeners();
      await _save();
    }
    return removed;
  }

  Future<void> clear() async {
    await load();
    if (_favorites.isEmpty) return;
    _favorites.clear();
    notifyListeners();
    await _save();
  }

  /// 用匹配到的新平台歌曲替换收藏项，未匹配项保持不变。
  Future<int> replaceMany(Map<String, SongSearchResult> replacements) async {
    await load();
    if (replacements.isEmpty) return 0;

    final replacementKeys = replacements.keys.toSet();
    final reservedKeys = _favorites
        .where((song) => !replacementKeys.contains(keyOf(song)))
        .map(keyOf)
        .toSet();
    final seen = <String>{};
    final updated = <SongSearchResult>[];
    var replaced = 0;

    for (final original in _favorites) {
      final originalKey = keyOf(original);
      final replacement = replacements[originalKey];
      final replacementKey = replacement == null ? null : keyOf(replacement);
      final canReplace =
          replacement != null &&
          replacementKey != originalKey &&
          !reservedKeys.contains(replacementKey) &&
          !seen.contains(replacementKey);
      final chosen = canReplace ? replacement : original;
      final chosenKey = keyOf(chosen);
      if (seen.add(chosenKey)) {
        updated.add(chosen);
        if (canReplace) replaced++;
      }
    }

    if (replaced > 0) {
      _favorites
        ..clear()
        ..addAll(updated);
      notifyListeners();
      await _save();
    }
    return replaced;
  }

  String exportJson() {
    return const JsonEncoder.withIndent('  ').convert({
      'format': exportFormat,
      'version': exportVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'songs': _favorites.map((song) => song.toJson()).toList(),
    });
  }

  /// 导入库仔音乐备份，也兼容旧版直接导出的歌曲数组。
  Future<FavoriteImportResult> importJson(
    String raw, {
    FavoriteImportMode mode = FavoriteImportMode.merge,
  }) async {
    await load();
    final decoded = _decodeSongs(raw);
    var skipped = decoded.skipped;
    var added = 0;

    if (mode == FavoriteImportMode.replace) {
      _favorites
        ..clear()
        ..addAll(decoded.songs);
      added = decoded.songs.length;
    } else {
      final existing = _favorites.map(keyOf).toSet();
      for (final song in decoded.songs) {
        if (existing.add(keyOf(song))) {
          _favorites.add(song);
          added++;
        } else {
          skipped++;
        }
      }
    }

    notifyListeners();
    await _save();
    return FavoriteImportResult(
      added: added,
      skipped: skipped,
      total: decoded.songs.length + decoded.skipped,
    );
  }

  static ({List<SongSearchResult> songs, int skipped}) _decodeSongs(
    String raw,
  ) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('备份文件不是有效的 JSON');
    }

    final List<dynamic> entries;
    if (decoded is List) {
      entries = decoded;
    } else if (decoded is Map) {
      final format = decoded['format'];
      if (format != null && format != exportFormat) {
        throw const FormatException('不是库仔音乐收藏备份');
      }
      final songs = decoded['songs'];
      if (songs is! List) {
        throw const FormatException('备份文件缺少歌曲列表');
      }
      entries = songs;
    } else {
      throw const FormatException('备份文件格式不受支持');
    }

    final songs = <SongSearchResult>[];
    final seen = <String>{};
    var skipped = 0;
    for (final entry in entries) {
      if (entry is! Map) {
        skipped++;
        continue;
      }
      final map = Map<String, dynamic>.from(entry);
      final platformCode = map['platform']?.toString();
      final platform = _platformFromCode(platformCode);
      final id = map['id']?.toString().trim() ?? '';
      final name = map['name']?.toString().trim() ?? '';
      if (platform == null || id.isEmpty || name.isEmpty) {
        skipped++;
        continue;
      }
      final song = SongSearchResult.fromJson(map);
      if (seen.add(keyOf(song))) {
        songs.add(song);
      } else {
        skipped++;
      }
    }
    return (songs: songs, skipped: skipped);
  }

  static MusicPlatform? _platformFromCode(String? code) {
    for (final platform in MusicPlatform.values) {
      if (platform.code == code) return platform;
    }
    return null;
  }

  static List<FavoritePlaylist> _decodePlaylists(String raw) {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final playlists = <FavoritePlaylist>[];
    final seen = <String>{};
    for (final entry in decoded) {
      if (entry is! Map) continue;
      try {
        final playlist = FavoritePlaylist.fromJson(
          Map<String, dynamic>.from(entry),
        );
        if (seen.add(playlistKeyOf(playlist))) playlists.add(playlist);
      } on FormatException {
        continue;
      }
    }
    return playlists;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_favorites.map((song) => song.toJson()).toList()),
    );
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _playlistPrefsKey,
      jsonEncode(
        _favoritePlaylists.map((playlist) => playlist.toJson()).toList(),
      ),
    );
  }
}
