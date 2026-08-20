import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ai_assistant.dart';
import '../models/song.dart';
import '../providers/ai_config_controller.dart';
import '../providers/player_provider.dart';
import '../providers/theme_controller.dart';
import '../services/audio_cache_service.dart';
import '../services/ai_service.dart';
import '../services/favorite_service.dart';
import '../services/floating_capsule_service.dart';
import '../services/lan_ai_config_service.dart';
import '../services/lan_api_key_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import '../theme/lyric_style.dart';
import '../widgets/bilibili_login_dialog.dart';
import '../widgets/remote_focusable.dart';
import 'backup_restore_screen.dart';
import 'cache_list_screen.dart';
import 'favorites_screen.dart';
import 'playback_history_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _apiKeyController = TextEditingController();
  bool _obscureKey = true;
  bool _apiKeyEdited = false;
  final _aiUrlController = TextEditingController();
  final _aiApiKeyController = TextEditingController();
  final _aiModelController = TextEditingController();
  late final AiConfigController _aiConfigController;
  late final bool _ownsAiConfigController;
  AiProviderKind _aiProvider = AiProviderKind.openAi;
  AiRequestProtocol _aiProtocol = AiRequestProtocol.openAiResponses;
  AiReasoningEffort _aiReasoning = AiReasoningEffort.platformDefault;
  AiWebSearchMode _aiWebSearch = AiWebSearchMode.automatic;
  bool _obscureAiKey = true;
  bool _aiConfigEdited = false;
  bool _testingAiConnection = false;
  bool _savingAiConfig = false;

  String _versionName = '';
  String _versionCode = '';
  String _cacheSizeText = '';
  int _cacheCount = 0;
  LyricFontFamilyPreset _lyricFontFamily = LyricFontFamilyPreset.system;
  LyricFontWeightPreset _lyricFontWeight = LyricFontWeightPreset.medium;

  @override
  void initState() {
    super.initState();
    final sharedAiConfig = Provider.of<AiConfigController?>(
      context,
      listen: false,
    );
    _ownsAiConfigController = sharedAiConfig == null;
    _aiConfigController =
        sharedAiConfig ??
        AiConfigController(secretStore: MemoryAiSecretStore());
    _applyAiConfig(_aiConfigController.config);
    _aiConfigController.ready.then((_) {
      if (mounted && !_aiConfigEdited) {
        setState(() => _applyAiConfig(_aiConfigController.config));
      }
    });
    final player = context.read<PlayerProvider>();
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
        AudioCacheService.getCacheSize(),
        AudioCacheService.getCacheCount(),
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
    if (_lyricFontFamily != family && mounted) {
      setState(() => _lyricFontFamily = family);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(LyricStylePreferences.fontFamilyKey, family.value);
    } catch (_) {}
  }

  Future<void> _setLyricFontWeight(LyricFontWeightPreset weight) async {
    if (_lyricFontWeight != weight && mounted) {
      setState(() => _lyricFontWeight = weight);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
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

    await AudioCacheService.clearCache();
    await _loadCacheInfo();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('缓存已清除')));
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
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) =>
          _ApiKeyQrDialog(session: session, saveFuture: saveFuture),
    );
    await session.stop();
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

  void _applyAiConfig(AiAssistantConfig config) {
    _aiProvider = config.provider;
    _aiProtocol = config.protocol;
    _aiReasoning = config.reasoningEffort;
    _aiWebSearch = config.webSearchMode;
    _aiUrlController.text = config.baseUrl;
    _aiApiKeyController.text = config.apiKey;
    _aiModelController.text = config.model;
  }

  AiAssistantConfig _aiConfigFromForm() => AiAssistantConfig(
    provider: _aiProvider,
    protocol: _aiProtocol,
    baseUrl: _aiUrlController.text.trim(),
    apiKey: _aiApiKeyController.text.trim(),
    model: _aiModelController.text.trim(),
    reasoningEffort: _aiReasoning,
    webSearchMode: _aiWebSearch,
  );

  void _selectAiProvider(AiProviderKind provider) {
    final previousDefault = _aiProvider.defaultBaseUrl;
    final currentUrl = _aiUrlController.text.trim();
    setState(() {
      _aiProvider = provider;
      _aiProtocol = provider.defaultProtocol;
      if (currentUrl.isEmpty || currentUrl == previousDefault) {
        _aiUrlController.text = provider.defaultBaseUrl;
      }
      _aiConfigEdited = true;
    });
  }

  Future<void> _saveAiConfig() async {
    if (_savingAiConfig) return;
    final config = _aiConfigFromForm();
    if (!config.isComplete) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请完整填写中转站 URL、API Key 和模型')));
      return;
    }
    setState(() => _savingAiConfig = true);
    try {
      await _aiConfigController.save(config);
      if (!mounted) return;
      setState(() {
        _savingAiConfig = false;
        _aiConfigEdited = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('AI 助理配置已安全保存'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _savingAiConfig = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  Future<void> _testAiConnection() async {
    if (_testingAiConnection) return;
    final config = _aiConfigFromForm();
    if (!config.isComplete) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先完整填写 AI 配置')));
      return;
    }
    setState(() => _testingAiConnection = true);
    final service = AiAssistantService();
    try {
      final result = await service.checkConnection(
        config,
        checkSearch: config.webSearchMode != AiWebSearchMode.disabled,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message),
          backgroundColor: result.success ? null : Colors.redAccent,
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      service.close();
      if (mounted) setState(() => _testingAiConnection = false);
    }
  }

  Future<void> _showAiConfigQrInput() async {
    FocusManager.instance.primaryFocus?.unfocus();
    late final LanAiConfigSession session;
    try {
      session = await LanAiConfigService.start();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('启动扫码配置失败：$error')));
      return;
    }
    if (!mounted) {
      await session.stop();
      return;
    }
    final saveFuture = _receiveAndSaveAiConfig(session);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _AiConfigQrDialog(session: session, saveFuture: saveFuture),
    );
    await session.stop();
    if (mounted) FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<bool> _receiveAndSaveAiConfig(LanAiConfigSession session) async {
    final config = await session.receivedConfig;
    if (config == null) return false;
    await _aiConfigController.save(config);
    if (!mounted) return true;
    setState(() {
      _applyAiConfig(config);
      _aiConfigEdited = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('手机提交的 AI 配置已安全保存'),
        duration: Duration(seconds: 2),
      ),
    );
    return true;
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _aiUrlController.dispose();
    _aiApiKeyController.dispose();
    _aiModelController.dispose();
    if (_ownsAiConfigController) _aiConfigController.dispose();
    super.dispose();
  }

  /// 系统悬浮胶囊开关
  Future<void> _toggleFloatingCapsule(bool value) async {
    if (value) {
      final hasPerm = await FloatingCapsuleService.hasPermission();
      if (!hasPerm) {
        FloatingCapsuleService.openPermissionSettings();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('请在系统设置中开启「悬浮窗」权限，返回后重新打开开关'),
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }
    } else {
      FloatingCapsuleService.hide();
    }
    if (!mounted) return;
    FloatingCapsuleService.setEnabled(value);
    if (value) {
      final player = context.read<PlayerProvider>();
      final song = player.currentSong;
      if (song != null) {
        await FloatingCapsuleService.show(
          title: song.name,
          artist: song.artist,
          coverUrl: song.coverUrl,
          isPlaying: player.isPlaying,
        );
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('floating_capsule_enabled', value);
    } catch (_) {}
    if (mounted) setState(() {});
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
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _buildPageTitle(),
        _buildAppearanceCard(),
        _buildLyricsCard(),
        _buildLibraryCard(),
        _buildPlaybackCard(),
        _buildBilibiliAccountCard(),
        _buildApiCard(),
        _buildAiAssistantCard(),
        _buildAboutCard(),
      ],
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
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.circle_notifications),
                    title: const Text('系统悬浮胶囊'),
                    subtitle: Text(
                      FloatingCapsuleService.enabled
                          ? '播放时跨 App 悬浮显示（需悬浮窗权限）'
                          : '在任意界面顶部显示播放胶囊',
                      style: TextStyle(
                        fontSize: layout.secondarySize,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    value: FloatingCapsuleService.enabled,
                    onChanged: _toggleFloatingCapsule,
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
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
    if (selected != null) await player.setLyricOffsetStep(selected);
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
      await player.setBilibiliLyricPlatformOrder(selected);
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
                    leading: Icon(
                      source == PlaybackSource.chksz
                          ? Icons.key_outlined
                          : Icons.cloud_outlined,
                    ),
                    title: Text(
                      '${platform.label}播放源',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      source == PlaybackSource.chksz
                          ? 'ChKSz · 需要 API Key'
                          : 'QingMusic · 第三方备用解析',
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
              MaterialPageRoute(builder: (_) => const FavoritesScreen()),
            ),
          ),
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
              MaterialPageRoute(
                builder: (_) => const PlaybackHistoryScreen(),
              ),
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
    final loggedIn = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const BilibiliLoginDialog(),
    );
    if (loggedIn != true || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('B站账号登录成功')));
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
    await player.logoutBilibili();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已退出 B站账号')));
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
                '仅用于选择 ChKSz 播放源的平台；QingMusic 备用源不使用此 Key',
                style: TextStyle(
                  fontSize: layout.secondarySize,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              RemoteTextFieldTraversal(
                controller: _apiKeyController,
                child: TextField(
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
                      await player.setApiKey(_apiKeyController.text.trim());
                      if (!mounted) return;
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text('API Key 已保存'),
                          duration: Duration(seconds: 1),
                        ),
                      );
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

  Widget _buildAiAssistantCard({bool compact = false}) {
    final layout = AppLayout.fromContext(context);
    final searchDependsOnRelay =
        _aiWebSearch != AiWebSearchMode.disabled &&
        (_aiProvider == AiProviderKind.deepSeek ||
            _aiProvider == AiProviderKind.custom);
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
              const SizedBox(height: 12),
              DropdownButtonFormField<AiProviderKind>(
                key: ValueKey('ai-provider-${_aiProvider.value}'),
                initialValue: _aiProvider,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '厂商预设'),
                items: AiProviderKind.values
                    .map(
                      (provider) => DropdownMenuItem(
                        value: provider,
                        child: Text(provider.label),
                      ),
                    )
                    .toList(),
                onChanged: (provider) {
                  if (provider != null) _selectAiProvider(provider);
                },
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<AiRequestProtocol>(
                key: ValueKey('ai-protocol-${_aiProtocol.value}'),
                initialValue: _aiProtocol,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '请求协议'),
                items: AiRequestProtocol.values
                    .map(
                      (protocol) => DropdownMenuItem(
                        value: protocol,
                        child: Text(protocol.label),
                      ),
                    )
                    .toList(),
                onChanged: (protocol) {
                  if (protocol == null) return;
                  setState(() {
                    _aiProtocol = protocol;
                    _aiConfigEdited = true;
                  });
                },
              ),
              const SizedBox(height: 10),
              RemoteTextFieldTraversal(
                controller: _aiUrlController,
                child: TextField(
                  key: const ValueKey('ai-base-url-field'),
                  controller: _aiUrlController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onChanged: (_) => _aiConfigEdited = true,
                  decoration: const InputDecoration(
                    labelText: '中转站 Base URL',
                    hintText: 'https://example.com/v1',
                  ),
                ),
              ),
              const SizedBox(height: 10),
              RemoteTextFieldTraversal(
                controller: _aiApiKeyController,
                child: TextField(
                  key: const ValueKey('ai-api-key-field'),
                  controller: _aiApiKeyController,
                  obscureText: _obscureAiKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => _aiConfigEdited = true,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    suffixIcon: IconButton(
                      tooltip: _obscureAiKey ? '显示 Key' : '隐藏 Key',
                      onPressed: () =>
                          setState(() => _obscureAiKey = !_obscureAiKey),
                      icon: Icon(
                        _obscureAiKey ? Icons.visibility : Icons.visibility_off,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              RemoteTextFieldTraversal(
                controller: _aiModelController,
                child: TextField(
                  key: const ValueKey('ai-model-field'),
                  controller: _aiModelController,
                  autocorrect: false,
                  onChanged: (_) => _aiConfigEdited = true,
                  decoration: const InputDecoration(
                    labelText: '模型',
                    hintText: '填写中转站实际支持的模型名称',
                  ),
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<AiReasoningEffort>(
                key: ValueKey('ai-reasoning-${_aiReasoning.value}'),
                initialValue: _aiReasoning,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '推理等级'),
                items: AiReasoningEffort.values
                    .map(
                      (effort) => DropdownMenuItem(
                        value: effort,
                        child: Text(effort.label),
                      ),
                    )
                    .toList(),
                onChanged: (effort) {
                  if (effort == null) return;
                  setState(() {
                    _aiReasoning = effort;
                    _aiConfigEdited = true;
                  });
                },
              ),
              const SizedBox(height: 4),
              Text(
                '选择“平台默认”时不会发送任何推理等级参数。其他等级会按当前协议转换。',
                style: TextStyle(
                  color: AppColors.textHint,
                  fontSize: layout.secondarySize,
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<AiWebSearchMode>(
                key: ValueKey('ai-web-search-${_aiWebSearch.value}'),
                initialValue: _aiWebSearch,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '联网搜索'),
                items: AiWebSearchMode.values
                    .map(
                      (mode) => DropdownMenuItem(
                        value: mode,
                        child: Text(mode.label),
                      ),
                    )
                    .toList(),
                onChanged: (mode) {
                  if (mode == null) return;
                  setState(() {
                    _aiWebSearch = mode;
                    _aiConfigEdited = true;
                  });
                },
              ),
              if (searchDependsOnRelay) ...[
                const SizedBox(height: 6),
                Text(
                  '当前厂商的 OpenAI 兼容接口没有统一搜索字段，是否联网取决于中转站能力；请用“测试连接”核验。',
                  style: TextStyle(
                    color: Colors.orange.shade700,
                    fontSize: layout.secondarySize,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('ai-config-save'),
                    onPressed: _savingAiConfig ? null : _saveAiConfig,
                    icon: _savingAiConfig
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(_savingAiConfig ? '保存中' : '保存'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('ai-config-test'),
                    onPressed: _testingAiConnection ? null : _testAiConnection,
                    icon: _testingAiConnection
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check_rounded),
                    label: Text(_testingAiConnection ? '测试中' : '测试连接'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('ai-config-qr-input'),
                    onPressed: _showAiConfigQrInput,
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text('手机扫码配置'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'API Key 使用系统安全存储，不写入二维码或普通应用配置。',
                style: TextStyle(
                  color: AppColors.textHint,
                  fontSize: layout.secondarySize,
                ),
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
            onChanged: (v) {
              player.setNeteaseLevel(level);
              Navigator.pop(ctx);
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
            onChanged: (v) {
              player.setCommonLevel(level);
              Navigator.pop(ctx);
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
          return RadioListTile<PlaybackSource>(
            key: ValueKey('playback-source-${platform.code}-${source.value}'),
            value: source,
            groupValue: player.playbackSourceFor(platform),
            title: Text(source.label),
            subtitle: Text(
              source == PlaybackSource.chksz
                  ? '现有解析服务，需要已配置的 API Key'
                  : 'QingMusic 第三方备用解析，不使用 ChKSz API Key',
            ),
            onChanged: (selected) async {
              if (selected == null) return;
              await player.setPlaybackSource(platform, selected);
              if (!dialogContext.mounted) return;
              Navigator.pop(dialogContext);
            },
          );
        }).toList(),
      ),
    );
    if (mounted) FocusManager.instance.primaryFocus?.unfocus();
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
              await player.setVideoPlayerMode(selected);
              if (!dialogContext.mounted) return;
              Navigator.pop(dialogContext);
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
