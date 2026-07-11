import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/locale_strings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('pick returns English and Traditional Chinese verbatim', () async {
    await L.setLocale('en');
    expect(L.pick(en: 'Settings', zhTW: '設定'), 'Settings');

    await L.setLocale('zh_TW');
    expect(L.pick(en: 'Settings', zhTW: '設定'), '設定');
  });

  test('pick converts fallback UI text to Simplified Chinese', () async {
    await L.setLocale('zh_CN');
    expect(L.pick(en: 'Import settings', zhTW: '導入設定與記憶'), '导入设定与记忆');
  });

  test('explicit Simplified Chinese text takes precedence', () async {
    await L.setLocale('zh_CN');
    expect(L.pick(en: 'Done', zhTW: '完成', zhCN: '搞定'), '搞定');
  });
}
