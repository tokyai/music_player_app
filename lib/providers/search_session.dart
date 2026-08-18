import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import '../services/api_service.dart';

enum SearchSubject { general, title, artist, album }

/// 应用级搜索会话。搜索页面即使因路由或横竖屏切换重建，也能恢复完整结果。
class SearchSession extends ChangeNotifier {
  static const String _historyPrefsKey = 'search_history';
  static const int _maxHistoryItems = 20;

  final Map<MusicPlatform, List<SongSearchResult>> _results = {
    MusicPlatform.qq: [],
    MusicPlatform.netease: [],
    MusicPlatform.kugou: [],
    MusicPlatform.bilibili: [],
  };
  final Map<MusicPlatform, List<PlaylistInfo>> _playlistResults = {
    MusicPlatform.qq: [],
    MusicPlatform.netease: [],
    MusicPlatform.kugou: [],
    MusicPlatform.bilibili: [],
  };
  final Map<MusicPlatform, String?> _errors = {
    MusicPlatform.qq: null,
    MusicPlatform.netease: null,
    MusicPlatform.kugou: null,
    MusicPlatform.bilibili: null,
  };
  final Map<MusicPlatform, bool> _loading = {
    MusicPlatform.qq: false,
    MusicPlatform.netease: false,
    MusicPlatform.kugou: false,
    MusicPlatform.bilibili: false,
  };
  final Set<MusicPlatform> _loadedPlatforms = {};
  final List<String> _searchHistory = [];

  String _keyword = '';
  bool _playlistMode = false;
  SearchSubject _subject = SearchSubject.general;
  int _selectedPlatformIndex = 0;
  int _requestId = 0;
  int _navigationId = 0;
  bool _disposed = false;
  late final Future<void> _historyReady;

  SearchSession() {
    _historyReady = _loadSearchHistory();
  }

  String get keyword => _keyword;
  bool get playlistMode => _playlistMode;
  int get selectedPlatformIndex => _selectedPlatformIndex;
  int get navigationId => _navigationId;
  List<String> get searchHistory => List.unmodifiable(_searchHistory);

  List<SongSearchResult> songsFor(MusicPlatform platform) =>
      _results[platform] ?? const [];

  List<PlaylistInfo> playlistsFor(MusicPlatform platform) =>
      _playlistResults[platform] ?? const [];

  String? errorFor(MusicPlatform platform) => _errors[platform];

  bool isLoading(MusicPlatform platform) => _loading[platform] ?? false;

  Future<void> search(
    ApiService api,
    String keyword, {
    SearchSubject subject = SearchSubject.general,
    MusicPlatform? preferredPlatform,
    bool forceSongMode = false,
    bool navigate = false,
  }) async {
    final normalizedKeyword = keyword.trim();
    if (normalizedKeyword.isEmpty) return;

    unawaited(_rememberSearch(normalizedKeyword));
    _requestId++;
    if (navigate) _navigationId++;
    _keyword = normalizedKeyword;
    _subject = subject;
    if (forceSongMode || subject != SearchSubject.general) {
      _playlistMode = false;
    }
    if (preferredPlatform != null) {
      _selectedPlatformIndex = musicPlatformDisplayOrder.indexOf(
        preferredPlatform,
      );
    }
    _resetResults();
    _notify();

    await ensurePlatformLoaded(
      api,
      musicPlatformDisplayOrder[_selectedPlatformIndex],
    );
  }

  Future<void> openScopedSearch(
    ApiService api, {
    required String keyword,
    required SearchSubject subject,
    required MusicPlatform preferredPlatform,
  }) {
    return search(
      api,
      keyword,
      subject: subject,
      preferredPlatform: preferredPlatform,
      forceSongMode: true,
      navigate: true,
    );
  }

  Future<void> selectPlatform(ApiService api, int index) async {
    if (index < 0 || index >= musicPlatformDisplayOrder.length) return;
    if (_selectedPlatformIndex != index) {
      _selectedPlatformIndex = index;
      _notify();
    }
    await ensurePlatformLoaded(api, musicPlatformDisplayOrder[index]);
  }

  Future<void> setPlaylistMode(ApiService api, bool playlistMode) async {
    if (_playlistMode == playlistMode) return;
    _requestId++;
    _playlistMode = playlistMode;
    _subject = SearchSubject.general;
    if (_keyword.isEmpty) {
      _notify();
      return;
    }
    _loadedPlatforms.clear();
    for (final platform in musicPlatformDisplayOrder) {
      _loading[platform] = false;
      _errors[platform] = null;
      final hasCachedTarget = playlistMode
          ? (_playlistResults[platform]?.isNotEmpty ?? false)
          : (_results[platform]?.isNotEmpty ?? false);
      if (hasCachedTarget) _loadedPlatforms.add(platform);
    }
    _notify();
    await ensurePlatformLoaded(
      api,
      musicPlatformDisplayOrder[_selectedPlatformIndex],
    );
  }

  Future<void> ensurePlatformLoaded(
    ApiService api,
    MusicPlatform platform,
  ) async {
    if (_keyword.isEmpty ||
        _loadedPlatforms.contains(platform) ||
        (_loading[platform] ?? false)) {
      return;
    }

    final keyword = _keyword;
    final requestId = _requestId;
    final playlistMode = _playlistMode;
    final subject = _subject;
    _loading[platform] = true;
    _errors[platform] = null;
    _notify();

    if (playlistMode) {
      await _loadPlaylists(
        api,
        platform,
        keyword,
        requestId,
        playlistMode,
        subject,
      );
    } else if (subject == SearchSubject.general) {
      await Future.wait([
        _loadSongs(api, platform, keyword, requestId, playlistMode, subject),
        _loadPlaylists(
          api,
          platform,
          keyword,
          requestId,
          playlistMode,
          subject,
        ),
      ]);
    } else {
      await _loadSongs(
        api,
        platform,
        keyword,
        requestId,
        playlistMode,
        subject,
      );
    }

    if (_isCurrentSearch(requestId, playlistMode, subject)) {
      _loading[platform] = false;
      _loadedPlatforms.add(platform);
      _notify();
    }
  }

  Future<void> retry(ApiService api, MusicPlatform platform) async {
    _loadedPlatforms.remove(platform);
    await ensurePlatformLoaded(api, platform);
  }

  Future<void> removeSearchHistory(String keyword) async {
    await _historyReady;
    if (_disposed) return;
    final normalized = _normalize(keyword);
    final oldLength = _searchHistory.length;
    _searchHistory.removeWhere((item) => _normalize(item) == normalized);
    if (_searchHistory.length == oldLength) return;
    _notify();
    await _saveSearchHistory();
  }

  void clear() {
    _requestId++;
    _keyword = '';
    _subject = SearchSubject.general;
    _resetResults();
    _notify();
  }

  Future<void> _loadSongs(
    ApiService api,
    MusicPlatform platform,
    String keyword,
    int requestId,
    bool playlistMode,
    SearchSubject subject,
  ) async {
    try {
      final songs = await api.search(platform, keyword);
      if (_isCurrentSearch(requestId, playlistMode, subject)) {
        _results[platform] = _filterScopedSongs(songs, subject, keyword);
        _notify();
      }
    } catch (error) {
      debugPrint('搜索 ${platform.label} 歌曲失败: $error');
      if (_isCurrentSearch(requestId, playlistMode, subject)) {
        _errors[platform] = '搜索失败，请稍后重试';
        _notify();
      }
    }
  }

  Future<void> _loadPlaylists(
    ApiService api,
    MusicPlatform platform,
    String keyword,
    int requestId,
    bool playlistMode,
    SearchSubject subject,
  ) async {
    try {
      final List<PlaylistInfo> playlists;
      switch (platform) {
        case MusicPlatform.netease:
          playlists = await api.neteaseSearchPlaylists(keyword);
        case MusicPlatform.qq:
          playlists = await api.qqSearchPlaylists(keyword);
        case MusicPlatform.kugou:
          playlists = await api.kugouSearchPlaylists(keyword);
        case MusicPlatform.bilibili:
          playlists = const [];
      }
      if (_isCurrentSearch(requestId, playlistMode, subject)) {
        _playlistResults[platform] = playlists;
        _notify();
      }
    } catch (error) {
      debugPrint('搜索 ${platform.label} 歌单失败: $error');
      if (_isCurrentSearch(requestId, playlistMode, subject)) {
        _errors[platform] = '搜索失败，请稍后重试';
        _notify();
      }
    }
  }

  List<SongSearchResult> _filterScopedSongs(
    List<SongSearchResult> songs,
    SearchSubject subject,
    String keyword,
  ) {
    if (subject == SearchSubject.general) return songs;
    final expected = _normalize(keyword);
    final matches = songs.where((song) {
      final value = switch (subject) {
        SearchSubject.title => song.name,
        SearchSubject.artist => song.artist,
        SearchSubject.album => song.album,
        SearchSubject.general => '',
      };
      final normalizedValue = _normalize(value);
      return normalizedValue.isNotEmpty &&
          (normalizedValue.contains(expected) ||
              expected.contains(normalizedValue));
    }).toList();
    return matches.isEmpty ? songs : matches;
  }

  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  Future<void> _loadSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;
      final saved = prefs.getStringList(_historyPrefsKey) ?? const <String>[];
      final seen = <String>{};
      for (final item in saved) {
        final keyword = item.trim();
        if (keyword.isEmpty || !seen.add(_normalize(keyword))) continue;
        _searchHistory.add(keyword);
        if (_searchHistory.length >= _maxHistoryItems) break;
      }
      _notify();
    } catch (_) {}
  }

  Future<void> _rememberSearch(String keyword) async {
    await _historyReady;
    if (_disposed) return;
    final normalized = _normalize(keyword);
    _searchHistory.removeWhere((item) => _normalize(item) == normalized);
    _searchHistory.insert(0, keyword);
    if (_searchHistory.length > _maxHistoryItems) {
      _searchHistory.removeRange(_maxHistoryItems, _searchHistory.length);
    }
    _notify();
    await _saveSearchHistory();
  }

  Future<void> _saveSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_historyPrefsKey, _searchHistory);
    } catch (_) {}
  }

  bool _isCurrentSearch(
    int requestId,
    bool playlistMode,
    SearchSubject subject,
  ) {
    return !_disposed &&
        requestId == _requestId &&
        playlistMode == _playlistMode &&
        subject == _subject;
  }

  void _resetResults() {
    _loadedPlatforms.clear();
    for (final platform in musicPlatformDisplayOrder) {
      _results[platform] = [];
      _playlistResults[platform] = [];
      _errors[platform] = null;
      _loading[platform] = false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
