import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/screens/settings_screen.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/theme/app_theme.dart';

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

  test('character edit title is the short Edit label in all locales', () async {
    await L.setLocale('en');
    expect(L.get('char_edit_title'), 'Edit');
    await L.setLocale('zh_TW');
    expect(L.get('char_edit_title'), '編輯');
    await L.setLocale('zh_CN');
    expect(L.get('char_edit_title'), '编辑');
  });

  testWidgets('language selection refreshes settings immediately', (
    tester,
  ) async {
    await L.setLocale('en');
    YanciTheme.setPreset('dawn');

    await tester.pumpWidget(
      MaterialApp(theme: YanciTheme.themeData, home: const SettingsScreen()),
    );
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Preferences'), findsOneWidget);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('繁體中文').last);
    await tester.pumpAndSettle();

    expect(L.localeNotifier.value, 'zh_TW');
    expect(find.text('設定'), findsOneWidget);
    expect(find.text('介面與語言'), findsOneWidget);
  });
}
