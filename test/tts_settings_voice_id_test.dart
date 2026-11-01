import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/settings/tts_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('new Voice ID is normalized, saved, and selected', () async {
    final values = await TtsSettings.addAndSelectVoiceId('  voice-new  ');

    expect(values, <String>['voice-new']);
    expect(await TtsSettings.getTtsElevenlabsVoiceId(), 'voice-new');
  });

  test('voice options keep an old bound ID without duplicates', () {
    expect(
      TtsSettings.normalizeVoiceIdOptions(const <String>[
        ' voice-a ',
        'voice-a',
        '',
      ], boundVoiceId: 'voice-legacy'),
      <String>['voice-a', 'voice-legacy'],
    );
  });

  test('removing selected Voice ID falls back to the next saved ID', () async {
    await TtsSettings.saveVoiceIdList(<String>['voice-a', 'voice-b']);
    await TtsSettings.saveTtsElevenlabsVoiceId('voice-a');

    await TtsSettings.removeVoiceId('voice-a');

    expect(await TtsSettings.getVoiceIdList(), <String>['voice-b']);
    expect(await TtsSettings.getTtsElevenlabsVoiceId(), 'voice-b');
  });

  test(
    'Voice ID alias persists while the immutable ID stays visible',
    () async {
      await TtsSettings.saveVoiceIdLabel('voice-cantonese', '阿澈粵語');

      final labels = await TtsSettings.getVoiceIdLabels();
      expect(labels['voice-cantonese'], '阿澈粵語');
      expect(
        TtsSettings.voiceIdDisplayName('voice-cantonese', labels),
        '阿澈粵語 · voice-cantonese',
      );
    },
  );

  test('STT language list exposes Cantonese and three explicit labels', () {
    expect(TtsSettings.sttLocaleName('zh_HK'), '粵語');
    expect(TtsSettings.sttLocaleName('zh_TW'), '繁中');
    expect(TtsSettings.sttLocaleName('zh_CN'), '簡中');
    expect(TtsSettings.sttLocaleName('en_US'), 'EN');
  });
}
