import 'package:flutter/material.dart';

import '../services/manual_summary_service.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_background.dart';

class ManualSummaryCleanScreen extends StatefulWidget {
  final String conversationId;
  final String characterId;
  final String title;
  final String initialExcerpt;

  const ManualSummaryCleanScreen({
    super.key,
    required this.conversationId,
    required this.characterId,
    required this.title,
    required this.initialExcerpt,
  });

  @override
  State<ManualSummaryCleanScreen> createState() =>
      _ManualSummaryCleanScreenState();
}

class _ManualSummaryCleanScreenState extends State<ManualSummaryCleanScreen> {
  late final TextEditingController _controller;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialExcerpt);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final excerpt = _controller.text.trim();
    if (excerpt.isEmpty) {
      _showSnack(
        L.pick(en: 'There is no content to summarize', zhTW: '沒有可摘要的內容'),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ManualSummaryService.summarizeExcerpt(
        conversationId: widget.conversationId,
        characterId: widget.characterId,
        excerpt: excerpt,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            L.pick(en: 'Manual summary completed.', zhTW: '手動摘要已完成。'),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: YanciTheme.accent,
        ),
      );
    } on ManualSummaryPolicyFailure {
      if (!mounted) return;
      _showSnack(
        L.pick(
          en: 'Summary still failed. Remove more sensitive content and try again.',
          zhTW: '摘要仍失敗，請再刪除敏感內容。',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack('${L.pick(en: 'Summary failed', zhTW: '摘要失敗')}：$e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        backgroundColor: YanciTheme.accent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title.trim().isEmpty
        ? L.pick(en: 'Clean source excerpt', zhTW: '原文摘錄清洗')
        : widget.title;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: GradientBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: _isSubmitting
                          ? null
                          : () => Navigator.of(context).pop(false),
                      icon: Icon(
                        Icons.arrow_back_ios_rounded,
                        color: YanciTheme.textPrimary,
                        size: 20,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            L.pick(en: 'Clean source excerpt', zhTW: '原文摘錄清洗'),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: YanciTheme.textPrimary,
                              fontFamily: YanciTheme.fontFamily,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 11,
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.55,
                              ),
                              fontFamily: YanciTheme.fontFamily,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: YanciTheme.glassInputBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: YanciTheme.accent.withValues(alpha: 0.18),
                      width: 0.6,
                    ),
                  ),
                  child: Text(
                    L.pick(
                      en: 'Delete or rewrite excerpts that trigger a refusal. This only changes this summary source, not chat history.',
                      zhTW: '刪掉或改寫會觸發拒絕的摘錄。這裡只影響本次摘要來源，不會改動聊天記錄。',
                    ),
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.75),
                      fontFamily: YanciTheme.fontFamily,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: YanciTheme.isDark
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.white.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: YanciTheme.textSecondary.withValues(alpha: 0.12),
                        width: 0.6,
                      ),
                    ),
                    child: TextField(
                      controller: _controller,
                      expands: true,
                      minLines: null,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      enabled: !_isSubmitting,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.55,
                        color: YanciTheme.textPrimary,
                        fontFamily: YanciTheme.fontFamily,
                      ),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: L.pick(
                          en: 'Paste or keep the excerpt to summarize',
                          zhTW: '貼上或保留要摘要的摘錄',
                        ),
                        hintStyle: TextStyle(
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.35,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _isSubmitting
                            ? null
                            : () => Navigator.of(context).pop(false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: YanciTheme.textSecondary,
                          side: BorderSide(
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.25,
                            ),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: Text(L.pick(en: 'Cancel', zhTW: '取消')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isSubmitting ? null : _submit,
                        icon: _isSubmitting
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: YanciTheme.textPrimary.withValues(
                                    alpha: 0.7,
                                  ),
                                ),
                              )
                            : const Icon(Icons.edit_note_rounded, size: 18),
                        label: Text(
                          L.pick(
                            en: _isSubmitting ? 'Summarizing' : 'Retry summary',
                            zhTW: _isSubmitting ? '摘要中' : '重試摘要',
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: YanciTheme.accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
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
