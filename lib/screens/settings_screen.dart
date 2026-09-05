import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ai_assistant.dart';
import '../models/app_user.dart';
import '../models/song.dart';
import '../providers/ai_assistant_controller.dart';
import '../providers/ai_config_controller.dart';
import '../providers/player_provider.dart';
import '../providers/theme_controller.dart';
import '../providers/user_controller.dart';
import '../services/audio_cache_service.dart';
import '../services/app_exit_service.dart';
import '../services/batch_favorite_import_service.dart';
import '../services/favorite_service.dart';
import '../services/floating_capsule_service.dart';
import '../services/lan_ai_config_service.dart';
import '../services/lan_api_key_service.dart';
import '../services/lan_favorite_import_service.dart';
import '../services/user_data_scope.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import '../theme/lyric_style.dart';
import '../widgets/bilibili_login_dialog.dart';
import '../widgets/ai_profile_editor_dialog.dart';
import '../widgets/remote_focusable.dart';
import '../widgets/app_user_avatar.dart';
import '../widgets/user_profile_editor_dialog.dart';
import 'backup_restore_screen.dart';
import 'cache_list_screen.dart';
import 'favorites_screen.dart';
import 'playback_history_screen.dart';
import 'playback_source_config_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  final _apiKeyController = TextEditingController();
  bool _obscureKey = true;
  bool _apiKeyEdited = false;
  late final AiConfigController _aiConfigController;
  late final UserDataScope _dataScope;
  late final bool _ownsAiConfigController;
  double _petScaleDraft = AiConfigController.minPetScale + 0.35;
  double _duckingReductionDraft = AiConfigController
      .defaultDuckingReductionPercent
      .toDouble();

  String _versionName = '';
  String _versionCode = '';
  String _cacheSizeText = '';
  int _cacheCount = 0;
  LyricFontFamilyPreset _lyricFontFamily = LyricFontFamilyPreset.system;
  LyricFontWeightPreset _lyricFontWeight = LyricFontWeightPreset.medium;
  bool _waitingForFloatingPermission = false;
  bool _leftForFloatingPermission = false;
  bool _changingFloatingCapsule = false;
  bool _savingVoiceSettings = false;
  bool _batchFavoriteImportInProgress = false;
  int _batchFavoriteImportGeneration = 0;
  LanFavoriteImportSession? _activeFavoriteImportSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final player = context.read<PlayerProvider>();
    _dataScope = player.dataScope;
    final sharedAiConfig = Provider.of<AiConfigController?>(
      context,
      listen: false,
    );
    _ownsAiConfigController = sharedAiConfig == null;
    _aiConfigController =
        sharedAiConfig ??
        AiConfigController(
          dataScope: _dataScope,
          secretStore: MemoryAiSecretStore(),
        );
    _petScaleDraft = _aiConfigController.petScale;
    _duckingReductionDraft = _aiConfigController.duckingReductionPercent
        .toDouble();
    _aiConfigController.addListener(_syncAiConfigDrafts);
    _aiConfigController.ready.then((_) {
      if (mounted) {
        setState(() {
          _petScaleDraft = _aiConfigController.petScale;
          _duckingReductionDraft = _aiConfigController.duckingReductionPercent
              .toDouble();
        });
      }
    });
    _apiKeyController.text = player.apiKey;
    player.settingsReady.then((_) {
      if (mounted && !_apiKeyEdited) {
        _apiKeyController.text = player.apiKey;
      }
    });
    _loadVersion();
    _loadCacheInfo();
    _loadLyricStyleSettings();
  }

  void _syncAiConfigDrafts() {
    if (!mounted) return;
    final scale = _aiConfigController.petScale;
    final duckingReduction = _aiConfigController.duckingReductionPercent
        .toDouble();
    if ((_petScaleDraft - scale).abs() < 0.001 &&
        (_duckingReductionDraft - duckingReduction).abs() < 0.001) {
      return;
    }
    setState(() {
      _petScaleDraft = scale;
      _duckingReductionDraft = duckingReduction;
    });
  }

  Future<void> _setGlobalVoiceModel(AiVoiceModelKind model) async {
    if (_savingVoiceSettings || model == _aiConfigController.voiceModel) return;
    setState(() => _savingVoiceSettings = true);
    try {
      await _aiConfigController.setVoiceModel(model);
      if (model != AiVoiceModelKind.zipformerChinese && mounted) {
        final assistant = Provider.of<AiAssistantController?>(
          context,
          listen: false,
        );
        await assistant?.releasePreloadedVoiceModel();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('语音引擎保存失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _savingVoiceSettings = false);
    }
  }

  Future<void> _setVoiceLoadMode(AiVoiceLoadMode mode) async {
    if (_savingVoiceSettings || mode == _aiConfigController.voiceLoadMode) {
      return;
    }
    setState(() => _savingVoiceSettings = true);
    try {
      await _aiConfigController.setVoiceLoadMode(mode);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('语音加载方式保存失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _savingVoiceSettings = false);
    }
  }

  Future<void> _setBargeInMode(AiBargeInMode mode) async {
    if (_savingVoiceSettings || mode == _aiConfigController.bargeInMode) {
      return;
    }
    setState(() => _savingVoiceSettings = true);
    try {
      await _aiConfigController.setBargeInMode(mode);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('自动打断设置保存失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _savingVoiceSettings = false);
    }
  }

  Future<void> _setAssistantPlaybackMode(AiAssistantPlaybackMode mode) async {
    if (_savingVoiceSettings ||
        mode == _aiConfigController.assistantPlaybackMode) {
      return;
    }
    setState(() => _savingVoiceSettings = true);
    try {
      await _aiConfigController.setAssistantPlaybackMode(mode);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('助手播放方式保存失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _savingVoiceSettings = false);
    }
  }

  Future<void> _setDuckingReductionPercent(double value) async {
    final percent = value.round();
    if (_savingVoiceSettings ||
        percent == _aiConfigController.duckingReductionPercent) {
      return;
    }
    setState(() => _savingVoiceSettings = true);
    try {
      await _aiConfigController.setDuckingReductionPercent(percent);
    } catch (error) {
      if (mounted) {
        setState(() {
          _duckingReductionDraft = _aiConfigController.duckingReductionPercent
              .toDouble();
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('后台音量降低比例保存失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _savingVoiceSettings = false);
    }
  }

  Future<void> _loadVersion() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _versionName = pkg.version;
          _versionCode = pkg.buildNumber;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadCacheInfo() async {
    try {
      final results = await Future.wait([
        AudioCacheService.getCacheSize(scope: _dataScope),
        AudioCacheService.getCacheCount(scope: _dataScope),
      ]);
      if (!mounted) return;
      setState(() {
        _cacheSizeText = AudioCacheService.formatSize(results[0]);
        _cacheCount = results[1];
      });
    } catch (_) {}
  }

  Future<void> _loadLyricStyleSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final family = LyricFontFamilyPreset.fromValue(
        prefs.getString(LyricStylePreferences.fontFamilyKey),
      );
      final rawWeight = prefs.get(LyricStylePreferences.fontWeightKey);
      final weight = LyricFontWeightPreset.fromValue(
        rawWeight is num ? rawWeight.toInt() : null,
      );
      if (!mounted) return;
      setState(() {
        _lyricFontFamily = family;
        _lyricFontWeight = weight;
      });
    } catch (_) {}
  }

  Future<void> _setLyricFontFamily(LyricFontFamilyPreset family) async {
    if (_dataScope.isDeleted) return;
    if (_lyricFontFamily != family && mounted) {
      setState(() => _lyricFontFamily = family);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_dataScope.isDeleted) return;
      await prefs.setString(LyricStylePreferences.fontFamilyKey, family.value);
    } catch (_) {}
  }

  Future<void> _setLyricFontWeight(LyricFontWeightPreset weight) async {
    if (_dataScope.isDeleted) return;
    if (_lyricFontWeight != weight && mounted) {
      setState(() => _lyricFontWeight = weight);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_dataScope.isDeleted) return;
      await prefs.setInt(LyricStylePreferences.fontWeightKey, weight.value);
    } catch (_) {}
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除缓存'),
        content: Text('将删除 $_cacheCount 首已缓存歌曲（$_cacheSizeText），下次播放需重新联网。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    try {
      await AudioCacheService.clearCache(scope: _dataScope);
      await _loadCacheInfo();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('缓存已清除')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('清除缓存失败：$error')));
    }
  }

  Future<void> _showApiKeyQrInput(PlayerProvider player) async {
    FocusManager.instance.primaryFocus?.unfocus();
    late final LanApiKeySession session;
    try {
      session = await LanApiKeyService.start();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('启动扫码输入失败：$error')));
      return;
    }
    if (!mounted) {
      await session.stop();
      return;
    }

    final saveFuture = _receiveAndSaveApiKey(session, player);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) =>
            _ApiKeyQrDialog(session: session, saveFuture: saveFuture),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('扫码输入已中止：$error')));
      }
    } finally {
      try {
        await session.stop();
      } catch (_) {}
    }
    if (mounted) FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<bool> _receiveAndSaveApiKey(
    LanApiKeySession session,
    PlayerProvider player,
  ) async {
    final apiKey = await session.receivedApiKey;
    if (apiKey == null) return false;
    await player.setApiKey(apiKey);
    if (!mounted) return true;
    setState(() {
      _apiKeyController.text = apiKey;
      _apiKeyEdited = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('手机提交的 API Key 已保存'),
        duration: Duration(seconds: 2),
      ),
    );
    return true;
  }

  Future<void> _showBatchFavoriteImport() async {
    if (_batchFavoriteImportInProgress || !mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final generation = ++_batchFavoriteImportGeneration;
    setState(() => _batchFavoriteImportInProgress = true);

    LanFavoriteImportSession? session;
    Future<BatchFavoriteImportResult?>? importFuture;
    try {
      session = await LanFavoriteImportService.start();
      if (!mounted || generation != _batchFavoriteImportGeneration) return;
      _activeFavoriteImportSession = session;
      final receivedFuture = session.receivedSongNames;
      importFuture = _receiveAndAddFavoriteSongs(
        session,
        context.read<PlayerProvider>(),
        context.read<FavoriteService>(),
        generation,
      );
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _FavoriteImportQrDialog(
          session: session!,
          receivedFuture: receivedFuture,
          importFuture: importFuture!,
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('批量收藏失败：$error')));
      }
    } finally {
      if (identical(_activeFavoriteImportSession, session)) {
        _activeFavoriteImportSession = null;
      }
      try {
        await session?.stop();
      } catch (error, stackTrace) {
        debugPrint('关闭批量收藏局域网服务失败: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      if (importFuture != null) {
        try {
          await importFuture;
        } catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('匹配收藏歌曲失败：$error')));
          }
        }
      }
      if (mounted && generation == _batchFavoriteImportGeneration) {
        setState(() => _batchFavoriteImportInProgress = false);
      }
    }
  }

  Future<BatchFavoriteImportResult?> _receiveAndAddFavoriteSongs(
    LanFavoriteImportSession session,
    PlayerProvider player,
    FavoriteService favorites,
    int generation,
  ) async {
    final names = await session.receivedSongNames;
    if (names == null ||
        !mounted ||
        generation != _batchFavoriteImportGeneration) {
      return null;
    }
    final result = await BatchFavoriteImportService.import(
      api: player.api,
      favorites: favorites,
      songNames: names,
      isCancelled: () =>
          !mounted || generation != _batchFavoriteImportGeneration,
    );
    if (!mounted || result.cancelled) return result;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_favoriteImportMessage(result)),
        duration: const Duration(seconds: 4),
      ),
    );
    return result;
  }

  String _favoriteImportMessage(BatchFavoriteImportResult result) {
    final parts = <String>['新增 ${result.added} 首'];
    if (result.alreadyFavorite > 0) {
      parts.add('${result.alreadyFavorite} 首已收藏');
    }
    if (result.notFound.isNotEmpty) {
      final preview = result.notFound.take(3).join('、');
      final remaining = result.notFound.length - 3;
      parts.add(
        '未找到 $preview${remaining > 0 ? ' 等 ${result.notFound.length} 首' : ''}',
      );
    }
    return parts.join('，');
  }

  Future<void> _selectAiProfile(AiAssistantProfile profile) async {
    try {
      await _aiConfigController.selectProfile(profile.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('切换模型配置失败：$error')));
    }
  }

  Future<String?> _askProfileName({String initial = ''}) async {
    var value = initial;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(initial.isEmpty ? '新增模型配置' : '重命名模型配置'),
        content: TextFormField(
          key: const ValueKey('ai-profile-name-dialog-field'),
          autofocus: true,
          initialValue: initial,
          maxLength: 40,
          decoration: const InputDecoration(labelText: '配置名称'),
          onChanged: (next) => value = next,
          onFieldSubmitted: (value) =>
              Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, value.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return result?.trim().isEmpty == true ? null : result?.trim();
  }

  Future<void> _createAiProfile() async {
    final name = await _askProfileName();
    if (name == null) return;
    try {
      final current = _aiConfigController.config;
      final profile = await _aiConfigController.createProfile(
        name: name,
        config: current.copyWith(model: ''),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已新增模型配置“${profile.name}”，请点击编辑填写完整参数')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('新增模型配置失败：$error')));
    }
  }

  Future<void> _renameAiProfile(AiAssistantProfile profile) async {
    await showDialog<void>(
      context: context,
      builder: (_) => AiProfileEditorDialog(
        controller: _aiConfigController,
        profile: profile,
        onScanConfig: _showAiConfigQrInput,
      ),
    );
  }

  Future<void> _deleteAiProfile(AiAssistantProfile profile) async {
    if (_aiConfigController.profiles.length <= 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('至少保留一个模型配置')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除模型配置？'),
        content: Text('将删除“${profile.name}”及其对应的中转站 Key。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _aiConfigController.deleteProfile(profile.id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败：$error')));
      }
    }
  }

  Future<AiAssistantConfig?> _showAiConfigQrInput(String profileId) async {
    FocusManager.instance.primaryFocus?.unfocus();
    late final LanAiConfigSession session;
    try {
      session = await LanAiConfigService.start();
    } catch (error) {
      if (!mounted) return null;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('启动扫码配置失败：$error')));
      return null;
    }
    if (!mounted) {
      await session.stop();
      return null;
    }
    final saveFuture = _receiveAndSaveAiConfig(session, profileId);
    final statusFuture = saveFuture.then((config) => config != null);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _AiConfigQrDialog(session: session, saveFuture: statusFuture),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('扫码配置已中止：$error')));
      }
    } finally {
      try {
        await session.stop();
      } catch (_) {}
    }
    if (mounted) FocusManager.instance.primaryFocus?.unfocus();
    return saveFuture;
  }

  Future<AiAssistantConfig?> _receiveAndSaveAiConfig(
    LanAiConfigSession session,
    String profileId,
  ) async {
    final received = await session.receivedConfig;
    if (received == null) return null;
    await _aiConfigController.updateProfile(profileId, config: received);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('手机提交的 AI 配置已安全保存'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    return received;
  }

  @override
  void dispose() {
    _batchFavoriteImportGeneration++;
    final activeFavoriteImport = _activeFavoriteImportSession;
    _activeFavoriteImportSession = null;
    if (activeFavoriteImport != null) unawaited(activeFavoriteImport.stop());
    WidgetsBinding.instance.removeObserver(this);
    _apiKeyController.dispose();
    _aiConfigController.removeListener(_syncAiConfigDrafts);
    if (_ownsAiConfigController) _aiConfigController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_waitingForFloatingPermission && state != AppLifecycleState.resumed) {
      _leftForFloatingPermission = true;
    }
    if (state == AppLifecycleState.resumed &&
        _waitingForFloatingPermission &&
        _leftForFloatingPermission) {
      unawaited(_finishFloatingPermissionRequest());
    }
  }

  /// 车机迷你窗开关：允许在其他应用上方持续查看当前歌曲。
  Future<void> _toggleFloatingCapsule(bool value) async {
    if (_changingFloatingCapsule) return;
    setState(() => _changingFloatingCapsule = true);
    try {
      if (value) {
        final hasPerm = await FloatingCapsuleService.hasPermission();
        if (!mounted) return;
        if (!hasPerm) {
          _waitingForFloatingPermission = true;
          _leftForFloatingPermission = false;
          final opened = await FloatingCapsuleService.openPermissionSettings();
          if (!mounted) return;
          if (!opened) {
            _waitingForFloatingPermission = false;
            _leftForFloatingPermission = false;
            _showFloatingMessage('无法打开悬浮窗权限设置，请在系统设置中手动授权');
          } else {
            _showFloatingMessage('授权后返回库仔音乐，迷你窗会自动开启');
          }
          return;
        }
        _waitingForFloatingPermission = false;
        _leftForFloatingPermission = false;
        final shown = await _enableFloatingCapsule();
        if (mounted) _announceFloatingEnableResult(shown);
      } else {
        _waitingForFloatingPermission = false;
        _leftForFloatingPermission = false;
        FloatingCapsuleService.setEnabled(false);
        await FloatingCapsuleService.hide();
        await FloatingCapsuleService.persistEnabled(false, scope: _dataScope);
        if (mounted) setState(() {});
      }
    } catch (error) {
      if (!mounted) return;
      _showFloatingMessage('车机迷你窗设置失败：$error');
    } finally {
      if (mounted) setState(() => _changingFloatingCapsule = false);
      if (mounted &&
          _waitingForFloatingPermission &&
          _leftForFloatingPermission &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(_finishFloatingPermissionRequest());
      }
    }
  }

  Future<void> _finishFloatingPermissionRequest() async {
    if (!_waitingForFloatingPermission || _changingFloatingCapsule) return;
    _waitingForFloatingPermission = false;
    _leftForFloatingPermission = false;
    if (mounted) setState(() => _changingFloatingCapsule = true);
    try {
      final granted = await FloatingCapsuleService.hasPermission();
      if (!mounted) return;
      if (!granted) {
        await FloatingCapsuleService.persistEnabled(false, scope: _dataScope);
        _showFloatingMessage('未获得悬浮窗权限，迷你窗未开启');
        return;
      }
      final shown = await _enableFloatingCapsule();
      if (mounted) _announceFloatingEnableResult(shown);
    } catch (error) {
      if (mounted) _showFloatingMessage('启用车机迷你窗失败：$error');
    } finally {
      if (mounted) setState(() => _changingFloatingCapsule = false);
    }
  }

  Future<bool?> _enableFloatingCapsule() async {
    if (!mounted) return false;
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    FloatingCapsuleService.setEnabled(true);
    bool? shown;
    if (song != null) {
      shown = await FloatingCapsuleService.show(
        title: song.name,
        artist: song.artist,
        coverUrl: song.coverUrl,
        isPlaying: player.isPlaying,
      );
    }
    await FloatingCapsuleService.persistEnabled(true, scope: _dataScope);
    if (mounted) setState(() {});
    return shown;
  }

  void _announceFloatingEnableResult(bool? shown) {
    if (shown == true) {
      _showFloatingMessage('车机迷你窗已开启');
    } else if (shown == null) {
      _showFloatingMessage('车机迷你窗已开启，播放歌曲后会自动显示');
    } else {
      _showFloatingMessage('权限已生效，窗口将在下次播放或返回应用时重试');
    }
  }

  void _showFloatingMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      body: SafeArea(
        child: isLandscape ? _buildLandscapeBody() : _buildPortraitBody(),
      ),
    );
  }

  Widget _buildPortraitBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        children: [
          _buildPageTitle(),
          _buildUsersCard(),
          _buildAppearanceCard(),
          _buildLyricsCard(),
          _buildLibraryCard(),
          _buildPlaybackCard(),
          _buildBilibiliAccountCard(),
          _buildApiCard(),
          AnimatedBuilder(
            animation: _aiConfigController,
            builder: (context, _) => _buildGlobalVoiceSettingsCard(),
          ),
          _buildAiAssistantCard(),
          _buildAboutCard(),
          _buildSystemActionsCard(),
        ],
      ),
    );
  }

  Widget _buildLandscapeBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = AppLayout.fromConstraints(context, constraints);
        final compact = layout.isCompactLandscape;
        return Column(
          children: [
            _buildPageTitle(layout: layout),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      key: const PageStorageKey(
                        'settings-landscape-preferences',
                      ),
                      padding: EdgeInsets.only(
                        left: compact ? 4 : 8,
                        right: compact ? 4 : 8,
                        bottom: compact ? 16 : 28,
                      ),
                      child: Column(
                        children: [
                          _buildUsersCard(compact: compact),
                          _buildAppearanceCard(compact: compact),
                          _buildLyricsCard(compact: compact),
                          _buildLibraryCard(compact: compact),
                          _buildPlaybackCard(compact: compact),
                        ],
                      ),
                    ),
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: AppColors.surfaceSoft,
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      key: const PageStorageKey('settings-landscape-system'),
                      padding: EdgeInsets.only(
                        left: compact ? 4 : 8,
                        right: compact ? 4 : 8,
                        bottom: compact ? 16 : 28,
                      ),
                      child: Column(
                        children: [
                          _buildBilibiliAccountCard(compact: compact),
                          _buildApiCard(compact: compact),
                          AnimatedBuilder(
                            animation: _aiConfigController,
                            builder: (context, _) =>
                                _buildGlobalVoiceSettingsCard(compact: compact),
                          ),
                          _buildAiAssistantCard(compact: compact),
                          _buildAboutCard(compact: compact),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPageTitle({bool compact = false, AppLayout? layout}) {
    final metrics = layout ?? AppLayout.fromContext(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 16 : 20,
        compact ? 10 : 16,
        compact ? 16 : 20,
        compact ? 4 : 4,
      ),
      child: Text(
        '设置',
        style: TextStyle(
          fontSize: metrics.pageTitleSize,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }

  Widget _buildAppearanceCard({bool compact = false}) {
    final layout = AppLayout.fromContext(context);
    return _buildCard(
      compact: compact,
      children: [
        _buildSectionHeader(icon: Icons.dark_mode_outlined, title: '外观'),
        Consumer<ThemeController>(
          builder: (ctx, themeCtrl, _) {
            final compactSegments =
                compact ||
                (themeCtrl.fontScale > ThemeController.defaultFontScale &&
                    MediaQuery.sizeOf(ctx).width < 1180);
            final fontScalePercent = (themeCtrl.fontScale * 100).round();
            final segments = compactSegments
                ? const [
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.system,
                      label: Text('系统'),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.light,
                      label: Text('浅色'),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.dark,
                      label: Text('深色'),
                    ),
                  ]
                : const [
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.system,
                      label: Text('跟随系统'),
                      icon: Icon(Icons.brightness_auto),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.light,
                      label: Text('浅色'),
                      icon: Icon(Icons.light_mode_outlined),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.dark,
                      label: Text('深色'),
                      icon: Icon(Icons.dark_mode_outlined),
                    ),
                  ];
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '深色模式',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '夜间使用深色配色，保护眼睛',
                    style: TextStyle(
                      fontSize: layout.secondarySize,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      segments: segments,
                      selected: {themeCtrl.mode},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) {
                        if (s.isNotEmpty) themeCtrl.setMode(s.first);
                      },
                      style: SegmentedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        textStyle: TextStyle(
                          fontSize: compact ? 16 : layout.bodySize,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '整体字号',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: compact ? 16 : layout.bodySize,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      Text(
                        '$fontScalePercent%',
                        key: const ValueKey('font-scale-value'),
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: compact ? 15 : layout.secondarySize,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        key: const ValueKey('font-scale-reset'),
                        tooltip: '恢复默认字号',
                        onPressed:
                            themeCtrl.fontScale ==
                                ThemeController.defaultFontScale
                            ? null
                            : () => themeCtrl.setFontScale(
                                ThemeController.defaultFontScale,
                              ),
                        icon: const Icon(Icons.restart_alt_rounded),
                      ),
                    ],
                  ),
                  Slider(
                    key: const ValueKey('font-scale-slider'),
                    value: themeCtrl.fontScale,
                    min: ThemeController.minFontScale,
                    max: ThemeController.maxFontScale,
                    divisions: 20,
                    label: '$fontScalePercent%',
                    semanticFormatterCallback: (value) =>
                        '${(value * 100).round()}%',
                    onChanged: themeCtrl.previewFontScale,
                    onChangeEnd: themeCtrl.setFontScale,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '50%',
                          style: TextStyle(
                            fontSize: layout.secondarySize,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        Text(
                          '150%',
                          style: TextStyle(
                            fontSize: layout.secondarySize,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 24),
                  SwitchListTile(
                    key: const ValueKey('floating-mini-window-toggle'),
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.picture_in_picture_alt_rounded),
                    title: const Text('车机迷你窗（置顶）'),
                    subtitle: Text(
                      _changingFloatingCapsule
                          ? '正在检查悬浮窗状态…'
                          : FloatingCapsuleService.enabled
                          ? '切换到其他应用后仍显示封面、歌名和歌手'
                          : '在其他应用上方显示当前歌曲信息（需悬浮窗权限）',
                      style: TextStyle(
                        fontSize: layout.secondarySize,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    value: FloatingCapsuleService.enabled,
                    onChanged: _changingFloatingCapsule
                        ? null
                        : _toggleFloatingCapsule,
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildUsersCard({bool compact = false}) {
    final users = Provider.of<UserController?>(context);
    if (users == null) return const SizedBox.shrink();
    return _buildCard(
      compact: compact,
      children: [
        Padding(
          padding: EdgeInsets.only(right: compact ? 8 : 12),
          child: Row(
            children: [
              Expanded(
                child: _buildSectionHeader(
                  icon: Icons.group_outlined,
                  title: '用户',
                ),
              ),
              IconButton(
                key: const ValueKey('user-add'),
                tooltip: '新增用户',
                onPressed:
                    users.switching ||
                        users.users.length >= UserController.maxUsers
                    ? null
                    : () => _editUser(users),
                icon: const Icon(Icons.person_add_alt_1_rounded),
              ),
            ],
          ),
        ),
        for (final user in users.users)
          ListTile(
            key: ValueKey('user-management-${user.id}'),
            dense: compact,
            leading: AppUserAvatar(user: user, size: compact ? 40 : 44),
            title: Text(
              user.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              user.id == users.activeUserId
                  ? '当前用户${user.isDefault ? ' · 系统默认' : ''}'
                  : user.isDefault
                  ? '系统默认'
                  : '独立数据空间',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: ValueKey('user-edit-${user.id}'),
                  tooltip: '编辑用户',
                  onPressed: users.switching
                      ? null
                      : () => _editUser(users, user),
                  icon: const Icon(Icons.edit_outlined),
                ),
                if (!user.isDefault)
                  IconButton(
                    key: ValueKey('user-delete-${user.id}'),
                    tooltip: '删除用户',
                    onPressed: users.switching
                        ? null
                        : () => _deleteUser(users, user),
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _editUser(UserController users, [AppUserProfile? user]) async {
    final draft = await showDialog<UserProfileDraft>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UserProfileEditorDialog(initialUser: user),
    );
    if (draft == null || !mounted) return;
    try {
      if (user == null) {
        await users.createUser(
          name: draft.name,
          avatarId: draft.avatarId,
          avatarColorIndex: draft.avatarColorIndex,
          customAvatarBytes: draft.customAvatarBytes,
        );
      } else {
        await users.updateUser(
          user.id,
          name: draft.name,
          avatarId: draft.avatarId,
          avatarColorIndex: draft.avatarColorIndex,
          customAvatarBytes: draft.customAvatarBytes,
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存用户失败：$error')));
    }
  }

  Future<void> _deleteUser(UserController users, AppUserProfile user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('user-delete-dialog'),
        title: const Text('删除用户？'),
        content: Text('将永久删除“${user.name}”的收藏、历史、配置、账号和缓存数据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('user-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await users.deleteUser(user.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除用户失败：$error')));
    }
  }

  Widget _buildLyricsCard({bool compact = false}) {
    final layout = AppLayout.fromContext(context);
    return _buildCard(
      compact: compact,
      children: [
        _buildSectionHeader(icon: Icons.lyrics_outlined, title: '歌词显示'),
        ListTile(
          key: const ValueKey('lyric-font-family-setting'),
          dense: compact,
          leading: const Icon(Icons.text_fields_rounded),
          title: const Text(
            '字体样式',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${_lyricFontFamily.label} · ${_lyricFontFamily.description}',
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: _showLyricFontFamilyPicker,
        ),
        const Divider(height: 1),
        ListTile(
          key: const ValueKey('lyric-font-weight-setting'),
          dense: compact,
          leading: const Icon(Icons.format_bold_rounded),
          title: const Text(
            '字体粗细',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text('${_lyricFontWeight.label} · 当前歌词会自动加粗'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: _showLyricFontWeightPicker,
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 12 : 16,
            compact ? 8 : 12,
            compact ? 12 : 16,
            compact ? 12 : 16,
          ),
          child: Container(
            key: const ValueKey('lyric-font-preview'),
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 12 : 16,
              vertical: compact ? 10 : 14,
            ),
            decoration: BoxDecoration(
              color: AppColors.surfaceSoft,
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '字体预览',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: layout.secondarySize,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '让音乐陪你一路前行',
                  key: const ValueKey('lyric-font-preview-text'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: compact ? 18 : layout.sectionTitleSize,
                    fontWeight: _lyricFontWeight.weight,
                    fontFamily: _lyricFontFamily.fontFamily,
                    fontFamilyFallback: _lyricFontFamily.fontFamilyFallback,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '字号与上下间距仍可在播放页的字体按钮中调节',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: layout.secondarySize,
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Consumer<PlayerProvider>(
          builder: (context, player, _) {
            final stepLabel = _formatLyricOffsetStep(player.lyricOffsetStep);
            return ListTile(
              key: const ValueKey('lyric-offset-step-setting'),
              dense: compact,
              leading: const Icon(Icons.timer_outlined),
              title: const Text(
                '歌词时延单次调节',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '播放页每次提前/延后 $stepLabel 秒',
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$stepLabel 秒'),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
              onTap: () => _showLyricOffsetStepPicker(player),
            );
          },
        ),
        const Divider(height: 1),
        Consumer<PlayerProvider>(
          builder: (context, player, _) {
            final order = player.bilibiliLyricPlatformOrder;
            return ListTile(
              key: const ValueKey('bilibili-lyric-platform-order-setting'),
              dense: compact,
              leading: const Icon(Icons.swap_vert_rounded),
              title: const Text(
                'B站歌词平台权重',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${order.map((platform) => platform.label).join(' > ')} · 仅影响B站歌词匹配',
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _showBilibiliLyricPlatformOrderPicker(player),
            );
          },
        ),
      ],
    );
  }

  Future<void> _showLyricOffsetStepPicker(PlayerProvider player) async {
    final selected = await showDialog<Duration>(
      context: context,
      builder: (dialogContext) {
        var milliseconds = player.lyricOffsetStep.inMilliseconds;
        final minimum = PlayerProvider.minLyricOffsetStep.inMilliseconds;
        final maximum = PlayerProvider.maxLyricOffsetStep.inMilliseconds;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final value = Duration(milliseconds: milliseconds);
            final valueLabel = _formatLyricOffsetStep(value);
            return AlertDialog(
              key: const ValueKey('lyric-offset-step-dialog'),
              title: const Text('歌词时延单次调节'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Expanded(child: Text('每次提前或延后')),
                        Text(
                          '$valueLabel 秒',
                          key: const ValueKey('lyric-offset-step-value'),
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      key: const ValueKey('lyric-offset-step-slider'),
                      value: milliseconds.toDouble(),
                      min: minimum.toDouble(),
                      max: maximum.toDouble(),
                      divisions: (maximum - minimum) ~/ 100,
                      label: '$valueLabel 秒',
                      semanticFormatterCallback: (rawValue) =>
                          '${_formatLyricOffsetStep(Duration(milliseconds: rawValue.round()))} 秒',
                      onChanged: (rawValue) => setDialogState(() {
                        milliseconds = (rawValue / 100).round() * 100;
                      }),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: const [Text('0.1 秒'), Text('2.0 秒')],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => setDialogState(() {
                    milliseconds =
                        PlayerProvider.defaultLyricOffsetStep.inMilliseconds;
                  }),
                  child: const Text('恢复默认'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const ValueKey('lyric-offset-step-save'),
                  onPressed: () => Navigator.pop(
                    dialogContext,
                    Duration(milliseconds: milliseconds),
                  ),
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    if (selected == null) return;
    try {
      await player.setLyricOffsetStep(selected);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存歌词时延失败：$error')));
    }
  }

  String _formatLyricOffsetStep(Duration step) {
    final milliseconds = step.inMilliseconds;
    return milliseconds % 1000 == 0
        ? '${milliseconds ~/ 1000}'
        : (milliseconds / 1000).toStringAsFixed(1);
  }

  Future<void> _showBilibiliLyricPlatformOrderPicker(
    PlayerProvider player,
  ) async {
    final selected = await showDialog<List<MusicPlatform>>(
      context: context,
      builder: (dialogContext) {
        var order = player.bilibiliLyricPlatformOrder;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            key: const ValueKey('bilibili-lyric-platform-order-dialog'),
            title: const Text('B站歌词平台优先级'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var index = 0; index < order.length; index++)
                  ListTile(
                    key: ValueKey(
                      'bilibili-lyric-platform-order-${order[index].code}',
                    ),
                    dense: true,
                    leading: Text(
                      '${index + 1}',
                      style: const TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    title: Text(order[index].label),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: ValueKey(
                            'bilibili-lyric-platform-order-${order[index].code}-up',
                          ),
                          tooltip: '上移',
                          onPressed: index == 0
                              ? null
                              : () => setDialogState(() {
                                  final next = List<MusicPlatform>.from(order);
                                  final moved = next.removeAt(index);
                                  next.insert(index - 1, moved);
                                  order = next;
                                }),
                          icon: const Icon(Icons.keyboard_arrow_up_rounded),
                        ),
                        IconButton(
                          key: ValueKey(
                            'bilibili-lyric-platform-order-${order[index].code}-down',
                          ),
                          tooltip: '下移',
                          onPressed: index == order.length - 1
                              ? null
                              : () => setDialogState(() {
                                  final next = List<MusicPlatform>.from(order);
                                  final moved = next.removeAt(index);
                                  next.insert(index + 1, moved);
                                  order = next;
                                }),
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, order),
                child: const Text('保存'),
              ),
            ],
          ),
        );
      },
    );
    if (selected != null) {
      try {
        await player.setBilibiliLyricPlatformOrder(selected);
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存歌词平台顺序失败：$error')));
      }
    }
  }

  Future<void> _showLyricFontFamilyPicker() async {
    final selected = await showDialog<LyricFontFamilyPreset>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        key: const ValueKey('lyric-font-family-dialog'),
        title: const Text('选择歌词字体'),
        children: LyricFontFamilyPreset.values.map((preset) {
          final selected = preset == _lyricFontFamily;
          return SimpleDialogOption(
            key: ValueKey('lyric-font-family-${preset.value}'),
            onPressed: () => Navigator.pop(dialogContext, preset),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 9),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: selected ? AppColors.primary : AppColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${preset.label}　春风又绿江南岸',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: preset.fontFamily,
                      fontFamilyFallback: preset.fontFamilyFallback,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
    if (selected != null) await _setLyricFontFamily(selected);
  }

  Future<void> _showLyricFontWeightPicker() async {
    final selected = await showDialog<LyricFontWeightPreset>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        key: const ValueKey('lyric-font-weight-dialog'),
        title: const Text('选择字体粗细'),
        children: LyricFontWeightPreset.values.map((preset) {
          final selected = preset == _lyricFontWeight;
          return SimpleDialogOption(
            key: ValueKey('lyric-font-weight-${preset.value}'),
            onPressed: () => Navigator.pop(dialogContext, preset),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 9),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: selected ? AppColors.primary : AppColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${preset.label}　让音乐陪你一路前行',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: preset.weight,
                      fontFamily: _lyricFontFamily.fontFamily,
                      fontFamilyFallback: _lyricFontFamily.fontFamilyFallback,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
    if (selected != null) await _setLyricFontWeight(selected);
  }

  Widget _buildPlaybackCard({bool compact = false}) {
    final layout = AppLayout.fromContext(context);
    return _buildCard(
      compact: compact,
      children: [
        _buildSectionHeader(icon: Icons.graphic_eq, title: '播放与音质'),
        Consumer<PlayerProvider>(
          builder: (ctx, player, _) {
            return Column(
              children: [
                ListTile(
                  dense: compact,
                  leading: const Icon(Icons.audiotrack),
                  title: const Text('网易云音质'),
                  subtitle: Text(player.neteaseLevel.label),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showNeteaseLevelPicker(ctx, player),
                ),
                ListTile(
                  dense: compact,
                  leading: const Icon(Icons.library_music),
                  title: const Text('QQ / 酷狗音质'),
                  subtitle: Text(player.commonLevel.label),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showCommonLevelPicker(ctx, player),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '平台播放源',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: compact ? 16 : layout.bodySize,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                ...configurableMusicPlatforms.map((platform) {
                  final source = player.playbackSourceFor(platform);
                  return ListTile(
                    key: ValueKey('playback-source-${platform.code}'),
                    dense: compact,
                    leading: Icon(switch (source) {
                      PlaybackSource.automatic => Icons.alt_route_rounded,
                      PlaybackSource.chksz => Icons.key_outlined,
                      PlaybackSource.qingMusic => Icons.cloud_outlined,
                      PlaybackSource.hyw => Icons.hub_outlined,
                      PlaybackSource.xinghai => Icons.auto_awesome_outlined,
                      PlaybackSource.gdStudio => Icons.backup_outlined,
                    }),
                    title: Text(
                      '${platform.label}播放源',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _playbackSourceDescription(
                        source,
                        enabled: player.playbackSourceConfig.isEnabled(source),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () =>
                        _showPlaybackSourcePicker(ctx, player, platform),
                  );
                }),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('playback-source-config'),
                  dense: compact,
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('备用源接口配置'),
                  subtitle: const Text(
                    '勾选参与竞速的接口，修改预置字段并测试连通性/响应速度',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    FocusManager.instance.primaryFocus?.unfocus();
                    final player = context.read<PlayerProvider>();
                    await player.settingsReady;
                    if (!mounted) return;
                    await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => const PlaybackSourceConfigScreen(),
                      ),
                    );
                    if (mounted) FocusManager.instance.primaryFocus?.unfocus();
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('mv-player-mode'),
                  dense: compact,
                  leading: const Icon(Icons.ondemand_video_rounded),
                  title: const Text(
                    'MV 播放器',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    switch (player.videoPlayerMode) {
                      VideoPlayerMode.automatic => '自动兼容 · Exo 失败后切换 MPV',
                      VideoPlayerMode.mpv => 'MPV · 更广的格式和车机兼容性',
                      VideoPlayerMode.exo => 'ExoPlayer · Android 原生内核',
                    },
                    maxLines: compact ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _showVideoPlayerModePicker(ctx, player),
                ),
                ExpansionTile(
                  tilePadding: compact
                      ? const EdgeInsets.symmetric(horizontal: 8)
                      : null,
                  leading: const Icon(Icons.info_outline),
                  title: const Text('音质说明'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  children: [
                    _buildQualityRow('QQ音乐', CommonLevel.values),
                    const SizedBox(height: 6),
                    _buildQualityRow('网易云', NeteaseLevel.values),
                    const SizedBox(height: 6),
                    _buildQualityRow('酷狗音乐', CommonLevel.values),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(AppRadius.control),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.warning_amber,
                            color: Colors.orange[700],
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '高音质（无损/Hi-Res/母带）加载更慢，部分歌曲可能受版权限制无法播放。',
                              style: TextStyle(
                                fontSize: layout.secondarySize,
                                color: Colors.orange[800],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildLibraryCard({bool compact = false}) {
    return _buildCard(
      compact: compact,
      children: [
        _buildSectionHeader(icon: Icons.library_music_outlined, title: '音乐库'),
        Consumer<FavoriteService>(
          builder: (context, favorites, _) => ListTile(
            dense: compact,
            leading: const Icon(Icons.favorite, color: Colors.redAccent),
            title: const Text('我的收藏'),
            subtitle: Text(
              '${favorites.favorites.length} 首歌曲 · '
              '${favorites.favoritePlaylists.length} 个歌单 · '
              '${favorites.bilibiliFavorites.length} 个B站收藏',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FavoriteSongsScreen()),
            ),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          key: const ValueKey('batch-favorite-import'),
          dense: compact,
          leading: const Icon(Icons.playlist_add_rounded),
          title: const Text('批量加入收藏歌曲'),
          subtitle: const Text('手机扫码输入歌名，使用“、”分隔'),
          trailing: _batchFavoriteImportInProgress
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : const Icon(Icons.qr_code_rounded),
          onTap: _batchFavoriteImportInProgress
              ? null
              : () => unawaited(_showBatchFavoriteImport()),
        ),
        const Divider(height: 1),
        Consumer<PlayerProvider>(
          builder: (context, player, _) => ListTile(
            dense: compact,
            leading: const Icon(Icons.history_rounded),
            title: const Text('播放历史'),
            subtitle: Text('${player.playbackHistory.length} 条记录，可从断点继续'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PlaybackHistoryScreen()),
            ),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          dense: compact,
          leading: const Icon(Icons.cloud_sync_outlined),
          title: const Text('备份与还原'),
          subtitle: const Text('文件、WebDAV 或手机局域网传输'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const BackupRestoreScreen()),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          dense: compact,
          leading: const Icon(Icons.download_done_outlined),
          title: const Text('已缓存歌曲'),
          subtitle: Text(
            _cacheSizeText.isEmpty
                ? '播放过的歌曲自动缓存'
                : '$_cacheCount 首 · $_cacheSizeText',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_cacheCount > 0)
                IconButton(
                  tooltip: '清除缓存',
                  onPressed: _clearCache,
                  icon: const Icon(Icons.delete_outline),
                ),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CacheListScreen()),
            );
            await _loadCacheInfo();
          },
        ),
      ],
    );
  }

  Widget _buildBilibiliAccountCard({bool compact = false}) {
    return _buildCard(
      compact: compact,
      children: [
        _buildSectionHeader(
          icon: Icons.video_collection_outlined,
          title: 'B站账号',
        ),
        Consumer<PlayerProvider>(
          builder: (context, player, _) {
            final user = player.bilibiliUser;
            final loading = player.bilibiliAccountLoading;
            return ListTile(
              key: const ValueKey('bilibili-account-setting'),
              dense: compact,
              leading: CircleAvatar(
                backgroundColor: PlatformColors.bilibili.withValues(
                  alpha: 0.14,
                ),
                child: loading
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        user == null
                            ? Icons.qr_code_2_rounded
                            : Icons.person_rounded,
                        color: PlatformColors.bilibili,
                      ),
              ),
              title: Text(
                user?.name ?? '扫码登录 B站',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                user == null ? '登录后可使用账号对应的视频清晰度权限' : 'UID ${user.mid} · 已登录',
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: user == null
                  ? const Icon(Icons.chevron_right_rounded)
                  : IconButton(
                      key: const ValueKey('bilibili-logout-action'),
                      tooltip: '退出 B站账号',
                      onPressed: loading ? null : () => _logoutBilibili(player),
                      icon: const Icon(Icons.logout_rounded),
                    ),
              onTap: loading || user != null
                  ? null
                  : () => _openBilibiliLogin(player),
            );
          },
        ),
      ],
    );
  }

  Future<void> _openBilibiliLogin(PlayerProvider player) async {
    try {
      final loggedIn = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const BilibiliLoginDialog(),
      );
      if (loggedIn != true || !mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('B站账号登录成功')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('B站登录失败：$error')));
    }
  }

  Future<void> _logoutBilibili(PlayerProvider player) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出 B站账号'),
        content: const Text('将清除本机保存的 B站登录信息。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await player.logoutBilibili();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已退出 B站账号')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('退出 B站失败：$error')));
    }
  }

  Widget _buildApiCard({bool compact = false}) {
    final layout = AppLayout.fromContext(context);
    return _buildCard(
      compact: compact,
      children: [
        _buildSectionHeader(icon: Icons.key, title: 'API 配置'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ChKSz API Key',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: layout.bodySize,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '用于 ChKSz 或自动备用链；未填写时自动模式会跳过 ChKSz',
                style: TextStyle(
                  fontSize: layout.secondarySize,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              RemoteTextFieldTraversal(
                controller: _apiKeyController,
                child: TextField(
                  key: const ValueKey('api-key-field'),
                  controller: _apiKeyController,
                  obscureText: _obscureKey,
                  onChanged: (_) => _apiKeyEdited = true,
                  decoration: InputDecoration(
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureKey ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () =>
                          setState(() => _obscureKey = !_obscureKey),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () async {
                      final player = context.read<PlayerProvider>();
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        await player.setApiKey(_apiKeyController.text.trim());
                        if (!mounted) return;
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('API Key 已保存'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      } catch (error) {
                        if (!mounted) return;
                        messenger.showSnackBar(
                          SnackBar(content: Text('API Key 保存失败：$error')),
                        );
                      }
                    },
                    icon: const Icon(Icons.save),
                    label: const Text('保存'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('api-key-qr-input'),
                    onPressed: () =>
                        _showApiKeyQrInput(context.read<PlayerProvider>()),
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text('手机扫码输入'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _showApiKeyHelp(context),
                    icon: const Icon(Icons.help_outline),
                    label: const Text('如何获取？'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAiProfileList(AppLayout layout) {
    final profiles = _aiConfigController.profiles;
    return Container(
      key: const ValueKey('ai-profile-list'),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceSoft,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.layers_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '模型配置',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: layout.bodySize,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('ai-profile-add'),
                tooltip: '新增模型配置',
                onPressed: _createAiProfile,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          if (profiles.isEmpty)
            const Padding(padding: EdgeInsets.all(12), child: Text('还没有模型配置'))
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: profiles.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final profile = profiles[index];
                final selected =
                    profile.id == _aiConfigController.activeProfileId;
                final model = profile.config.model.trim();
                return ListTile(
                  key: ValueKey('ai-profile-${profile.id}'),
                  dense: layout.isCompactLandscape,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: selected ? AppColors.primary : AppColors.textHint,
                  ),
                  title: Text(
                    profile.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${profile.config.provider.label} · ${model.isEmpty ? '未填写模型' : model}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: selected ? null : () => _selectAiProfile(profile),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      KeyedSubtree(
                        key: ValueKey('ai-profile-edit-${profile.id}'),
                        child: IconButton(
                          key: ValueKey('ai-profile-rename-${profile.id}'),
                          tooltip: '编辑模型配置',
                          onPressed: () => _renameAiProfile(profile),
                          icon: const Icon(Icons.edit_outlined, size: 20),
                        ),
                      ),
                      IconButton(
                        key: ValueKey('ai-profile-delete-${profile.id}'),
                        tooltip: '删除',
                        onPressed: profiles.length <= 1
                            ? null
                            : () => _deleteAiProfile(profile),
                        icon: const Icon(Icons.delete_outline, size: 20),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildGlobalVoiceSettingsCard({bool compact = false}) {
    final layout = AppLayout.fromContext(context);
    final voiceModel = _aiConfigController.voiceModel;
    final loadMode = _aiConfigController.voiceLoadMode;
    final bargeInMode = _aiConfigController.bargeInMode;
    final playbackMode = _aiConfigController.assistantPlaybackMode;
    final ducksPlayback = playbackMode == AiAssistantPlaybackMode.duck;
    final supportsPreload = voiceModel == AiVoiceModelKind.zipformerChinese;
    final supportsBargeIn =
        voiceModel == AiVoiceModelKind.zipformerChinese ||
        voiceModel == AiVoiceModelKind.doubaoIme;
    return _buildCard(
      compact: compact,
      children: [
        _buildSectionHeader(icon: Icons.mic_none_rounded, title: '全局语音设置'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<AiVoiceModelKind>(
                key: ValueKey('global-voice-engine-${voiceModel.value}'),
                initialValue: voiceModel,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '语音输入引擎',
                  helperText: '对所有 AI 模型配置生效',
                ),
                items: AiVoiceModelKind.values
                    .map(
                      (model) => DropdownMenuItem(
                        value: model,
                        child: Text(
                          model.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _savingVoiceSettings
                    ? null
                    : (model) {
                        if (model != null) {
                          unawaited(_setGlobalVoiceModel(model));
                        }
                      },
              ),
              const SizedBox(height: 12),
              Text(
                'Zipformer 加载方式',
                style: TextStyle(
                  color: supportsPreload
                      ? AppColors.textPrimary
                      : AppColors.textHint,
                  fontSize: layout.secondarySize,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<AiVoiceLoadMode>(
                  key: const ValueKey('global-voice-load-mode'),
                  segments: AiVoiceLoadMode.values
                      .map(
                        (mode) => ButtonSegment<AiVoiceLoadMode>(
                          value: mode,
                          label: Text(
                            mode.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  selected: {loadMode},
                  showSelectedIcon: false,
                  expandedInsets: EdgeInsets.zero,
                  onSelectionChanged: !supportsPreload || _savingVoiceSettings
                      ? null
                      : (selection) {
                          if (selection.isNotEmpty) {
                            unawaited(_setVoiceLoadMode(selection.first));
                          }
                        },
                ),
              ),
              const SizedBox(height: 6),
              Text(
                supportsPreload ? '加载方式将在下次完整启动应用时生效' : '车机系统语音和豆包语音保持使用时初始化',
                style: TextStyle(
                  color: AppColors.textHint,
                  fontSize: layout.secondarySize,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '触发助手时的音乐状态',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: layout.secondarySize,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<AiAssistantPlaybackMode>(
                  key: const ValueKey('global-voice-playback-mode'),
                  segments: AiAssistantPlaybackMode.values
                      .map(
                        (mode) => ButtonSegment<AiAssistantPlaybackMode>(
                          value: mode,
                          label: Text(
                            mode.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  selected: {playbackMode},
                  showSelectedIcon: false,
                  expandedInsets: EdgeInsets.zero,
                  onSelectionChanged: _savingVoiceSettings
                      ? null
                      : (selection) {
                          if (selection.isNotEmpty) {
                            unawaited(
                              _setAssistantPlaybackMode(selection.first),
                            );
                          }
                        },
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '后台播放降低比例',
                      style: TextStyle(
                        color: ducksPlayback
                            ? AppColors.textPrimary
                            : AppColors.textHint,
                        fontSize: layout.secondarySize,
                      ),
                    ),
                  ),
                  Text(
                    '${_duckingReductionDraft.round()}%',
                    key: const ValueKey('global-voice-ducking-reduction-value'),
                    style: TextStyle(
                      color: ducksPlayback
                          ? AppColors.primary
                          : AppColors.textHint,
                      fontSize: layout.secondarySize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              Slider.adaptive(
                key: const ValueKey('global-voice-ducking-reduction'),
                value: _duckingReductionDraft,
                min: AiConfigController.minDuckingReductionPercent.toDouble(),
                max: AiConfigController.maxDuckingReductionPercent.toDouble(),
                divisions:
                    (AiConfigController.maxDuckingReductionPercent -
                        AiConfigController.minDuckingReductionPercent) ~/
                    10,
                label: '降低 ${_duckingReductionDraft.round()}%',
                onChanged: !ducksPlayback || _savingVoiceSettings
                    ? null
                    : (value) {
                        setState(() => _duckingReductionDraft = value);
                      },
                onChangeEnd: !ducksPlayback || _savingVoiceSettings
                    ? null
                    : (value) => unawaited(_setDuckingReductionPercent(value)),
              ),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                key: const ValueKey('global-voice-barge-in'),
                contentPadding: EdgeInsets.zero,
                title: const Text('播报时自动打断'),
                subtitle: Text(
                  supportsBargeIn ? '检测到连续人声后停止播报并开始识别' : '当前车机系统语音暂不支持自动打断',
                ),
                value:
                    supportsBargeIn &&
                    bargeInMode == AiBargeInMode.voiceActivity,
                onChanged: !supportsBargeIn || _savingVoiceSettings
                    ? null
                    : (enabled) => unawaited(
                        _setBargeInMode(
                          enabled == true
                              ? AiBargeInMode.voiceActivity
                              : AiBargeInMode.disabled,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAiAssistantCard({bool compact = false}) {
    final layout = AppLayout.fromContext(context);
    return _buildCard(
      compact: compact,
      children: [
        _buildSectionHeader(icon: Icons.auto_awesome_rounded, title: 'AI 音乐助理'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '配置用于聊天、联网查询和语音点歌。每次打开助理都会开始一段全新对话。',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: layout.secondarySize,
                ),
              ),
              AnimatedBuilder(
                animation: _aiConfigController,
                builder: (context, _) => SwitchListTile.adaptive(
                  key: const ValueKey('ai-all-pages-toggle'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('所有页面显示 AI 助理'),
                  subtitle: const Text('控制发现、搜索、歌单、设置和播放页的悬浮入口'),
                  value: _aiConfigController.showAssistantOnAllPages,
                  onChanged: _aiConfigController.setShowAssistantOnAllPages,
                ),
              ),
              AnimatedBuilder(
                animation: _aiConfigController,
                builder: (context, _) => SwitchListTile.adaptive(
                  key: const ValueKey('ai-player-page-pet-toggle'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('播放页显示 AI 宠物'),
                  subtitle: const Text('在正在播放页面右上方显示悬浮入口'),
                  value: _aiConfigController.showPetOnPlayerPage,
                  onChanged: _aiConfigController.setShowPetOnPlayerPage,
                ),
              ),
              AnimatedBuilder(
                animation: _aiConfigController,
                builder: (context, _) => _buildAiProfileList(layout),
              ),
              const SizedBox(height: 12),
              AnimatedBuilder(
                animation: _aiConfigController,
                builder: (context, _) => DropdownButtonFormField<AiPetAppearance>(
                  key: ValueKey(
                    'ai-pet-appearance-${_aiConfigController.petAppearance.value}',
                  ),
                  initialValue: _aiConfigController.petAppearance,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '宠物外形',
                    helperText: '浮标和横屏助理头像同步切换',
                  ),
                  items: AiPetAppearance.values
                      .map(
                        (appearance) => DropdownMenuItem(
                          value: appearance,
                          child: Text(
                            appearance.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (appearance) {
                    if (appearance != null) {
                      unawaited(
                        _aiConfigController.setPetAppearance(appearance),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.open_in_full_rounded, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '桌面宠物大小',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${_petScaleDraft.toStringAsFixed(2)}x'),
                ],
              ),
              Slider(
                key: const ValueKey('ai-pet-scale-slider'),
                min: AiConfigController.minPetScale,
                max: AiConfigController.maxPetScale,
                divisions: 27,
                value: _petScaleDraft.clamp(
                  AiConfigController.minPetScale,
                  AiConfigController.maxPetScale,
                ),
                label: '${_petScaleDraft.toStringAsFixed(2)}x',
                onChanged: (value) => setState(() => _petScaleDraft = value),
                onChangeEnd: _aiConfigController.setPetScale,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const ValueKey('ai-pet-position-reset'),
                  onPressed: _aiConfigController.resetPetPosition,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('恢复宠物位置'),
                ),
              ),
              const SizedBox(height: 8),
              AnimatedBuilder(
                animation: _aiConfigController,
                builder: (context, _) {
                  final profile = _aiConfigController.activeProfile;
                  if (profile == null) return const SizedBox.shrink();
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.check_circle_outline_rounded),
                    title: const Text('当前使用的模型'),
                    subtitle: Text(
                      '${profile.name} · ${profile.config.model.isEmpty ? '尚未填写模型' : profile.config.model}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      key: const ValueKey('ai-active-profile-edit'),
                      tooltip: '编辑当前模型',
                      onPressed: () => _renameAiProfile(profile),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAboutCard({bool compact = false}) {
    return _buildCard(
      compact: compact,
      children: [
        _buildSectionHeader(icon: Icons.music_note, title: '关于'),
        ListTile(
          dense: compact,
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.media),
            child: Image.asset(
              'assets/images/app_logo.png',
              width: 40,
              height: 40,
            ),
          ),
          title: const Text('库仔音乐'),
          subtitle: const Text('多平台音乐播放器'),
        ),
        const ListTile(
          leading: Icon(Icons.link),
          title: Text('API 文档'),
          subtitle: Text('api.chksz.com'),
        ),
        ListTile(
          dense: compact,
          leading: const Icon(Icons.info),
          title: const Text('版本'),
          trailing: Text(
            _versionName.isEmpty ? '—' : '$_versionName ($_versionCode)',
          ),
        ),
      ],
    );
  }

  Widget _buildSystemActionsCard() {
    final colors = Theme.of(context).colorScheme;
    return _buildCard(
      children: [
        _buildSectionHeader(icon: Icons.settings_power_rounded, title: '系统操作'),
        ListTile(
          key: const ValueKey('portrait-complete-exit'),
          leading: Icon(Icons.power_settings_new_rounded, color: colors.error),
          title: Text(
            '完全退出',
            style: TextStyle(color: colors.error, fontWeight: FontWeight.w600),
          ),
          subtitle: const Text('保存当前状态并彻底关闭软件'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => AppExitService.confirmAndExit(context),
        ),
      ],
    );
  }

  /// 卡片分组容器
  Widget _buildCard({required List<Widget> children, bool compact = false}) {
    final layout = AppLayout.fromContext(context);
    return Container(
      margin: EdgeInsets.fromLTRB(
        layout.usesLargeTypography ? 20 : (compact ? 8 : 16),
        layout.usesLargeTypography ? 14 : 8,
        layout.usesLargeTypography ? 20 : (compact ? 8 : 16),
        layout.usesLargeTypography ? 14 : 8,
      ),
      decoration: CardStyle.softCard(),
      child: Column(children: children),
    );
  }

  /// 分组标题（图标 + 文字）
  Widget _buildSectionHeader({required IconData icon, required String title}) {
    final layout = AppLayout.fromContext(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        layout.usesLargeTypography ? 28 : (layout.isCompactLandscape ? 12 : 16),
        layout.usesLargeTypography ? 20 : (layout.isCompactLandscape ? 12 : 14),
        layout.usesLargeTypography ? 28 : (layout.isCompactLandscape ? 12 : 16),
        layout.usesLargeTypography ? 10 : 6,
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: layout.usesLargeTypography
                ? 24
                : (layout.isCompactLandscape ? 22 : 20),
            color: AppColors.primary,
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: layout.sectionTitleSize,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQualityRow(String platform, List values) {
    final layout = AppLayout.fromContext(context);
    final labels = values.map((e) => e.label).join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            platform,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: layout.bodySize,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            labels,
            style: TextStyle(
              fontSize: layout.secondarySize,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  void _showNeteaseLevelPicker(BuildContext ctx, PlayerProvider player) {
    showDialog(
      context: ctx,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择网易云音质'),
        children: NeteaseLevel.values.map((level) {
          return RadioListTile<String>(
            value: level.value,
            groupValue: player.neteaseLevel.value,
            title: Text(level.label),
            onChanged: (v) async {
              if (v == null) return;
              try {
                await player.setNeteaseLevel(level);
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (error) {
                if (!mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('保存网易云音质失败：$error')));
              }
            },
          );
        }).toList(),
      ),
    );
  }

  void _showCommonLevelPicker(BuildContext ctx, PlayerProvider player) {
    showDialog(
      context: ctx,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择 QQ/酷狗音质'),
        children: CommonLevel.values.map((level) {
          return RadioListTile<String>(
            value: level.value,
            groupValue: player.commonLevel.value,
            title: Text(level.label),
            onChanged: (v) async {
              if (v == null) return;
              try {
                await player.setCommonLevel(level);
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (error) {
                if (!mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('保存 QQ/酷狗音质失败：$error')));
              }
            },
          );
        }).toList(),
      ),
    );
  }

  Future<void> _showPlaybackSourcePicker(
    BuildContext context,
    PlayerProvider player,
    MusicPlatform platform,
  ) async {
    // Do not restore the API Key TextField focus when this settings dialog
    // closes. This is especially visible on TV/car displays with a keyboard.
    FocusManager.instance.primaryFocus?.unfocus();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('${platform.label}播放源'),
        children: PlaybackSource.values.map((source) {
          final enabled = player.playbackSourceConfig.isEnabled(source);
          return RadioListTile<PlaybackSource>(
            key: ValueKey('playback-source-${platform.code}-${source.value}'),
            value: source,
            groupValue: player.playbackSourceFor(platform),
            title: Text(source.label),
            subtitle: Text(
              _playbackSourceDescription(source, enabled: enabled),
            ),
            onChanged: enabled
                ? (selected) async {
                    if (selected == null) return;
                    try {
                      await player.setPlaybackSource(platform, selected);
                      if (!dialogContext.mounted) return;
                      Navigator.pop(dialogContext);
                    } catch (error) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('保存${platform.label}音源失败：$error'),
                        ),
                      );
                    }
                  }
                : null,
          );
        }).toList(),
      ),
    );
    if (mounted) FocusManager.instance.primaryFocus?.unfocus();
  }

  String _playbackSourceDescription(
    PlaybackSource source, {
    required bool enabled,
  }) {
    if (!enabled) return '${source.label} · 已在接口配置中停用';
    return switch (source) {
      PlaybackSource.automatic => '主组并行竞速 · 失败后 GDStudio 兜底 · 自动降音质',
      PlaybackSource.chksz => '现有解析服务 · 需要 API Key',
      PlaybackSource.qingMusic => '统一 POST 第三方解析',
      PlaybackSource.hyw => '统一 GET 聚合解析 · 使用 Card Key',
      PlaybackSource.xinghai => '动态 X-Token 聚合解析',
      PlaybackSource.gdStudio => '简单 GET 末级备用解析',
    };
  }

  void _showVideoPlayerModePicker(BuildContext context, PlayerProvider player) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('默认 MV 播放器'),
        children: VideoPlayerMode.values.map((mode) {
          final description = switch (mode) {
            VideoPlayerMode.automatic => '优先使用 ExoPlayer，失败时自动切换 MPV',
            VideoPlayerMode.mpv => '直接使用 libmpv，支持更多格式和协议',
            VideoPlayerMode.exo => '直接使用 Android Media3 ExoPlayer',
          };
          return RadioListTile<VideoPlayerMode>(
            key: ValueKey('mv-player-mode-${mode.value}'),
            value: mode,
            groupValue: player.videoPlayerMode,
            title: Text(mode.label),
            subtitle: Text(description),
            onChanged: (selected) async {
              if (selected == null) return;
              try {
                await player.setVideoPlayerMode(selected);
                if (!dialogContext.mounted) return;
                Navigator.pop(dialogContext);
              } catch (error) {
                if (!mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('保存视频播放器设置失败：$error')));
              }
            },
          );
        }).toList(),
      ),
    );
  }

  void _showApiKeyHelp(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (ctx) => AlertDialog(
        title: const Text('获取 API Key'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('1. 访问 api.chksz.com'),
            SizedBox(height: 8),
            Text('2. 注册/登录账号'),
            SizedBox(height: 8),
            Text('3. 点击「查看密钥」获取个人 API Key'),
            SizedBox(height: 8),
            Text('4. 将 Key 复制到上方输入框并保存'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

class _FavoriteImportQrDialog extends StatelessWidget {
  final LanFavoriteImportSession session;
  final Future<List<String>?> receivedFuture;
  final Future<BatchFavoriteImportResult?> importFuture;

  const _FavoriteImportQrDialog({
    required this.session,
    required this.receivedFuture,
    required this.importFuture,
  });

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.fromContext(context);
    final compact = layout.isCompactLandscape;
    final qrSize = compact ? 146.0 : 205.0;
    final qrCode = Container(
      padding: const EdgeInsets.all(10),
      color: Colors.white,
      child: QrImageView(
        key: const ValueKey('favorite-import-qr-code'),
        data: session.url,
        version: QrVersions.auto,
        size: qrSize,
        backgroundColor: Colors.white,
      ),
    );
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '批量加入收藏歌曲',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: layout.sectionTitleSize,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        _buildStatus(),
        const SizedBox(height: 10),
        Text(
          '手机与车机需连接同一个 Wi-Fi。歌曲之间使用“、”连接，一次最多 30 首。',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: layout.secondarySize,
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('favorite-import-qr-close'),
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
            label: const Text('关闭'),
          ),
        ),
      ],
    );

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.all(compact ? 12 : 20),
            child: MediaQuery.orientationOf(context) == Orientation.landscape
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      qrCode,
                      SizedBox(width: compact ? 12 : 20),
                      Flexible(child: details),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [qrCode, const SizedBox(height: 16), details],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatus() {
    return FutureBuilder<List<String>?>(
      future: receivedFuture,
      builder: (context, received) {
        if (received.hasError) {
          return const _FavoriteImportQrStatus(
            icon: Icons.error_outline_rounded,
            message: '接收失败，请关闭后重试',
            color: Colors.redAccent,
          );
        }
        if (received.connectionState != ConnectionState.done) {
          return const _FavoriteImportQrStatus(
            icon: Icons.phone_android_rounded,
            message: '等待手机扫码并提交歌曲列表',
            color: AppColors.primary,
          );
        }
        final names = received.data;
        if (names == null) {
          return _FavoriteImportQrStatus(
            icon: Icons.timer_off_outlined,
            message: '本次批量收藏已结束',
            color: AppColors.textHint,
          );
        }
        return FutureBuilder<BatchFavoriteImportResult?>(
          future: importFuture,
          builder: (context, imported) {
            if (imported.hasError) {
              return const _FavoriteImportQrStatus(
                icon: Icons.error_outline_rounded,
                message: '匹配收藏歌曲失败，请关闭后重试',
                color: Colors.redAccent,
              );
            }
            if (imported.connectionState != ConnectionState.done) {
              return _FavoriteImportQrStatus(
                icon: Icons.sync_rounded,
                message: '已收到 ${names.length} 首，正在匹配并加入收藏',
                color: AppColors.primary,
                showProgress: true,
              );
            }
            final result = imported.data;
            if (result == null || result.cancelled) {
              return _FavoriteImportQrStatus(
                icon: Icons.timer_off_outlined,
                message: '本次批量收藏已结束',
                color: AppColors.textHint,
              );
            }
            return _FavoriteImportQrStatus(
              icon: Icons.check_circle_outline_rounded,
              message: _resultMessage(result),
              color: AppColors.primary,
            );
          },
        );
      },
    );
  }

  String _resultMessage(BatchFavoriteImportResult result) {
    final parts = <String>['已完成：新增 ${result.added} 首'];
    if (result.alreadyFavorite > 0) {
      parts.add('${result.alreadyFavorite} 首已收藏');
    }
    if (result.notFound.isNotEmpty) {
      parts.add('${result.notFound.length} 首未找到');
    }
    return parts.join('，');
  }
}

class _FavoriteImportQrStatus extends StatelessWidget {
  final IconData icon;
  final String message;
  final Color color;
  final bool showProgress;

  const _FavoriteImportQrStatus({
    required this.icon,
    required this.message,
    required this.color,
    this.showProgress = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (showProgress)
          SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: color),
          )
        else
          Icon(icon, color: color, size: 22),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            key: const ValueKey('favorite-import-qr-status'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppColors.textPrimary),
          ),
        ),
      ],
    );
  }
}

class _AiConfigQrDialog extends StatelessWidget {
  final LanAiConfigSession session;
  final Future<bool> saveFuture;

  const _AiConfigQrDialog({required this.session, required this.saveFuture});

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.fromContext(context);
    final compact = layout.isCompactLandscape;
    final qrSize = compact ? 146.0 : 205.0;
    final status = FutureBuilder<bool>(
      future: saveFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _AiConfigQrStatus(
            icon: Icons.error_outline_rounded,
            message: '保存失败，请关闭后重试',
            color: Colors.redAccent,
          );
        }
        if (snapshot.connectionState == ConnectionState.done) {
          return _AiConfigQrStatus(
            icon: snapshot.data == true
                ? Icons.check_circle_outline_rounded
                : Icons.timer_off_outlined,
            message: snapshot.data == true ? 'AI 配置已安全保存' : '本次扫码配置已结束',
            color: snapshot.data == true
                ? AppColors.primary
                : AppColors.textHint,
          );
        }
        return const _AiConfigQrStatus(
          icon: Icons.phone_android_rounded,
          message: '手机扫码后填写整套 AI 配置',
          color: AppColors.primary,
        );
      },
    );
    final qrCode = Container(
      padding: const EdgeInsets.all(10),
      color: Colors.white,
      child: QrImageView(
        key: const ValueKey('ai-config-qr-code'),
        data: session.url,
        version: QrVersions.auto,
        size: qrSize,
        backgroundColor: Colors.white,
      ),
    );
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '扫码配置 AI 助理',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: layout.sectionTitleSize,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        status,
        const SizedBox(height: 10),
        Text(
          '一次填写厂商、协议、URL、Key、模型、推理等级和联网搜索。手机与车机需在同一 Wi-Fi。',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: layout.secondarySize,
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('ai-config-qr-close'),
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
            label: const Text('关闭'),
          ),
        ),
      ],
    );
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: EdgeInsets.all(compact ? 12 : 20),
          child: MediaQuery.orientationOf(context) == Orientation.landscape
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    qrCode,
                    SizedBox(width: compact ? 12 : 20),
                    Flexible(child: details),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [qrCode, const SizedBox(height: 16), details],
                ),
        ),
      ),
    );
  }
}

class _AiConfigQrStatus extends StatelessWidget {
  final IconData icon;
  final String message;
  final Color color;

  const _AiConfigQrStatus({
    required this.icon,
    required this.message,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            key: const ValueKey('ai-config-qr-status'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
        ),
      ],
    );
  }
}

class _ApiKeyQrDialog extends StatelessWidget {
  final LanApiKeySession session;
  final Future<bool> saveFuture;

  const _ApiKeyQrDialog({required this.session, required this.saveFuture});

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.fromContext(context);
    final compact = layout.isCompactLandscape;
    final qrSize = compact ? 150.0 : 210.0;
    final status = FutureBuilder<bool>(
      future: saveFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _ApiKeyQrStatus(
            icon: Icons.error_outline_rounded,
            message: '保存失败，请关闭后重试',
            color: Colors.redAccent,
          );
        }
        if (snapshot.connectionState == ConnectionState.done) {
          return _ApiKeyQrStatus(
            icon: snapshot.data == true
                ? Icons.check_circle_outline_rounded
                : Icons.timer_off_outlined,
            message: snapshot.data == true ? 'API Key 已保存到车机' : '本次扫码输入已结束',
            color: snapshot.data == true
                ? AppColors.primary
                : AppColors.textHint,
          );
        }
        return const _ApiKeyQrStatus(
          icon: Icons.phone_android_rounded,
          message: '手机扫码后输入 Key 并提交',
          color: AppColors.primary,
        );
      },
    );

    final qrCode = Container(
      padding: const EdgeInsets.all(10),
      color: Colors.white,
      child: QrImageView(
        key: const ValueKey('api-key-qr-code'),
        data: session.url,
        version: QrVersions.auto,
        size: qrSize,
        backgroundColor: Colors.white,
      ),
    );
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '扫码输入 API Key',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: layout.sectionTitleSize,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        status,
        const SizedBox(height: 10),
        Text(
          '手机与车机需连接同一个 Wi-Fi，二维码约 10 分钟后失效。',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: layout.secondarySize,
          ),
        ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('api-key-qr-close'),
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
            label: const Text('关闭'),
          ),
        ),
      ],
    );

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: EdgeInsets.all(compact ? 12 : 20),
          child: MediaQuery.orientationOf(context) == Orientation.landscape
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    qrCode,
                    SizedBox(width: compact ? 12 : 20),
                    Flexible(child: details),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [qrCode, const SizedBox(height: 16), details],
                ),
        ),
      ),
    );
  }
}

class _ApiKeyQrStatus extends StatelessWidget {
  final IconData icon;
  final String message;
  final Color color;

  const _ApiKeyQrStatus({
    required this.icon,
    required this.message,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            key: const ValueKey('api-key-qr-status'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
        ),
      ],
    );
  }
}
