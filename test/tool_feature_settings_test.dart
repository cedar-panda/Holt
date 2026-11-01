import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/services/scratch_service.dart';
import 'package:project_yanci/services/tool_feature_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'tool feature switches default on and shell economy persists as one switch',
    () async {
      final defaults = await ToolFeatureSettings.load();
      expect(defaults.imageGenerationEnabled, isTrue);
      expect(defaults.shopEnabled, isTrue);
      expect(defaults.scratchEnabled, isTrue);
      expect(defaults.transferEnabled, isTrue);
      expect(defaults.coinSnapshotEnabled, isTrue);
      expect(defaults.diaryEnabled, isTrue);
      expect(defaults.toolPromptsEnabled, isTrue);
      expect(defaults.modelGreetingEnabled, isTrue);
      expect(defaults.emailDraftEnabled, isTrue);

      await ToolFeatureSettings.setShellEconomyEnabled(false);
      await ToolFeatureSettings.setDiaryEnabled(false);
      await ToolFeatureSettings.setToolPromptsEnabled(false);
      await ToolFeatureSettings.setModelGreetingEnabled(false);
      await ToolFeatureSettings.setEmailDraftEnabled(false);

      final reloaded = await ToolFeatureSettings.load();
      expect(reloaded.scratchEnabled, isFalse);
      expect(reloaded.toolPromptsEnabled, isFalse);
      expect(reloaded.modelGreetingEnabled, isFalse);
      expect(reloaded.shopEnabled, isFalse);
      expect(reloaded.transferEnabled, isFalse);
      expect(reloaded.coinSnapshotEnabled, isFalse);
      expect(reloaded.diaryEnabled, isFalse);
      expect(reloaded.emailDraftEnabled, isFalse);
    },
  );

  test('shell economy aliases follow the merged capability switch', () {
    expect(const ToolFeatureState().shellEconomyEnabled, isTrue);
    expect(
      const ToolFeatureState(shellEconomyEnabled: false).shellEconomyEnabled,
      isFalse,
    );
  });

  test('model home greeting is independent from tool prompts', () async {
    await ToolFeatureSettings.setToolPromptsEnabled(false);

    var reloaded = await ToolFeatureSettings.load();
    expect(reloaded.toolPromptsEnabled, isFalse);
    expect(reloaded.modelGreetingEnabled, isTrue);

    await ToolFeatureSettings.setModelGreetingEnabled(false);
    reloaded = await ToolFeatureSettings.load();
    expect(reloaded.toolPromptsEnabled, isFalse);
    expect(reloaded.modelGreetingEnabled, isFalse);
  });

  test(
    'one named preset can become the default RP capability bundle',
    () async {
      const first = FeatureModulePreset(
        id: 'rp-first',
        name: 'RP first',
        applyToRp: true,
        state: ToolFeatureState(
          imageGenerationEnabled: false,
          diaryEnabled: false,
          toolPromptsEnabled: false,
        ),
      );
      const second = FeatureModulePreset(
        id: 'rp-second',
        name: 'RP second',
        applyToRp: true,
        state: ToolFeatureState(
          imageGenerationEnabled: true,
          diaryEnabled: true,
          toolPromptsEnabled: true,
          rpDailyLifeToolsEnabled: true,
        ),
      );

      await ToolFeatureSettings.savePreset(first);
      await ToolFeatureSettings.savePreset(second);

      final presets = await ToolFeatureSettings.loadPresets();
      expect(presets.where((preset) => preset.applyToRp), hasLength(1));
      expect(presets.last.id, 'rp-second');

      final rp = await ToolFeatureSettings.loadForContext(ContextMode.rp);
      expect(rp.imageGenerationEnabled, isTrue);
      expect(rp.diaryEnabled, isTrue);
      expect(rp.toolPromptsEnabled, isTrue);
      expect(rp.rpDailyLifeToolsEnabled, isTrue);
    },
  );

  test(
    'daily shell grant is frozen while every economy module is off',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ability_scratch_card_enabled': false,
        'ability_transfer_enabled': false,
        'shop_enabled': false,
        'ability_coin_snapshot_enabled': false,
        'scratch_coins__user': 125,
        'scratch_coins_char-a': 230,
      });
      await ToolFeatureSettings.load();

      await ScratchService.checkDailyGrant(
        characterIds: const <String>['char-a'],
      );

      expect(await ScratchService.getUserCoins(), 125);
      expect(await ScratchService.getCoins('char-a'), 230);
    },
  );
}
