import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/widgets/chat_model_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
  });

  testWidgets(
    'model picker uses a theme capsule, active light and local section',
    (tester) async {
      const customAccent = Color(0xFF2A8C7D);
      bool? thinkingValue;
      String? selectedModel;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 390,
                child: ChatModelPickerPanel(
                  entries: const [
                    ChatModelPickerEntry(
                      id: 'cloud-popular',
                      label: 'Popular Cloud',
                      isLocal: false,
                    ),
                    ChatModelPickerEntry(
                      id: 'cloud-other',
                      label: 'Other Cloud',
                      isLocal: false,
                    ),
                    ChatModelPickerEntry(
                      id: 'local:qwen',
                      label: 'Qwen Local',
                      isLocal: true,
                    ),
                  ],
                  currentModelId: 'cloud-popular',
                  initialThinking: false,
                  accentColor: customAccent,
                  onThinkingChanged: (value) async {
                    thinkingValue = value;
                  },
                  onModelSelected: (modelId) async {
                    selectedModel = modelId;
                  },
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Thinking'), findsOneWidget);
      expect(find.text('本地'), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      expect(
        find.byKey(const ValueKey('chat-model-active-dot')),
        findsOneWidget,
      );
      final dotDecorations = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byKey(const ValueKey('chat-model-active-dot')),
              matching: find.byType(Container),
            ),
          )
          .map((container) => container.decoration)
          .whereType<BoxDecoration>();
      expect(
        dotDecorations.any((decoration) => decoration.color == customAccent),
        isTrue,
      );

      final cloudTop = tester.getTopLeft(
        find.byKey(const ValueKey('chat-model-row-cloud-popular')),
      );
      final localHeaderTop = tester.getTopLeft(
        find.byKey(const ValueKey('chat-model-local-header')),
      );
      final localTop = tester.getTopLeft(
        find.byKey(const ValueKey('chat-model-row-local:qwen')),
      );
      expect(cloudTop.dy, lessThan(localHeaderTop.dy));
      expect(localHeaderTop.dy, lessThan(localTop.dy));

      final selectedContainer = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(const ValueKey('chat-model-row-cloud-popular')),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final selectedDecoration = selectedContainer.decoration! as BoxDecoration;
      expect(selectedDecoration.border, isNull);
      expect(selectedDecoration.color, isNot(Colors.transparent));
      expect(selectedDecoration.borderRadius, BorderRadius.circular(999));

      await tester.tap(
        find.byKey(const ValueKey('chat-model-thinking-toggle')),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(thinkingValue, isTrue);

      await tester.tap(
        find.byKey(const ValueKey('chat-model-row-cloud-other')),
      );
      await tester.pump();
      expect(selectedModel, 'cloud-other');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion keeps both active indicators static', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: SizedBox(
              width: 300,
              height: 280,
              child: ChatModelPickerPanel(
                entries: const [
                  ChatModelPickerEntry(
                    id: 'cloud',
                    label: 'Cloud',
                    isLocal: false,
                  ),
                ],
                currentModelId: 'cloud',
                initialThinking: true,
                accentColor: const Color(0xFF906CB4),
                onThinkingChanged: (_) async {},
                onModelSelected: (_) async {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-model-active-dot')), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('route transition unfolds once without overshoot or fading', (
    tester,
  ) async {
    final controller = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 220),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: ChatModelPickerRouteTransition(
              animation: controller,
              reduceMotion: false,
              child: const SizedBox(
                key: ValueKey('transition-probe'),
                width: 280,
                height: 200,
              ),
            ),
          ),
        ),
      ),
    );

    final clip = find.byKey(
      const ValueKey('chat-model-picker-transition-clip'),
    );
    final pickerFade = find.descendant(
      of: find.byType(ChatModelPickerRouteTransition),
      matching: find.byType(FadeTransition),
    );
    expect(tester.getSize(clip).height, 0);
    expect(pickerFade, findsNothing);

    controller.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    final openingHeight = tester.getSize(clip).height;
    expect(openingHeight, greaterThan(0));
    expect(openingHeight, lessThan(200));

    controller.value = 0.75;
    await tester.pump();
    final transforms = tester
        .widgetList<Transform>(
          find.descendant(
            of: find.byType(ChatModelPickerRouteTransition),
            matching: find.byType(Transform),
          ),
        )
        .toList(growable: false);
    expect(transforms, hasLength(3));
    expect(transforms.first.transform.storage[13], lessThanOrEqualTo(0));
    expect(transforms.last.transform.storage[0], lessThanOrEqualTo(1));

    controller.forward();
    await tester.pumpAndSettle();
    expect(tester.getSize(clip).height, 200);

    controller.reverse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 135));
    expect(tester.getSize(clip).height, lessThan(1));
    expect(pickerFade, findsNothing);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion shows the picker at full size immediately', (
    tester,
  ) async {
    final controller = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 220),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatModelPickerRouteTransition(
            animation: controller,
            reduceMotion: true,
            child: const SizedBox(
              key: ValueKey('reduced-motion-probe'),
              width: 280,
              height: 200,
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const ValueKey('reduced-motion-probe'))),
      const Size(280, 200),
    );
    expect(
      find.descendant(
        of: find.byType(ChatModelPickerRouteTransition),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
