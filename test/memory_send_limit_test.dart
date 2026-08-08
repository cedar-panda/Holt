import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/settings/memory_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('memory send limit defaults to 10 and clamps to 1..500', () async {
    expect(
      await MemorySettings.getMemorySendLimit(),
      MemorySettings.defaultMemorySendLimit,
    );

    await MemorySettings.saveMemorySendLimit(0);
    expect(await MemorySettings.getMemorySendLimit(), 1);

    await MemorySettings.saveMemorySendLimit(999);
    expect(
      await MemorySettings.getMemorySendLimit(),
      MemorySettings.maxMemorySendLimit,
    );
  });
}
