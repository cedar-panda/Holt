import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/theme/app_theme.dart';
import 'package:project_yanci/theme/theme_presets.dart';

void main() {
  test('particle backdrop and tones do not recursively refresh each other', () {
    addTearDown(() => YanciTheme.setPreset('ivory'));

    for (final preset in presets) {
      YanciTheme.setPreset(preset.id);
      final backdrop = YanciTheme.particleBackdrop;
      final star = YanciTheme.starColor;
      final glow = YanciTheme.starGlow;

      expect(YanciTheme.particleBackdrop, backdrop, reason: preset.id);
      expect(YanciTheme.starColor, star, reason: preset.id);
      expect(YanciTheme.starGlow, glow, reason: preset.id);
      expect(YanciTheme.particleTone(preset.starColor).a, preset.starColor.a);
    }
  });
}
