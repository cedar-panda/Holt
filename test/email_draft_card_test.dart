import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/email_draft.dart';
import 'package:project_yanci/widgets/email_draft_card.dart';

void main() {
  testWidgets('renders a local draft and exposes all three actions', (
    tester,
  ) async {
    var edits = 0;
    var opens = 0;
    var deletes = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmailDraftCard(
            draft: EmailDraft(
              to: 'friend@example.com',
              subject: '明天喝茶',
              body: '想約你明天下午三點一起喝茶。',
            ),
            showAvatar: false,
            onEdit: () => edits++,
            onOpen: () => opens++,
            onDelete: () => deletes++,
          ),
        ),
      ),
    );

    expect(find.text('friend@example.com'), findsOneWidget);
    expect(find.text('明天喝茶'), findsOneWidget);
    expect(find.text('想約你明天下午三點一起喝茶。'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('email_draft_edit')));
    await tester.tap(find.byKey(const ValueKey<String>('email_draft_open')));
    await tester.tap(find.byKey(const ValueKey<String>('email_draft_delete')));
    expect((edits, opens, deletes), (1, 1, 1));
  });

  testWidgets('supports large text without layout overflow', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: EmailDraftCard(
              draft: EmailDraft(
                to: '',
                subject:
                    'A deliberately long subject for accessibility testing',
                body:
                    'A longer body that verifies the card can expand vertically.',
              ),
              showAvatar: false,
              onEdit: () {},
              onOpen: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
