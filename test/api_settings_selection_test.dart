import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/settings/api_settings.dart';
import 'package:project_yanci/services/settings/memory_settings.dart';
import 'package:project_yanci/services/xai_service.dart';

import 'helpers/secure_storage_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecureStorageTestMock secureStorage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureStorage = SecureStorageTestMock()..install();
  });

  tearDown(() => secureStorage.uninstall());

  for (final provider in <String>[
    'openrouter',
    'xai',
    'bedrock',
    'gemini',
    'deepseek',
    'qwen',
    'thinking_machines',
    'openai_compatible',
    'local_api',
    'local',
  ]) {
    test(
      '$provider reports missing configuration as ApiConfigException',
      () async {
        await expectLater(
          ApiSettings.buildAdapter(
            overrideProvider: provider,
            overrideModel: 'model-x',
          ),
          throwsA(isA<ApiConfigException>()),
        );
      },
    );
  }

  test('xAI key and model build the native Grok adapter', () async {
    await ApiSettings.saveXaiApiKey('xai-test-key');
    await ApiSettings.saveProviderModelSelection('xai', 'grok-4.5');

    expect(await ApiSettings.getXaiApiKey(), 'xai-test-key');
    expect(await ApiSettings.getModelForProvider('xai'), 'grok-4.5');
    expect(await ApiSettings.buildAdapter(), isA<XaiService>());
  });

  test('OpenAI-compatible source distinguishes a missing API key', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'oai_compat_base_url': 'https://api.example.com/v1',
    });

    await expectLater(
      ApiSettings.buildAdapter(
        overrideProvider: 'openai_compatible',
        overrideModel: 'model-x',
      ),
      throwsA(
        isA<ApiConfigException>().having(
          (error) => error.message,
          'message',
          contains('API Key'),
        ),
      ),
    );
  });

  test('starred model remembers its API provider', () async {
    await ApiSettings.toggleStarModel(
      '[A2-量]claude-opus-4-6-thinking',
      provider: 'openai_compatible',
    );

    expect(
      await ApiSettings.getStarredModelProvider(
        '[A2-量]claude-opus-4-6-thinking',
      ),
      'openai_compatible',
    );
  });

  test(
    'window summary defaults to Gemini 3 Flash as a provider pair',
    () async {
      expect(
        await MemorySettings.getSummaryModel(),
        MemorySettings.defaultSummaryModel,
      );
      expect(
        await MemorySettings.getSummaryProvider(),
        MemorySettings.defaultSummaryProvider,
      );
      expect(
        await ApiSettings.resolveSummaryModelProvider(
          await MemorySettings.getSummaryModel(),
        ),
        'gemini',
      );
    },
  );

  test('explicit follow-main summary selection stays empty', () async {
    await MemorySettings.saveSummarySelection(provider: '', model: '');

    expect(await MemorySettings.getSummaryModel(), isEmpty);
    expect(await MemorySettings.getSummaryProvider(), isEmpty);
  });

  test('legacy summary model keeps its starred API provider', () async {
    const model = '[A-按次]gemini-3-flash';
    await ApiSettings.toggleStarModel(model, provider: 'openai_compatible');
    await MemorySettings.saveSummaryModel(model);

    expect(await MemorySettings.getSummaryModel(), model);
    expect(await MemorySettings.getSummaryProvider(), isEmpty);
    expect(
      await ApiSettings.resolveSummaryModelProvider(model),
      'openai_compatible',
    );
  });

  test('summary provider and model are saved and restored together', () async {
    await MemorySettings.saveSummarySelection(
      provider: 'openrouter',
      model: 'google/gemini-3-flash',
    );

    expect(await MemorySettings.getSummaryProvider(), 'openrouter');
    expect(await MemorySettings.getSummaryModel(), 'google/gemini-3-flash');
  });

  test('removing a star also removes its provider association', () async {
    const model = '[A-按次]gemini-3-flash';
    await ApiSettings.toggleStarModel(model, provider: 'openai_compatible');
    await ApiSettings.toggleStarModel(model, provider: 'openai_compatible');

    expect(await ApiSettings.getStarredModels(), isNot(contains(model)));
    expect(await ApiSettings.getStarredModelProvider(model), isNull);
  });

  test(
    'starred model usage ranks cloud first and resumes after re-starring',
    () async {
      const cloudA = 'anthropic/claude-sonnet-4';
      const cloudB = 'google/gemini-3-flash';
      const local = 'local:qwen3-4b';
      await ApiSettings.saveStarredModels([cloudA, local, cloudB]);

      await ApiSettings.recordStarredModelUsage(cloudA);
      await ApiSettings.recordStarredModelUsage(cloudB);
      await ApiSettings.recordStarredModelUsage(cloudB);
      for (var i = 0; i < 5; i++) {
        await ApiSettings.recordStarredModelUsage(local);
      }

      expect(await ApiSettings.getRankedStarredModels(), [
        cloudB,
        cloudA,
        local,
      ]);

      await ApiSettings.saveStarredModels([cloudA, local]);
      await ApiSettings.recordStarredModelUsage(cloudB);
      expect(await ApiSettings.getRankedStarredModels(), [cloudA, local]);

      await ApiSettings.saveStarredModels([cloudA, local, cloudB]);
      expect(await ApiSettings.getRankedStarredModels(), [
        cloudB,
        cloudA,
        local,
      ]);
      expect((await ApiSettings.getStarredModelUsageCounts())[cloudB], 2);
    },
  );

  test('provider and model selection are saved together', () async {
    const model = '[A2-量]claude-opus-4-6-thinking';
    await ApiSettings.saveProviderModelSelection('openai_compatible', model);

    expect(await ApiSettings.getApiProvider(), 'openai_compatible');
    expect(await ApiSettings.getModel(), model);
    expect(await ApiSettings.getModelForProvider('openai_compatible'), model);
  });

  test('legacy stars gain provider when loaded from that source', () async {
    const model = '[A-zy-按量]claude-sonnet-4-6';
    await ApiSettings.saveStarredModels([model]);

    await ApiSettings.rememberStarredModelProviders([
      model,
    ], 'openai_compatible');

    expect(
      await ApiSettings.getStarredModelProvider(model),
      'openai_compatible',
    );
  });

  test('legacy custom model is inferred from configured gateway', () async {
    const model = '[A2-量]claude-opus-4-6-thinking';
    await ApiSettings.saveStarredModels([model]);
    await ApiSettings.saveOaiCompatBaseUrl('https://api.example.com/v1');

    expect(
      await ApiSettings.resolveStarredModelProvider(model),
      'openai_compatible',
    );
    expect(
      await ApiSettings.getStarredModelProvider(model),
      'openai_compatible',
    );
  });

  test('legacy OpenRouter-style model keeps OpenRouter source', () async {
    const model = 'anthropic/claude-sonnet-4';
    await ApiSettings.saveStarredModels([model]);
    await ApiSettings.saveOaiCompatBaseUrl('https://api.example.com/v1');

    expect(await ApiSettings.resolveStarredModelProvider(model), 'openrouter');
  });

  test(
    'plain legacy star stays on the current provider when ambiguous',
    () async {
      const model = 'gpt-5.5';
      await ApiSettings.saveStarredModels([model]);
      await ApiSettings.saveProviderModelSelection('gemini', 'gemini-3-flash');

      expect(await ApiSettings.resolveStarredModelProvider(model), 'gemini');
    },
  );

  test('unknown provider never falls back to OpenRouter', () async {
    expect(
      () => ApiSettings.saveModelForProvider('unknown_gateway', 'model-x'),
      throwsUnsupportedError,
    );
    expect(
      () => ApiSettings.buildAdapter(overrideProvider: 'unknown_gateway'),
      throwsUnsupportedError,
    );
  });

  test('local model selection no longer uses OpenRouter as carrier', () async {
    await ApiSettings.saveProviderModelSelection('local', 'local:test-model');

    expect(await ApiSettings.getApiProvider(), 'local');
    expect(await ApiSettings.getModel(), 'local:test-model');
  });
}
