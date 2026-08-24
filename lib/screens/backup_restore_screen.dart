import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../providers/ai_config_controller.dart';
import '../providers/player_provider.dart';
import '../providers/search_session.dart';
import '../providers/theme_controller.dart';
import '../services/backup_service.dart';
import '../services/favorite_file_service.dart';
import '../services/favorite_service.dart';
import '../services/global_settings_service.dart';
import '../services/lan_backup_service.dart';
import '../services/webdav_backup_service.dart';
import '../services/user_data_scope.dart';
import '../theme/app_layout.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../widgets/backup_restore_options_dialog.dart';
import '../widgets/remote_focusable.dart';

class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({super.key});

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  final _urlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _fingerprintController = TextEditingController();

  LanBackupSession? _lanSession;
  bool _loadingConfig = true;
  bool _busy = false;
  bool _obscurePassword = true;
  String? _status;
  bool _statusError = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    final session = _lanSession;
    if (session != null) unawaited(_stopSessionQuietly(session));
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _fingerprintController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final config = await WebDavConfig.load(
        dataScope: context.read<PlayerProvider>().dataScope,
      );
      if (!mounted) return;
      setState(() {
        _urlController.text = config.url;
        _usernameController.text = config.username;
        _passwordController.text = config.password;
        _fingerprintController.text = config.certificateSha256;
        _loadingConfig = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingConfig = false);
    }
  }

  Future<String> _prepareExport() async {
    final favorites = context.read<FavoriteService>();
    final player = context.read<PlayerProvider>();
    final aiConfig = context.read<AiConfigController?>();
    final theme = context.read<ThemeController?>();
    final search = context.read<SearchSession?>();
    final operationScope = player.dataScope;
    await Future.wait([
      favorites.load(),
      player.settingsReady,
      if (aiConfig != null) aiConfig.ready,
      if (theme != null) theme.ready,
      if (search != null) search.historyReady,
    ]);
    if (!mounted ||
        !identical(context.read<PlayerProvider>(), player) ||
        player.dataScope != operationScope) {
      throw StateError('用户已切换，请重试备份操作');
    }
    final lyricDisplay = operationScope.isDefault
        ? await GlobalSettingsService.exportLyricDisplay()
        : null;
    if (!mounted ||
        !identical(context.read<PlayerProvider>(), player) ||
        player.dataScope != operationScope) {
      throw StateError('用户已切换，请重试备份操作');
    }
    return BackupService.exportJson(
      favorites: favorites,
      player: player,
      aiConfig: aiConfig,
      theme: theme,
      search: search,
      lyricDisplay: lyricDisplay,
    );
  }

  Future<BackupRestoreSelection?> _chooseRestoreOptions(
    String raw, {
    required UserDataScope scope,
  }) async {
    try {
      final contents = BackupService.inspect(raw);
      final scoped = contents.forScope(scope);
      return await showBackupRestoreSelectionDialog(context, scoped);
    } on FormatException catch (error) {
      _showStatus(error.message, error: true);
      return null;
    } catch (error) {
      _showStatus('检查备份失败：$error', error: true);
      return null;
    }
  }

  Future<void> _restoreRaw(
    String raw, {
    String source = '备份',
    FavoriteService? operationFavorites,
    PlayerProvider? operationPlayer,
    AiConfigController? operationAiConfig,
    ThemeController? operationTheme,
    SearchSession? operationSearch,
  }) async {
    if (!mounted || raw.trim().isEmpty) return;
    final favorites = operationFavorites ?? context.read<FavoriteService>();
    final player = operationPlayer ?? context.read<PlayerProvider>();
    final aiConfig = operationAiConfig ?? context.read<AiConfigController?>();
    final theme = operationTheme ?? context.read<ThemeController?>();
    final search = operationSearch ?? context.read<SearchSession?>();
    final operationScope = player.dataScope;
    final selection = await _chooseRestoreOptions(raw, scope: operationScope);
    if (selection == null ||
        !mounted ||
        player.dataScope != operationScope ||
        !identical(context.read<PlayerProvider>(), player)) {
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在从$source恢复...';
      _statusError = false;
    });
    try {
      final result = await BackupService.importJson(
        raw: raw,
        favorites: favorites,
        player: player,
        aiConfig: aiConfig,
        theme: theme,
        search: search,
        mode: selection.mode,
        sections: selection.sections,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = _restoreStatus(result, selection);
        _statusError = false;
      });
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = error.message;
        _statusError = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '恢复失败：$error';
        _statusError = true;
      });
    }
  }

  String _restoreStatus(
    BackupRestoreResult result,
    BackupRestoreSelection selection,
  ) {
    final parts = <String>[];
    if (selection.sections.contains(BackupRestoreSection.songs)) {
      parts.add('歌曲 ${result.songsAdded} 首');
    }
    if (selection.sections.contains(BackupRestoreSection.bilibili)) {
      parts.add('B站 ${result.bilibiliAdded} 个');
    }
    if (selection.sections.contains(BackupRestoreSection.playlists)) {
      parts.add('歌单 ${result.playlistsAdded} 个');
    }
    if (result.apiKeyRestored) parts.add('音乐 API Key');
    if (result.appearanceRestored) parts.add('外观');
    if (result.lyricDisplayRestored) parts.add('歌词显示');
    if (result.bilibiliAccountRestored) parts.add('B站账号');
    if (result.globalVoiceRestored) parts.add('全局语音设置');
    if (result.aiConfigRestored) parts.add('AI 助手配置');
    if (result.playerSettingsRestored) parts.add('播放器设置');
    if (result.searchHistoryRestored) parts.add('搜索历史');
    final skipped =
        result.songsSkipped + result.bilibiliSkipped + result.playlistsSkipped;
    final target = result.restoredToDefaultUser ? '默认用户：' : '';
    return '恢复完成：$target${parts.join('，')}${skipped > 0 ? '（重复或无效项目已跳过）' : ''}';
  }

  Future<String?> _showPasteDialog() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('粘贴备份 JSON'),
        content: RemoteTextFieldTraversal(
          controller: controller,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 6,
            maxLines: 12,
            maxLength: BackupService.maxBackupBytes,
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            buildCounter:
                (_, {required currentLength, required isFocused, maxLength}) =>
                    null,
            decoration: const InputDecoration(hintText: 'JSON 内容'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _exportFile() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final exportJson = await _prepareExport();
      if (!mounted) return;
      final result = await FavoriteFileService.exportBackup(exportJson);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = result == FavoriteExportResult.saved
            ? '备份文件已保存'
            : result == FavoriteExportResult.copiedToClipboard
            ? '备份 JSON 已复制到剪贴板'
            : '已取消导出';
        _statusError = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '导出失败：$error';
        _statusError = true;
      });
    }
  }

  Future<void> _copyBackupJson() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final exportJson = await _prepareExport();
      if (!mounted) return;
      await Clipboard.setData(ClipboardData(text: exportJson));
      if (mounted) _showStatus('备份 JSON 已复制');
    } catch (error) {
      if (mounted) _showStatus('复制失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importPastedJson() async {
    if (_busy) return;
    final raw = await _showPasteDialog();
    if (raw != null && raw.trim().isNotEmpty) {
      await _restoreRaw(raw, source: '粘贴内容');
    }
  }

  Future<void> _importFile() async {
    if (_busy) return;
    try {
      var raw = await FavoriteFileService.importBackup();
      if (!mounted || raw == null) return;
      await _restoreRaw(raw, source: '文件');
    } on UnsupportedError {
      if (!mounted) return;
      final raw = await _showPasteDialog();
      if (raw != null) await _restoreRaw(raw, source: '剪贴板');
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _status = error.message ?? '读取备份失败';
        _statusError = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = '读取备份失败：$error';
        _statusError = true;
      });
    }
  }

  WebDavConfig _configFromFields() {
    return WebDavConfig(
      url: _urlController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      certificateSha256: WebDavConfig.normalizeFingerprint(
        _fingerprintController.text,
      ),
      dataScope: context.read<PlayerProvider>().dataScope,
    );
  }

  Future<WebDavBackupService?> _makeWebDav() async {
    try {
      final config = _configFromFields();
      await config.save();
      if (!mounted) return null;
      return WebDavBackupService(config: config);
    } on WebDavException catch (error) {
      _showStatus(error.message, error: true);
      return null;
    } catch (error) {
      _showStatus('WebDAV 配置无效：$error', error: true);
      return null;
    }
  }

  Future<void> _testWebDav() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '正在测试 WebDAV...';
      _statusError = false;
    });
    final service = await _makeWebDav();
    if (service == null) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    try {
      await service.testConnection();
      _showStatus('WebDAV 连接成功');
    } on WebDavException catch (error) {
      _showStatus(error.message, error: true);
    } catch (error) {
      _showStatus('WebDAV 连接失败：$error', error: true);
    } finally {
      service.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadWebDav() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '正在上传备份...';
      _statusError = false;
    });
    final service = await _makeWebDav();
    if (service == null) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    try {
      final exportJson = await _prepareExport();
      if (!mounted) return;
      await service.upload(exportJson);
      _showStatus('备份已上传到 WebDAV');
    } on WebDavException catch (error) {
      _showStatus(error.message, error: true);
    } catch (error) {
      _showStatus('WebDAV 上传失败：$error', error: true);
    } finally {
      service.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadWebDav() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '正在下载备份...';
      _statusError = false;
    });
    final service = await _makeWebDav();
    if (service == null) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    try {
      final raw = await service.download();
      if (!mounted) return;
      setState(() => _busy = false);
      await _restoreRaw(raw, source: 'WebDAV');
    } on WebDavException catch (error) {
      _showStatus(error.message, error: true);
      if (mounted) setState(() => _busy = false);
    } catch (error) {
      _showStatus('WebDAV 下载失败：$error', error: true);
      if (mounted) setState(() => _busy = false);
    } finally {
      service.close();
    }
  }

  Future<void> _startLanTransfer() async {
    if (_busy || _lanSession?.isActive == true) return;
    setState(() {
      _busy = true;
      _status = '正在启动局域网传输...';
      _statusError = false;
    });
    try {
      final exportJson = await _prepareExport();
      if (!mounted) return;
      final operationFavorites = context.read<FavoriteService>();
      final operationPlayer = context.read<PlayerProvider>();
      final operationAiConfig = context.read<AiConfigController?>();
      final operationTheme = context.read<ThemeController?>();
      final operationSearch = context.read<SearchSession?>();
      final operationScope = operationPlayer.dataScope;
      final session = await LanBackupService.start(
        exportBackup: () => exportJson,
      );
      if (!mounted) {
        await session.stop();
        return;
      }
      setState(() {
        _lanSession = session;
        _busy = false;
        _status = '手机打开下方地址并输入 PIN，即可下载或上传备份';
      });
      unawaited(
        _watchLanRestore(
          session,
          operationScope,
          operationFavorites,
          operationPlayer,
          operationAiConfig,
          operationTheme,
          operationSearch,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '启动局域网传输失败：$error';
        _statusError = true;
      });
    }
  }

  Future<void> _watchLanRestore(
    LanBackupSession session,
    UserDataScope operationScope,
    FavoriteService operationFavorites,
    PlayerProvider operationPlayer,
    AiConfigController? operationAiConfig,
    ThemeController? operationTheme,
    SearchSession? operationSearch,
  ) async {
    try {
      final raw = await session.restored;
      if (raw == null || raw.isEmpty) return;
      if (!mounted || !identical(_lanSession, session)) return;
      if (operationPlayer.dataScope != operationScope) return;
      await _restoreRaw(
        raw,
        source: '手机',
        operationFavorites: operationFavorites,
        operationPlayer: operationPlayer,
        operationAiConfig: operationAiConfig,
        operationTheme: operationTheme,
        operationSearch: operationSearch,
      );
      if (!mounted || !identical(_lanSession, session)) return;
      await _stopLanTransfer();
    } catch (_) {}
  }

  Future<void> _stopLanTransfer() async {
    final session = _lanSession;
    if (session == null) return;
    if (mounted) setState(() => _lanSession = null);
    try {
      await session.stop();
      if (mounted) _showStatus('局域网传输已关闭');
    } catch (error) {
      if (mounted) _showStatus('关闭局域网传输失败：$error', error: true);
    }
  }

  void _showStatus(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusError = error;
    });
  }

  Future<void> _copy(String value, String label) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) _showStatus('$label已复制');
    } catch (error) {
      if (mounted) _showStatus('复制失败：$error', error: true);
    }
  }

  Future<void> _stopSessionQuietly(LanBackupSession session) async {
    try {
      await session.stop();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    return Scaffold(
      appBar: AppBar(title: const Text('备份与还原')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final layout = AppLayout.fromConstraints(context, constraints);
            final wide = layout.isLandscape && constraints.maxWidth >= 760;
            final left = _buildLocalAndLan(layout);
            final right = _buildWebDav(layout);
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                layout.isCompactLandscape ? 8 : 16,
                4,
                layout.isCompactLandscape ? 8 : 16,
                28,
              ),
              child: wide
                  ? Row(
                      key: const ValueKey('backup-responsive-wide'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: left),
                        const SizedBox(width: 12),
                        Expanded(child: right),
                      ],
                    )
                  : Column(
                      key: const ValueKey('backup-responsive-compact'),
                      children: [left, right],
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildLocalAndLan(AppLayout layout) {
    return Column(
      children: [
        _buildCard(
          title: '本地备份',
          icon: Icons.folder_copy_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSummary(),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('backup-file-export'),
                    onPressed: _busy ? null : _exportFile,
                    icon: const Icon(Icons.save_alt_outlined),
                    label: const Text('导出备份'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('backup-file-import'),
                    onPressed: _busy ? null : _importFile,
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('导入备份'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('backup-copy-json'),
                    onPressed: _busy ? null : _copyBackupJson,
                    icon: const Icon(Icons.content_copy_rounded),
                    label: const Text('复制 JSON'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('backup-paste-json'),
                    onPressed: _busy ? null : _importPastedJson,
                    icon: const Icon(Icons.content_paste_rounded),
                    label: const Text('粘贴恢复'),
                  ),
                ],
              ),
            ],
          ),
        ),
        _buildCard(
          title: '手机局域网传输',
          icon: Icons.phone_android_outlined,
          child: AppMotionSwitcher(
            child: KeyedSubtree(
              key: ValueKey(
                _lanSession?.isActive == true
                    ? 'backup-lan-active'
                    : 'backup-lan-idle',
              ),
              child: _buildLanContent(layout),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLanContent(AppLayout layout) {
    final session = _lanSession;
    if (session == null || !session.isActive) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '车机和手机连接同一个 Wi-Fi 后，手机浏览器即可传输备份。',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: layout.bodySize,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('backup-lan-start'),
            onPressed: _busy ? null : _startLanTransfer,
            icon: const Icon(Icons.wifi_tethering),
            label: const Text('开启手机传输'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: Border.all(color: AppColors.surfaceSoft),
            ),
            child: QrImageView(
              key: const ValueKey('backup-lan-qr'),
              data: session.qrUrl,
              version: QrVersions.auto,
              size: layout.usesLargeTypography ? 220 : 190,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            '扫码打开备份页面（PIN 已自动填入）',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: layout.secondarySize,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text('手机浏览器打开：', style: TextStyle(fontSize: layout.bodySize)),
        const SizedBox(height: 6),
        RemoteTextFieldTraversal(
          child: SelectableText(
            session.url,
            key: const ValueKey('backup-lan-url'),
            style: TextStyle(
              color: AppColors.primary,
              fontSize: layout.bodySize,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'PIN：${session.pin}',
                key: const ValueKey('backup-lan-pin'),
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: layout.sectionTitleSize,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              tooltip: '复制地址',
              onPressed: () => _copy(session.url, '地址'),
              icon: const Icon(Icons.link),
            ),
            IconButton(
              tooltip: '复制 PIN',
              onPressed: () => _copy(session.pin, 'PIN'),
              icon: const Icon(Icons.pin),
            ),
          ],
        ),
        Text(
          '有效期约 10 分钟，上传后回到车机确认合并或覆盖。',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: layout.secondarySize,
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('backup-lan-stop'),
          onPressed: _stopLanTransfer,
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('关闭手机传输'),
        ),
      ],
    );
  }

  Widget _buildWebDav(AppLayout layout) {
    return _buildCard(
      title: 'WebDAV 网络备份',
      icon: Icons.cloud_sync_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppMotionSwitcher(
            child: _loadingConfig
                ? const LinearProgressIndicator(
                    key: ValueKey('backup-webdav-loading'),
                    minHeight: 2,
                  )
                : Column(
                    key: const ValueKey('backup-webdav-form'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      RemoteTextFieldTraversal(
                        controller: _urlController,
                        child: TextField(
                          key: const ValueKey('backup-webdav-url'),
                          controller: _urlController,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(
                            labelText: 'WebDAV 地址',
                            hintText: 'https://服务器:端口/路径/',
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      RemoteTextFieldTraversal(
                        controller: _usernameController,
                        child: TextField(
                          controller: _usernameController,
                          decoration: const InputDecoration(labelText: '用户名'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      RemoteTextFieldTraversal(
                        controller: _passwordController,
                        child: TextField(
                          controller: _passwordController,
                          obscureText: _obscurePassword,
                          decoration: InputDecoration(
                            labelText: '独立 WebDAV 密码',
                            suffixIcon: IconButton(
                              tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                              onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      RemoteTextFieldTraversal(
                        controller: _fingerprintController,
                        child: TextField(
                          controller: _fingerprintController,
                          decoration: const InputDecoration(
                            labelText: 'HTTPS 证书 SHA-256 指纹',
                            hintText: '64 位十六进制，可带冒号',
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '自签名 HTTPS 必须填写指纹；不要填写服务器 root 密码。',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: layout.secondarySize,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            key: const ValueKey('backup-webdav-test'),
                            onPressed: _busy ? null : _testWebDav,
                            icon: const Icon(Icons.check_circle_outline),
                            label: const Text('测试连接'),
                          ),
                          FilledButton.icon(
                            key: const ValueKey('backup-webdav-upload'),
                            onPressed: _busy ? null : _uploadWebDav,
                            icon: const Icon(Icons.cloud_upload_outlined),
                            label: const Text('上传备份'),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('backup-webdav-download'),
                            onPressed: _busy ? null : _downloadWebDav,
                            icon: const Icon(Icons.cloud_download_outlined),
                            label: const Text('下载并恢复'),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
          AppMotionSwitcher(
            child: _status == null
                ? const SizedBox.shrink(key: ValueKey('backup-status-empty'))
                : Padding(
                    key: ValueKey(
                      'backup-status-${_statusError ? 'error' : 'success'}',
                    ),
                    padding: const EdgeInsets.only(top: 14),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: (_statusError ? Colors.red : AppColors.primary)
                            .withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(AppRadius.control),
                      ),
                      child: Text(
                        _status!,
                        style: TextStyle(
                          color: _statusError
                              ? Colors.red.shade700
                              : AppColors.textPrimary,
                          fontSize: layout.secondarySize,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary() {
    return Consumer2<FavoriteService, PlayerProvider>(
      builder: (context, favorites, player, _) {
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _summaryChip(Icons.favorite, '${favorites.favorites.length} 首歌曲'),
            _summaryChip(
              Icons.video_collection_outlined,
              '${favorites.bilibiliFavorites.length} 个B站收藏',
            ),
            _summaryChip(
              Icons.queue_music,
              '${favorites.favoritePlaylists.length} 个歌单',
            ),
            _summaryChip(
              Icons.key_outlined,
              player.apiKey.isEmpty ? '未设置 API Key' : 'API Key 已设置',
            ),
          ],
        );
      },
    );
  }

  Widget _summaryChip(IconData icon, String label) {
    return Chip(
      avatar: Icon(icon, size: 18, color: AppColors.primary),
      label: Text(label),
      backgroundColor: AppColors.primarySoft,
      side: BorderSide.none,
    );
  }

  Widget _buildCard({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: CardStyle.softCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: AppLayout.fromContext(context).sectionTitleSize,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}
