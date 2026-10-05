import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/x_post_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'X posting is available and settings remain isolated per character',
    () async {
      expect(XPostSettings.featureEnabled, isTrue);

      await XPostSettings.setEnabled('character-a', true);
      await XPostSettings.setHandle('character-a', '@alice');
      await XPostSettings.setDailyLimit('character-a', 3);

      expect(await XPostSettings.isEnabled('character-a'), isTrue);
      expect(await XPostSettings.handle('character-a'), 'alice');
      expect(await XPostSettings.dailyLimit('character-a'), 3);

      expect(await XPostSettings.isEnabled('character-b'), isFalse);
      expect(await XPostSettings.handle('character-b'), isEmpty);
      expect(
        await XPostSettings.dailyLimit('character-b'),
        XPostSettings.defaultDailyLimit,
      );
    },
  );
}
