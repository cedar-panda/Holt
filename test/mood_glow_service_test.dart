import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/services/mood_glow_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MoodGlowService.activeColor.value = null;
  });

  Future<String> reply(String text, {ContextMode mode = ContextMode.daily}) =>
      MoodGlowService.processReply(text, conversationId: 'c1', mode: mode);

  test('tag is stripped and the first color is accepted', () async {
    await MoodGlowService.bindConversation('c1', mode: ContextMode.daily);
    final out = await reply('嗯。<mood_color>#E8A0BF</mood_color>');
    expect(out, '嗯。');
    expect(MoodGlowService.activeColor.value, const Color(0xFFE8A0BF));
  });

  test('a second color within the cooldown is ignored', () async {
    await MoodGlowService.bindConversation('c1', mode: ContextMode.daily);
    await reply('a<mood_color>#E8A0BF</mood_color>');
    for (var i = 0; i < MoodGlowService.cooldownTurns - 1; i++) {
      await reply('b<mood_color>#112233</mood_color>');
      expect(MoodGlowService.activeColor.value, const Color(0xFFE8A0BF));
    }
    await reply('c<mood_color>#112233</mood_color>');
    expect(MoodGlowService.activeColor.value, const Color(0xFF112233));
  });

  test('scope controls whether colors apply', () async {
    await MoodGlowService.saveScope(MoodGlowScope.daily);
    expect(await MoodGlowService.isEnabledFor(ContextMode.rp), isFalse);
    final out = await reply(
      'x<mood_color>#112233</mood_color>',
      mode: ContextMode.rp,
    );
    expect(out, 'x');
    expect(MoodGlowService.activeColor.value, isNull);

    await MoodGlowService.saveScope(MoodGlowScope.off);
    expect(await MoodGlowService.isEnabledFor(ContextMode.daily), isFalse);
  });

  test('display color stays close to the theme accent', () {
    MoodGlowService.blendMode.value = MoodGlowBlend.theme;
    const accent = Color(0xFF7FA7D9);
    final shown = MoodGlowService.displayColor(
      const Color(0xFFFF0000),
      base: accent,
      locked: false,
    );
    final a = HSLColor.fromColor(accent);
    final d = HSLColor.fromColor(shown);
    expect((d.lightness - a.lightness).abs(), lessThanOrEqualTo(0.081));
  });

  test('a locked color ignores mood changes until unlocked', () async {
    await MoodGlowService.bindConversation('c1', mode: ContextMode.daily);
    await reply('好<mood_color_lock>#A0C4FF</mood_color_lock>');
    expect(MoodGlowService.activeColor.value, const Color(0xFFA0C4FF));
    expect(await MoodGlowService.statusPrompt('c1'), contains('#A0C4FF'));

    for (var i = 0; i < MoodGlowService.cooldownTurns + 2; i++) {
      await reply('x<mood_color>#112233</mood_color>');
    }
    expect(MoodGlowService.activeColor.value, const Color(0xFFA0C4FF));

    final out = await reply('改回來<mood_color_unlock/>');
    expect(out, '改回來');
    await reply('y<mood_color>#112233</mood_color>');
    expect(MoodGlowService.activeColor.value, const Color(0xFF112233));
  });

  test('complementary hues do not turn muddy grey', () {
    MoodGlowService.blendMode.value = MoodGlowBlend.theme;
    const accent = Color(0xFF4F7DD9); // blue
    final shown = MoodGlowService.displayColor(
      const Color(0xFFE8873A), // orange
      base: accent,
      locked: false,
    );
    final a = HSLColor.fromColor(accent);
    final d = HSLColor.fromColor(shown);
    expect(d.saturation, greaterThanOrEqualTo(a.saturation * 0.5 - 0.001));
  });
}
