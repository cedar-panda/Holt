import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/tts_service.dart';
import 'package:project_yanci/widgets/bubble_action_glyph.dart';
import 'package:project_yanci/widgets/orbit_loading_indicator.dart';
import 'package:project_yanci/widgets/tts_play_button.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TtsService.playingMessageId.value = null;
    TtsService.stateNotifier.value = TtsState.idle;
  });

  tearDown(() {
    TtsService.playingMessageId.value = null;
    TtsService.stateNotifier.value = TtsState.idle;
  });

  testWidgets('TTS keeps idle, connecting, and playing visuals distinct', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TtsPlayButton(
              messageId: 'message-1',
              onTap: () {},
              size: 18,
            ),
          ),
        ),
      ),
    );

    final idleGlyph = tester.widget<BubbleActionGlyph>(
      find.byType(BubbleActionGlyph),
    );
    expect(idleGlyph.type, BubbleActionGlyphType.soundWave);
    expect(BubbleActionGlyph.strokeWidth, 1);

    TtsService.playingMessageId.value = 'message-1';
    TtsService.stateNotifier.value = TtsState.connecting;
    await tester.pump();
    final connectingPainters = tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    );
    expect(
      connectingPainters.any((widget) => widget.painter is OrbitPainter),
      isTrue,
    );
    expect(find.byType(BubbleActionGlyph), findsNothing);

    TtsService.stateNotifier.value = TtsState.playing;
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(TtsPlayButton),
        matching: find.byType(AnimatedBuilder),
      ),
      findsNWidgets(3),
    );
    expect(find.byType(BubbleActionGlyph), findsNothing);
  });
}
