import '../models/ai_assistant.dart';
import '../providers/ai_config_controller.dart';
import '../providers/ai_assistant_controller.dart';
import 'runtime_bridge_protocol.dart';
import 'ai_service.dart';

/// 固定语音和 AI 会话能力，配置表单及会话展示来自远程业务包。
/// SHIXIAOYANG，2026/11/19。
class NativeRuntimeAssistant {
  final AiConfigController config;
  final AiAssistantController controller;
  final void Function() ensureActive;
  AiAssistantService? _service;

  NativeRuntimeAssistant({
    required this.config,
    required this.controller,
    required this.ensureActive,
  });

  /// 高频状态只携带短状态，不复制完整对话。
  Map<String, dynamic> state() => {
    'active': controller.isActive,
    'state': controller.state.name,
    'status': controller.statusLabel,
    'transcript': controller.transcript,
    'error': controller.error,
  };

  /// 复用既有语音生命周期；页面不直接持有麦克风、模型或 TTS 句柄。
  Future<Map<String, dynamic>> handle(Map<String, dynamic> data) async {
    ensureActive();
    switch (data['action'] ?? 'history') {
      case 'start':
        await controller.startSession();
        break;
      case 'stop':
        await controller.stopSession();
        break;
      case 'listen':
        await controller.toggleListening();
        break;
      case 'new':
        await controller.newSession();
        break;
      case 'send':
        await controller.sendText(
          RuntimeBridgeProtocol.text(data, 'text', max: 8000),
        );
        break;
      case 'history':
        break;
      default:
        throw const FormatException('助理操作无效');
    }
    ensureActive();
    return {
      'state': state(),
      'messages': controller.messages
          .skip(
            controller.messages.length > 40
                ? controller.messages.length - 40
                : 0,
          )
          .map(
            (item) => {
              'role': item.role.name,
              'text': item.text,
              'createdAt': item.createdAt.toIso8601String(),
            },
          )
          .toList(),
    };
  }

  /// 配置密钥交给已有安全存储，不返回到普通状态消息。
  Future<Map<String, dynamic>> configure(Map<String, dynamic> data) async {
    ensureActive();
    switch (data['action'] ?? 'get') {
      case 'save':
        final raw = data['values'];
        if (raw is! Map) throw const FormatException('AI 配置无效');
        final values = Map<String, dynamic>.from(raw);
        final url = RuntimeBridgeProtocol.text(values, 'baseUrl', max: 2048);
        final endpoint = Uri.tryParse(url);
        if (endpoint == null ||
            !['https', 'http'].contains(endpoint.scheme) ||
            endpoint.host.isEmpty ||
            endpoint.userInfo.isNotEmpty) {
          throw const FormatException('AI 地址无效');
        }
        RuntimeBridgeProtocol.text(values, 'model', max: 128);
        final key = RuntimeBridgeProtocol.text(
          values,
          'apiKey',
          max: 2048,
          required: false,
        );
        await config.save(
          AiAssistantConfig.fromJson(
            values,
            apiKey: key.isEmpty ? config.config.apiKey : key,
          ),
        );
        break;
      case 'select':
        await config.selectProfile(
          RuntimeBridgeProtocol.text(data, 'id', max: 128),
        );
        break;
      case 'create':
        await config.createProfile(
          name: RuntimeBridgeProtocol.text(data, 'name', max: 32),
        );
        break;
      case 'delete':
        await config.deleteProfile(
          RuntimeBridgeProtocol.text(data, 'id', max: 128),
        );
        break;
      case 'voice':
        final values = data['values'];
        if (values is! Map) throw const FormatException('语音设置无效');
        await config.restoreVoiceBackupJson(Map<String, dynamic>.from(values));
        break;
      case 'check':
        final service = AiAssistantService();
        _service = service;
        try {
          final result = await service.checkConnection(config.config);
          ensureActive();
          return {'success': result.success, 'message': result.message};
        } finally {
          service.close();
          if (identical(_service, service)) _service = null;
        }
      case 'get':
        break;
      default:
        throw const FormatException('AI 配置操作无效');
    }
    ensureActive();
    return {
      'config': config.config.toPreferencesJson(),
      'configured': config.config.isComplete,
      'profiles': config.profiles
          .map((item) => item.toPreferencesJson())
          .toList(),
      'active': config.activeProfileId,
      'voice': config.toVoiceBackupJson(),
      'providers': AiProviderKind.values
          .map(
            (item) => {
              'id': item.value,
              'name': item.label,
              'baseUrl': item.defaultBaseUrl,
              'protocol': item.defaultProtocol.value,
            },
          )
          .toList(),
      'protocols': AiRequestProtocol.values
          .map((item) => {'id': item.value, 'name': item.label})
          .toList(),
    };
  }

  /// 业务页面卸载时中止页面拥有的连接测试。
  void resetPage() {
    _service?.close();
    _service = null;
  }
}
