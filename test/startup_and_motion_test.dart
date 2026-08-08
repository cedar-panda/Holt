import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/main.dart' as app;
import 'package:project_yanci/screens/splash_screen.dart';
import 'package:project_yanci/services/settings/user_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('startup step gives control back after its deadline', () async {
    final never = Completer<void>();
    final stopwatch = Stopwatch()..start();

    await app.startupStepForTesting(
      'never',
      () => never.future,
      timeout: const Duration(milliseconds: 20),
    );

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  testWidgets('reduced motion skips the splash business gate', (tester) async {
    SharedPreferences.setMockInitialValues({
      'first_launch_language_version':
          UserSettings.currentFirstLaunchLanguageVersion,
      'initial_setup_version': UserSettings.currentInitialSetupVersion,
    });
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: const SplashScreen(),
        routes: {'/home': (_) => const Text('home-ready')},
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('home-ready'), findsOneWidget);
  });
}
