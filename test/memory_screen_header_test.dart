import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/theme/app_theme.dart';
import 'package:project_yanci/widgets/memory_screen_header.dart';

void main() {
  testWidgets('memory header grows instead of overflowing at large text', (
    tester,
  ) async {
    final originalScale = YanciTheme.fontScale;
    addTearDown(() => YanciTheme.setFontScale(originalScale));
    YanciTheme.setFontScale(1.5);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.2)),
          child: Scaffold(
            body: MemoryScreenHeader(
              isSpiderWebEnabled: true,
              isGraphView: false,
              memoryCount: 42,
              totalTokens: 2048,
              activeLayerIndex: 0,
              layerCount: 10,
              memorySendLimit: 8,
              onBack: () {},
              onToggleGraph: () {},
              onSendLimitPressed: () {},
              onBudgetPressed: () {},
              onAddMemory: () {},
              onManualAddBlocked: () {},
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
