import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/theme_controller.dart';
import '../services/floating_capsule_service.dart';
import '../theme/app_theme.dart';

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
        _buildPlaybackCard(),
        _buildApiCard(),
        _buildAboutCard(),
      ],
    );
  }

  Widget _buildLandscapeBody() {
    return Column(
      children: [
        _buildPageTitle(compact: true),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  key: const PageStorageKey('settings-landscape-preferences'),
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Column(
                    children: [
                      _buildAppearanceCard(compact: true),
                      _buildPlaybackCard(compact: true),
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
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Column(
                    children: [
                      _buildApiCard(compact: true),
                      _buildAboutCard(compact: true),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPageTitle({bool compact = false}) {
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
          fontSize: compact ? 20 : 24,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }

  Widget _buildAppearanceCard({bool compact = false}) {
    return _buildCard(
      compact: compact,
      children: [
        _buildSectionHeader(icon: Icons.dark_mode_outlined, title: '外观'),
        Consumer<ThemeController>(
          builder: (ctx, themeCtrl, _) {
            final segments = compact
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
                      fontSize: 13,
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
                          fontSize: compact ? 11 : 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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
                        fontSize: 12,
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
                        borderRadius: BorderRadius.circular(8),
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
                                fontSize: 13,
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

  Widget _buildApiCard({bool compact = false}) {
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
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '用于酷狗/QQ 播放地址解析（网易云免配置）',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
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
            borderRadius: BorderRadius.circular(10),
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
    return Container(
      margin: EdgeInsets.fromLTRB(compact ? 8 : 16, 8, compact ? 8 : 16, 8),
      decoration: CardStyle.softCard(),
      child: Column(children: children),
    );
  }

  /// 分组标题（图标 + 文字）
  Widget _buildSectionHeader({required IconData icon, required String title}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQualityRow(String platform, List values) {
    final labels = values.map((e) => e.label).join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            platform,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
        Expanded(
          child: Text(
            labels,
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
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
