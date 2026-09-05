import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/playback_source_config.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../theme/app_theme.dart';

class PlaybackSourceConfigScreen extends StatefulWidget {
  const PlaybackSourceConfigScreen({super.key});

  @override
  State<PlaybackSourceConfigScreen> createState() =>
      _PlaybackSourceConfigScreenState();
}

class _PlaybackSourceConfigScreenState
    extends State<PlaybackSourceConfigScreen> {
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
    final config = context.read<PlayerProvider>().playbackSourceConfig;
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

  bool get _busy => _saving || _testingAll || _testingSources.isNotEmpty;

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
    if (result.successful) return '可用$latency';
    if (result.reachable) {
      return '可达 · ${result.message}$latency';
    }
    return '不可用 · ${result.message}$latency';
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
            Text('自动备用顺序', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text('ChKSz（有 Key 时）→ QingMusic → HYW → 星海 → GDStudio'),
            const SizedBox(height: 6),
            Text(
              '主组内并行竞速，全部失败后进入 GDStudio 兜底组；每档失败后最多自动降 3 档。选择具体源时不会自动切换。',
              style: TextStyle(color: AppColors.textSecondary),
            ),
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
      subtitle: 'API Key 仍在设置页“API 配置”中填写。默认使用现有中转地址。',
      enabled: _chkszEnabled,
      onEnabled: (value) => setState(() => _chkszEnabled = value),
      children: [
        _textField(
          key: const ValueKey('source-config-chksz-url'),
          controller: _chkszUrlController,
          label: '服务基础 URL',
        ),
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
