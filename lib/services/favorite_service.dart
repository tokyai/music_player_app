import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import 'user_data_scope.dart';

enum FavoriteImportMode { merge, replace }

class FavoriteImportResult {
  final int added;
  final int skipped;
  final int total;
  final int bilibiliAdded;
  final int bilibiliSkipped;
  final int bilibiliTotal;
  final int playlistsAdded;
  final int playlistsSkipped;
  final bool apiKeyPresent;
  final String? apiKey;

  const FavoriteImportResult({
    required this.added,
    required this.skipped,
    required this.total,
    this.bilibiliAdded = 0,
    this.bilibiliSkipped = 0,
    this.bilibiliTotal = 0,
    this.playlistsAdded = 0,
    this.playlistsSkipped = 0,
    this.apiKeyPresent = false,
    this.apiKey,
  });
}

class FavoriteAddResult {
  final int added;
  final int skipped;
  final int total;

  const FavoriteAddResult({
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
  static const int exportVersion = 4;

  final List<SongSearchResult> _favorites = [];
  final List<FavoritePlaylist> _favoritePlaylists = [];
  List<SongSearchResult>? _favoritesView;
  List<SongSearchResult>? _bilibiliFavoritesView;
  List<SongSearchResult>? _allFavoritesView;
  List<FavoritePlaylist>? _favoritePlaylistsView;
  bool _loaded = false;
  bool _disposed = false;

  final UserDataScope dataScope;

  FavoriteService({this.dataScope = UserDataScope.defaultScope});

  List<SongSearchResult> get favorites => _favoritesView ??= List.unmodifiable(
    _favorites.where((song) => song.platform != MusicPlatform.bilibili),
  );
  List<SongSearchResult> get bilibiliFavorites =>
      _bilibiliFavoritesView ??= List.unmodifiable(
        _favorites.where((song) => song.platform == MusicPlatform.bilibili),
      );
  List<SongSearchResult> get allFavorites =>
      _allFavoritesView ??= List.unmodifiable(_favorites);
  List<FavoritePlaylist> get favoritePlaylists =>
      _favoritePlaylistsView ??= List.unmodifiable(_favoritePlaylists);
  bool get loaded => _loaded;

  @override
  void notifyListeners() {
    if (_disposed) return;
    _favoritesView = null;
    _bilibiliFavoritesView = null;
    _allFavoritesView = null;
    _favoritePlaylistsView = null;
    super.notifyListeners();
  }

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
    if (_loaded || _disposed) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(dataScope.preferenceKey(_prefsKey));
      if (raw != null && raw.isNotEmpty) {
        final decoded = _decodeBackup(raw);
        _favorites
          ..clear()
          ..addAll(decoded.songs)
          ..addAll(decoded.bilibili);
      }
      final playlistRaw = prefs.getString(
        dataScope.preferenceKey(_playlistPrefsKey),
      );
      if (playlistRaw != null && playlistRaw.isNotEmpty) {
        _favoritePlaylists
          ..clear()
          ..addAll(_decodePlaylists(playlistRaw));
      }
    } catch (_) {
      _favorites.clear();
      _favoritePlaylists.clear();
    }
    if (_disposed) return;
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
    if (_disposed) return false;
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

  /// Adds songs without removing entries that are already favorites.
  /// The complete batch is deduplicated and persisted in one write.
  Future<FavoriteAddResult> addMany(Iterable<SongSearchResult> songs) async {
    await load();
    final batch = songs.toList(growable: false);
    if (_disposed || batch.isEmpty) {
      return FavoriteAddResult(
        added: 0,
        skipped: batch.length,
        total: batch.length,
      );
    }

    final existing = _favorites.map(keyOf).toSet();
    final additions = <SongSearchResult>[];
    var skipped = 0;
    for (final song in batch) {
      if (existing.add(keyOf(song))) {
        additions.add(song);
      } else {
        skipped++;
      }
    }
    if (additions.isNotEmpty) {
      _favorites.insertAll(0, additions);
      notifyListeners();
      await _save();
    }
    return FavoriteAddResult(
      added: additions.length,
      skipped: skipped,
      total: batch.length,
    );
  }

  /// 切换歌单收藏状态，返回操作后是否已收藏。
  Future<bool> togglePlaylist(
    MusicPlatform platform,
    PlaylistInfo playlist,
  ) async {
    await load();
    if (_disposed) return false;
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

  /// 将歌单保存到本地歌单库，已存在时更新元数据而不删除。
  ///
  /// 返回值表示是否新增了歌单。
  Future<bool> savePlaylist(
    MusicPlatform platform,
    PlaylistInfo playlist,
  ) async {
    await load();
    if (_disposed) return false;
    final key = playlistKey(platform, playlist.id);
    final index = _favoritePlaylists.indexWhere(
      (item) => playlistKeyOf(item) == key,
    );
    final saved = FavoritePlaylist(platform: platform, playlist: playlist);
    if (index >= 0) {
      _favoritePlaylists[index] = saved;
      notifyListeners();
      await _savePlaylists();
      return false;
    }

    _favoritePlaylists.insert(0, saved);
    notifyListeners();
    await _savePlaylists();
    return true;
  }

  Future<void> removePlaylist(MusicPlatform platform, String id) async {
    await load();
    if (_disposed) return;
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
    if (_disposed) return;
    await removeMany({songKey(platform, id)});
  }

  Future<int> removeMany(Set<String> keys) async {
    await load();
    if (_disposed) return 0;
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
    if (_disposed) return;
    if (_favorites.isEmpty) return;
    _favorites.clear();
    notifyListeners();
    await _save();
  }

  /// 用匹配到的新平台歌曲替换收藏项，未匹配项保持不变。
  Future<int> replaceMany(Map<String, SongSearchResult> replacements) async {
    await load();
    if (_disposed) return 0;
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

  /// 导出统一备份。API Key 由调用方传入，避免收藏服务直接依赖播放器。
  ///
  /// 版本 4 标记备份属于单个用户；版本 3 及更早版本还原到默认用户。
  /// 歌单曲目不写入备份，还原后会按平台重新获取最新曲目。
  Map<String, dynamic> exportData({String? apiKey}) {
    final songs = <Map<String, dynamic>>[];
    final bilibili = <Map<String, dynamic>>[];
    for (final song in _favorites) {
      final data = song.toJson();
      if (song.platform == MusicPlatform.bilibili) {
        bilibili.add(data);
      } else {
        songs.add(data);
      }
    }
    return {
      'format': exportFormat,
      'version': exportVersion,
      'userDataVersion': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'songs': songs,
      'bilibili': bilibili,
      'playlists': _favoritePlaylists
          .map((playlist) => playlist.toJson())
          .toList(),
      'apiKey': apiKey,
    };
  }

  String exportJson({String? apiKey}) {
    return const JsonEncoder.withIndent(
      '  ',
    ).convert(exportData(apiKey: apiKey));
  }

  static void validateDecodedBackup(dynamic decodedJson) {
    final decoded = _decodeBackupValue(decodedJson);
    if (decoded.skipped > 0 ||
        decoded.bilibiliSkipped > 0 ||
        decoded.playlistsSkipped > 0) {
      throw const FormatException('备份文件中的收藏数据不完整');
    }
  }

  /// 导入库仔音乐备份，也兼容旧版直接导出的歌曲数组。
  Future<FavoriteImportResult> importJson(
    String raw, {
    FavoriteImportMode mode = FavoriteImportMode.merge,
    bool importSongs = true,
    bool importBilibili = true,
    bool importPlaylists = true,
    bool importApiKey = true,
  }) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('备份文件不是有效的 JSON');
    }
    return importDecoded(
      decoded,
      mode: mode,
      importSongs: importSongs,
      importBilibili: importBilibili,
      importPlaylists: importPlaylists,
      importApiKey: importApiKey,
    );
  }

  /// Imports an already decoded backup document.
  ///
  /// BackupService uses this entry point so the same JSON tree can be shared
  /// with the AI/player sections instead of decoding a large backup again.
  Future<FavoriteImportResult> importDecoded(
    dynamic decodedJson, {
    FavoriteImportMode mode = FavoriteImportMode.merge,
    bool importSongs = true,
    bool importBilibili = true,
    bool importPlaylists = true,
    bool importApiKey = true,
  }) async {
    await load();
    if (_disposed) {
      return const FavoriteImportResult(added: 0, skipped: 0, total: 0);
    }
    final decoded = _decodeBackupValue(decodedJson);
    var skipped = importSongs ? decoded.skipped : 0;
    var added = 0;
    var bilibiliSkipped = importBilibili ? decoded.bilibiliSkipped : 0;
    var bilibiliAdded = 0;

    if (mode == FavoriteImportMode.replace) {
      if (importSongs) {
        _favorites.removeWhere(
          (song) => song.platform != MusicPlatform.bilibili,
        );
        _favorites.insertAll(0, decoded.songs);
        added = decoded.songs.length;
      }
      if (importBilibili && decoded.hasBilibili) {
        _favorites.removeWhere(
          (song) => song.platform == MusicPlatform.bilibili,
        );
        _favorites.addAll(decoded.bilibili);
        bilibiliAdded = decoded.bilibili.length;
      }
    } else {
      final existing = _favorites.map(keyOf).toSet();
      if (importSongs) {
        for (final song in decoded.songs) {
          if (existing.add(keyOf(song))) {
            _favorites.add(song);
            added++;
          } else {
            skipped++;
          }
        }
      }
      if (importBilibili) {
        for (final song in decoded.bilibili) {
          if (existing.add(keyOf(song))) {
            _favorites.add(song);
            bilibiliAdded++;
          } else {
            bilibiliSkipped++;
          }
        }
      }
    }

    var playlistsAdded = 0;
    if (importPlaylists && decoded.hasPlaylists) {
      if (mode == FavoriteImportMode.replace) {
        _favoritePlaylists
          ..clear()
          ..addAll(decoded.playlists);
        playlistsAdded = decoded.playlists.length;
      } else {
        final existing = _favoritePlaylists.map(playlistKeyOf).toSet();
        for (final playlist in decoded.playlists) {
          if (existing.add(playlistKeyOf(playlist))) {
            _favoritePlaylists.add(playlist);
            playlistsAdded++;
          } else {
            // 歌曲与歌单的重复计数分别统计，便于 UI 准确反馈。
            decoded.playlistsSkipped++;
          }
        }
      }
    }

    final favoritesSelected = importSongs || importBilibili;
    final playlistsSelected = importPlaylists && decoded.hasPlaylists;
    if (favoritesSelected || playlistsSelected) {
      notifyListeners();
      if (favoritesSelected) await _save();
      if (playlistsSelected) await _savePlaylists();
    }
    return FavoriteImportResult(
      added: added,
      skipped: skipped,
      total: importSongs ? decoded.songs.length + decoded.skipped : 0,
      bilibiliAdded: bilibiliAdded,
      bilibiliSkipped: bilibiliSkipped,
      bilibiliTotal: importBilibili
          ? decoded.bilibili.length + decoded.bilibiliSkipped
          : 0,
      playlistsAdded: playlistsAdded,
      playlistsSkipped: importPlaylists ? decoded.playlistsSkipped : 0,
      apiKeyPresent: importApiKey && decoded.apiKeyPresent,
      apiKey: importApiKey ? decoded.apiKey : null,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static _DecodedBackup _decodeBackup(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('备份文件不是有效的 JSON');
    }
    return _decodeBackupValue(decoded);
  }

  static _DecodedBackup _decodeBackupValue(dynamic decoded) {
    final List<dynamic> entries;
    List<dynamic> bilibiliEntries = const [];
    var hasPlaylists = false;
    var hasBilibili = false;
    List<dynamic> playlistEntries = const [];
    var apiKeyPresent = false;
    String? apiKey;
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
      if (decoded.containsKey('bilibili')) {
        final bilibili = decoded['bilibili'];
        if (bilibili is! List) {
          throw const FormatException('备份文件中的 B站收藏格式错误');
        }
        hasBilibili = true;
        bilibiliEntries = bilibili;
      }
      if (decoded.containsKey('playlists')) {
        final playlists = decoded['playlists'];
        if (playlists is! List) {
          throw const FormatException('备份文件中的歌单列表格式错误');
        }
        hasPlaylists = true;
        playlistEntries = playlists;
      }
      if (decoded.containsKey('apiKey')) {
        apiKeyPresent = true;
        final rawApiKey = decoded['apiKey'];
        if (rawApiKey != null && rawApiKey is! String) {
          throw const FormatException('备份文件中的 API Key 格式错误');
        }
        apiKey = rawApiKey as String? ?? '';
      }
    } else {
      throw const FormatException('备份文件格式不受支持');
    }

    final songs = <SongSearchResult>[];
    final bilibili = <SongSearchResult>[];
    final seen = <String>{};
    var skipped = 0;
    var bilibiliSkipped = 0;
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
        if (platform == MusicPlatform.bilibili) {
          hasBilibili = true;
          bilibiliSkipped++;
        } else {
          skipped++;
        }
        continue;
      }
      final song = SongSearchResult.fromJson(map);
      if (seen.add(keyOf(song))) {
        if (song.platform == MusicPlatform.bilibili) {
          bilibili.add(song);
          hasBilibili = true;
        } else {
          songs.add(song);
        }
      } else {
        if (song.platform == MusicPlatform.bilibili) {
          hasBilibili = true;
          bilibiliSkipped++;
        } else {
          skipped++;
        }
      }
    }
    for (final entry in bilibiliEntries) {
      if (entry is! Map) {
        bilibiliSkipped++;
        continue;
      }
      final map = Map<String, dynamic>.from(entry);
      final platform = _platformFromCode(map['platform']?.toString());
      final id = map['id']?.toString().trim() ?? '';
      final name = map['name']?.toString().trim() ?? '';
      if (platform != MusicPlatform.bilibili || id.isEmpty || name.isEmpty) {
        bilibiliSkipped++;
        continue;
      }
      final song = SongSearchResult.fromJson(map);
      if (seen.add(keyOf(song))) {
        bilibili.add(song);
      } else {
        bilibiliSkipped++;
      }
    }
    final decodedPlaylists = <FavoritePlaylist>[];
    final playlistSeen = <String>{};
    var playlistsSkipped = 0;
    for (final entry in playlistEntries) {
      if (entry is! Map) {
        playlistsSkipped++;
        continue;
      }
      try {
        final playlist = FavoritePlaylist.fromJson(
          Map<String, dynamic>.from(entry),
        );
        if (playlistSeen.add(playlistKeyOf(playlist))) {
          decodedPlaylists.add(playlist);
        } else {
          playlistsSkipped++;
        }
      } on FormatException {
        playlistsSkipped++;
      }
    }
    return _DecodedBackup(
      songs: songs,
      skipped: skipped,
      bilibili: bilibili,
      bilibiliSkipped: bilibiliSkipped,
      hasBilibili: hasBilibili,
      playlists: decodedPlaylists,
      playlistsSkipped: playlistsSkipped,
      hasPlaylists: hasPlaylists,
      apiKeyPresent: apiKeyPresent,
      apiKey: apiKey,
    );
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
    if (dataScope.isDeleted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (dataScope.isDeleted) return;
      await prefs.setString(
        dataScope.preferenceKey(_prefsKey),
        jsonEncode(_favorites.map((song) => song.toJson()).toList()),
      );
    } catch (error) {
      // Keep the in-memory change usable when the platform store is
      // temporarily unavailable; a persistence failure must not crash a tap.
      debugPrint('保存收藏失败: $error');
    }
  }

  Future<void> _savePlaylists() async {
    if (dataScope.isDeleted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (dataScope.isDeleted) return;
      await prefs.setString(
        dataScope.preferenceKey(_playlistPrefsKey),
        jsonEncode(
          _favoritePlaylists.map((playlist) => playlist.toJson()).toList(),
        ),
      );
    } catch (error) {
      debugPrint('保存收藏歌单失败: $error');
    }
  }
}

class _DecodedBackup {
  final List<SongSearchResult> songs;
  final int skipped;
  final List<SongSearchResult> bilibili;
  final int bilibiliSkipped;
  final bool hasBilibili;
  final List<FavoritePlaylist> playlists;
  int playlistsSkipped;
  final bool hasPlaylists;
  final bool apiKeyPresent;
  final String? apiKey;

  _DecodedBackup({
    required this.songs,
    required this.skipped,
    required this.bilibili,
    required this.bilibiliSkipped,
    required this.hasBilibili,
    required this.playlists,
    required this.playlistsSkipped,
    required this.hasPlaylists,
    required this.apiKeyPresent,
    required this.apiKey,
  });
}
