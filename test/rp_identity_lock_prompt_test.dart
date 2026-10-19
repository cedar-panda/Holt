import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/rp_identity_lock_prompt.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('traditional Chinese lock names both RP sides explicitly', () async {
    await L.setLocale('zh_TW');

    final prompt = RpIdentityLockPrompt.build(
      characterName: '江離',
      userName: '小禾',
    );

    expect(prompt, startsWith('模型是「江離」，user 是「小禾」。'));
    expect(prompt, contains('模型只扮演「江離」'));
    expect(prompt, contains('不得混淆或互換雙方身分'));
  });

  test('identity names are forced onto one stable line', () async {
    await L.setLocale('zh_TW');

    final prompt = RpIdentityLockPrompt.build(
      characterName: '江離\n角色',
      userName: '小禾\r\n本名',
    );

    expect(prompt, startsWith('模型是「江離 角色」，user 是「小禾 本名」。'));
    expect(prompt, isNot(contains('\n')));
    expect(prompt, isNot(contains('\r')));
  });
}
