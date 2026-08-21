enum AiProviderKind {
  openAi('OpenAI', 'openai'),
  anthropic('Claude', 'anthropic'),
  gemini('Gemini', 'gemini'),
  xai('Grok', 'xai'),
  deepSeek('DeepSeek', 'deepseek'),
  glm('GLM', 'glm'),
  mimo('小米 MiMo', 'mimo'),
  qwen('Qwen', 'qwen'),
  custom('自定义中转站', 'custom');

  final String label;
  final String value;

  const AiProviderKind(this.label, this.value);

  AiRequestProtocol get defaultProtocol => switch (this) {
    AiProviderKind.openAi => AiRequestProtocol.openAiResponses,
    AiProviderKind.anthropic => AiRequestProtocol.anthropicMessages,
    AiProviderKind.gemini => AiRequestProtocol.geminiGenerateContent,
    AiProviderKind.xai => AiRequestProtocol.openAiResponses,
    _ => AiRequestProtocol.openAiChatCompletions,
  };

  String get defaultBaseUrl => switch (this) {
    AiProviderKind.openAi => 'https://api.openai.com/v1',
    AiProviderKind.anthropic => 'https://api.anthropic.com/v1',
    AiProviderKind.gemini => 'https://generativelanguage.googleapis.com/v1beta',
    AiProviderKind.xai => 'https://api.x.ai/v1',
    AiProviderKind.deepSeek => 'https://api.deepseek.com',
    AiProviderKind.glm => 'https://open.bigmodel.cn/api/paas/v4',
    AiProviderKind.mimo => 'https://api.xiaomimimo.com/v1',
    AiProviderKind.qwen => 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    AiProviderKind.custom => '',
  };

  static AiProviderKind fromValue(String? value) => values.firstWhere(
    (item) => item.value == value,
    orElse: () => AiProviderKind.openAi,
  );
}

enum AiRequestProtocol {
  openAiResponses('OpenAI Responses', 'openai_responses'),
  openAiChatCompletions('OpenAI Chat Completions', 'openai_chat'),
  anthropicMessages('Anthropic Messages', 'anthropic_messages'),
  geminiGenerateContent('Gemini GenerateContent', 'gemini_generate_content');

  final String label;
  final String value;

  const AiRequestProtocol(this.label, this.value);

  static AiRequestProtocol fromValue(String? value) => values.firstWhere(
    (item) => item.value == value,
    orElse: () => AiRequestProtocol.openAiResponses,
  );
}

enum AiReasoningEffort {
  platformDefault('平台默认', 'default'),
  off('关闭', 'off'),
  minimal('极低', 'minimal'),
  low('低', 'low'),
  medium('中', 'medium'),
  high('高', 'high'),
  maximum('极高', 'maximum');

  final String label;
  final String value;

  const AiReasoningEffort(this.label, this.value);

  static AiReasoningEffort fromValue(String? value) => values.firstWhere(
    (item) => item.value == value,
    orElse: () => AiReasoningEffort.platformDefault,
  );
}

enum AiWebSearchMode {
  disabled('关闭', 'disabled'),
  automatic('按需使用', 'automatic'),
  always('尽量强制', 'always');

  final String label;
  final String value;

  const AiWebSearchMode(this.label, this.value);

  static AiWebSearchMode fromValue(String? value) => values.firstWhere(
    (item) => item.value == value,
    orElse: () => AiWebSearchMode.automatic,
  );
}

class AiAssistantConfig {
  final AiProviderKind provider;
  final AiRequestProtocol protocol;
  final String baseUrl;
  final String apiKey;
  final String model;
  final AiReasoningEffort reasoningEffort;
  final AiWebSearchMode webSearchMode;

  const AiAssistantConfig({
    required this.provider,
    required this.protocol,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.reasoningEffort,
    required this.webSearchMode,
  });

  factory AiAssistantConfig.defaults() => AiAssistantConfig(
    provider: AiProviderKind.openAi,
    protocol: AiProviderKind.openAi.defaultProtocol,
    baseUrl: AiProviderKind.openAi.defaultBaseUrl,
    apiKey: '',
    model: '',
    reasoningEffort: AiReasoningEffort.platformDefault,
    webSearchMode: AiWebSearchMode.automatic,
  );

  bool get isComplete =>
      Uri.tryParse(baseUrl.trim())?.hasScheme == true &&
      apiKey.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  AiAssistantConfig copyWith({
    AiProviderKind? provider,
    AiRequestProtocol? protocol,
    String? baseUrl,
    String? apiKey,
    String? model,
    AiReasoningEffort? reasoningEffort,
    AiWebSearchMode? webSearchMode,
  }) => AiAssistantConfig(
    provider: provider ?? this.provider,
    protocol: protocol ?? this.protocol,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    webSearchMode: webSearchMode ?? this.webSearchMode,
  );

  Map<String, dynamic> toPreferencesJson() => {
    'provider': provider.value,
    'protocol': protocol.value,
    'baseUrl': baseUrl.trim(),
    'model': model.trim(),
    'reasoningEffort': reasoningEffort.value,
    'webSearchMode': webSearchMode.value,
  };

  factory AiAssistantConfig.fromJson(
    Map<String, dynamic> json, {
    String apiKey = '',
  }) {
    final provider = AiProviderKind.fromValue(json['provider']?.toString());
    return AiAssistantConfig(
      provider: provider,
      protocol: AiRequestProtocol.fromValue(json['protocol']?.toString()),
      baseUrl: json['baseUrl']?.toString().trim().isNotEmpty == true
          ? json['baseUrl'].toString().trim()
          : provider.defaultBaseUrl,
      apiKey: apiKey,
      model: json['model']?.toString().trim() ?? '',
      reasoningEffort: AiReasoningEffort.fromValue(
        json['reasoningEffort']?.toString(),
      ),
      webSearchMode: AiWebSearchMode.fromValue(
        json['webSearchMode']?.toString(),
      ),
    );
  }

  Map<String, dynamic> toLanJson() => {
    ...toPreferencesJson(),
    'apiKey': apiKey.trim(),
  };
}

/// A model advertised by an AI provider's model-list endpoint.
///
/// `id` is the value sent in chat requests. `label` may contain a more
/// descriptive provider display name, while keeping the raw id available for
/// gateways that use non-standard names.
class AiModelOption {
  final String id;
  final String? label;

  const AiModelOption({required this.id, this.label});

  String get displayName =>
      label == null || label!.trim().isEmpty ? id : '${label!.trim()} ($id)';

  @override
  bool operator ==(Object other) =>
      other is AiModelOption && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

enum AiMessageRole { user, assistant }

class AiConversationMessage {
  final AiMessageRole role;
  final String text;
  final DateTime createdAt;

  AiConversationMessage({
    required this.role,
    required this.text,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}

class AiPlaySongRequest {
  final String title;
  final String artist;

  const AiPlaySongRequest({required this.title, required this.artist});
}

class AiChatResult {
  final String reply;
  final AiPlaySongRequest? playRequest;
  final List<Uri> sources;

  const AiChatResult({
    required this.reply,
    this.playRequest,
    this.sources = const [],
  });
}

class AiConnectionCheck {
  final bool success;
  final bool webSearchObserved;
  final String message;

  const AiConnectionCheck({
    required this.success,
    required this.webSearchObserved,
    required this.message,
  });
}
