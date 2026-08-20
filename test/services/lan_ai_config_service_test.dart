import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:music_player_app/models/ai_assistant.dart';
import 'package:music_player_app/services/lan_ai_config_service.dart';

void main() {
  test('QR session receives the complete AI configuration', () async {
    final session = await LanAiConfigService.start();
    addTearDown(session.stop);
    const secret = 'sk-secret-must-not-be-in-qr';

    expect(session.url, isNot(contains(secret)));
    final localUrl = Uri.parse(session.url).replace(host: '127.0.0.1');
    final page = await http.get(localUrl);
    expect(page.statusCode, 200);
    expect(page.body, contains('厂商'));
    expect(page.body, contains('请求协议'));
    expect(page.body, contains('推理等级'));
    expect(page.body, contains('联网搜索'));
    expect(page.body, isNot(contains(secret)));

    final response = await http.post(
      localUrl.resolve('submit'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'provider': 'mimo',
        'protocol': 'openai_chat',
        'baseUrl': 'https://api.xiaomimimo.com/v1',
        'apiKey': secret,
        'model': 'mimo-v2.5-pro',
        'reasoningEffort': 'high',
        'webSearchMode': 'always',
      }),
    );
    final config = await session.receivedConfig.timeout(
      const Duration(seconds: 2),
    );

    expect(response.statusCode, 200);
    expect(config, isNotNull);
    expect(config!.provider, AiProviderKind.mimo);
    expect(config.protocol, AiRequestProtocol.openAiChatCompletions);
    expect(config.baseUrl, 'https://api.xiaomimimo.com/v1');
    expect(config.apiKey, secret);
    expect(config.model, 'mimo-v2.5-pro');
    expect(config.reasoningEffort, AiReasoningEffort.high);
    expect(config.webSearchMode, AiWebSearchMode.always);
  });
}
