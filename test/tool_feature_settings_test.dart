import 'package:flutter_test/flutter_test.dart';
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

      await ToolFeatureSettings.setShellEconomyEnabled(false);
      await ToolFeatureSettings.setDiaryEnabled(false);
      await ToolFeatureSettings.setToolPromptsEnabled(false);

      final reloaded = await ToolFeatureSettings.load();
      expect(reloaded.scratchEnabled, isFalse);
      expect(reloaded.toolPromptsEnabled, isFalse);
      expect(reloaded.shopEnabled, isFalse);
      expect(reloaded.transferEnabled, isFalse);
      expect(reloaded.coinSnapshotEnabled, isFalse);
      expect(reloaded.diaryEnabled, isFalse);
    },
  );

  test('shell economy aliases follow the merged capability switch', () {
    expect(const ToolFeatureState().shellEconomyEnabled, isTrue);
    expect(
      const ToolFeatureState(shellEconomyEnabled: false).shellEconomyEnabled,
      isFalse,
    );
  });

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
