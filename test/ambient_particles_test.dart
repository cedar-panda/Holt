import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/screens/theme_workshop_screen.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/settings/theme_settings.dart';
import 'package:project_yanci/theme/app_theme.dart';
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
  });

  testWidgets('ambient particle field exposes every supported style', (
    tester,
  ) async {
    final expectedTypes = <String, Type>{
      'neural': NeuralFieldWidget,
      'stars': StarfieldWidget,
      'fog': FogParticleWidget,
      'rain': RainWidget,
      'ripple': RippleParticleWidget,
      'ember': EmberParticleWidget,
      'dandelion': DandelionParticleWidget,
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

    expect(find.byKey(const ValueKey('particle-effect-tabs')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('particle-effect-neural')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('particle-effect-dandelion')),
      findsOneWidget,
    );
    final neuralCenter = tester.getCenter(
      find.byKey(const ValueKey('particle-effect-neural')),
    );
    final fogCenter = tester.getCenter(
      find.byKey(const ValueKey('particle-effect-fog')),
    );
    final rippleCenter = tester.getCenter(
      find.byKey(const ValueKey('particle-effect-ripple')),
    );
    final dandelionCenter = tester.getCenter(
      find.byKey(const ValueKey('particle-effect-dandelion')),
    );
    expect(fogCenter.dy, neuralCenter.dy);
    expect(dandelionCenter.dy, rippleCenter.dy);
    expect(rippleCenter.dy, greaterThan(neuralCenter.dy));

    await tester.tap(find.byKey(const ValueKey('particle-effect-ember')));
    await tester.pump();

    expect(YanciTheme.particleEffect, 'ember');
    expect(await ThemeSettings.getParticleEffect(), 'ember');
  });
}
