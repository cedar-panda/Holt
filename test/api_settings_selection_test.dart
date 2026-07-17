import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/settings/api_settings.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
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

  test('removing a star also removes its provider association', () async {
    const model = '[A-按次]gemini-3-flash';
    await ApiSettings.toggleStarModel(model, provider: 'openai_compatible');
    await ApiSettings.toggleStarModel(model, provider: 'openai_compatible');

    expect(await ApiSettings.getStarredModels(), isNot(contains(model)));
    expect(await ApiSettings.getStarredModelProvider(model), isNull);
  });

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
