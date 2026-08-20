import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_assistant.dart';
import 'bounded_http_response.dart';

const _assistantSystemPrompt = '''你是库仔音乐里的 AI 小助理，使用中文和用户自然对话。
你不是只能回答音乐问题。你可以处理日常聊天、知识问答、天气、翻译、计算、建议和音乐相关问题，并在用户明确要求播放某首歌时调用 play_song。
天气等实时问题缺少城市或必要条件时，先用一句话追问；联网搜索不可用时，只说明无法取得实时数据，不要声称该类问题不能回答。
仅当用户明确说“播放/放/听/来一首/就要/选这首”等，或明确确认你刚刚列出的某个候选时，才调用 play_song。
用户只是询问推荐、歌单、资料或表达偏好时，绝对不要调用 play_song。
play_song 只填写确定的歌曲名和歌手名，不要编造歌曲 ID、URL 或平台资源。
如果歌手或歌曲不明确，先用一句话追问，不要调用工具。
联网搜索开启时，涉及今天、最新、资料核验或歌曲推荐的内容应按需使用搜索；没有搜索结果时不要声称已经联网。
回复简洁、自然，适合语音播报，不要输出 Markdown 表格。''';

class AiServiceException implements Exception {
  final String message;
  final int? statusCode;

  const AiServiceException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

abstract class AiChatGateway {
  Future<AiChatResult> sendMessage(
    AiAssistantConfig config,
    List<AiConversationMessage> messages, {
    bool connectionCheck = false,
  });

  Future<AiConnectionCheck> checkConnection(
    AiAssistantConfig config, {
    bool checkSearch = false,
  });

  void close();
}

class AiAssistantService implements AiChatGateway {
  static const _timeout = Duration(seconds: 35);
  static const _maxResponseBytes = 3 * 1024 * 1024;

  final http.Client _client;

  AiAssistantService({http.Client? client}) : _client = client ?? http.Client();

  @override
  Future<AiChatResult> sendMessage(
    AiAssistantConfig config,
    List<AiConversationMessage> messages, {
    bool connectionCheck = false,
  }) async {
    _validateConfig(config);
    final normalizedMessages = messages.isEmpty
        ? [
            AiConversationMessage(
              role: AiMessageRole.user,
              text: connectionCheck ? '请只回复 OK。' : '你好',
            ),
          ]
        : messages;
    final response = switch (config.protocol) {
      AiRequestProtocol.openAiResponses => await _requestOpenAiResponses(
        config,
        normalizedMessages,
      ),
      AiRequestProtocol.openAiChatCompletions => await _requestOpenAiChat(
        config,
        normalizedMessages,
      ),
      AiRequestProtocol.anthropicMessages => await _requestAnthropic(
        config,
        normalizedMessages,
      ),
      AiRequestProtocol.geminiGenerateContent => await _requestGemini(
        config,
        normalizedMessages,
      ),
    };
    final result = _parseResult(response);
    if (connectionCheck && result.reply.trim().isEmpty) {
      return const AiChatResult(reply: '连接成功');
    }
    return result;
  }

  @override
  Future<AiConnectionCheck> checkConnection(
    AiAssistantConfig config, {
    bool checkSearch = false,
  }) async {
    try {
      final prompt = checkSearch
          ? '请使用联网搜索核验今天的 UTC 日期，只用一句话回答并保留来源。'
          : '请只回复 OK。';
      final result = await sendMessage(
        config.copyWith(
          webSearchMode: checkSearch
              ? AiWebSearchMode.automatic
              : AiWebSearchMode.disabled,
        ),
        [AiConversationMessage(role: AiMessageRole.user, text: prompt)],
      );
      return AiConnectionCheck(
        success: true,
        webSearchObserved: result.sources.isNotEmpty,
        message: result.sources.isNotEmpty
            ? '连接成功，检测到联网搜索来源'
            : checkSearch
            ? '连接成功，但未检测到搜索来源；中转站可能未转发联网工具'
            : '连接成功',
      );
    } on AiServiceException catch (error) {
      return AiConnectionCheck(
        success: false,
        webSearchObserved: false,
        message: error.message,
      );
    } catch (error) {
      return AiConnectionCheck(
        success: false,
        webSearchObserved: false,
        message: '连接失败：$error',
      );
    }
  }

  Future<Map<String, dynamic>> _requestOpenAiResponses(
    AiAssistantConfig config,
    List<AiConversationMessage> messages,
  ) async {
    final tools = <Map<String, dynamic>>[];
    if (config.webSearchMode != AiWebSearchMode.disabled) {
      tools.add({'type': 'web_search'});
    }
    tools.add(_responsesPlayTool);
    final body = <String, dynamic>{
      'model': config.model.trim(),
      'instructions': _systemPrompt(config),
      'input': messages
          .map(
            (message) => {
              'role': message.role == AiMessageRole.user ? 'user' : 'assistant',
              'content': message.text,
            },
          )
          .toList(),
      'tools': tools,
    };
    _addOpenAiReasoning(body, config.reasoningEffort, responses: true);
    return _postJson(
      _joinEndpoint(config.baseUrl, '/responses'),
      body,
      headers: _bearerHeaders(config.apiKey),
    );
  }

  Future<Map<String, dynamic>> _requestOpenAiChat(
    AiAssistantConfig config,
    List<AiConversationMessage> messages,
  ) async {
    final tools = <Map<String, dynamic>>[_chatPlayTool];
    final body = <String, dynamic>{
      'model': config.model.trim(),
      'messages': [
        {'role': 'system', 'content': _systemPrompt(config)},
        ...messages.map(
          (message) => {
            'role': message.role == AiMessageRole.user ? 'user' : 'assistant',
            'content': message.text,
          },
        ),
      ],
      'tools': tools,
      'tool_choice': 'auto',
    };
    if (config.webSearchMode != AiWebSearchMode.disabled) {
      switch (config.provider) {
        case AiProviderKind.openAi:
          // OpenAI 的兼容 Chat Completions 搜索扩展；不支持的中转站可改用 Responses。
          body['web_search_options'] = {'search_context_size': 'medium'};
        case AiProviderKind.xai:
          body['tools'] = [
            {'type': 'web_search'},
            _chatPlayTool,
          ];
        case AiProviderKind.glm:
          body['tools'] = [
            {
              'type': 'web_search',
              'web_search': {'enable': true},
            },
            _chatPlayTool,
          ];
        case AiProviderKind.qwen:
          body['enable_search'] = true;
        case AiProviderKind.mimo:
          body['tools'] = [
            {
              'type': 'web_search',
              'max_keyword': 3,
              'force_search': config.webSearchMode == AiWebSearchMode.always,
              'limit': 1,
            },
            _chatPlayTool,
          ];
        case AiProviderKind.deepSeek ||
            AiProviderKind.custom ||
            AiProviderKind.anthropic ||
            AiProviderKind.gemini:
          // These Chat-compatible surfaces do not share a standard search
          // field. Select the provider-native protocol or let the relay
          // implement search explicitly instead of sending an unknown key.
          break;
      }
    }
    _addCompatibleReasoning(body, config);
    return _postJson(
      _joinEndpoint(config.baseUrl, '/chat/completions'),
      body,
      headers: _bearerHeaders(config.apiKey),
    );
  }

  Future<Map<String, dynamic>> _requestAnthropic(
    AiAssistantConfig config,
    List<AiConversationMessage> messages,
  ) async {
    final tools = <Map<String, dynamic>>[_anthropicPlayTool];
    if (config.webSearchMode != AiWebSearchMode.disabled) {
      tools.add({
        'type': 'web_search_20250305',
        'name': 'web_search',
        'max_uses': 5,
      });
    }
    final body = <String, dynamic>{
      'model': config.model.trim(),
      'max_tokens': 2048,
      'system': _systemPrompt(config),
      'messages': messages
          .map(
            (message) => {
              'role': message.role == AiMessageRole.user ? 'user' : 'assistant',
              'content': message.text,
            },
          )
          .toList(),
      'tools': tools,
    };
    final effort = _anthropicEffort(config.reasoningEffort);
    if (effort != null) body['output_config'] = {'effort': effort};
    if (config.reasoningEffort == AiReasoningEffort.off) {
      body['thinking'] = {'type': 'disabled'};
    }
    return _postJson(
      _joinEndpoint(config.baseUrl, '/messages'),
      body,
      headers: {
        'x-api-key': config.apiKey,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    );
  }

  Future<Map<String, dynamic>> _requestGemini(
    AiAssistantConfig config,
    List<AiConversationMessage> messages,
  ) async {
    final declarations = <Map<String, dynamic>>[
      {
        'name': 'play_song',
        'description': '在用户明确要求时播放一首确定的歌曲',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'artist': {'type': 'STRING', 'description': '歌手名'},
            'title': {'type': 'STRING', 'description': '歌曲名'},
          },
          'required': ['artist', 'title'],
        },
      },
    ];
    final contents = messages
        .map(
          (message) => {
            'role': message.role == AiMessageRole.user ? 'user' : 'model',
            'parts': [
              {'text': message.text},
            ],
          },
        )
        .toList();
    final body = <String, dynamic>{
      'systemInstruction': {
        'parts': [
          {'text': _systemPrompt(config)},
        ],
      },
      'contents': contents,
      'tools': <Map<String, dynamic>>[
        {'functionDeclarations': declarations},
        if (config.webSearchMode != AiWebSearchMode.disabled)
          {'googleSearch': <String, dynamic>{}},
      ],
    };
    final thinkingConfig = _geminiThinkingConfig(config);
    if (thinkingConfig != null) {
      body['generationConfig'] = {'thinkingConfig': thinkingConfig};
    }
    final endpoint = _joinEndpoint(
      config.baseUrl,
      '/models/${Uri.encodeComponent(config.model.trim())}:generateContent',
    );
    return _postJson(
      endpoint,
      body,
      headers: {
        'x-goog-api-key': config.apiKey,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    );
  }

  Future<Map<String, dynamic>> _postJson(
    String endpoint,
    Map<String, dynamic> body, {
    required Map<String, String> headers,
  }) async {
    final request = http.Request('POST', Uri.parse(endpoint))
      ..headers.addAll(headers)
      ..body = jsonEncode(body);
    try {
      final response = await sendBoundedHttpRequest(
        _client,
        request,
        maxBytes: _maxResponseBytes,
        timeout: _timeout,
      );
      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      dynamic decoded;
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        throw AiServiceException(
          'AI 返回了无效数据${response.statusCode == 200 ? '' : '（HTTP ${response.statusCode}）'}',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = decoded is Map
            ? _firstString(Map<String, dynamic>.from(decoded), const [
                'error',
                'message',
                'msg',
              ])
            : null;
        throw AiServiceException(
          message == null || message.isEmpty
              ? 'AI 请求失败（HTTP ${response.statusCode}）'
              : 'AI 请求失败：$message',
          statusCode: response.statusCode,
        );
      }
      if (decoded is! Map) throw const AiServiceException('AI 返回格式不是对象');
      return Map<String, dynamic>.from(decoded);
    } on AiServiceException {
      rethrow;
    } on TimeoutException {
      throw const AiServiceException('AI 请求超时，请检查网络或中转站设置');
    } catch (error) {
      throw AiServiceException('AI 请求失败：$error');
    }
  }

  AiChatResult _parseResult(Map<String, dynamic> response) {
    final texts = <String>[];
    AiPlaySongRequest? action;
    final sources = <Uri>{};

    void inspect(dynamic value) {
      if (value is Map) {
        final map = Map<String, dynamic>.from(value);
        final type = map['type']?.toString();
        if (type == 'function_call' ||
            type == 'tool_use' ||
            type == 'functionCall' ||
            map['name']?.toString() == 'play_song') {
          final name =
              map['name']?.toString() ??
              (map['function'] is Map
                  ? (map['function'] as Map)['name']?.toString()
                  : null);
          final rawArguments =
              map['arguments'] ??
              map['args'] ??
              map['input'] ??
              (map['function'] is Map
                  ? (map['function'] as Map)['arguments']
                  : null);
          if (name == 'play_song') {
            final parsed = _parsePlayRequest(rawArguments);
            if (parsed != null) action = parsed;
          }
        }
        final geminiCall = map['functionCall'];
        if (geminiCall is Map && geminiCall['name'] == 'play_song') {
          final parsed = _parsePlayRequest(geminiCall['args']);
          if (parsed != null) action = parsed;
        }
        final openAiFunction = map['function'];
        if (openAiFunction is Map && openAiFunction['name'] == 'play_song') {
          final parsed = _parsePlayRequest(openAiFunction['arguments']);
          if (parsed != null) action = parsed;
        }
        for (final entry in map.entries) {
          if (entry.key == 'url' || entry.key == 'uri' || entry.key == 'link') {
            final uri = Uri.tryParse(entry.value?.toString() ?? '');
            if (uri != null &&
                (uri.scheme == 'http' || uri.scheme == 'https')) {
              sources.add(uri);
            }
          }
          inspect(entry.value);
        }
      } else if (value is List) {
        for (final item in value) {
          inspect(item);
        }
      }
    }

    inspect(response);
    final extractedTexts = _extractTexts(response);
    texts.addAll(extractedTexts);
    final combined = texts.join('\n').trim();
    final textAction = _parseActionFromText(combined);
    action ??= textAction;
    final reply = _cleanReply(combined, action != null);
    return AiChatResult(
      reply: reply.isEmpty && action != null ? '好的，我来为你播放。' : reply,
      playRequest: action,
      sources: sources.toList(growable: false),
    );
  }

  List<String> _extractTexts(Map<String, dynamic> response) {
    final values = <String>[];
    void add(dynamic value) {
      if (value is String && value.trim().isNotEmpty) values.add(value.trim());
    }

    // OpenAI Responses.
    final output = response['output'];
    if (output is List) {
      for (final item in output) {
        if (item is! Map) continue;
        final content = item['content'];
        if (content is List) {
          for (final block in content) {
            if (block is Map) add(block['text']);
          }
        }
        add(item['text']);
      }
    }
    // OpenAI Chat Completions and compatible gateways.
    final choices = response['choices'];
    if (choices is List) {
      for (final choice in choices) {
        if (choice is! Map) continue;
        final message = choice['message'];
        if (message is Map) {
          add(message['content']);
          final toolCalls = message['tool_calls'];
          if (toolCalls is List) {
            for (final call in toolCalls) {
              if (call is Map) {
                final function = call['function'];
                if (function is Map && function['name'] == 'play_song') {
                  // The action is discovered by _parseResult's recursive walk.
                }
              }
            }
          }
        }
        add(choice['text']);
      }
    }
    // Anthropic Messages.
    final content = response['content'];
    if (content is List) {
      for (final block in content) {
        if (block is Map) add(block['text']);
      }
    }
    // Gemini GenerateContent.
    final candidates = response['candidates'];
    if (candidates is List) {
      for (final candidate in candidates) {
        if (candidate is! Map) continue;
        final parts = (candidate['content'] as Map?)?['parts'];
        if (parts is List) {
          for (final part in parts) {
            if (part is Map) add(part['text']);
          }
        }
      }
    }
    // Some relays expose output_text directly.
    add(response['output_text']);
    return values;
  }

  AiPlaySongRequest? _parseActionFromText(String text) {
    if (text.isEmpty) return null;
    final json = _tryDecodeJson(text);
    if (json != null) {
      final action = json['action']?.toString();
      if (action == 'play_song') {
        return _parsePlayRequest(json);
      }
    }
    return null;
  }

  AiPlaySongRequest? _parsePlayRequest(dynamic raw) {
    Map<String, dynamic>? map;
    if (raw is Map) {
      map = Map<String, dynamic>.from(raw);
    } else if (raw is String) {
      final decoded = _tryDecodeJson(raw);
      if (decoded != null) map = decoded;
    }
    if (map == null) return null;
    final title =
        (map['title'] ?? map['song'] ?? map['name'])?.toString().trim() ?? '';
    final artist =
        (map['artist'] ?? map['singer'] ?? map['author'])?.toString().trim() ??
        '';
    if (title.isEmpty || artist.isEmpty) return null;
    return AiPlaySongRequest(title: title, artist: artist);
  }

  Map<String, dynamic>? _tryDecodeJson(String text) {
    var candidate = text.trim();
    if (candidate.startsWith('```')) {
      candidate = candidate
          .replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '')
          .replaceFirst(RegExp(r'\s*```$'), '')
          .trim();
    }
    try {
      final decoded = jsonDecode(candidate);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      final start = candidate.indexOf('{');
      final end = candidate.lastIndexOf('}');
      if (start >= 0 && end > start) {
        try {
          final decoded = jsonDecode(candidate.substring(start, end + 1));
          return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
        } catch (_) {}
      }
    }
    return null;
  }

  String _cleanReply(String text, bool hasAction) {
    var result = text.trim();
    final decoded = _tryDecodeJson(result);
    if (decoded != null && decoded['reply'] is String) {
      result = decoded['reply'].toString().trim();
    }
    if (hasAction && result == '{}') return '';
    return result;
  }

  void _validateConfig(AiAssistantConfig config) {
    if (!config.isComplete) {
      throw const AiServiceException('请先在设置中填写完整的 AI URL、Key 和模型');
    }
    final uri = Uri.tryParse(config.baseUrl.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const AiServiceException('AI 中转站 URL 必须是 http 或 https 地址');
    }
  }

  static String _joinEndpoint(String base, String path) {
    final trimmed = base.trim().replaceFirst(RegExp(r'/+$'), '');
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    if (trimmed.endsWith('/responses') ||
        trimmed.endsWith('/chat/completions') ||
        trimmed.endsWith('/messages') ||
        trimmed.contains(':generateContent')) {
      return trimmed;
    }
    return '$trimmed$normalizedPath';
  }

  static Map<String, String> _bearerHeaders(String key) => {
    'Authorization': 'Bearer ${key.trim()}',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  static void _addOpenAiReasoning(
    Map<String, dynamic> body,
    AiReasoningEffort effort, {
    required bool responses,
  }) {
    if (effort == AiReasoningEffort.platformDefault) return;
    final value = switch (effort) {
      AiReasoningEffort.off => 'none',
      AiReasoningEffort.minimal => 'minimal',
      AiReasoningEffort.low => 'low',
      AiReasoningEffort.medium => 'medium',
      AiReasoningEffort.high => 'high',
      AiReasoningEffort.maximum => 'xhigh',
      AiReasoningEffort.platformDefault => null,
    };
    if (value == null) return;
    if (responses) {
      body['reasoning'] = {'effort': value};
    } else {
      body['reasoning_effort'] = value;
    }
  }

  static void _addCompatibleReasoning(
    Map<String, dynamic> body,
    AiAssistantConfig config,
  ) {
    final effort = config.reasoningEffort;
    if (effort == AiReasoningEffort.platformDefault) return;
    switch (config.provider) {
      case AiProviderKind.deepSeek || AiProviderKind.glm || AiProviderKind.mimo:
        body['thinking'] = {
          'type': effort == AiReasoningEffort.off ? 'disabled' : 'enabled',
        };
      case AiProviderKind.qwen:
        body['enable_thinking'] = effort != AiReasoningEffort.off;
      default:
        _addOpenAiReasoning(body, effort, responses: false);
    }
  }

  static String? _anthropicEffort(AiReasoningEffort effort) => switch (effort) {
    AiReasoningEffort.platformDefault || AiReasoningEffort.off => null,
    AiReasoningEffort.minimal || AiReasoningEffort.low => 'low',
    AiReasoningEffort.medium => 'medium',
    AiReasoningEffort.high => 'high',
    AiReasoningEffort.maximum => 'max',
  };

  static Map<String, dynamic>? _geminiThinkingConfig(AiAssistantConfig config) {
    final effort = config.reasoningEffort;
    if (effort == AiReasoningEffort.platformDefault) return null;
    if (config.model.toLowerCase().contains('2.5')) {
      return {
        'thinkingBudget': switch (effort) {
          AiReasoningEffort.off => 0,
          AiReasoningEffort.minimal => 512,
          AiReasoningEffort.low => 1024,
          AiReasoningEffort.medium => 4096,
          AiReasoningEffort.high => 8192,
          AiReasoningEffort.maximum => 16384,
          AiReasoningEffort.platformDefault => 0,
        },
      };
    }
    return {
      'thinkingLevel': switch (effort) {
        AiReasoningEffort.off || AiReasoningEffort.minimal => 'minimal',
        AiReasoningEffort.low => 'low',
        AiReasoningEffort.medium => 'medium',
        AiReasoningEffort.high || AiReasoningEffort.maximum => 'high',
        AiReasoningEffort.platformDefault => 'medium',
      },
    };
  }

  static String _systemPrompt(AiAssistantConfig config) =>
      config.webSearchMode == AiWebSearchMode.always
      ? '$_assistantSystemPrompt\n本轮凡可通过联网核验的信息都应先使用联网搜索。'
      : _assistantSystemPrompt;

  static String? _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is Map) {
        final nested = _firstString(Map<String, dynamic>.from(value), keys);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  static const _responsesPlayTool = {
    'type': 'function',
    'name': 'play_song',
    'description': '在用户明确要求时播放一首确定的歌曲',
    'parameters': {
      'type': 'object',
      'properties': {
        'artist': {'type': 'string', 'description': '歌手名'},
        'title': {'type': 'string', 'description': '歌曲名'},
      },
      'required': ['artist', 'title'],
      'additionalProperties': false,
    },
  };

  static const _chatPlayTool = {
    'type': 'function',
    'function': {
      'name': 'play_song',
      'description': '在用户明确要求时播放一首确定的歌曲',
      'parameters': {
        'type': 'object',
        'properties': {
          'artist': {'type': 'string', 'description': '歌手名'},
          'title': {'type': 'string', 'description': '歌曲名'},
        },
        'required': ['artist', 'title'],
        'additionalProperties': false,
      },
    },
  };

  static const _anthropicPlayTool = {
    'name': 'play_song',
    'description': '在用户明确要求时播放一首确定的歌曲',
    'input_schema': {
      'type': 'object',
      'properties': {
        'artist': {'type': 'string', 'description': '歌手名'},
        'title': {'type': 'string', 'description': '歌曲名'},
      },
      'required': ['artist', 'title'],
      'additionalProperties': false,
    },
  };

  @override
  void close() => _client.close();
}
