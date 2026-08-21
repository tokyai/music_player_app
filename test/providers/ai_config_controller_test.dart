import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/ai_assistant.dart';
import 'package:music_player_app/providers/ai_config_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('migrates the legacy single config and plain secure key', () async {
    SharedPreferences.setMockInitialValues({
      'ai_assistant_config_v1': jsonEncode({
        'provider': 'mimo',
        'protocol': 'openai_chat',
        'baseUrl': 'https://legacy.example/v1',
        'model': 'legacy-model',
        'reasoningEffort': 'high',
        'webSearchMode': 'always',
        'voiceModel': AiVoiceModelKind.paraformerBilingual.value,
      }),
    });
    final secrets = MemoryAiSecretStore('legacy-secret');
    final controller = AiConfigController(secretStore: secrets);
    addTearDown(controller.dispose);

    await controller.ready;

    expect(controller.profiles, hasLength(1));
    expect(controller.activeProfile?.name, '默认配置');
    expect(controller.config.baseUrl, 'https://legacy.example/v1');
    expect(controller.config.apiKey, 'legacy-secret');
    expect(controller.config.model, 'legacy-model');
    expect(controller.config.voiceModel, AiVoiceModelKind.paraformerBilingual);
  });

  test('creates, selects, updates, deletes and reloads profiles', () async {
    final secrets = MemoryAiSecretStore();
    final controller = AiConfigController(secretStore: secrets);
    await controller.ready;
    final firstId = controller.activeProfileId;
    await controller.updateProfile(
      firstId,
      name: '主力配置',
      config: _config(
        url: 'https://primary.example/v1',
        key: 'primary-key',
        model: 'primary-model',
      ),
    );
    final second = await controller.createProfile(
      name: '备用配置',
      config: _config(
        url: 'https://backup.example/v1',
        key: 'backup-key',
        model: 'backup-model',
      ),
    );

    expect(controller.profiles, hasLength(2));
    expect(controller.activeProfileId, second.id);
    expect(controller.config.model, 'backup-model');

    await controller.selectProfile(firstId);
    expect(controller.config.model, 'primary-model');
    expect(controller.config.apiKey, 'primary-key');
    controller.dispose();

    final reloaded = AiConfigController(secretStore: secrets);
    addTearDown(reloaded.dispose);
    await reloaded.ready;

    expect(reloaded.profiles.map((profile) => profile.name), ['主力配置', '备用配置']);
    expect(reloaded.activeProfileId, firstId);
    expect(reloaded.config.apiKey, 'primary-key');
    final storedSecrets = jsonDecode(secrets.value!) as Map<String, dynamic>;
    expect(storedSecrets[firstId], 'primary-key');
    expect(storedSecrets[second.id], 'backup-key');
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('ai_assistant_profiles_v1'),
      isNot(contains('primary-key')),
    );
    expect(
      preferences.getString('ai_assistant_profiles_v1'),
      isNot(contains('backup-key')),
    );

    await reloaded.deleteProfile(second.id);
    expect(reloaded.profiles, hasLength(1));
    await expectLater(
      reloaded.deleteProfile(firstId),
      throwsA(isA<StateError>()),
    );
  });

  test('persists normalized pet scale and position', () async {
    final secrets = MemoryAiSecretStore();
    final controller = AiConfigController(secretStore: secrets);
    await controller.ready;

    await controller.setPetScale(3);
    await controller.setPetPosition(const AiPetPosition(x: -0.4, y: 1.8));

    expect(controller.petScale, AiConfigController.maxPetScale);
    expect(controller.petPosition.x, 0);
    expect(controller.petPosition.y, 1);
    controller.dispose();

    final reloaded = AiConfigController(secretStore: secrets);
    addTearDown(reloaded.dispose);
    await reloaded.ready;
    expect(reloaded.petScale, AiConfigController.maxPetScale);
    expect(reloaded.petPosition.x, 0);
    expect(reloaded.petPosition.y, 1);
  });
}

AiAssistantConfig _config({
  required String url,
  required String key,
  required String model,
}) => AiAssistantConfig(
  provider: AiProviderKind.custom,
  protocol: AiRequestProtocol.openAiChatCompletions,
  baseUrl: url,
  apiKey: key,
  model: model,
  reasoningEffort: AiReasoningEffort.platformDefault,
  webSearchMode: AiWebSearchMode.disabled,
);
