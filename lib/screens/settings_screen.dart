import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/theme_controller.dart';
import '../services/audio_cache_service.dart';
import '../services/favorite_service.dart';
import '../services/floating_capsule_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import 'backup_restore_screen.dart';
import 'cache_list_screen.dart';
import 'favorites_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _apiKeyController = TextEditingController();
  bool _obscureKey = true;
  bool _apiKeyEdited = false;

  String _versionName = '';
  String _versionCode = '';
  String _cacheSizeText = '';
  int _cacheCount = 0;

  @override
  void initState() {
    super.initState();
    final player = context.read<PlayerProvider>();
    _apiKeyController.text = player.apiKey;
    player.settingsReady.then((_) {
      if (mounted && !_apiKeyEdited) {
        _apiKeyController.text = player.apiKey;
      }
    });
    _loadVersion();
    _loadCacheInfo();
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

  @override
  void dispose() {
    _apiKeyController.dispose();
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
        _buildLibraryCard(),
        _buildPlaybackCard(),
        _buildApiCard(),
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
                          _buildApiCard(compact: compact),
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
                      onSelectionChanged: (s) => themeCtrl.setMode(s.first),
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
                    divisions: 10,
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
                          '80%',
                          style: TextStyle(
                            fontSize: layout.secondarySize,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        Text(
                          '130%',
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
                ...musicPlatformDisplayOrder.map((platform) {
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
              '${favorites.favoritePlaylists.length} 个歌单',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FavoritesScreen()),
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
              TextField(
                controller: _apiKeyController,
                obscureText: _obscureKey,
                onChanged: (_) => _apiKeyEdited = true,
                decoration: InputDecoration(
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureKey ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
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

  void _showPlaybackSourcePicker(
    BuildContext context,
    PlayerProvider player,
    MusicPlatform platform,
  ) {
    showDialog<void>(
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
