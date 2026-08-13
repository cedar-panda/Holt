import '../models/email_draft.dart';
import 'locale_strings.dart';

class EmailDraftExtraction {
  const EmailDraftExtraction({required this.visibleText, this.draft});

  final String visibleText;
  final EmailDraft? draft;
}

/// Local tag tool used by the companion model to propose an editable email.
/// No account data, OAuth token, or network operation is involved.
class EmailDraftTool {
  static final RegExp _draftTag = RegExp(
    r'<email_draft\b[^>]*>([\s\S]*?)</email_draft>',
    caseSensitive: false,
  );

  static String runtimeInstruction() => L.pick(
    en:
        '【Local Email Draft】\n'
        'When they ask you to write an email, or when an email draft is clearly useful, place exactly one block at the end of your natural reply:\n'
        '<email_draft>\n<to>recipient@example.com (leave empty if unknown)</to>\n<subject>email subject</subject>\n<body>complete plain-text email body</body>\n</email_draft>\n'
        'This only creates an editable local draft. It never sends email. Do not mention the tags.',
    zhTW:
        '【本地郵件草稿】\n'
        '當對方要求你寫郵件，或郵件草稿明顯有幫助時，在自然回覆末尾放且只放一組：\n'
        '<email_draft>\n<to>收件人信箱（未知可留空）</to>\n<subject>郵件主旨</subject>\n<body>完整純文字郵件正文</body>\n</email_draft>\n'
        '這只會建立可編輯的本地草稿，絕不會寄出郵件。正文不要提及標籤。',
    zhCN:
        '【本地邮件草稿】\n'
        '当对方要求你写邮件，或邮件草稿明显有帮助时，在自然回复末尾放且只放一组：\n'
        '<email_draft>\n<to>收件人邮箱（未知可留空）</to>\n<subject>邮件主题</subject>\n<body>完整纯文本邮件正文</body>\n</email_draft>\n'
        '这只会创建可编辑的本地草稿，绝不会发送邮件。正文不要提及标签。',
  );

  static EmailDraftExtraction extract(String text) {
    final matches = _draftTag.allMatches(text).toList(growable: false);
    EmailDraft? draft;
    if (matches.isNotEmpty) {
      final content = matches.last.group(1) ?? '';
      final candidate = EmailDraft(
        to: _field(content, 'to'),
        subject: _field(content, 'subject'),
        body: _field(content, 'body'),
      );
      if (!candidate.isEmpty) draft = candidate;
    }
    final visible = text.replaceAll(_draftTag, '').trim();
    return EmailDraftExtraction(visibleText: visible, draft: draft);
  }

  static String _field(String content, String name) {
    final match = RegExp(
      '<$name\\b[^>]*>([\\s\\S]*?)</$name>',
      caseSensitive: false,
    ).firstMatch(content);
    return match?.group(1)?.trim() ?? '';
  }
}
