import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/speech_locale_resolver.dart';

void main() {
  group('SpeechLocaleResolver', () {
    test('uses the exact Traditional Chinese id reported by iOS', () {
      final locale = SpeechLocaleResolver.resolve(
        configuredLocale: 'zh_TW',
        availableLocaleIds: const ['en_US', 'zh_TW', 'zh_CN'],
        preferAppleStyle: true,
      );

      expect(locale, 'zh_TW');
    });

    test('accepts Apple script-based Traditional Chinese locale', () {
      final locale = SpeechLocaleResolver.resolve(
        configuredLocale: 'zh_TW',
        availableLocaleIds: const ['zh-Hant-TW', 'zh-Hans-CN'],
        preferAppleStyle: true,
      );

      expect(locale, 'zh-Hant-TW');
    });

    test('keeps Android Mandarin locale when it is available', () {
      final locale = SpeechLocaleResolver.resolve(
        configuredLocale: 'zh_CN',
        availableLocaleIds: const ['cmn-Hans-CN', 'en-US'],
        preferAppleStyle: false,
      );

      expect(locale, 'cmn-Hans-CN');
    });

    test('uses a safe Apple fallback when locale discovery is empty', () {
      final locale = SpeechLocaleResolver.resolve(
        configuredLocale: 'zh_TW',
        availableLocaleIds: const [],
        preferAppleStyle: true,
      );

      expect(locale, 'zh-TW');
    });
  });
}
