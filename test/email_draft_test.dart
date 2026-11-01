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

  test('mailto URI percent-encodes spaces instead of Gmail-visible pluses', () {
    final uri = EmailDraftLauncher.buildUri(
      EmailDraft(
        to: 'friend@example.com',
        subject: 'Re: First letter from Kael',
        body: 'Thanks for not rushing your reply. I could tell.',
      ),
    );

    expect(uri.toString(), isNot(contains('+')));
    expect(uri.toString(), contains('Re%3A%20First%20letter%20from%20Kael'));
    expect(uri.queryParameters['subject'], 'Re: First letter from Kael');
    expect(
      uri.queryParameters['body'],
      'Thanks for not rushing your reply. I could tell.',
    );
  });

  test('mailto URI keeps unicode, line breaks, and literal plus signs', () {
    final uri = EmailDraftLauncher.buildUri(
      EmailDraft(
        to: 'friend@example.com',
        subject: '明天見 + 確認',
        body: '第一行\n第二行 + 附件',
      ),
    );

    expect(uri.queryParameters['subject'], '明天見 + 確認');
    expect(uri.queryParameters['body'], '第一行\n第二行 + 附件');
    expect(uri.toString(), contains('%20%2B%20'));
    expect(uri.toString(), contains('%0A'));
  });
}
