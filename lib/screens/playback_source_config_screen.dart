import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/remote_playback.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/lan_api_key_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import '../widgets/remote_focusable.dart';

/// 管理服务器提供的音源及当前用户凭据，SHIXIAOYANG，2026/11/20。
class PlaybackSourceConfigScreen extends StatefulWidget {
  const PlaybackSourceConfigScreen({super.key});

  @override
  State<PlaybackSourceConfigScreen> createState() =>
      _PlaybackSourceConfigScreenState();
}

class _PlaybackSourceConfigScreenState
    extends State<PlaybackSourceConfigScreen> {
  final _apiKeyController = TextEditingController();
  final Map<String, TextEditingController> _credentialControllers = {};
  final Set<TextEditingController> _retiredControllers = {};
  final Set<String> _disabledSources = {};
  bool _obscureKey = true;
  bool _apiKeyEdited = false;
  bool _savingApiKey = false;
  bool _apiKeyQrInputInProgress = false;
  bool _saving = false;
  bool _refreshing = false;
  bool _dirty = false;
  LanApiKeySession? _activeApiKeySession;

  bool get _busy =>
      _saving || _savingApiKey || _apiKeyQrInputInProgress || _refreshing;

  @override
  void initState() {
    super.initState();
    // 先显示当前用户设置，再异步同步音源定义，界面不等待网络才能打开。
    final player = context.read<PlayerProvider>();
    _apiKeyController.text = player.apiKey;
    _disabledSources.addAll(player.playbackSourceConfig.disabledSourceIds);
    unawaited(_initialize(player));
  }

  Future<void> _initialize(PlayerProvider player) async {
    try {
      // 等待用户设置恢复；用户已经编辑的内容不能被迟到的加载覆盖。
      await player.settingsReady;
      if (!mounted) return;
      if (!_apiKeyEdited) _apiKeyController.text = player.apiKey;
      if (!_dirty) {
        _disabledSources
          ..clear()
          ..addAll(player.playbackSourceConfig.disabledSourceIds);
      }
      await _refresh();
    } catch (error) {
      _showMessage('加载音源配置失败：$error');
    }
  }

  @override
  void dispose() {
    final apiKeySession = _activeApiKeySession;
    _activeApiKeySession = null;
    if (apiKeySession != null) unawaited(apiKeySession.stop());
    _apiKeyController.dispose();
    for (final controller in _credentialControllers.values) {
      controller.dispose();
    }
    for (final controller in _retiredControllers) {
      controller.dispose();
    }
    _credentialControllers.clear();
    _retiredControllers.clear();
    super.dispose();
  }

  // 更新字段定义时保留仍存在的输入，仅释放服务端已移除字段的控制器。
  void _synchronizeFields(PlayerProvider player) {
    final activeKeys = <String>{};
    final config = player.playbackSourceConfig;
    // 升级前保存的个人卡密也参与初始化，避免未编辑就保存时被空输入覆盖。
    final effectiveCredentials = config.credentialsForServer(
      apiKey: player.apiKey,
    );
    for (final descriptor in player.remotePlaybackSources) {
      if (!_dirty && !config.isEnabled(descriptor.source)) {
        _disabledSources.add(descriptor.source.value);
      }
      for (final field in descriptor.credentials) {
        if (_usesApiKeyShortcut(descriptor, field)) continue;
        final key = '${descriptor.source.value}/${field.key}';
        activeKeys.add(key);
        if (_credentialControllers.containsKey(key)) continue;
        _credentialControllers[key] = TextEditingController(
          text: effectiveCredentials[descriptor.source.value]?[field.key] ?? '',
        );
      }
    }
    final removedKeys = _credentialControllers.keys
        .where((key) => !activeKeys.contains(key))
        .toList();
    for (final key in removedKeys) {
      final controller = _credentialControllers.remove(key)!;
      _retiredControllers.add(controller);
      // 旧 TextField 在这一帧结束后移除，随后释放它使用的控制器。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_retiredControllers.remove(controller)) controller.dispose();
      });
    }
  }

  bool _usesApiKeyShortcut(
    RemotePlaybackSource descriptor,
    PlaybackCredentialField field,
  ) => descriptor.source.value == 'chksz' && field.key == 'apiKey';

  Future<void> _refresh() async {
    if (!mounted || _busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final player = context.read<PlayerProvider>();
    setState(() => _refreshing = true);
    try {
      // Provider 合并重复请求；刷新只更新字段定义，不重置已有输入。
      await player.refreshPlaybackSources();
    } catch (error) {
      _showMessage('刷新音源失败：$error');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final player = context.read<PlayerProvider>();
    // 合并当前字段草稿，保留当前列表之外已有的用户凭据。
    final credentials = <String, Map<String, String>>{};
    for (final entry in player.playbackSourceConfig.remoteCredentials.entries) {
      credentials[entry.key] = Map<String, String>.from(entry.value);
    }
    for (final entry in _credentialControllers.entries) {
      final parts = entry.key.split('/');
      final values = credentials.putIfAbsent(
        parts[0],
        () => <String, String>{},
      );
      values[parts[1]] = entry.value.text.trim();
    }
    setState(() => _saving = true);
    try {
      // 先校验并写入存储，失败时继续保留编辑草稿供重试。
      await player.setRemotePlaybackSourceSettings(
        disabledSources: _disabledSources.toList(),
        credentials: credentials,
      );
      if (!mounted) return;
      setState(() => _dirty = false);
      _showMessage('音源配置已保存');
      Navigator.pop(context, true);
    } catch (error) {
      _showMessage('保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final player = context.watch<PlayerProvider>();
    _synchronizeFields(player);
    final sources = player.remotePlaybackSources;
    final cards = <Widget>[
      _buildStatusCard(player),
      for (final source in sources) _buildSourceCard(source),
      if (sources.isEmpty)
        Card(
          key: const ValueKey('source-config-chksz'),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: _buildApiKeyConfiguration(),
          ),
        ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('音源配置'),
        actions: [
          IconButton(
            key: const ValueKey('refresh-playback-sources'),
            tooltip: '刷新音源列表',
            onPressed: _busy || player.playbackSourcesLoading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            key: const ValueKey('save-playback-source-config'),
            tooltip: '保存配置',
            onPressed: _busy ? null : _save,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            key: const PageStorageKey('playback-source-config-scroll'),
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            child: constraints.maxWidth >= 960
                ? _buildWideCards(cards)
                : Column(children: cards),
          ),
        ),
      ),
    );
  }

  Widget _buildWideCards(List<Widget> cards) {
    // 宽横屏按顺序分成两列；旋转时继续使用同一组输入控制器。
    final left = <Widget>[];
    final right = <Widget>[];
    for (var index = 0; index < cards.length; index++) {
      if (index.isEven) {
        left.add(cards[index]);
      } else {
        right.add(cards[index]);
      }
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Column(children: left)),
        const SizedBox(width: 12),
        Expanded(child: Column(children: right)),
      ],
    );
  }

  Widget _buildStatusCard(PlayerProvider player) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('可用音源', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          const Text('音源列表自动更新。可选择参与自动播放的音源，并填写个人授权凭据。'),
          if (_refreshing || player.playbackSourcesLoading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (player.playbackSourcesError != null) ...[
            const SizedBox(height: 8),
            Text(
              player.playbackSourcesError!,
              key: const ValueKey('playback-sources-error'),
              style: const TextStyle(color: Colors.redAccent),
            ),
          ],
          if (player.remotePlaybackSources.isEmpty &&
              !player.playbackSourcesLoading &&
              !_refreshing) ...[
            const SizedBox(height: 8),
            const Text('暂未取得音源列表，本地歌曲仍可播放。'),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('retry-playback-sources'),
                onPressed: _busy || player.playbackSourcesLoading
                    ? null
                    : _refresh,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('刷新列表'),
              ),
              FilledButton.icon(
                key: const ValueKey('save-playback-source-config-bottom'),
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存配置'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _buildSourceCard(RemotePlaybackSource descriptor) {
    final source = descriptor.source;
    final enabled = !_disabledSources.contains(source.value);
    return Card(
      key: ValueKey('source-config-${source.value}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              key: ValueKey('source-enabled-${source.value}'),
              contentPadding: EdgeInsets.zero,
              title: Text(source.label),
              subtitle: Text(descriptor.description),
              value: enabled,
              onChanged: _busy
                  ? null
                  : (value) => _changeEnabled(source.value, value),
            ),
            Text('支持：${_platformLabels(descriptor.platforms)}'),
            for (final field in descriptor.credentials)
              if (_usesApiKeyShortcut(descriptor, field))
                _buildApiKeyConfiguration()
              else
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _buildCredentialField(descriptor, field),
                ),
          ],
        ),
      ),
    );
  }

  String _platformLabels(List<String> codes) {
    final labels = <String>[];
    for (final code in codes) {
      final platform = MusicPlatform.values.firstWhere(
        (item) => item.code == code,
        orElse: () => MusicPlatform.local,
      );
      labels.add(platform == MusicPlatform.local ? code : platform.label);
    }
    return labels.join('、');
  }

  void _changeEnabled(String sourceId, bool enabled) {
    setState(() {
      _dirty = true;
      if (enabled) {
        _disabledSources.remove(sourceId);
      } else {
        _disabledSources.add(sourceId);
      }
    });
  }

  Widget _buildCredentialField(
    RemotePlaybackSource descriptor,
    PlaybackCredentialField field,
  ) {
    // 字段来自服务端定义，所有个人凭据默认隐藏并限制输入长度。
    final controller =
        _credentialControllers['${descriptor.source.value}/${field.key}']!;
    return RemoteTextFieldTraversal(
      controller: controller,
      child: TextField(
        key: ValueKey(
          'source-credential-${descriptor.source.value}-${field.key}',
        ),
        controller: controller,
        enabled: !_busy,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        inputFormatters: [LengthLimitingTextInputFormatter(1024)],
        onChanged: (_) => _dirty = true,
        decoration: InputDecoration(
          labelText: field.label,
          helperText: field.requiredPlatforms.isEmpty
              ? null
              : '${_platformLabels(field.requiredPlatforms)}需填写',
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Future<void> _saveApiKey() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final key = _apiKeyController.text.trim();
    setState(() => _savingApiKey = true);
    try {
      await context.read<PlayerProvider>().setApiKey(key);
      if (!mounted) return;
      setState(() {
        _apiKeyController.text = key;
        _apiKeyEdited = true;
      });
      _showMessage('API Key 已保存');
    } catch (error) {
      _showMessage('API Key 保存失败：$error');
    } finally {
      if (mounted) setState(() => _savingApiKey = false);
    }
  }

  Future<void> _showApiKeyQrInput() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final player = context.read<PlayerProvider>();
    setState(() => _apiKeyQrInputInProgress = true);
    LanApiKeySession? session;
    try {
      session = await LanApiKeyService.start();
      if (!mounted) return;
      _activeApiKeySession = session;
      final saveFuture = _receiveAndSaveApiKey(session, player);
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _ApiKeyQrDialog(session: session!, saveFuture: saveFuture),
      );
    } catch (error) {
      _showMessage('扫码输入失败：$error');
    } finally {
      if (identical(_activeApiKeySession, session)) {
        _activeApiKeySession = null;
      }
      await session?.stop();
      if (mounted) {
        FocusManager.instance.primaryFocus?.unfocus();
        setState(() => _apiKeyQrInputInProgress = false);
      }
    }
  }

  Future<bool> _receiveAndSaveApiKey(
    LanApiKeySession session,
    PlayerProvider player,
  ) async {
    final apiKey = await session.receivedApiKey;
    if (apiKey == null || !mounted || !session.isActive) return false;
    setState(() => _savingApiKey = true);
    try {
      await player.setApiKey(apiKey);
      if (!mounted) return true;
      setState(() {
        _apiKeyController.text = apiKey;
        _apiKeyEdited = true;
      });
      _showMessage('手机提交的 API Key 已保存');
      return true;
    } finally {
      if (mounted) setState(() => _savingApiKey = false);
    }
  }

  Widget _buildApiKeyConfiguration() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('API 配置', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      RemoteTextFieldTraversal(
        controller: _apiKeyController,
        child: TextField(
          key: const ValueKey('api-key-field'),
          controller: _apiKeyController,
          enabled: !_busy,
          obscureText: _obscureKey,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: [LengthLimitingTextInputFormatter(8192)],
          onChanged: (_) => _apiKeyEdited = true,
          decoration: InputDecoration(
            labelText: 'ChKSz API Key',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _obscureKey ? '显示 API Key' : '隐藏 API Key',
              icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off),
              onPressed: _busy
                  ? null
                  : () => setState(() => _obscureKey = !_obscureKey),
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
            key: const ValueKey('api-key-save'),
            onPressed: _busy ? null : _saveApiKey,
            icon: _savingApiKey
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: const Text('保存 API Key'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('api-key-qr-input'),
            onPressed: _busy ? null : _showApiKeyQrInput,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('手机扫码输入'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _showApiKeyHelp(context),
            icon: const Icon(Icons.help_outline),
            label: const Text('如何获取？'),
          ),
        ],
      ),
    ],
  );

  void _showApiKeyHelp(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (ctx) => AlertDialog(
        title: const Text('获取 API Key'),
        scrollable: true,
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
