import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/settings/memory_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('summary trigger is independent from context send limit', () async {
    await MemorySettings.saveContextSummaryTriggerMessages(18);
    await MemorySettings.saveContextMessageLimit(12);

    expect(await MemorySettings.getContextMessageLimit(), 12);
    expect(await MemorySettings.getContextSummaryTriggerMessages(), 18);
  });
}
