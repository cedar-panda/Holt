import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/sticker_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'Vision prompt defaults to 20 characters in Traditional Chinese',
    () async {
      await L.setLocale('zh_TW');

      final prompt = StickerService.buildVisionPrompt(characterName: '林澈');

      expect(prompt, contains('你是「林澈」'));
    expect(prompt, contains('輸出內容務必控制在 20 字數內'));
      expect(prompt, isNot(contains('max_tokens')));
    },
  );

  test('Vision prompt accepts the full 20 to 100 character range', () async {
    await L.setLocale('zh_TW');

    final minimum = StickerService.buildVisionPrompt(
      characterName: '林澈',
      maxCharacters: 20,
    );
    final maximum = StickerService.buildVisionPrompt(
      characterName: '林澈',
      maxCharacters: 100,
    );

    expect(minimum, contains('控制在 20 字數內'));
    expect(maximum, contains('控制在 100 字數內'));
  });

  test('Vision prompt clamps out-of-range character values', () async {
    await L.setLocale('zh_TW');

    final below = StickerService.buildVisionPrompt(
      characterName: '林澈',
      maxCharacters: 1,
    );
    final above = StickerService.buildVisionPrompt(
      characterName: '林澈',
      maxCharacters: 999,
    );

    expect(below, contains('控制在 20 字數內'));
    expect(above, contains('控制在 100 字數內'));
  });

  test('Vision prompt localizes the character limit instruction', () async {
    await L.setLocale('en');

    final prompt = StickerService.buildVisionPrompt(
      characterName: 'Lin',
      maxCharacters: 36,
    );

    expect(prompt, contains('You are “Lin”'));
    expect(prompt, contains('within 36 characters'));
  });
}
