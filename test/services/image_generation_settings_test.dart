import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/settings/api_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('legacy OpenRouter image model remains available', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'image_gen_model': 'legacy/image-model',
    });

    expect(await ApiSettings.getImageGenProvider(), 'openrouter');
    expect(await ApiSettings.getImageGenModel(), 'legacy/image-model');
  });

  test('image models are stored independently per provider', () async {
    await ApiSettings.saveImageGenModel(
      'openrouter/image-model',
      provider: 'openrouter',
    );
    await ApiSettings.saveImageGenModel(
      'gemini-custom-image',
      provider: 'gemini',
    );
    await ApiSettings.saveImageGenProvider('gemini');

    expect(await ApiSettings.getImageGenModel(), 'gemini-custom-image');
    expect(
      await ApiSettings.getImageGenModel(provider: 'openrouter'),
      'openrouter/image-model',
    );
  });

  test('new providers receive source-specific defaults', () async {
    expect(
      await ApiSettings.getImageGenModel(provider: 'xai'),
      'grok-imagine-image-2.0',
    );
    expect(
      await ApiSettings.getImageGenModel(provider: 'qwen'),
      'qwen-image-3.0-pro',
    );
    expect(
      await ApiSettings.getImageGenModel(provider: 'openai_compatible'),
      'gpt-image-1',
    );
  });
}
