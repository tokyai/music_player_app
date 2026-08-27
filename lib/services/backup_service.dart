import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_user.dart';
import '../models/song.dart';
import '../providers/ai_config_controller.dart';
import '../providers/player_provider.dart';
import '../providers/search_session.dart';
import '../providers/theme_controller.dart';
import '../providers/user_controller.dart';
import '../services/bilibili_service.dart';
import '../services/favorite_service.dart';
import '../services/global_settings_service.dart';
import '../services/playback_history_service.dart';
import '../services/playback_state_service.dart';
import '../services/user_avatar_storage.dart';
import '../services/user_data_scope.dart';

/// A user-selectable portion of an exported backup.
enum BackupRestoreSection {
  songs,
  bilibili,
  playlists,
  searchHistory,
  appearance,
  lyricDisplay,
  playerSettings,
  bilibiliAccount,
  apiKey,
  globalVoice,
  aiAssistant,
}

/// The import mode and the portions the user wants to restore.
class BackupRestoreSelection {
  final FavoriteImportMode mode;
  final Set<BackupRestoreSection> sections;

  BackupRestoreSelection({
    required this.mode,
    required Iterable<BackupRestoreSection> sections,
  }) : sections = Set.unmodifiable(sections);
}

/// Describes which optional sections are present in a backup payload.
class BackupRestoreContents {
  final bool songs;
  final bool bilibili;
  final bool playlists;
  final bool searchHistory;
  final bool appearance;
  final bool lyricDisplay;
  final bool bilibiliAccount;
  final bool apiKey;
  final bool globalVoice;
  final bool aiAssistant;
  final bool playerSettings;
  final bool fullSnapshot;

  const BackupRestoreContents({
    required this.songs,
    required this.bilibili,
    required this.playlists,
    this.searchHistory = false,
    this.appearance = false,
    this.lyricDisplay = false,
    this.bilibiliAccount = false,
    this.apiKey = false,
    this.globalVoice = false,
    this.aiAssistant = false,
    this.playerSettings = false,
    this.fullSnapshot = false,
  });

  bool contains(BackupRestoreSection section) => switch (section) {
    BackupRestoreSection.songs => songs,
    BackupRestoreSection.bilibili => bilibili,
    BackupRestoreSection.playlists => playlists,
    BackupRestoreSection.searchHistory => searchHistory,
    BackupRestoreSection.appearance => appearance,
    BackupRestoreSection.lyricDisplay => lyricDisplay,
    BackupRestoreSection.playerSettings => playerSettings,
    BackupRestoreSection.bilibiliAccount => bilibiliAccount,
    BackupRestoreSection.apiKey => apiKey,
    BackupRestoreSection.globalVoice => globalVoice,
    BackupRestoreSection.aiAssistant => aiAssistant,
  };

  Set<BackupRestoreSection> get availableSections =>
      BackupRestoreSection.values.where(contains).toSet();

  BackupRestoreContents forScope(UserDataScope scope) {
    if (fullSnapshot) return this;
    if (scope.isDefault) return this;
    return BackupRestoreContents(
      songs: songs,
      bilibili: bilibili,
      playlists: playlists,
      searchHistory: searchHistory,
    );
  }
}

/// 收藏数据与播放器设置之间的备份协调层。
///
/// FavoriteService 只负责收藏数据本身，播放器 API Key 由这里统一编排，
/// 因此文件、WebDAV 和局域网三种入口都会得到完全一致的行为。
class BackupService {
  static const maxBackupBytes = 12 * 1024 * 1024;
  static const fullSnapshotFormat = 'kuzai_music_full_backup';
  static const fullSnapshotVersion = 1;

  static const _excludedGlobalPreferenceKeys = <String>{
    'kuzai_users_v1',
    'kuzai_active_user_v1',
  };
  static const _legacyUserPreferenceKeys = <String>{
    'favorites',
    'favorite_playlists',
    'search_history',
    PlaybackHistoryService.preferenceKey,
    PlaybackStateService.preferenceKey,
    'webdav_url',
    'webdav_username',
    'webdav_password',
    'webdav_certificate_sha256',
  };
  static const _structuredUserPreferenceKeys = <String>{
    'favorites',
    'favorite_playlists',
    'search_history',
    PlaybackHistoryService.preferenceKey,
    PlaybackStateService.preferenceKey,
  };

  const BackupService._();

  static BackupRestoreContents inspect(String raw) {
    final decoded = _decodeJson(raw);

    if (_isFullSnapshot(decoded)) {
      _decodeFullSnapshot(decoded);
      return const BackupRestoreContents(
        songs: true,
        bilibili: true,
        playlists: true,
        searchHistory: true,
        appearance: true,
        lyricDisplay: true,
        bilibiliAccount: true,
        apiKey: true,
        globalVoice: true,
        aiAssistant: true,
        playerSettings: true,
        fullSnapshot: true,
      );
    }

    if (decoded is List) {
      return BackupRestoreContents(
        songs: true,
        bilibili: _containsBilibili(decoded),
        playlists: false,
      );
    }
    if (decoded is! Map) {
      throw const FormatException('备份文件格式不受支持');
    }
    final format = decoded['format'];
    if (format != null && format != FavoriteService.exportFormat) {
      throw const FormatException('不是库仔音乐收藏备份');
    }
    final songs = decoded['songs'];
    if (songs is! List) {
      throw const FormatException('备份文件缺少歌曲列表');
    }
    final bilibili = decoded['bilibili'];
    if (bilibili != null && bilibili is! List) {
      throw const FormatException('备份文件中的 B站收藏格式错误');
    }
    final playlists = decoded['playlists'];
    if (playlists != null && playlists is! List) {
      throw const FormatException('备份文件中的歌单列表格式错误');
    }
    final rawApiKey = decoded['apiKey'];
    if (decoded.containsKey('apiKey') &&
        rawApiKey != null &&
        rawApiKey is! String) {
      throw const FormatException('备份文件中的 API Key 格式错误');
    }
    final rawSearchHistory = decoded['searchHistory'];
    if (rawSearchHistory != null && rawSearchHistory is! Map) {
      throw const FormatException('备份文件中的搜索历史格式错误');
    }
    final rawAppearance = decoded['appearance'];
    if (rawAppearance != null && rawAppearance is! Map) {
      throw const FormatException('备份文件中的外观设置格式错误');
    }
    final rawLyricDisplay = decoded['lyricDisplay'];
    if (rawLyricDisplay != null && rawLyricDisplay is! Map) {
      throw const FormatException('备份文件中的歌词显示设置格式错误');
    }
    final rawBilibiliAccount = decoded['bilibiliAccount'];
    if (rawBilibiliAccount != null && rawBilibiliAccount is! Map) {
      throw const FormatException('备份文件中的 B 站账号数据格式错误');
    }
    final rawVoice = decoded['globalVoice'];
    if (rawVoice != null && rawVoice is! Map) {
      throw const FormatException('备份文件中的全局语音设置格式错误');
    }
    // The payload has already been decoded and validated above. Reuse this
    // tree instead of decoding the complete backup once per optional section.
    final aiAssistant = _readAiBackupValue(decoded);
    final playerSettings = _readPlayerBackupValue(decoded);
    return BackupRestoreContents(
      songs: true,
      bilibili: bilibili is List ? true : _containsBilibili(songs),
      playlists: playlists is List,
      searchHistory: rawSearchHistory is Map,
      appearance: rawAppearance is Map,
      lyricDisplay: rawLyricDisplay is Map,
      bilibiliAccount: rawBilibiliAccount is Map,
      apiKey: decoded.containsKey('apiKey'),
      globalVoice: rawVoice is Map,
      aiAssistant: aiAssistant != null,
      playerSettings: playerSettings != null,
    );
  }

  static String exportJson({
    required FavoriteService favorites,
    required PlayerProvider player,
    AiConfigController? aiConfig,
    ThemeController? theme,
    SearchSession? search,
    Map<String, dynamic>? lyricDisplay,
  }) {
    _assertMatchingScopes(favorites, player, search);
    final isDefault = player.dataScope.isDefault;
    final decoded = favorites.exportData(
      apiKey: isDefault ? player.apiKey : null,
    );
    decoded['backupScope'] = isDefault ? 'global_and_default_user' : 'user';
    decoded['sourceUserId'] = player.dataScope.userId;
    if (search != null) decoded['searchHistory'] = search.toBackupJson();
    if (isDefault) {
      if (theme != null) decoded['appearance'] = theme.toBackupJson();
      decoded['lyricDisplay'] = Map<String, dynamic>.from(
        lyricDisplay ?? GlobalSettingsService.defaultLyricDisplay(),
      );
      if (aiConfig != null) {
        decoded['aiAssistant'] = aiConfig.toBackupJson();
        decoded['globalVoice'] = aiConfig.toVoiceBackupJson();
      }
      decoded['playerSettings'] = player.toBackupJson();
      decoded['bilibiliAccount'] = player.bilibiliAccountToBackupJson();
    } else {
      decoded.remove('apiKey');
    }
    return const JsonEncoder.withIndent('  ').convert(decoded);
  }

  static Future<String> exportFullJson({
    required UserController users,
    required FavoriteService favorites,
    required PlayerProvider player,
    required AiConfigController aiConfig,
    required ThemeController theme,
    required SearchSession search,
  }) async {
    await users.ready;
    _assertMatchingScopes(favorites, player, search);
    if (users.activeUserId != player.dataScope.userId) {
      throw StateError('当前用户与备份会话不一致，已拒绝操作');
    }
    await Future.wait([
      favorites.load(),
      player.settingsReady,
      player.historyReady,
      player.playbackStateReady,
      aiConfig.ready,
      theme.ready,
      search.historyReady,
    ]);

    final operationActiveUserId = users.activeUserId;
    final operationProfiles = users.users;
    final prefs = await SharedPreferences.getInstance();
    final userBackups = <Map<String, dynamic>>[];
    for (final profile in operationProfiles) {
      final scope = UserDataScope(profile.id);
      final scopedFavorites = profile.id == player.dataScope.userId
          ? favorites
          : FavoriteService(dataScope: scope);
      final scopedSearch = profile.id == search.dataScope.userId
          ? search
          : SearchSession(dataScope: scope);
      final ownsFavorites = !identical(scopedFavorites, favorites);
      final ownsSearch = !identical(scopedSearch, search);
      try {
        await Future.wait([scopedFavorites.load(), scopedSearch.historyReady]);
        final playbackHistory = profile.id == player.dataScope.userId
            ? player.playbackHistory
            : await PlaybackHistoryService.load(scope: scope);
        final livePlayerData = profile.id == player.dataScope.userId
            ? player.toUserBackupJson()
            : null;
        final dynamic playbackState;
        if (profile.id == player.dataScope.userId) {
          playbackState = livePlayerData?['playbackState'];
        } else {
          playbackState = (await PlaybackStateService.load(
            scope: scope,
          ))?.toJson();
        }
        final avatarBytes = await users.avatarStorage.read(
          profile.avatarFileName,
        );
        if (profile.hasCustomAvatar && avatarBytes == null) {
          throw StateError('用户“${profile.name}”的自定义头像已丢失，无法完整备份');
        }
        final data = scopedFavorites.exportData()..remove('apiKey');
        data.remove('format');
        data.remove('version');
        data.remove('userDataVersion');
        data.remove('exportedAt');
        userBackups.add({
          'profile': profile.toJson(),
          if (avatarBytes != null)
            'avatarJpegBase64': base64Encode(avatarBytes),
          'data': {
            ...data,
            'searchHistory': scopedSearch.toBackupJson(),
            'playbackHistory': PlaybackHistoryService.toBackupJson(
              playbackHistory,
            ),
            if (playbackState != null) 'playbackState': playbackState,
            'preferences': _exportUserPreferences(prefs, scope),
          },
        });
      } finally {
        if (ownsFavorites) scopedFavorites.dispose();
        if (ownsSearch) scopedSearch.dispose();
      }
    }

    if (users.activeUserId != operationActiveUserId ||
        !_sameUserProfiles(users.users, operationProfiles) ||
        player.dataScope.userId != operationActiveUserId) {
      throw StateError('用户数据在备份期间发生变化，请重试');
    }

    final decoded = <String, dynamic>{
      'format': fullSnapshotFormat,
      'version': fullSnapshotVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'activeUserId': operationActiveUserId,
      'global': {
        'preferences': _exportGlobalPreferences(prefs),
        'appearance': theme.toBackupJson(),
        'lyricDisplay': await GlobalSettingsService.exportLyricDisplay(),
        'apiKey': player.apiKey,
        'playerSettings': player.toBackupJson(),
        'bilibiliAccount': player.bilibiliAccountToBackupJson(),
        'globalVoice': aiConfig.toVoiceBackupJson(),
        'aiAssistant': aiConfig.toBackupJson(),
      },
      'users': userBackups,
    };
    final encoded = const JsonEncoder.withIndent('  ').convert(decoded);
    _ensureWithinLimit(encoded);
    return encoded;
  }

  static Future<BackupRestoreResult> importJson({
    required String raw,
    required FavoriteService favorites,
    required PlayerProvider player,
    AiConfigController? aiConfig,
    ThemeController? theme,
    SearchSession? search,
    UserController? users,
    FavoriteImportMode mode = FavoriteImportMode.merge,
    Iterable<BackupRestoreSection>? sections,
  }) async {
    final decoded = _decodeJson(raw);
    _assertMatchingScopes(favorites, player, search);
    if (_isFullSnapshot(decoded)) {
      if (users == null ||
          aiConfig == null ||
          theme == null ||
          search == null) {
        throw StateError('完整备份需要在“备份与还原”页面恢复');
      }
      return _importFullSnapshot(
        decoded: decoded,
        users: users,
        favorites: favorites,
        player: player,
        aiConfig: aiConfig,
        theme: theme,
        search: search,
      );
    }
    final requestedSections = sections == null
        ? BackupRestoreSection.values.toSet()
        : sections.toSet();
    const userSections = {
      BackupRestoreSection.songs,
      BackupRestoreSection.bilibili,
      BackupRestoreSection.playlists,
      BackupRestoreSection.searchHistory,
    };
    final selectedSections = player.dataScope.isDefault
        ? requestedSections
        : requestedSections.intersection(userSections);
    return _importDecoded(
      decoded: decoded,
      favorites: favorites,
      player: player,
      aiConfig: aiConfig,
      theme: theme,
      search: search,
      mode: mode,
      selectedSections: selectedSections,
    );
  }

  static Future<BackupRestoreResult> _importDecoded({
    required dynamic decoded,
    required FavoriteService favorites,
    required PlayerProvider player,
    required AiConfigController? aiConfig,
    required ThemeController? theme,
    required SearchSession? search,
    required FavoriteImportMode mode,
    required Set<BackupRestoreSection> selectedSections,
  }) async {
    final aiBackup = selectedSections.contains(BackupRestoreSection.aiAssistant)
        ? _readAiBackupValue(decoded)
        : null;
    final playerBackup =
        selectedSections.contains(BackupRestoreSection.playerSettings)
        ? _readPlayerBackupValue(decoded)
        : null;
    final appearanceBackup =
        selectedSections.contains(BackupRestoreSection.appearance)
        ? _readMapBackupValue(decoded, 'appearance', '外观设置')
        : null;
    final lyricBackup =
        selectedSections.contains(BackupRestoreSection.lyricDisplay)
        ? _readMapBackupValue(decoded, 'lyricDisplay', '歌词显示设置')
        : null;
    final bilibiliAccountBackup =
        selectedSections.contains(BackupRestoreSection.bilibiliAccount)
        ? _readMapBackupValue(decoded, 'bilibiliAccount', 'B 站账号数据')
        : null;
    final voiceBackup =
        selectedSections.contains(BackupRestoreSection.globalVoice)
        ? _readMapBackupValue(decoded, 'globalVoice', '全局语音设置')
        : null;
    final searchBackup =
        selectedSections.contains(BackupRestoreSection.searchHistory)
        ? _readMapBackupValue(decoded, 'searchHistory', '搜索历史')
        : null;
    // Validate portable AI credentials before FavoriteService writes any
    // selected collection. A malformed key must not leave a half-restored
    // backup with new favorites but old settings.
    if (aiBackup != null && aiConfig != null) {
      await aiConfig.validateBackupJson(aiBackup);
    }
    if (appearanceBackup != null && theme != null) {
      await theme.ready;
      _validateAppearanceBackup(appearanceBackup);
    }
    if (lyricBackup != null) {
      GlobalSettingsService.validateLyricDisplay(lyricBackup);
    }
    if (bilibiliAccountBackup != null) {
      BilibiliService.validateBackupJson(bilibiliAccountBackup);
    }
    if (voiceBackup != null && aiConfig != null) {
      aiConfig.validateVoiceBackupJson(voiceBackup);
    }
    if (searchBackup != null) {
      SearchSession.decodeBackupJson(searchBackup);
    }
    final result = await favorites.importDecoded(
      decoded,
      mode: mode,
      importSongs: selectedSections.contains(BackupRestoreSection.songs),
      importBilibili: selectedSections.contains(BackupRestoreSection.bilibili),
      importPlaylists: selectedSections.contains(
        BackupRestoreSection.playlists,
      ),
      importApiKey: selectedSections.contains(BackupRestoreSection.apiKey),
    );
    var apiKeyRestored = false;
    if (selectedSections.contains(BackupRestoreSection.apiKey) &&
        result.apiKeyPresent) {
      await player.setApiKey(result.apiKey ?? '');
      apiKeyRestored = true;
    }
    var aiConfigRestored = false;
    if (selectedSections.contains(BackupRestoreSection.aiAssistant) &&
        aiBackup != null &&
        aiConfig != null) {
      await aiConfig.restoreBackupJson(aiBackup);
      aiConfigRestored = true;
    }
    var playerSettingsRestored = false;
    if (selectedSections.contains(BackupRestoreSection.playerSettings) &&
        playerBackup != null) {
      await player.restoreBackupJson(playerBackup);
      playerSettingsRestored = true;
    }
    var appearanceRestored = false;
    if (appearanceBackup != null && theme != null) {
      await theme.restoreBackupJson(appearanceBackup);
      appearanceRestored = true;
    }
    var lyricDisplayRestored = false;
    if (lyricBackup != null) {
      await GlobalSettingsService.restoreLyricDisplay(lyricBackup);
      lyricDisplayRestored = true;
    }
    var bilibiliAccountRestored = false;
    if (bilibiliAccountBackup != null) {
      await player.restoreBilibiliAccountBackupJson(bilibiliAccountBackup);
      bilibiliAccountRestored = true;
    }
    var globalVoiceRestored = false;
    if (voiceBackup != null && aiConfig != null) {
      await aiConfig.restoreVoiceBackupJson(voiceBackup);
      globalVoiceRestored = true;
    }
    var searchHistoryRestored = false;
    if (searchBackup != null && search != null) {
      await search.restoreBackupJson(
        searchBackup,
        replace: mode == FavoriteImportMode.replace,
      );
      searchHistoryRestored = true;
    }
    return BackupRestoreResult(
      songsAdded: result.added,
      songsSkipped: result.skipped,
      songsTotal: result.total,
      bilibiliAdded: result.bilibiliAdded,
      bilibiliSkipped: result.bilibiliSkipped,
      bilibiliTotal: result.bilibiliTotal,
      playlistsAdded: result.playlistsAdded,
      playlistsSkipped: result.playlistsSkipped,
      apiKeyRestored: apiKeyRestored,
      aiConfigRestored: aiConfigRestored,
      playerSettingsRestored: playerSettingsRestored,
      appearanceRestored: appearanceRestored,
      lyricDisplayRestored: lyricDisplayRestored,
      bilibiliAccountRestored: bilibiliAccountRestored,
      globalVoiceRestored: globalVoiceRestored,
      searchHistoryRestored: searchHistoryRestored,
    );
  }

  static bool _isFullSnapshot(dynamic decoded) {
    return decoded is Map && decoded['format'] == fullSnapshotFormat;
  }

  static _FullSnapshot _decodeFullSnapshot(dynamic decoded) {
    if (decoded is! Map || decoded['format'] != fullSnapshotFormat) {
      throw const FormatException('不是库仔音乐全量备份');
    }
    final version = decoded['version'];
    if (version is! num || version.toInt() != fullSnapshotVersion) {
      throw const FormatException('备份文件版本不受支持');
    }
    final activeUserId = decoded['activeUserId']?.toString().trim() ?? '';
    if (activeUserId.isEmpty) {
      throw const FormatException('备份文件缺少当前用户');
    }
    final global = decoded['global'];
    if (global is! Map) {
      throw const FormatException('备份文件缺少全局配置');
    }
    final users = decoded['users'];
    if (users is! List ||
        users.isEmpty ||
        users.length > UserController.maxUsers) {
      throw const FormatException('备份文件中的用户列表无效');
    }
    final parsedUsers = <_FullUserSnapshot>[];
    final ids = <String>{};
    final names = <String>{};
    for (final rawUser in users) {
      if (rawUser is! Map) {
        throw const FormatException('备份文件中的用户数据格式错误');
      }
      final profileValue = rawUser['profile'];
      if (profileValue is! Map) {
        throw const FormatException('备份文件中的用户资料格式错误');
      }
      final profile = AppUserProfile.fromJson(
        Map<String, dynamic>.from(profileValue),
      );
      if (!ids.add(profile.id) ||
          !names.add(profile.name.trim().toLowerCase())) {
        throw const FormatException('备份文件中存在重复用户');
      }
      final rawAvatar = rawUser['avatarJpegBase64'];
      Uint8List? avatarBytes;
      if (rawAvatar != null) {
        if (rawAvatar is! String || rawAvatar.length > 700 * 1024) {
          throw const FormatException('备份文件中的头像格式错误');
        }
        try {
          avatarBytes = Uint8List.fromList(base64Decode(rawAvatar));
          UserAvatarStorage.validateJpeg(avatarBytes);
        } on FormatException {
          rethrow;
        } catch (_) {
          throw const FormatException('备份文件中的头像格式错误');
        }
      }
      if (profile.hasCustomAvatar && avatarBytes == null) {
        throw const FormatException('备份文件缺少自定义头像');
      }
      if (!profile.hasCustomAvatar && avatarBytes != null) {
        throw const FormatException('内置头像不能附带图片数据');
      }
      final dataValue = rawUser['data'];
      if (dataValue is! Map) {
        throw const FormatException('备份文件中的用户数据缺失');
      }
      final data = Map<String, dynamic>.from(dataValue);
      _validateFullUserData(data);
      parsedUsers.add(
        _FullUserSnapshot(
          profile: profile,
          avatarBytes: avatarBytes,
          data: data,
        ),
      );
    }
    if (!ids.contains(activeUserId) ||
        parsedUsers.where((item) => item.profile.isDefault).length != 1) {
      throw const FormatException('备份文件中的用户集合不完整');
    }
    return _FullSnapshot(
      activeUserId: activeUserId,
      global: Map<String, dynamic>.from(global),
      users: parsedUsers,
    );
  }

  static void _validateFullUserData(Map<String, dynamic> data) {
    final songs = data['songs'];
    final bilibili = data['bilibili'];
    final playlists = data['playlists'];
    if (songs is! List || bilibili is! List || playlists is! List) {
      throw const FormatException('备份文件中的收藏数据格式错误');
    }
    // Reuse the collection parser for strict song/playlist validation before
    // any preference is written.
    FavoriteService.validateDecodedBackup({
      'format': FavoriteService.exportFormat,
      'songs': songs,
      'bilibili': bilibili,
      'playlists': playlists,
    });
    final search = data['searchHistory'];
    if (search is! Map) {
      throw const FormatException('备份文件中的搜索历史格式错误');
    }
    SearchSession.decodeBackupJson(Map<String, dynamic>.from(search));
    final history = data['playbackHistory'];
    if (history is! Map) {
      throw const FormatException('备份文件中的播放历史格式错误');
    }
    PlaybackHistoryService.decodeBackupJson(Map<String, dynamic>.from(history));
    final state = data['playbackState'];
    if (state != null) {
      if (state is! Map) {
        throw const FormatException('备份文件中的播放队列格式错误');
      }
      PlaybackStateService.validateBackupJson(Map<String, dynamic>.from(state));
    }
    _validateUserPreferenceMap(data['preferences']);
  }

  static void _validatePreferenceMap(dynamic value, String label) {
    if (value == null) return;
    if (value is! Map) throw FormatException('备份文件中的$label格式错误');
    for (final entry in value.entries) {
      if (entry.key is! String || !_isPreferenceValue(entry.value)) {
        throw FormatException('备份文件中的$label格式错误');
      }
    }
  }

  static void _validateGlobalPreferenceMap(dynamic value) {
    if (value is! Map) throw const FormatException('备份文件中的全局配置格式错误');
    _validatePreferenceMap(value, '全局配置');
    for (final key in value.keys.cast<String>()) {
      if (_excludedGlobalPreferenceKeys.contains(key) ||
          _legacyUserPreferenceKeys.contains(key) ||
          UserDataScope.isScopedPreferenceKey(key)) {
        throw const FormatException('备份文件中的全局配置包含保留项');
      }
    }
  }

  static void _validateUserPreferenceMap(dynamic value) {
    if (value is! Map) throw const FormatException('备份文件中的用户配置格式错误');
    _validatePreferenceMap(value, '用户配置');
    for (final key in value.keys.cast<String>()) {
      if (!_legacyUserPreferenceKeys.contains(key) ||
          _structuredUserPreferenceKeys.contains(key)) {
        throw const FormatException('备份文件中的用户配置包含无效项');
      }
    }
  }

  static bool _isPreferenceValue(Object? value) {
    if (value is bool || value is int || value is double || value is String) {
      return true;
    }
    return value is List && value.every((item) => item is String);
  }

  static Map<String, dynamic> _exportGlobalPreferences(
    SharedPreferences prefs,
  ) {
    final result = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      if (_excludedGlobalPreferenceKeys.contains(key) ||
          UserDataScope.isScopedPreferenceKey(key) ||
          _legacyUserPreferenceKeys.contains(key)) {
        continue;
      }
      final value = prefs.get(key);
      if (_isPreferenceValue(value)) result[key] = value;
    }
    return result;
  }

  static Map<String, dynamic> _exportUserPreferences(
    SharedPreferences prefs,
    UserDataScope scope,
  ) {
    final result = <String, dynamic>{};
    if (scope.isDefault) {
      for (final key in _legacyUserPreferenceKeys) {
        if (_structuredUserPreferenceKeys.contains(key)) continue;
        final value = prefs.get(key);
        if (_isPreferenceValue(value)) result[key] = value;
      }
      return result;
    }
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(scope.preferencePrefix)) continue;
      final plain = key.substring(scope.preferencePrefix.length);
      if (!_legacyUserPreferenceKeys.contains(plain) ||
          _structuredUserPreferenceKeys.contains(plain)) {
        continue;
      }
      final value = prefs.get(key);
      if (_isPreferenceValue(value)) {
        result[plain] = value;
      }
    }
    return result;
  }

  static Future<BackupRestoreResult> _importFullSnapshot({
    required dynamic decoded,
    required UserController users,
    required FavoriteService favorites,
    required PlayerProvider player,
    required AiConfigController aiConfig,
    required ThemeController theme,
    required SearchSession search,
  }) async {
    final snapshot = _decodeFullSnapshot(decoded);
    final global = snapshot.global;
    final globalPrefs = _requiredMap(global, 'preferences', '全局配置');
    _validateGlobalPreferenceMap(globalPrefs);
    final appearance = _requiredMap(global, 'appearance', '外观设置');
    final lyricDisplay = _requiredMap(global, 'lyricDisplay', '歌词显示设置');
    final playerSettings = _requiredMap(global, 'playerSettings', '播放器设置');
    final bilibiliAccount = _requiredMap(global, 'bilibiliAccount', 'B站账号数据');
    final voice = _requiredMap(global, 'globalVoice', '全局语音设置');
    final ai = _requiredMap(global, 'aiAssistant', 'AI 助手配置');
    _validateAppearanceBackup(appearance);
    GlobalSettingsService.validateLyricDisplay(lyricDisplay);
    PlayerProvider.validateBackupJson(playerSettings);
    BilibiliService.validateBackupJson(bilibiliAccount);
    aiConfig.validateVoiceBackupJson(voice);
    await aiConfig.validateBackupJson(ai);
    final apiKey = global['apiKey'];
    if (apiKey is! String) {
      throw const FormatException('备份文件中的 API Key 格式错误');
    }

    final prefs = await SharedPreferences.getInstance();
    final oldPreferences = <String, Object?>{};
    final oldScopedPreferences = <String, Object?>{};
    final oldDefaultUserPreferences = <String, Object?>{};
    final createdAvatars = <String>[];
    final restoredProfiles = <AppUserProfile>[];
    final oldAi = aiConfig.toBackupJson();
    final oldVoice = aiConfig.toVoiceBackupJson();
    final oldAppearance = theme.toBackupJson();
    final oldLyricDisplay = await GlobalSettingsService.exportLyricDisplay();
    final oldPlayerSettings = player.toBackupJson();
    final oldApiKey = player.apiKey;
    final oldBilibiliAccount = player.bilibiliAccountToBackupJson();
    var preparationStarted = false;
    var preferenceMutationStarted = false;
    var profileRestoreAttempted = false;
    try {
      // Flush pending history/queue writes before replacing their preference
      // keys. Otherwise a timer from the old session could overwrite the
      // freshly restored active user's data after this method returns.
      preparationStarted = true;
      await player.prepareForUserSwitch(waitForWrites: true);
      // Capture rollback state only after the player has flushed its live
      // history and queue. Capturing earlier could lose an operation still
      // inside the normal one- or two-second persistence debounce window.
      for (final key in prefs.getKeys()) {
        if (UserDataScope.isScopedPreferenceKey(key)) {
          oldScopedPreferences[key] = prefs.get(key);
          continue;
        }
        if (_excludedGlobalPreferenceKeys.contains(key) ||
            _legacyUserPreferenceKeys.contains(key)) {
          continue;
        }
        oldPreferences[key] = prefs.get(key);
      }
      for (final key in _legacyUserPreferenceKeys) {
        if (prefs.containsKey(key)) {
          oldDefaultUserPreferences[key] = prefs.get(key);
        }
      }
      for (final item in snapshot.users) {
        var profile = item.profile;
        if (item.avatarBytes != null) {
          final fileName = await users.avatarStorage.save(
            profile.id,
            item.avatarBytes!,
          );
          createdAvatars.add(fileName);
          profile = profile.copyWith(
            avatarId: AppUserProfile.customAvatarId,
            avatarFileName: fileName,
          );
        }
        restoredProfiles.add(profile);
      }

      preferenceMutationStarted = true;
      await _replacePreferenceMap(
        prefs,
        globalPrefs,
        exclude: _excludedGlobalPreferenceKeys,
      );
      await _removeUnlistedScopedPreferences(
        prefs,
        snapshot.users.map((item) => item.profile.id).toSet(),
      );
      for (final item in snapshot.users) {
        await _writeFullUserData(prefs, item);
      }
      await aiConfig.restoreBackupJson(ai, requirePersistence: true);
      await aiConfig.restoreVoiceBackupJson(voice);
      await theme.restoreBackupJson(appearance);
      await GlobalSettingsService.restoreLyricDisplay(lyricDisplay);
      await player.restoreBackupJson(playerSettings);
      await player.setApiKey(apiKey);
      await player.restoreBilibiliAccountBackupJson(bilibiliAccount);
      // Commit the user list last. Its callback replaces the active session,
      // so none of the old session providers are accessed after this point.
      profileRestoreAttempted = true;
      await users.restoreBackupProfiles(
        restoredProfiles,
        backupActiveUserId: snapshot.activeUserId,
      );

      final activeData = snapshot.users
          .firstWhere((item) => item.profile.id == snapshot.activeUserId)
          .data;
      final songs = activeData['songs'] as List;
      final bilibili = activeData['bilibili'] as List;
      final playlists = activeData['playlists'] as List;
      return BackupRestoreResult(
        songsAdded: songs.length,
        songsSkipped: 0,
        songsTotal: songs.length,
        bilibiliAdded: bilibili.length,
        bilibiliSkipped: 0,
        bilibiliTotal: bilibili.length,
        playlistsAdded: playlists.length,
        playlistsSkipped: 0,
        apiKeyRestored: true,
        aiConfigRestored: true,
        playerSettingsRestored: true,
        appearanceRestored: true,
        lyricDisplayRestored: true,
        bilibiliAccountRestored: true,
        globalVoiceRestored: true,
        searchHistoryRestored: true,
        restoredToDefaultUser:
            snapshot.activeUserId == AppUserProfile.defaultUserId,
        fullSnapshotRestored: true,
      );
    } catch (error) {
      // Restore the preference keys captured before the transaction. This is
      // best-effort because a storage outage may also prevent rollback; all
      // malformed input has already been rejected before this point.
      if (preferenceMutationStarted) {
        try {
          await _restorePreferenceSnapshot(prefs, oldPreferences);
          await _restoreScopedPreferenceSnapshot(prefs, oldScopedPreferences);
          await _replaceUserPreferences(
            prefs,
            AppUserProfile.defaultUserId,
            oldDefaultUserPreferences,
          );
        } catch (_) {}
        try {
          await aiConfig.restoreBackupJson(oldAi, requirePersistence: true);
        } catch (_) {}
        try {
          await aiConfig.restoreVoiceBackupJson(oldVoice);
        } catch (_) {}
        try {
          await theme.restoreBackupJson(oldAppearance);
        } catch (_) {}
        try {
          await GlobalSettingsService.restoreLyricDisplay(oldLyricDisplay);
        } catch (_) {}
        try {
          await player.restoreBackupJson(oldPlayerSettings);
        } catch (_) {}
        try {
          await player.setApiKey(oldApiKey);
        } catch (_) {}
        try {
          await player.restoreBilibiliAccountBackupJson(oldBilibiliAccount);
        } catch (_) {}
      }
      for (final fileName in createdAvatars) {
        try {
          await users.avatarStorage.delete(fileName);
        } catch (_) {}
      }
      if (preparationStarted) {
        try {
          await player.cancelPreparedUserSwitch();
        } catch (_) {}
      }
      if (profileRestoreAttempted) {
        try {
          // UserController has already restored the old profiles here. Reload
          // once more after preference rollback so its session cannot retain
          // values read from the failed snapshot.
          await users.reloadActiveSession();
        } catch (_) {}
      }
      rethrow;
    }
  }

  static Map<String, dynamic> _requiredMap(
    Map<String, dynamic> parent,
    String key,
    String label,
  ) {
    final value = parent[key];
    if (value is! Map) throw FormatException('备份文件中的$label格式错误');
    return Map<String, dynamic>.from(value);
  }

  static Future<void> _replacePreferenceMap(
    SharedPreferences prefs,
    Map<String, dynamic> values, {
    Set<String> exclude = const {},
  }) async {
    for (final key in prefs.getKeys().toList(growable: false)) {
      if (exclude.contains(key) || UserDataScope.isScopedPreferenceKey(key)) {
        continue;
      }
      if (!_legacyUserPreferenceKeys.contains(key) &&
          !values.containsKey(key)) {
        await prefs.remove(key);
      }
    }
    for (final entry in values.entries) {
      if (exclude.contains(entry.key)) continue;
      await _setPreference(prefs, entry.key, entry.value);
    }
  }

  static Future<void> _replaceUserPreferences(
    SharedPreferences prefs,
    String userId,
    dynamic rawValues,
  ) async {
    _validatePreferenceMap(rawValues, '用户配置');
    final values = rawValues is Map
        ? Map<String, dynamic>.from(rawValues)
        : const <String, dynamic>{};
    final scope = UserDataScope(userId);
    final existing = prefs
        .getKeys()
        .where((key) {
          if (scope.isDefault) return _legacyUserPreferenceKeys.contains(key);
          return key.startsWith(scope.preferencePrefix);
        })
        .toList(growable: false);
    for (final key in existing) {
      final plain = scope.isDefault
          ? key
          : key.substring(scope.preferencePrefix.length);
      if (!values.containsKey(plain)) await prefs.remove(key);
    }
    for (final entry in values.entries) {
      final key = scope.isDefault ? entry.key : scope.preferenceKey(entry.key);
      await _setPreference(prefs, key, entry.value);
    }
  }

  static Future<void> _writeFullUserData(
    SharedPreferences prefs,
    _FullUserSnapshot item,
  ) async {
    final data = item.data;
    final scope = UserDataScope(item.profile.id);
    await _replaceUserPreferences(prefs, item.profile.id, data['preferences']);
    final songs = List<dynamic>.from(data['songs'] as List);
    final bilibili = List<dynamic>.from(data['bilibili'] as List);
    await _setPreference(
      prefs,
      scope.preferenceKey('favorites'),
      jsonEncode([...songs, ...bilibili]),
    );
    await _setPreference(
      prefs,
      scope.preferenceKey('favorite_playlists'),
      jsonEncode(data['playlists']),
    );
    final search = SearchSession.decodeBackupJson(
      Map<String, dynamic>.from(data['searchHistory'] as Map),
    );
    await _setPreference(
      prefs,
      scope.preferenceKey('search_history'),
      List<String>.of(search),
    );
    final history = PlaybackHistoryService.decodeBackupJson(
      Map<String, dynamic>.from(data['playbackHistory'] as Map),
    );
    await _setPreference(
      prefs,
      scope.preferenceKey(PlaybackHistoryService.preferenceKey),
      jsonEncode(
        history.map((entry) => entry.toJson()).toList(growable: false),
      ),
    );
    final playbackState = data['playbackState'];
    final playbackKey = scope.preferenceKey(PlaybackStateService.preferenceKey);
    if (playbackState == null) {
      await prefs.remove(playbackKey);
    } else {
      await _setPreference(prefs, playbackKey, jsonEncode(playbackState));
    }
  }

  static Future<void> _removeUnlistedScopedPreferences(
    SharedPreferences prefs,
    Set<String> userIds,
  ) async {
    final keys = prefs
        .getKeys()
        .where((key) {
          if (!UserDataScope.isScopedPreferenceKey(key)) return false;
          return !userIds.any(
            (id) => key.startsWith(UserDataScope(id).preferencePrefix),
          );
        })
        .toList(growable: false);
    for (final key in keys) {
      if (!await prefs.remove(key)) throw StateError('清理旧用户配置失败');
    }
  }

  static Future<void> _setPreference(
    SharedPreferences prefs,
    String key,
    dynamic value,
  ) async {
    final saved = switch (value) {
      bool value => await prefs.setBool(key, value),
      int value => await prefs.setInt(key, value),
      double value => await prefs.setDouble(key, value),
      String value => await prefs.setString(key, value),
      List value when value.every((item) => item is String) =>
        await prefs.setStringList(key, value.cast<String>()),
      _ => false,
    };
    if (!saved) throw StateError('保存备份配置失败');
  }

  static Future<void> _restorePreferenceSnapshot(
    SharedPreferences prefs,
    Map<String, Object?> values,
  ) async {
    final current = prefs.getKeys().toList(growable: false);
    for (final key in current) {
      if (_excludedGlobalPreferenceKeys.contains(key) ||
          UserDataScope.isScopedPreferenceKey(key) ||
          _legacyUserPreferenceKeys.contains(key)) {
        continue;
      }
      if (!values.containsKey(key)) await prefs.remove(key);
    }
    for (final entry in values.entries) {
      if (entry.value != null) {
        await _setPreference(prefs, entry.key, entry.value);
      }
    }
  }

  static Future<void> _restoreScopedPreferenceSnapshot(
    SharedPreferences prefs,
    Map<String, Object?> values,
  ) async {
    final current = prefs
        .getKeys()
        .where(UserDataScope.isScopedPreferenceKey)
        .toList(growable: false);
    for (final key in current) {
      if (!values.containsKey(key) && !await prefs.remove(key)) {
        throw StateError('回滚用户配置失败');
      }
    }
    for (final entry in values.entries) {
      if (entry.value != null) {
        await _setPreference(prefs, entry.key, entry.value);
      }
    }
  }

  static dynamic _decodeJson(String raw) {
    _ensureWithinLimit(raw);
    try {
      return jsonDecode(raw);
    } on FormatException {
      throw const FormatException('备份文件不是有效的 JSON');
    }
  }

  static void _ensureWithinLimit(String raw) {
    var byteLength = 0;
    for (var index = 0; index < raw.length; index++) {
      final codeUnit = raw.codeUnitAt(index);
      if (codeUnit <= 0x7f) {
        byteLength += 1;
      } else if (codeUnit <= 0x7ff) {
        byteLength += 2;
      } else if (codeUnit >= 0xd800 &&
          codeUnit <= 0xdbff &&
          index + 1 < raw.length &&
          raw.codeUnitAt(index + 1) >= 0xdc00 &&
          raw.codeUnitAt(index + 1) <= 0xdfff) {
        byteLength += 4;
        index++;
      } else {
        byteLength += 3;
      }
      if (byteLength > maxBackupBytes) {
        throw const FormatException('备份文件不能超过 12 MB');
      }
    }
  }

  static Map<String, dynamic>? _readAiBackupValue(dynamic decoded) {
    if (decoded is! Map || !decoded.containsKey('aiAssistant')) return null;
    final value = decoded['aiAssistant'];
    if (value is! Map) {
      throw const FormatException('备份文件中的 AI 助理数据格式错误');
    }
    return Map<String, dynamic>.from(value);
  }

  static Map<String, dynamic>? _readPlayerBackupValue(dynamic decoded) {
    if (decoded is! Map || !decoded.containsKey('playerSettings')) return null;
    final value = decoded['playerSettings'];
    if (value is! Map) {
      throw const FormatException('备份文件中的播放器设置格式错误');
    }
    return Map<String, dynamic>.from(value);
  }

  static Map<String, dynamic>? _readMapBackupValue(
    dynamic decoded,
    String key,
    String label,
  ) {
    if (decoded is! Map || !decoded.containsKey(key)) return null;
    final value = decoded[key];
    if (value is! Map) throw FormatException('备份文件中的$label格式错误');
    return Map<String, dynamic>.from(value);
  }

  static void _validateAppearanceBackup(Map<String, dynamic> json) {
    final mode = json['mode'];
    final scale = json['fontScale'];
    if (mode is! String ||
        !const {'system', 'light', 'dark'}.contains(mode) ||
        scale is! num ||
        !scale.isFinite ||
        scale < 0.5 ||
        scale > 1.5) {
      throw const FormatException('备份文件中的外观设置无效');
    }
  }

  static void _assertMatchingScopes(
    FavoriteService favorites,
    PlayerProvider player,
    SearchSession? search,
  ) {
    if (favorites.dataScope != player.dataScope ||
        search != null && search.dataScope != player.dataScope) {
      throw StateError('备份数据作用域不一致，已拒绝操作');
    }
  }

  static bool _sameUserProfiles(
    List<AppUserProfile> first,
    List<AppUserProfile> second,
  ) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      final a = first[index];
      final b = second[index];
      if (a.id != b.id ||
          a.name != b.name ||
          a.avatarId != b.avatarId ||
          a.avatarColorIndex != b.avatarColorIndex ||
          a.avatarFileName != b.avatarFileName) {
        return false;
      }
    }
    return true;
  }

  static bool _containsBilibili(List<dynamic> entries) {
    return entries.any((entry) {
      if (entry is! Map) return false;
      return entry['platform']?.toString() == MusicPlatform.bilibili.code;
    });
  }
}

class BackupRestoreResult {
  final int songsAdded;
  final int songsSkipped;
  final int songsTotal;
  final int bilibiliAdded;
  final int bilibiliSkipped;
  final int bilibiliTotal;
  final int playlistsAdded;
  final int playlistsSkipped;
  final bool apiKeyRestored;
  final bool aiConfigRestored;
  final bool playerSettingsRestored;
  final bool appearanceRestored;
  final bool lyricDisplayRestored;
  final bool bilibiliAccountRestored;
  final bool globalVoiceRestored;
  final bool searchHistoryRestored;
  final bool restoredToDefaultUser;
  final bool fullSnapshotRestored;

  const BackupRestoreResult({
    required this.songsAdded,
    required this.songsSkipped,
    required this.songsTotal,
    this.bilibiliAdded = 0,
    this.bilibiliSkipped = 0,
    this.bilibiliTotal = 0,
    required this.playlistsAdded,
    required this.playlistsSkipped,
    required this.apiKeyRestored,
    this.aiConfigRestored = false,
    this.playerSettingsRestored = false,
    this.appearanceRestored = false,
    this.lyricDisplayRestored = false,
    this.bilibiliAccountRestored = false,
    this.globalVoiceRestored = false,
    this.searchHistoryRestored = false,
    this.restoredToDefaultUser = false,
    this.fullSnapshotRestored = false,
  });

  BackupRestoreResult copyWith({bool? restoredToDefaultUser}) {
    return BackupRestoreResult(
      songsAdded: songsAdded,
      songsSkipped: songsSkipped,
      songsTotal: songsTotal,
      bilibiliAdded: bilibiliAdded,
      bilibiliSkipped: bilibiliSkipped,
      bilibiliTotal: bilibiliTotal,
      playlistsAdded: playlistsAdded,
      playlistsSkipped: playlistsSkipped,
      apiKeyRestored: apiKeyRestored,
      aiConfigRestored: aiConfigRestored,
      playerSettingsRestored: playerSettingsRestored,
      appearanceRestored: appearanceRestored,
      lyricDisplayRestored: lyricDisplayRestored,
      bilibiliAccountRestored: bilibiliAccountRestored,
      globalVoiceRestored: globalVoiceRestored,
      searchHistoryRestored: searchHistoryRestored,
      restoredToDefaultUser:
          restoredToDefaultUser ?? this.restoredToDefaultUser,
      fullSnapshotRestored: fullSnapshotRestored,
    );
  }
}

/// Decoded, validated representation of the versioned all-user backup.
///
/// These classes intentionally stay private to the backup orchestration layer:
/// callers should deal in [BackupRestoreResult] and never depend on the wire
/// format's internal representation.
class _FullSnapshot {
  final String activeUserId;
  final Map<String, dynamic> global;
  final List<_FullUserSnapshot> users;

  const _FullSnapshot({
    required this.activeUserId,
    required this.global,
    required this.users,
  });
}

class _FullUserSnapshot {
  final AppUserProfile profile;
  final Uint8List? avatarBytes;
  final Map<String, dynamic> data;

  const _FullUserSnapshot({
    required this.profile,
    required this.avatarBytes,
    required this.data,
  });
}
