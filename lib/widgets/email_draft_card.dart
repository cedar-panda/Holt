import 'package:flutter/material.dart';

import '../models/email_draft.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class EmailDraftCard extends StatelessWidget {
  const EmailDraftCard({
    super.key,
    required this.draft,
    required this.onEdit,
    required this.onOpen,
    required this.onDelete,
    this.showAvatar = true,
  });

  final EmailDraft draft;
  final VoidCallback onEdit;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final bool showAvatar;

  @override
  Widget build(BuildContext context) {
    final recipient = draft.to.isEmpty
        ? L.pick(en: 'Recipient not set', zhTW: '尚未填寫收件人', zhCN: '尚未填写收件人')
        : draft.to;
    final subject = draft.subject.isEmpty
        ? L.pick(en: 'No subject', zhTW: '無主旨', zhCN: '无主题')
        : draft.subject;
    final surface = Color.alphaBlend(
      YanciTheme.accent.withValues(alpha: YanciTheme.isDark ? 0.12 : 0.08),
      YanciTheme.surfacePanel,
    );

    return Semantics(
      container: true,
      label: L.pick(en: 'Local email draft', zhTW: '本機郵件草稿', zhCN: '本机邮件草稿'),
      child: Padding(
        padding: EdgeInsets.only(
          left: showAvatar ? 60 : YanciTheme.spacingMd,
          right: MediaQuery.sizeOf(context).width * 0.12,
          top: YanciTheme.spacingXs,
          bottom: YanciTheme.spacingXs,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            border: Border.all(
              color: YanciTheme.accent.withValues(
                alpha: YanciTheme.isDark ? 0.30 : 0.22,
              ),
              width: 0.8,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.drafts_outlined,
                      size: 18,
                      color: YanciTheme.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            L.pick(
                              en: 'Email draft',
                              zhTW: '郵件草稿',
                              zhCN: '邮件草稿',
                            ),
                            style: YanciTheme.bodySmall.copyWith(
                              fontWeight: FontWeight.w700,
                              color: YanciTheme.textPrimary,
                            ),
                          ),
                          Text(
                            L.pick(
                              en: 'Local only · Not sent',
                              zhTW: '僅保存在本機 · 尚未寄出',
                              zhCN: '仅保存在本机 · 尚未发送',
                            ),
                            style: YanciTheme.bodySmall.copyWith(
                              fontSize: 10,
                              color: YanciTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const ValueKey<String>('email_draft_delete'),
                      tooltip: L.pick(
                        en: 'Delete draft',
                        zhTW: '刪除草稿',
                        zhCN: '删除草稿',
                      ),
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      color: YanciTheme.textSecondary,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                    ),
                  ],
                ),
                _DraftLine(
                  icon: Icons.alternate_email_rounded,
                  text: recipient,
                ),
                const SizedBox(height: 7),
                Text(
                  subject,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: YanciTheme.bodyText.copyWith(
                    fontWeight: FontWeight.w700,
                    color: YanciTheme.textPrimary,
                  ),
                ),
                if (draft.body.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 7),
                  SelectableText(
                    draft.body,
                    maxLines: 6,
                    style: YanciTheme.bodySmall.copyWith(
                      height: 1.45,
                      color: YanciTheme.textPrimary,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    OutlinedButton.icon(
                      key: const ValueKey<String>('email_draft_edit'),
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 17),
                      label: Text(L.pick(en: 'Edit', zhTW: '編輯', zhCN: '编辑')),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        foregroundColor: YanciTheme.accent,
                      ),
                    ),
                    FilledButton.icon(
                      key: const ValueKey<String>('email_draft_open'),
                      onPressed: onOpen,
                      icon: const Icon(Icons.open_in_new_rounded, size: 17),
                      label: Text(
                        L.pick(
                          en: 'Open email app',
                          zhTW: '用郵件 App 打開',
                          zhCN: '用邮件 App 打开',
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        backgroundColor: YanciTheme.accent,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DraftLine extends StatelessWidget {
  const _DraftLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 15, color: YanciTheme.textSecondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

Future<EmailDraft?> showEmailDraftEditor(
  BuildContext context,
  EmailDraft draft,
) {
  return showModalBottomSheet<EmailDraft>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: YanciTheme.surfacePanel,
    builder: (context) => _EmailDraftEditor(draft: draft),
  );
}

class _EmailDraftEditor extends StatefulWidget {
  const _EmailDraftEditor({required this.draft});

  final EmailDraft draft;

  @override
  State<_EmailDraftEditor> createState() => _EmailDraftEditorState();
}

class _EmailDraftEditorState extends State<_EmailDraftEditor> {
  late final TextEditingController _to = TextEditingController(
    text: widget.draft.to,
  );
  late final TextEditingController _subject = TextEditingController(
    text: widget.draft.subject,
  );
  late final TextEditingController _body = TextEditingController(
    text: widget.draft.body,
  );

  @override
  void dispose() {
    _to.dispose();
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  void _save() {
    final result = EmailDraft(
      to: _to.text,
      subject: _subject.text,
      body: _body.text,
    );
    if (result.isEmpty) return;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              L.pick(en: 'Edit email draft', zhTW: '編輯郵件草稿', zhCN: '编辑邮件草稿'),
              style: YanciTheme.headingMedium.copyWith(
                color: YanciTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey<String>('email_draft_to_field'),
              controller: _to,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: L.pick(
                  en: 'To (optional)',
                  zhTW: '收件人（可留空）',
                  zhCN: '收件人（可留空）',
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('email_draft_subject_field'),
              controller: _subject,
              decoration: InputDecoration(
                labelText: L.pick(en: 'Subject', zhTW: '主旨', zhCN: '主题'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('email_draft_body_field'),
              controller: _body,
              minLines: 6,
              maxLines: 14,
              decoration: InputDecoration(
                alignLabelWithHint: true,
                labelText: L.pick(en: 'Message', zhTW: '正文', zhCN: '正文'),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _save,
                  child: Text(
                    L.pick(en: 'Save draft', zhTW: '儲存草稿', zhCN: '保存草稿'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
