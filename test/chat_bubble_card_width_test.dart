import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/scratch_service.dart';
import 'package:project_yanci/services/transfer_service.dart';
import 'package:project_yanci/widgets/chat_bubble.dart';
import 'package:project_yanci/widgets/scratch_card.dart';
import 'package:project_yanci/widgets/transfer_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
  });

  Future<void> pumpBubble(
    WidgetTester tester, {
    required bool isUser,
    TransferData? transferData,
    ScratchData? scratchData,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ChatBubble(
              text: '短',
              isUser: isUser,
              messageId: 'message-id',
              characterId: 'character-id',
              transferData: transferData,
              scratchData: scratchData,
              captureMode: true,
              showToolbar: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('transfer card does not stretch user or character text bubble', (
    tester,
  ) async {
    for (final isUser in <bool>[true, false]) {
      await pumpBubble(
        tester,
        isUser: isUser,
        transferData: TransferData(
          amount: 20,
          direction: isUser ? 'toChar' : 'toUser',
          status: 'accepted',
        ),
      );

      final bubbleWidth = tester
          .getSize(find.byKey(const ValueKey('chat-bubble-surface')))
          .width;
      final cardWidth = tester.getSize(find.byType(TransferMiniCard)).width;
      expect(bubbleWidth, lessThan(cardWidth));
    }
  });

  testWidgets('scratch card does not stretch user or character text bubble', (
    tester,
  ) async {
    for (final isUser in <bool>[true, false]) {
      await pumpBubble(
        tester,
        isUser: isUser,
        scratchData: ScratchData(
          cost: 20,
          who: isUser ? 'user' : 'char',
          prizes: const [ScratchResult(label: '20 貝', coins: 20)],
          scratched: true,
        ),
      );

      final bubbleWidth = tester
          .getSize(find.byKey(const ValueKey('chat-bubble-surface')))
          .width;
      final cardWidth = tester.getSize(find.byType(ScratchMiniCard)).width;
      expect(bubbleWidth, lessThan(cardWidth));
    }
  });
}
