import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/email_draft.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/email_draft_launcher.dart';
import 'package:project_yanci/services/email_draft_tool.dart';

void main() {
  test('extracts the final draft block and keeps visible reply text', () {
    const raw = '''可以，草稿在下面。
<email_draft>
<to>friend@example.com</to>
<subject>明天見</subject>
<body>嗨，明天下午三點見。</body>
</email_draft>''';

    final result = EmailDraftTool.extract(raw);

    expect(result.visibleText, '可以，草稿在下面。');
    expect(result.draft?.to, 'friend@example.com');
    expect(result.draft?.subject, '明天見');
    expect(result.draft?.body, '嗨，明天下午三點見。');
  });

  test('empty draft tags are stripped without creating a card', () {
    final result = EmailDraftTool.extract(
      '完成。<email_draft><to></to><subject></subject><body></body></email_draft>',
    );

    expect(result.visibleText, '完成。');
    expect(result.draft, isNull);
  });

  test('draft serialization sanitizes header injection', () {
    final draft = EmailDraft(
      to: 'friend@example.com\r\nBcc: hidden@example.com',
      subject: 'Hello\nBcc: hidden@example.com',
      body: 'Line one\r\nLine two',
    );

    expect(draft.to, 'friend@example.com Bcc: hidden@example.com');
    expect(draft.subject, 'Hello Bcc: hidden@example.com');
    expect(EmailDraft.decode(draft.encode()), draft);
    expect(draft.body, 'Line one\nLine two');
  });

  test('draft metadata never enters provider prompt history', () {
    final message = Message(
      conversationId: 'c1',
      text: 'Visible reply',
      isUser: false,
      emailDraft: EmailDraft(to: '', subject: 'Private', body: 'Draft body'),
    );

    expect(message.toPromptHistoryEntry(), <String, String>{
      'role': 'assistant',
      'content': 'Visible reply',
    });
    final restored = Message.fromMap(message.toMap());
    expect(restored.emailDraft, message.emailDraft);
  });

  test('mailto URI contains only the user-reviewed draft fields', () {
    final uri = EmailDraftLauncher.buildUri(
      EmailDraft(
        to: 'friend@example.com',
        subject: 'Tea tomorrow?',
        body: 'See you at 3.',
      ),
    );

    expect(uri.scheme, 'mailto');
    expect(uri.path, 'friend@example.com');
    expect(uri.queryParameters['subject'], 'Tea tomorrow?');
    expect(uri.queryParameters['body'], 'See you at 3.');
  });
}
