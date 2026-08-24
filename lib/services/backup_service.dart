import 'dart:convert';

import '../models/song.dart';
import '../providers/ai_config_controller.dart';
import '../providers/player_provider.dart';
import '../providers/search_session.dart';
import '../providers/theme_controller.dart';
import '../services/bilibili_service.dart';
import '../services/favorite_service.dart';
import '../services/global_settings_service.dart';
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
  static const maxBackupBytes = 5 * 1024 * 1024;

  const BackupService._();

  static BackupRestoreContents inspect(String raw) {
    final decoded = _decodeJson(raw);

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

  static Future<BackupRestoreResult> importJson({
    required String raw,
    required FavoriteService favorites,
    required PlayerProvider player,
    AiConfigController? aiConfig,
    ThemeController? theme,
    SearchSession? search,
    FavoriteImportMode mode = FavoriteImportMode.merge,
    Iterable<BackupRestoreSection>? sections,
  }) async {
    final decoded = _decodeJson(raw);
    _assertMatchingScopes(favorites, player, search);
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

  static dynamic _decodeJson(String raw) {
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
        throw const FormatException('备份文件不能超过 5 MB');
      }
    }
    try {
      return jsonDecode(raw);
    } on FormatException {
      throw const FormatException('备份文件不是有效的 JSON');
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
    );
  }
}
