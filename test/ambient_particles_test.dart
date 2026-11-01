import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/screens/theme_workshop_screen.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/settings/theme_settings.dart';
import 'package:project_yanci/theme/app_theme.dart';
import 'package:project_yanci/theme/theme_presets.dart';
import 'package:project_yanci/widgets/ambient_particles.dart';
import 'package:project_yanci/widgets/neural_field.dart';
import 'package:project_yanci/widgets/rain_painter.dart';
import 'package:project_yanci/widgets/starfield_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    YanciTheme.setPreset('ivory');
    YanciTheme.starEnabled = true;
    YanciTheme.starDensity = 12;
    YanciTheme.particleEffectOverride = null;
    YanciTheme.cloudStyle = 'soft';
  });

  test(
    'particle density uses the whole slider range without changing anchors',
    () {
      expect(AmbientParticleField.densityScaleFor(1), 0.4);
      expect(AmbientParticleField.densityScaleFor(12), 1.0);
      expect(AmbientParticleField.densityScaleFor(50), 1.6);
      expect(
        AmbientParticleField.densityScaleFor(6),
        lessThan(AmbientParticleField.densityScaleFor(12)),
      );
      expect(
        AmbientParticleField.densityScaleFor(30),
        greaterThan(AmbientParticleField.densityScaleFor(12)),
      );
    },
  );

  test('emoji rain keeps at most five unique graphemes', () {
    final emojis = YanciTheme.normalizeParticleEmojis('🦦🦦 🐾👨‍👩‍👧🍃🌙✨⭐');
    expect(emojis, ['🦦', '🐾', '👨‍👩‍👧', '🍃', '🌙']);
    expect(YanciTheme.normalizeParticleEmojis('   '), isEmpty);
  });

  test('cloud style persists and ignores unknown values', () async {
    expect(await ThemeSettings.getCloudStyle(), 'soft');
    await ThemeSettings.saveCloudStyle('hard');
    expect(await ThemeSettings.getCloudStyle(), 'hard');
    await ThemeSettings.saveCloudStyle('bogus');
    expect(await ThemeSettings.getCloudStyle(), 'hard');
  });

  testWidgets('crisp clouds render through the sky effect', (tester) async {
    YanciTheme.setCloudStyle('hard');
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox.expand(child: AmbientParticleField(effect: 'sky')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SkyWidget), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('particles stay distinguishable from every theme background', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance();
      final lb = b.computeLuminance();
      return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
    }

    for (final preset in presets) {
      YanciTheme.setPreset(preset.id);
      final bg = YanciTheme.particleBackdrop;
      final star = YanciTheme.starColor;
      expect(
        contrast(star.withValues(alpha: 1), bg),
        greaterThanOrEqualTo(YanciTheme.particleMinContrast - 0.01),
        reason: preset.id,
      );
      if (!preset.isDark) {
        expect(star.a, greaterThanOrEqualTo(0.5), reason: preset.id);
      }
    }
    YanciTheme.setPreset('ivory');
  });

  test('particleTone keeps the requested alpha', () {
    YanciTheme.setPreset('changan');
    final toned = YanciTheme.particleTone(
      const Color(0x40FFFFFF),
      minContrast: 1.5,
    );
    expect(toned.a, closeTo(0x40 / 255, 0.01));
    YanciTheme.setPreset('ivory');
  });

  test('new particle styles are registered', () {
    for (final id in ['gold', 'spark', 'sky', 'firework', 'emoji']) {
      expect(YanciTheme.particleEffectIds, contains(id));
    }
  });

  testWidgets('ambient particle field exposes every supported style', (
    tester,
  ) async {
    final expectedTypes = <String, Type>{
      'neural': NeuralFieldWidget,
      'stars': StarfieldWidget,
      'rain': RainWidget,
      'ripple': RippleParticleWidget,
      'ember': EmberParticleWidget,
      'dandelion': DandelionParticleWidget,
      'gold': GoldDustWidget,
      'spark': SparkBurstWidget,
      'sky': SkyWidget,
      'firework': FireworkWidget,
      'emoji': EmojiRainWidget,
    };

    for (final entry in expectedTypes.entries) {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox.expand(child: AmbientParticleField(effect: entry.key)),
        ),
      );
      await tester.pump();
      expect(find.byType(entry.value), findsOneWidget, reason: entry.key);
    }
  });

  testWidgets(
    'ambient particle field rebuilds when the selected style changes',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: SizedBox.expand(child: AmbientParticleField())),
      );
      await tester.pump();
      expect(find.byType(NeuralFieldWidget), findsOneWidget);

      YanciTheme.setParticleEffect('ember');
      await tester.pump();

      expect(find.byType(NeuralFieldWidget), findsNothing);
      expect(find.byType(EmberParticleWidget), findsOneWidget);
    },
  );

  testWidgets('theme workshop particle tabs persist the selected style', (
    tester,
  ) async {
    await L.setLocale('zh_TW');
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: ThemeWorkshopScreen()));
    await tester.pump();

    final particleContent = tester.widget<AnimatedCrossFade>(
      find.byKey(const ValueKey('theme-particle-section-content')),
    );
    expect(particleContent.crossFadeState, CrossFadeState.showFirst);
    await tester.tap(
      find.byKey(const ValueKey('theme-particle-section-toggle')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('particle-effect-tabs')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('particle-effect-neural')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('particle-effect-dandelion')),
      findsOneWidget,
    );
    // 一排三個：neural / rain / ripple 第一排，ember 起換到第二排。
    Offset center(String id) =>
        tester.getCenter(find.byKey(ValueKey('particle-effect-$id')));
    expect(center('rain').dy, center('neural').dy);
    expect(center('ripple').dy, center('neural').dy);
    expect(center('ember').dy, greaterThan(center('neural').dy));
    expect(center('dandelion').dy, center('ember').dy);
    // 工坊內直接顯示粒子層。
    expect(find.byType(AmbientParticleField), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('particle-effect-ember')));
    await tester.pump();
    // 按鍵動畫跑完才換粒子。
    await tester.pump(const Duration(milliseconds: 200));

    expect(YanciTheme.particleEffect, 'ember');
    expect(await ThemeSettings.getParticleEffect(), 'ember');
  });

  testWidgets('bokeh is gone and old fog settings fall back to neural', (
    tester,
  ) async {
    await L.setLocale('zh_TW');
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    YanciTheme.particleEffectOverride = 'fog';
    expect(YanciTheme.particleEffect, 'neural');
    YanciTheme.particleEffectOverride = null;

    await tester.pumpWidget(const MaterialApp(home: ThemeWorkshopScreen()));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('theme-particle-section-toggle')),
    );
    await tester.pumpAndSettle();

    expect(find.text('流螢光斑'), findsNothing);
    expect(find.byKey(const ValueKey('particle-effect-fog')), findsNothing);
    expect(find.text('飛花'), findsOneWidget);
  });
}
