import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/ai_assistant.dart';
import 'package:music_player_app/services/ai_service.dart';

void main() {
  group('AiAssistantService protocols', () {
    test('OpenAI Responses sends tools and parses play_song', () async {
      late http.Request captured;
      final service = AiAssistantService(
        client: MockClient((request) async {
          captured = request;
          return _jsonResponse({
            'output': [
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': '好的，我来播放。'},
                ],
              },
              {
                'type': 'function_call',
                'name': 'play_song',
                'arguments': jsonEncode({'artist': '周杰伦', 'title': '夜曲'}),
              },
            ],
          });
        }),
      );
      addTearDown(service.close);

      final result = await service.sendMessage(
        _config(
          provider: AiProviderKind.openAi,
          protocol: AiRequestProtocol.openAiResponses,
        ),
        [_userMessage('播放周杰伦的夜曲')],
      );

      expect(captured.url.toString(), 'https://example.test/v1/responses');
      expect(captured.headers['Authorization'], 'Bearer test-key');
      final body = _body(captured);
      expect(body['model'], 'test-model');
      expect(body, isNot(contains('reasoning')));
      expect(body['instructions'], contains('你不是只能回答音乐问题'));
      expect(body['instructions'], contains('天气等实时问题'));
      expect(
        (body['tools'] as List).where(
          (tool) => tool is Map && tool['name'] == 'play_song',
        ),
        hasLength(1),
      );
      expect(result.reply, '好的，我来播放。');
      expect(result.playRequest?.artist, '周杰伦');
      expect(result.playRequest?.title, '夜曲');
    });

    test('OpenAI Chat Completions parses nested tool call', () async {
      late http.Request captured;
      final service = AiAssistantService(
        client: MockClient((request) async {
          captured = request;
          return _jsonResponse({
            'choices': [
              {
                'message': {
                  'content': '马上为你播放。',
                  'tool_calls': [
                    {
                      'type': 'function',
                      'function': {
                        'name': 'play_song',
                        'arguments': jsonEncode({
                          'artist': '周杰伦',
                          'title': '夜曲',
                        }),
                      },
                    },
                  ],
                },
              },
            ],
          });
        }),
      );
      addTearDown(service.close);

      final result = await service.sendMessage(
        _config(
          provider: AiProviderKind.custom,
          protocol: AiRequestProtocol.openAiChatCompletions,
        ),
        [_userMessage('就听夜曲')],
      );

      expect(
        captured.url.toString(),
        'https://example.test/v1/chat/completions',
      );
      final body = _body(captured);
      expect(body, isNot(contains('reasoning_effort')));
      expect(body['tool_choice'], 'auto');
      expect((body['messages'] as List).first['role'], 'system');
      expect(result.playRequest?.artist, '周杰伦');
      expect(result.playRequest?.title, '夜曲');
    });

    test('Anthropic Messages uses native schema and parses tool_use', () async {
      late http.Request captured;
      final service = AiAssistantService(
        client: MockClient((request) async {
          captured = request;
          return _jsonResponse({
            'content': [
              {'type': 'text', 'text': '这就播放。'},
              {
                'type': 'tool_use',
                'id': 'tool-1',
                'name': 'play_song',
                'input': {'artist': '周杰伦', 'title': '夜曲'},
              },
            ],
          });
        }),
      );
      addTearDown(service.close);

      final result = await service.sendMessage(
        _config(
          provider: AiProviderKind.anthropic,
          protocol: AiRequestProtocol.anthropicMessages,
        ),
        [_userMessage('播放夜曲')],
      );

      expect(captured.url.toString(), 'https://example.test/v1/messages');
      expect(captured.headers['x-api-key'], 'test-key');
      expect(captured.headers['anthropic-version'], '2023-06-01');
      final body = _body(captured);
      expect(body, isNot(contains('output_config')));
      expect(body, isNot(contains('thinking')));
      expect((body['tools'] as List).first['input_schema'], isA<Map>());
      expect(result.playRequest?.artist, '周杰伦');
      expect(result.playRequest?.title, '夜曲');
    });

    test('Gemini GenerateContent parses functionCall', () async {
      late http.Request captured;
      final service = AiAssistantService(
        client: MockClient((request) async {
          captured = request;
          return _jsonResponse({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': '好的。'},
                    {
                      'functionCall': {
                        'name': 'play_song',
                        'args': {'artist': '周杰伦', 'title': '夜曲'},
                      },
                    },
                  ],
                },
              },
            ],
          });
        }),
      );
      addTearDown(service.close);

      final result = await service.sendMessage(
        _config(
          provider: AiProviderKind.gemini,
          protocol: AiRequestProtocol.geminiGenerateContent,
        ),
        [_userMessage('播放夜曲')],
      );

      expect(
        captured.url.toString(),
        'https://example.test/v1/models/test-model:generateContent',
      );
      expect(captured.headers['x-goog-api-key'], 'test-key');
      final body = _body(captured);
      expect(body, isNot(contains('generationConfig')));
      expect(body['systemInstruction'], isA<Map>());
      expect(result.playRequest?.artist, '周杰伦');
      expect(result.playRequest?.title, '夜曲');
    });
  });

  group('MiMo request mapping', () {
    test('automatic search and non-default effort use native fields', () async {
      late http.Request captured;
      final service = AiAssistantService(
        client: MockClient((request) async {
          captured = request;
          return _jsonResponse({
            'choices': [
              {
                'message': {'content': '查询完成'},
              },
            ],
          });
        }),
      );
      addTearDown(service.close);

      await service.sendMessage(
        _config(
          provider: AiProviderKind.mimo,
          protocol: AiRequestProtocol.openAiChatCompletions,
          reasoningEffort: AiReasoningEffort.high,
          webSearchMode: AiWebSearchMode.automatic,
          model: 'mimo-v2.5',
        ),
        [_userMessage('今天有哪些音乐新闻')],
      );

      final body = _body(captured);
      expect(body['thinking'], {'type': 'enabled'});
      expect(body, isNot(contains('reasoning_effort')));
      final tools = body['tools'] as List;
      expect(tools.first, {
        'type': 'web_search',
        'max_keyword': 3,
        'force_search': false,
        'limit': 1,
      });
      expect((tools.last as Map)['function']['name'], 'play_song');
    });

    test('always search forces search and off disables thinking', () async {
      late http.Request captured;
      final service = AiAssistantService(
        client: MockClient((request) async {
          captured = request;
          return _jsonResponse({
            'choices': [
              {
                'message': {'content': '查询完成'},
              },
            ],
          });
        }),
      );
      addTearDown(service.close);

      await service.sendMessage(
        _config(
          provider: AiProviderKind.mimo,
          protocol: AiRequestProtocol.openAiChatCompletions,
          reasoningEffort: AiReasoningEffort.off,
          webSearchMode: AiWebSearchMode.always,
          model: 'mimo-v2.5-pro',
        ),
        [_userMessage('查询最新消息')],
      );

      final body = _body(captured);
      expect(body['thinking'], {'type': 'disabled'});
      expect((body['tools'] as List).first['force_search'], isTrue);
    });

    test('platform default omits every reasoning field', () async {
      late http.Request captured;
      final service = AiAssistantService(
        client: MockClient((request) async {
          captured = request;
          return _jsonResponse({
            'choices': [
              {
                'message': {'content': 'OK'},
              },
            ],
          });
        }),
      );
      addTearDown(service.close);

      await service.sendMessage(
        _config(
          provider: AiProviderKind.mimo,
          protocol: AiRequestProtocol.openAiChatCompletions,
        ),
        [_userMessage('你好')],
      );

      final body = _body(captured);
      expect(body, isNot(contains('thinking')));
      expect(body, isNot(contains('reasoning')));
      expect(body, isNot(contains('reasoning_effort')));
    });
  });
}

AiAssistantConfig _config({
  required AiProviderKind provider,
  required AiRequestProtocol protocol,
  AiReasoningEffort reasoningEffort = AiReasoningEffort.platformDefault,
  AiWebSearchMode webSearchMode = AiWebSearchMode.disabled,
  String model = 'test-model',
}) => AiAssistantConfig(
  provider: provider,
  protocol: protocol,
  baseUrl: 'https://example.test/v1',
  apiKey: 'test-key',
  model: model,
  reasoningEffort: reasoningEffort,
  webSearchMode: webSearchMode,
);

AiConversationMessage _userMessage(String text) =>
    AiConversationMessage(role: AiMessageRole.user, text: text);

Map<String, dynamic> _body(http.Request request) =>
    Map<String, dynamic>.from(jsonDecode(request.body) as Map);

http.Response _jsonResponse(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
