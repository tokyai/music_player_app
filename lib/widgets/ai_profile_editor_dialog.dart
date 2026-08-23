import 'package:flutter/material.dart';

import '../models/ai_assistant.dart';
import '../providers/ai_config_controller.dart';
import '../services/ai_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import 'remote_focusable.dart';

/// Edits one saved AI endpoint/model profile.
///
/// Keeping the form in its own route prevents the settings page from growing
/// into a second configuration screen and makes the same editor usable for
/// every profile in the list.
class AiProfileEditorDialog extends StatefulWidget {
  final AiConfigController controller;
  final AiAssistantProfile profile;
  final Future<AiAssistantConfig?> Function(String profileId) onScanConfig;

  const AiProfileEditorDialog({
    super.key,
    required this.controller,
    required this.profile,
    required this.onScanConfig,
  });

  @override
  State<AiProfileEditorDialog> createState() => _AiProfileEditorDialogState();
}

class _AiProfileEditorDialogState extends State<AiProfileEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;

  late AiProviderKind _provider;
  late AiRequestProtocol _protocol;
  late AiReasoningEffort _reasoning;
  late AiWebSearchMode _webSearch;
  late AiVoiceModelKind _voiceModel;

  bool _obscureKey = true;
  bool _saving = false;
  bool _testing = false;
  bool _fetchingModels = false;
  List<AiModelOption> _models = const [];
  String? _modelsError;

  @override
  void initState() {
    super.initState();
    final config = widget.profile.config;
    _nameController = TextEditingController(text: widget.profile.name);
    _urlController = TextEditingController(text: config.baseUrl);
    _apiKeyController = TextEditingController(text: config.apiKey);
    _modelController = TextEditingController(text: config.model);
    _provider = config.provider;
    _protocol = config.protocol;
    _reasoning = config.reasoningEffort;
    _webSearch = config.webSearchMode;
    _voiceModel = config.voiceModel;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  AiAssistantConfig _configFromForm() => AiAssistantConfig(
    provider: _provider,
    protocol: _protocol,
    baseUrl: _urlController.text.trim(),
    apiKey: _apiKeyController.text.trim(),
    model: _modelController.text.trim(),
    reasoningEffort: _reasoning,
    webSearchMode: _webSearch,
    voiceModel: _voiceModel,
  );

  void _markChanged({bool clearModels = false}) {
    if (!mounted) return;
    setState(() {
      if (clearModels) {
        _models = const [];
        _modelsError = null;
      }
    });
  }

  void _applyConfig(AiAssistantConfig config) {
    _provider = config.provider;
    _protocol = config.protocol;
    _reasoning = config.reasoningEffort;
    _webSearch = config.webSearchMode;
    _voiceModel = config.voiceModel;
    _urlController.text = config.baseUrl;
    _apiKeyController.text = config.apiKey;
    _modelController.text = config.model;
    _models = const [];
    _modelsError = null;
  }

  void _selectProvider(AiProviderKind provider) {
    final previousDefault = _provider.defaultBaseUrl;
    final currentUrl = _urlController.text.trim();
    setState(() {
      _provider = provider;
      _protocol = provider.defaultProtocol;
      if (currentUrl.isEmpty || currentUrl == previousDefault) {
        _urlController.text = provider.defaultBaseUrl;
      }
      _models = const [];
      _modelsError = null;
    });
  }

  Future<void> _fetchModels() async {
    if (_fetchingModels) return;
    final config = _configFromForm();
    if (config.baseUrl.trim().isEmpty || config.apiKey.trim().isEmpty) {
      _showMessage('请先填写 AI URL 和 API Key');
      return;
    }
    setState(() {
      _fetchingModels = true;
      _modelsError = null;
    });
    final service = AiAssistantService();
    try {
      final models = await service.fetchModels(config);
      if (!mounted) return;
      setState(() {
        _models = models;
        _fetchingModels = false;
      });
      _showMessage('已获取 ${models.length} 个可用模型');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _fetchingModels = false;
        _modelsError = error.toString();
      });
      _showMessage('获取模型失败：$error');
    } finally {
      service.close();
      if (mounted && _fetchingModels) {
        setState(() => _fetchingModels = false);
      }
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final config = _configFromForm();
    if (!config.isComplete) {
      _showMessage('请完整填写中转站 URL、API Key 和模型');
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.controller.updateProfile(
        widget.profile.id,
        name: _nameController.text.trim(),
        config: config,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      _showMessage('AI 助理配置已安全保存');
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showMessage('保存失败：$error');
    }
  }

  Future<void> _testConnection() async {
    if (_testing) return;
    final config = _configFromForm();
    if (!config.isComplete) {
      _showMessage('请先完整填写 AI 配置');
      return;
    }
    setState(() => _testing = true);
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
    } catch (error) {
      if (mounted) _showMessage('连接测试失败：$error');
    } finally {
      service.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _scanConfig() async {
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final config = await widget.onScanConfig(widget.profile.id);
      if (!mounted || config == null) return;
      setState(() => _applyConfig(config));
    } catch (error) {
      _showMessage('扫码配置失败：$error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.fromContext(context);
    final compact = layout.isCompactLandscape;
    final size = MediaQuery.sizeOf(context);
    final searchDependsOnRelay =
        _webSearch != AiWebSearchMode.disabled &&
        (_provider == AiProviderKind.deepSeek ||
            _provider == AiProviderKind.custom);

    return Dialog(
      key: const ValueKey('ai-profile-editor-dialog'),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 700,
          maxHeight: size.height * (compact ? 0.94 : 0.9),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 22,
                  compact ? 12 : 18,
                  compact ? 14 : 22,
                  8,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.tune_rounded, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '编辑模型配置',
                        style: TextStyle(
                          fontSize: layout.sectionTitleSize,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('ai-profile-editor-close'),
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 14 : 22,
                    14,
                    compact ? 14 : 22,
                    8,
                  ),
                  child: _buildForm(
                    layout,
                    searchDependsOnRelay: searchDependsOnRelay,
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 10 : 18,
                  8,
                  compact ? 10 : 18,
                  compact ? 10 : 14,
                ),
                child: _buildActions(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForm(AppLayout layout, {required bool searchDependsOnRelay}) {
    final secondarySize = layout.secondarySize;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RemoteTextFieldTraversal(
          controller: _nameController,
          child: TextField(
            key: const ValueKey('ai-profile-name-field'),
            controller: _nameController,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: '配置名称',
              hintText: '例如：主力模型、车机轻量模型',
            ),
          ),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<AiProviderKind>(
          key: ValueKey('ai-provider-${_provider.value}'),
          initialValue: _provider,
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
            if (provider != null) _selectProvider(provider);
          },
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<AiRequestProtocol>(
          key: ValueKey('ai-protocol-${_protocol.value}'),
          initialValue: _protocol,
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
              _protocol = protocol;
              _models = const [];
              _modelsError = null;
            });
          },
        ),
        const SizedBox(height: 10),
        RemoteTextFieldTraversal(
          controller: _urlController,
          child: TextField(
            key: const ValueKey('ai-base-url-field'),
            controller: _urlController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            onChanged: (_) => _markChanged(clearModels: true),
            decoration: const InputDecoration(
              labelText: '中转站 Base URL',
              hintText: 'https://example.com/v1',
            ),
          ),
        ),
        const SizedBox(height: 10),
        RemoteTextFieldTraversal(
          controller: _apiKeyController,
          child: TextField(
            key: const ValueKey('ai-api-key-field'),
            controller: _apiKeyController,
            obscureText: _obscureKey,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => _markChanged(clearModels: true),
            decoration: InputDecoration(
              labelText: 'API Key',
              suffixIcon: IconButton(
                tooltip: _obscureKey ? '显示 Key' : '隐藏 Key',
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
                icon: Icon(
                  _obscureKey ? Icons.visibility : Icons.visibility_off,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        RemoteTextFieldTraversal(
          controller: _modelController,
          child: TextField(
            key: const ValueKey('ai-model-field'),
            controller: _modelController,
            autocorrect: false,
            onChanged: (_) => _markChanged(),
            decoration: InputDecoration(
              labelText: '模型',
              hintText: '填写模型，或点击“获取模型”后选择',
              suffixIcon: _models.isEmpty
                  ? null
                  : PopupMenuButton<AiModelOption>(
                      key: const ValueKey('ai-model-menu'),
                      tooltip: '选择已发现模型',
                      icon: const Icon(Icons.arrow_drop_down),
                      onSelected: (model) => setState(() {
                        _modelController.text = model.id;
                      }),
                      itemBuilder: (context) => _models
                          .map(
                            (model) => PopupMenuItem<AiModelOption>(
                              value: model,
                              child: Text(
                                model.displayName,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('ai-model-fetch'),
            onPressed: _fetchingModels ? null : _fetchModels,
            icon: _fetchingModels
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded),
            label: Text(_fetchingModels ? '获取中' : '从 URL 获取模型'),
          ),
        ),
        if (_models.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '已发现 ${_models.length} 个模型，点击模型输入框右侧箭头选择；也可继续手动输入。',
            style: TextStyle(color: AppColors.textHint),
          ),
        ],
        if (_modelsError != null) ...[
          const SizedBox(height: 4),
          Text(_modelsError!, style: TextStyle(color: Colors.orange)),
        ],
        const SizedBox(height: 10),
        DropdownButtonFormField<AiVoiceModelKind>(
          key: ValueKey('ai-voice-model-${_voiceModel.value}'),
          initialValue: _voiceModel,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '车机离线语音模型',
            helperText: '只加载当前选择的模型；保存后下次打开 AI 助手生效',
          ),
          items: AiVoiceModelKind.values
              .map(
                (model) =>
                    DropdownMenuItem(value: model, child: Text(model.label)),
              )
              .toList(),
          onChanged: (model) {
            if (model != null) setState(() => _voiceModel = model);
          },
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<AiReasoningEffort>(
          key: ValueKey('ai-reasoning-${_reasoning.value}'),
          initialValue: _reasoning,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '推理等级'),
          items: AiReasoningEffort.values
              .map(
                (effort) =>
                    DropdownMenuItem(value: effort, child: Text(effort.label)),
              )
              .toList(),
          onChanged: (effort) {
            if (effort != null) setState(() => _reasoning = effort);
          },
        ),
        const SizedBox(height: 4),
        Text(
          '选择“平台默认”时不会发送任何推理等级参数。其他等级会按当前协议转换。',
          style: TextStyle(color: AppColors.textHint, fontSize: secondarySize),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<AiWebSearchMode>(
          key: ValueKey('ai-web-search-${_webSearch.value}'),
          initialValue: _webSearch,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '联网搜索'),
          items: AiWebSearchMode.values
              .map(
                (mode) =>
                    DropdownMenuItem(value: mode, child: Text(mode.label)),
              )
              .toList(),
          onChanged: (mode) {
            if (mode != null) setState(() => _webSearch = mode);
          },
        ),
        if (searchDependsOnRelay) ...[
          const SizedBox(height: 6),
          Text(
            '当前厂商的 OpenAI 兼容接口没有统一搜索字段，是否联网取决于中转站能力；请用“测试连接”核验。',
            style: TextStyle(color: Colors.orange, fontSize: secondarySize),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          'API Key 仅用于连接 AI 服务；显式备份会按你的选择一并导出。',
          style: TextStyle(color: AppColors.textHint, fontSize: secondarySize),
        ),
      ],
    );
  }

  Widget _buildActions() {
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('ai-config-qr-input'),
          onPressed: _scanConfig,
          icon: const Icon(Icons.qr_code_scanner_rounded),
          label: const Text('手机扫码配置'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('ai-config-test'),
          onPressed: _testing ? null : _testConnection,
          icon: _testing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.network_check_rounded),
          label: Text(_testing ? '测试中' : '测试连接'),
        ),
        FilledButton.icon(
          key: const ValueKey('ai-config-save'),
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(_saving ? '保存中' : '保存'),
        ),
      ],
    );
  }
}
