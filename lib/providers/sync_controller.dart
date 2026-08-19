import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/song.dart';
import '../services/account_sync_service.dart';
import '../services/favorite_service.dart';
import 'player_provider.dart';
import 'search_session.dart';
import 'theme_controller.dart';

enum SyncStatus { idle, syncing, offline, error }

class SyncController extends ChangeNotifier with WidgetsBindingObserver {
  final AccountSyncService service;
  final FavoriteService favorites;
  final PlayerProvider player;
  final SearchSession search;
  final ThemeController theme;

  SyncStatus _status = SyncStatus.idle;
  DateTime? _lastSyncedAt;
  String? _message;
  final Set<String> _dirtyDomains = {};
  Timer? _timer;
  bool _syncing = false;
  bool _pulling = false;
  bool _applyingRemote = false;
  int _historyRevision = 0;
  int _playerSettingsSignature = 0;
  int _searchSignature = 0;

  SyncController({
    required this.service,
    required this.favorites,
    required this.player,
    required this.search,
    required this.theme,
  }) {
    _historyRevision = player.playbackHistoryRevision;
    _playerSettingsSignature = _settingsSignature();
    _searchSignature = Object.hashAll(search.searchHistory);
    favorites.addListener(_onFavoritesChanged);
    player.addListener(_onPlayerChanged);
    search.addListener(_onSearchChanged);
    theme.addListener(_onThemeChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  SyncStatus get status => _status;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  String? get message => _message;

  Future<void> syncNow() async {
    _dirtyDomains.addAll(const {
      'favorites',
      'history',
      'settings',
      'search_history',
    });
    await _flush();
  }

  void _onFavoritesChanged() {
    if (!_applyingRemote) _schedule('favorites');
  }

  void _onThemeChanged() {
    if (!_applyingRemote) _schedule('settings');
  }

  void _onSearchChanged() {
    if (_applyingRemote) return;
    final signature = Object.hashAll(search.searchHistory);
    if (signature == _searchSignature) return;
    _searchSignature = signature;
    _schedule('search_history');
  }

  void _onPlayerChanged() {
    if (_applyingRemote) return;
    if (player.playbackHistoryRevision != _historyRevision) {
      _historyRevision = player.playbackHistoryRevision;
      _schedule('history');
    }
    final signature = _settingsSignature();
    if (signature != _playerSettingsSignature) {
      _playerSettingsSignature = signature;
      _schedule('settings');
    }
  }

  int _settingsSignature() => Object.hashAll([
    player.neteaseLevel,
    player.commonLevel,
    player.bilibiliAudioQuality,
    player.bilibiliVideoQuality,
    player.videoPlayerMode,
    player.lyricOffsetStep,
    for (final platform in MusicPlatform.values.where(
      (platform) => platform != MusicPlatform.bilibili,
    ))
      player.playbackSourceFor(platform),
    ...player.bilibiliLyricPlatformOrder,
  ]);

  void _schedule(String domain) {
    _dirtyDomains.add(domain);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 3), _flush);
  }

  Future<void> _flush() async {
    if (_syncing || _pulling || _dirtyDomains.isEmpty) return;
    _timer?.cancel();
    _timer = null;
    final domains = Set<String>.of(_dirtyDomains);
    _dirtyDomains.removeAll(domains);
    _syncing = true;
    _status = SyncStatus.syncing;
    _message = null;
    notifyListeners();
    try {
      final changed = await service.syncDomains(domains);
      await _reloadDomains(changed);
      _status = SyncStatus.idle;
      _lastSyncedAt = DateTime.now();
    } catch (error) {
      _dirtyDomains.addAll(domains);
      _status = SyncStatus.offline;
      _message = error.toString();
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> _pullRemote() async {
    if (_pulling || _syncing) return;
    _pulling = true;
    _status = SyncStatus.syncing;
    notifyListeners();
    try {
      final changed = await service.bootstrap();
      await _reloadDomains(changed);
      _status = SyncStatus.idle;
      _lastSyncedAt = DateTime.now();
      _message = null;
    } catch (error) {
      _status = SyncStatus.offline;
      _message = error.toString();
    } finally {
      _pulling = false;
      notifyListeners();
      if (_dirtyDomains.isNotEmpty) unawaited(_flush());
    }
  }

  Future<void> _reloadDomains(Set<String> changed) async {
    if (changed.isEmpty) return;
    _applyingRemote = true;
    try {
      final futures = <Future<void>>[];
      if (changed.contains('favorites')) {
        futures.add(favorites.reloadForAccount());
      }
      if (changed.contains('search_history')) {
        futures.add(search.reloadForAccount());
      }
      if (changed.contains('settings')) futures.add(theme.reloadForAccount());
      if (changed.contains('settings') || changed.contains('history')) {
        futures.add(player.reloadForAccount());
      }
      await Future.wait(futures);
      _historyRevision = player.playbackHistoryRevision;
      _playerSettingsSignature = _settingsSignature();
      _searchSignature = Object.hashAll(search.searchHistory);
    } finally {
      _applyingRemote = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_pullRemote());
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _dirtyDomains.addAll(const {
        'favorites',
        'history',
        'settings',
        'search_history',
      });
      unawaited(_flush());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    favorites.removeListener(_onFavoritesChanged);
    player.removeListener(_onPlayerChanged);
    search.removeListener(_onSearchChanged);
    theme.removeListener(_onThemeChanged);
    super.dispose();
  }
}
