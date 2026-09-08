import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/playback_source_config.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/lan_api_key_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import '../widgets/remote_focusable.dart';

class PlaybackSourceConfigScreen extends StatefulWidget {
  const PlaybackSourceConfigScreen({super.key});

  @override
  State<PlaybackSourceConfigScreen> createState() =>
      _PlaybackSourceConfigScreenState();
}

class _PlaybackSourceConfigScreenState
    extends State<PlaybackSourceConfigScreen> {
  final _apiKeyController = TextEditingController();
  bool _obscureKey = true;
  bool _apiKeyEdited = false;
  bool _savingApiKey = false;
  bool _apiKeyQrInputInProgress = false;
  LanApiKeySession? _activeApiKeySession;
  late final TextEditingController _chkszUrlController;
  late final TextEditingController _qingMusicUrlController;
  late final TextEditingController _hywUrlController;
  late final TextEditingController _hywCardKeyController;
  late final TextEditingController _xinghaiUrlController;
  late final TextEditingController _xinghaiIpUrlController;
  late final TextEditingController _xinghaiClientController;
  late final TextEditingController _xinghaiDeviceIdController;
  late final TextEditingController _gdStudioUrlController;

  bool _chkszEnabled = true;
  bool _qingMusicEnabled = true;
  bool _hywEnabled = true;
  bool _xinghaiEnabled = true;
  bool _gdStudioEnabled = true;
  bool _obscureHywKey = true;
  bool _saving = false;
  bool _testingAll = false;
  final Set<PlaybackSource> _testingSources = <PlaybackSource>{};
  final Map<PlaybackSource, PlaybackSourceTestResult> _testResults = {};
  late final Completer<void> _testCancelSignal;
  int _testRequestId = 0;

  @override
  void initState() {
    super.initState();
    _testCancelSignal = Completer<void>();
    final player = context.read<PlayerProvider>();
    final config = player.playbackSourceConfig;
    _apiKeyController.text = player.apiKey;
    player.settingsReady.then((_) {
      if (mounted && !_apiKeyEdited) {
        _apiKeyController.text = player.apiKey;
      }
    });
    _chkszUrlController = TextEditingController();
    _qingMusicUrlController = TextEditingController();
    _hywUrlController = TextEditingController();
    _hywCardKeyController = TextEditingController();
    _xinghaiUrlController = TextEditingController();
    _xinghaiIpUrlController = TextEditingController();
    _xinghaiClientController = TextEditingController();
    _xinghaiDeviceIdController = TextEditingController();
    _gdStudioUrlController = TextEditingController();
    _applyConfig(config, rebuild: false);
  }

  @override
  void dispose() {
    final apiKeySession = _activeApiKeySession;
    _activeApiKeySession = null;
    if (apiKeySession != null) unawaited(apiKeySession.stop());
    _apiKeyController.dispose();
    _testRequestId++;
    if (!_testCancelSignal.isCompleted) _testCancelSignal.complete();
    _chkszUrlController.dispose();
    _qingMusicUrlController.dispose();
    _hywUrlController.dispose();
    _hywCardKeyController.dispose();
    _xinghaiUrlController.dispose();
    _xinghaiIpUrlController.dispose();
    _xinghaiClientController.dispose();
    _xinghaiDeviceIdController.dispose();
    _gdStudioUrlController.dispose();
    super.dispose();
  }

  void _applyConfig(PlaybackSourceConfig config, {required bool rebuild}) {
    void update() {
      _chkszEnabled = config.chkszEnabled;
      _qingMusicEnabled = config.qingMusicEnabled;
      _hywEnabled = config.hywEnabled;
      _xinghaiEnabled = config.xinghaiEnabled;
      _gdStudioEnabled = config.gdStudioEnabled;
      _chkszUrlController.text = config.chkszBaseUrl;
      _qingMusicUrlController.text = config.qingMusicUrl;
      _hywUrlController.text = config.hywBaseUrl;
      _hywCardKeyController.text = config.hywCardKey;
      _xinghaiUrlController.text = config.xinghaiUrl;
      _xinghaiIpUrlController.text = config.xinghaiIpUrl;
      _xinghaiClientController.text = config.xinghaiClient;
      _xinghaiDeviceIdController.text = config.xinghaiDeviceId;
      _gdStudioUrlController.text = config.gdStudioUrl;
      _testResults.clear();
    }

    if (rebuild) {
      setState(update);
    } else {
      update();
    }
  }

  PlaybackSourceConfig _draftConfig() => PlaybackSourceConfig(
    chkszEnabled: _chkszEnabled,
    qingMusicEnabled: _qingMusicEnabled,
    hywEnabled: _hywEnabled,
    xinghaiEnabled: _xinghaiEnabled,
    gdStudioEnabled: _gdStudioEnabled,
    chkszBaseUrl: _chkszUrlController.text,
    qingMusicUrl: _qingMusicUrlController.text,
    hywBaseUrl: _hywUrlController.text,
    hywCardKey: _hywCardKeyController.text,
    xinghaiUrl: _xinghaiUrlController.text,
    xinghaiIpUrl: _xinghaiIpUrlController.text,
    xinghaiClient: _xinghaiClientController.text,
    xinghaiDeviceId: _xinghaiDeviceIdController.text,
    gdStudioUrl: _gdStudioUrlController.text,
  );

  bool get _busy =>
      _saving ||
      _savingApiKey ||
      _apiKeyQrInputInProgress ||
      _testingAll ||
      _testingSources.isNotEmpty;

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
        _testResults.remove(PlaybackSource.chksz);
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
        _testResults.remove(PlaybackSource.chksz);
      });
      _showMessage('手机提交的 API Key 已保存');
      return true;
    } finally {
      if (mounted) setState(() => _savingApiKey = false);
    }
  }

  PlaybackSourceConfig? _validatedDraftForProbe() {
    try {
      return _draftConfig().validated();
    } on FormatException catch (error) {
      _showMessage(error.message);
      return null;
    }
  }

  List<PlaybackSource> _draftEnabledSources(PlaybackSourceConfig config) => [
    for (final source in PlaybackSource.values)
      if (source != PlaybackSource.automatic && config.isEnabled(source))
        source,
  ];

  Future<void> _testSource(PlaybackSource source) async {
    if (_busy) return;
    final config = _validatedDraftForProbe();
    if (config == null) return;
    final requestId = ++_testRequestId;
    setState(() {
      _testingSources.add(source);
      _testResults.remove(source);
    });
    try {
      final result = await context.read<PlayerProvider>().testPlaybackSource(
        source,
        config: config,
        cancelSignal: _testCancelSignal.future,
      );
      if (!mounted || requestId != _testRequestId) return;
      setState(() => _testResults[source] = result);
    } catch (error) {
      if (mounted && requestId == _testRequestId) {
        _showMessage('测试失败：$error');
      }
    } finally {
      if (mounted && requestId == _testRequestId) {
        setState(() => _testingSources.remove(source));
      }
    }
  }

  Future<void> _testEnabledSources() async {
    if (_busy) return;
    final config = _validatedDraftForProbe();
    if (config == null) return;
    final sources = _draftEnabledSources(config);
    if (sources.isEmpty) {
      _showMessage('请至少勾选一个音乐源');
      return;
    }
    final requestId = ++_testRequestId;
    setState(() {
      _testingAll = true;
      _testingSources.addAll(sources);
      for (final source in sources) {
        _testResults.remove(source);
      }
    });
    try {
      final results = await context.read<PlayerProvider>().testPlaybackSources(
        config: config,
        enabledOnly: true,
        maxConcurrent: 3,
        cancelSignal: _testCancelSignal.future,
      );
      if (!mounted || requestId != _testRequestId) return;
      setState(() {
        for (final result in results) {
          _testResults[result.source] = result;
        }
      });
    } catch (error) {
      if (mounted && requestId == _testRequestId) {
        _showMessage('测试失败：$error');
      }
    } finally {
      if (mounted && requestId == _testRequestId) {
        setState(() {
          _testingAll = false;
          _testingSources.removeAll(sources);
        });
      }
    }
  }

  Future<void> _testAllSources() async {
    if (_busy) return;
    final config = _validatedDraftForProbe();
    if (config == null) return;
    final sources = PlaybackSource.values
        .where((source) => source != PlaybackSource.automatic)
        .toList(growable: false);
    final requestId = ++_testRequestId;
    setState(() {
      _testingAll = true;
      _testingSources.addAll(sources);
      for (final source in sources) {
        _testResults.remove(source);
      }
    });
    try {
      final results = await context.read<PlayerProvider>().testPlaybackSources(
        config: config,
        enabledOnly: false,
        maxConcurrent: 3,
        cancelSignal: _testCancelSignal.future,
      );
      if (!mounted || requestId != _testRequestId) return;
      setState(() {
        for (final result in results) {
          _testResults[result.source] = result;
        }
      });
    } catch (error) {
      if (mounted && requestId == _testRequestId) {
        _showMessage('测试失败：$error');
      }
    } finally {
      if (mounted && requestId == _testRequestId) {
        setState(() {
          _testingAll = false;
          _testingSources.removeAll(sources);
        });
      }
    }
  }

  String _testStatusText(PlaybackSource source) {
    if (_testingSources.contains(source)) return '测试中…';
    final result = _testResults[source];
    if (result == null) return '尚未测试';
    final latency = result.latencyMs == null ? '' : ' · ${result.latencyMs} ms';
    if (result.successful) return '已响应 · ${result.message}$latency';
    if (result.reachable) {
      return '可达 · ${result.message}$latency';
    }
    return '未连接 · ${result.message}$latency';
  }

  Color _testStatusColor(PlaybackSource source) {
    if (_testingSources.contains(source)) return AppColors.textSecondary;
    final result = _testResults[source];
    if (result == null) return AppColors.textSecondary;
    if (result.successful) return Colors.green.shade700;
    if (result.reachable) return Colors.orange.shade800;
    return Colors.red.shade700;
  }

  Future<void> _save() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    PlaybackSourceConfig config;
    try {
      config = _draftConfig().validated();
    } on FormatException catch (error) {
      _showMessage(error.message);
      return;
    }
    setState(() => _saving = true);
    try {
      await context.read<PlayerProvider>().setPlaybackSourceConfig(config);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('备用源配置已保存'),
          duration: Duration(seconds: 1),
        ),
      );
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) _showMessage('保存失败：$error');
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('备用源接口配置'),
        actions: [
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
          builder: (context, constraints) {
            final cards = _buildCards();
            final wide = constraints.maxWidth >= 960;
            return SingleChildScrollView(
              key: const PageStorageKey('playback-source-config-scroll'),
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            children: [cards[0], cards[1], cards[2]],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            children: [cards[3], cards[4], cards[5]],
                          ),
                        ),
                      ],
                    )
                  : Column(children: cards),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildCards() => [
    Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('接口连通性', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('test-enabled-playback-sources'),
                  onPressed: _busy
                      ? null
                      : () => unawaited(_testEnabledSources()),
                  icon: _testingAll
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.speed_rounded),
                  label: const Text('测试已启用源'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('test-all-playback-sources'),
                  onPressed: _busy ? null : () => unawaited(_testAllSources()),
                  icon: const Icon(Icons.network_check_rounded),
                  label: const Text('测试全部源'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    _sourceCard(
      source: PlaybackSource.chksz,
      cardKey: const ValueKey('source-config-chksz'),
      title: 'ChKSz',
      subtitle: '默认使用现有中转地址。',
      enabled: _chkszEnabled,
      onEnabled: (value) => setState(() => _chkszEnabled = value),
      children: [
        _textField(
          key: const ValueKey('source-config-chksz-url'),
          controller: _chkszUrlController,
          label: '服务基础 URL',
        ),
        const SizedBox(height: 16),
        _buildApiKeyConfiguration(),
      ],
    ),
    _sourceCard(
      source: PlaybackSource.qingMusic,
      cardKey: const ValueKey('source-config-qing'),
      title: 'QingMusic',
      subtitle: '统一 POST 解析接口，支持返回播放请求头。',
      enabled: _qingMusicEnabled,
      onEnabled: (value) => setState(() => _qingMusicEnabled = value),
      children: [
        _textField(
          key: const ValueKey('source-config-qing-url'),
          controller: _qingMusicUrlController,
          label: 'resolve-url 地址',
        ),
      ],
    ),
    _sourceCard(
      source: PlaybackSource.hyw,
      cardKey: const ValueKey('source-config-hyw'),
      title: 'HYWmusic',
      subtitle: '默认值来自 HYWmusic_beta；当前预置地址为 HTTP。',
      enabled: _hywEnabled,
      onEnabled: (value) => setState(() => _hywEnabled = value),
      children: [
        _textField(
          key: const ValueKey('source-config-hyw-url'),
          controller: _hywUrlController,
          label: '服务基础 URL',
        ),
        const SizedBox(height: 10),
        _textField(
          key: const ValueKey('source-config-hyw-key'),
          controller: _hywCardKeyController,
          label: 'X-Card-Key / key',
          obscureText: _obscureHywKey,
          maxLength: 1024,
          suffix: IconButton(
            tooltip: _obscureHywKey ? '显示 Card Key' : '隐藏 Card Key',
            onPressed: () => setState(() => _obscureHywKey = !_obscureHywKey),
            icon: Icon(
              _obscureHywKey ? Icons.visibility : Icons.visibility_off,
            ),
          ),
        ),
      ],
    ),
    _sourceCard(
      source: PlaybackSource.xinghai,
      cardKey: const ValueKey('source-config-xinghai'),
      title: '星海',
      subtitle: '生成 5 分钟动态 X-Token；设备 ID 和 X-Client 均可覆盖。',
      enabled: _xinghaiEnabled,
      onEnabled: (value) => setState(() => _xinghaiEnabled = value),
      children: [
        _textField(
          key: const ValueKey('source-config-xinghai-url'),
          controller: _xinghaiUrlController,
          label: '聚合接口 URL',
        ),
        const SizedBox(height: 10),
        _textField(
          key: const ValueKey('source-config-xinghai-ip-url'),
          controller: _xinghaiIpUrlController,
          label: '公网 IP 查询 URL（可留空）',
        ),
        const SizedBox(height: 10),
        _textField(
          key: const ValueKey('source-config-xinghai-client'),
          controller: _xinghaiClientController,
          label: 'X-Client',
          maxLength: 256,
        ),
        const SizedBox(height: 10),
        _textField(
          key: const ValueKey('source-config-xinghai-device'),
          controller: _xinghaiDeviceIdController,
          label: '设备 ID',
          maxLength: 256,
        ),
      ],
    ),
    _sourceCard(
      source: PlaybackSource.gdStudio,
      cardKey: const ValueKey('source-config-gd'),
      title: 'GDStudio',
      subtitle: '简单 GET 兜底；母带等档位会映射到后端最高可用码率。',
      enabled: _gdStudioEnabled,
      onEnabled: (value) => setState(() => _gdStudioEnabled = value),
      children: [
        _textField(
          key: const ValueKey('source-config-gd-url'),
          controller: _gdStudioUrlController,
          label: 'api.php 地址',
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('reset-playback-source-config'),
              onPressed: _busy
                  ? null
                  : () => _applyConfig(
                      PlaybackSourceConfig.defaults(),
                      rebuild: true,
                    ),
              icon: const Icon(Icons.restore),
              label: const Text('恢复 JS 默认值'),
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
  ];

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

  Widget _sourceCard({
    required PlaybackSource source,
    required Key cardKey,
    required String title,
    required String subtitle,
    required bool enabled,
    required ValueChanged<bool> onEnabled,
    required List<Widget> children,
  }) => Card(
    key: cardKey,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(title),
            subtitle: Text(subtitle),
            value: enabled,
            onChanged: _busy ? null : onEnabled,
          ),
          ...children,
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                _testResults[source]?.successful == true
                    ? Icons.check_circle_outline_rounded
                    : _testResults[source]?.reachable == true
                    ? Icons.warning_amber_rounded
                    : Icons.network_check_rounded,
                size: 19,
                color: _testStatusColor(source),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _testStatusText(source),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _testStatusColor(source)),
                ),
              ),
              IconButton(
                key: ValueKey('test-playback-source-${source.value}'),
                tooltip: '测试连通性和速度',
                onPressed: _busy ? null : () => unawaited(_testSource(source)),
                icon: const Icon(Icons.speed_rounded),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _textField({
    required Key key,
    required TextEditingController controller,
    required String label,
    bool obscureText = false,
    Widget? suffix,
    int maxLength = 2048,
  }) => TextField(
    key: key,
    controller: controller,
    enabled: !_busy,
    onChanged: (_) => setState(_testResults.clear),
    obscureText: obscureText,
    autocorrect: false,
    enableSuggestions: false,
    textInputAction: TextInputAction.next,
    inputFormatters: [LengthLimitingTextInputFormatter(maxLength)],
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      suffixIcon: suffix,
    ),
  );
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
