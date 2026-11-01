import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/settings/user_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('character stars persist without duplicates', () async {
    await UserSettings.setCharacterStarred(' char-a ', true);
    await UserSettings.setCharacterStarred('char-a', true);
    await UserSettings.setCharacterStarred('char-b', true);

    expect(await UserSettings.getStarredCharacterIds(), <String>{
      'char-a',
      'char-b',
    });

    await UserSettings.setCharacterStarred('char-a', false);
    expect(await UserSettings.getStarredCharacterIds(), <String>{'char-b'});
  });

  test('star hint is emitted only once', () async {
    expect(await UserSettings.markCharacterStarHintShown(), isTrue);
    expect(await UserSettings.markCharacterStarHintShown(), isFalse);
  });
}
