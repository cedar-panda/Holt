import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/context_compressor.dart';
import '../services/locale_strings.dart';
import '../widgets/gradient_background.dart';

/// 上下文壓縮 debug 頁（開發用，user 不可見）
class ContextDebugScreen extends StatefulWidget {
  final String characterId;
  const ContextDebugScreen({super.key, required this.characterId});

  @override
  State<ContextDebugScreen> createState() => _ContextDebugScreenState();
}

class _ContextDebugScreenState extends State<ContextDebugScreen> {
  Map<String, dynamic>? _info;
  bool _loading = true;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await ContextCompressor.getDebugInfo(widget.characterId);
    if (mounted) {
      setState(() {
        _info = info;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              // ═══ 頂欄 ═══
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.arrow_back_ios_new,
                        size: 18,
                        color: YanciTheme.textPrimary,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    Text(
                      'Context Debug',
                      style: YanciTheme.bodyText.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(
                        Icons.refresh,
                        size: 18,
                        color: YanciTheme.textPrimary,
                      ),
                      onPressed: () {
                        setState(() => _loading = true);
                        _load();
                      },
                    ),
                  ],
                ),
              ),

              // ═══ 內容 ═══
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _info == null
                    ? Center(child: Text('No data', style: YanciTheme.bodyText))
                    : _buildContent(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final summaryBlocks = _info!['summaryBlocks'] as List;
    final keywordBlocks = _info!['keywordBlocks'] as List;
    final summaryTotal = _info!['summaryTokenTotal'] as int;
    final keywordTotal = _info!['keywordTokenTotal'] as int;
    final summaryCap = _info!['summaryCap'] as int;
    final keywordCap = _info!['keywordCap'] as int;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ═══ 總覽 ═══
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Overview',
                style: YanciTheme.bodyText.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              _row('Summary tokens', '$summaryTotal / $summaryCap'),
              _row('Keyword tokens', '$keywordTotal / $keywordCap'),
              _row('Summary blocks', '${summaryBlocks.length}'),
              _row('Keyword blocks', '${keywordBlocks.length}'),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // ═══ 摘要塊 ═══
        Text(
          'Summary Blocks',
          style: YanciTheme.bodyText.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: YanciTheme.accent,
          ),
        ),
        const SizedBox(height: 8),
        if (summaryBlocks.isEmpty)
          _card(child: Text('(empty)', style: YanciTheme.bodySmall))
        else
          ...summaryBlocks.asMap().entries.map((e) {
            final b = e.value as Map;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '#${e.key + 1}',
                          style: YanciTheme.bodyText.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: YanciTheme.accent,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${b['token_count']}t',
                          style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatTime(b['created_at']),
                          style: YanciTheme.bodySmall.copyWith(fontSize: 10),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _buildEditableSummarySegments(
                      b['content'] as String? ?? '',
                      onEdit: (segment) => _reviseSummarySegment(b, segment),
                    ),
                  ],
                ),
              ),
            );
          }),

        const SizedBox(height: 16),

        // ═══ 關鍵詞塊 ═══
        Text(
          'Keyword Blocks',
          style: YanciTheme.bodyText.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: YanciTheme.accent,
          ),
        ),
        const SizedBox(height: 8),
        if (keywordBlocks.isEmpty)
          _card(child: Text('(empty)', style: YanciTheme.bodySmall))
        else
          ...keywordBlocks.asMap().entries.map((e) {
            final b = e.value as Map;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '#${e.key + 1}',
                          style: YanciTheme.bodyText.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: YanciTheme.accent,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${b['token_count']}t',
                          style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatTime(b['created_at']),
                          style: YanciTheme.bodySmall.copyWith(fontSize: 10),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: (b['keywords'] as String? ?? '')
                          .split(',')
                          .map((k) => k.trim())
                          .where((k) => k.isNotEmpty)
                          .map(
                            (k) => Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: YanciTheme.accent.withValues(
                                  alpha: 0.15,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                k,
                                style: YanciTheme.bodyText.copyWith(
                                  fontSize: 11,
                                  color: YanciTheme.accent,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                    if ((b['source_summary_content'] as String? ?? '')
                        .trim()
                        .isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Source Summary',
                        style: YanciTheme.bodySmall.copyWith(
                          fontSize: 10,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.65,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      _buildEditableSummarySegments(
                        b['source_summary_content'] as String,
                        dense: true,
                        onEdit: (segment) => _reviseKeywordSegment(b, segment),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }),

        const SizedBox(height: 40),
      ],
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: YanciTheme.glassWhite,
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        border: Border.all(color: YanciTheme.glassBorder, width: 0.5),
      ),
      child: child,
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: YanciTheme.bodySmall.copyWith(fontSize: 12)),
          Text(value, style: YanciTheme.bodyText.copyWith(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildEditableSummarySegments(
    String content, {
    required ValueChanged<_EditableSummarySegment> onEdit,
    bool dense = false,
  }) {
    final segments = _splitEditableSegments(content);
    if (segments.isEmpty) {
      return Text(content, style: YanciTheme.bodyText.copyWith(fontSize: 12));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final segment in segments) ...[
          Container(
            width: double.infinity,
            margin: EdgeInsets.only(bottom: dense ? 6 : 8),
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 8 : 10,
              vertical: dense ? 7 : 8,
            ),
            decoration: BoxDecoration(
              color: YanciTheme.glassWhite.withValues(alpha: 0.38),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: YanciTheme.glassBorder.withValues(alpha: 0.65),
                width: 0.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      L.pick(
                        en: 'Block ${segment.index + 1}',
                        zhTW: '段 ${segment.index + 1}',
                      ),
                      style: YanciTheme.bodySmall.copyWith(
                        fontSize: 10,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.65),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 30,
                        minHeight: 28,
                      ),
                      icon: Icon(
                        Icons.edit_note_rounded,
                        size: 17,
                        color: _editing
                            ? YanciTheme.textSecondary.withValues(alpha: 0.35)
                            : YanciTheme.accent,
                      ),
                      onPressed: _editing ? null : () => onEdit(segment),
                    ),
                  ],
                ),
                Text(
                  segment.text,
                  style: YanciTheme.bodyText.copyWith(
                    fontSize: dense ? 11 : 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  List<_EditableSummarySegment> _splitEditableSegments(String content) {
    if (content.trim().isEmpty) return const [];
    final hasBlankLine = RegExp(r'\n\s*\n').hasMatch(content);
    final pattern = hasBlankLine
        ? RegExp(r'\S[\s\S]*?(?=\n\s*\n|$)')
        : RegExp(r'[^\n]+');
    final segments = <_EditableSummarySegment>[];
    var index = 0;
    for (final match in pattern.allMatches(content)) {
      final raw = match.group(0) ?? '';
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final leading = raw.length - raw.trimLeft().length;
      final trailing = raw.length - raw.trimRight().length;
      segments.add(
        _EditableSummarySegment(
          index: index,
          start: match.start + leading,
          end: match.end - trailing,
          text: trimmed,
        ),
      );
      index++;
    }
    return segments;
  }

  Future<void> _reviseSummarySegment(
    Map block,
    _EditableSummarySegment segment,
  ) async {
    final id = block['id'] as int?;
    final fullSummary = block['content'] as String? ?? '';
    if (id == null || segment.text.trim().isEmpty) return;

    final issue = await _askRevisionIssue(segment.text);
    if (issue == null || issue.trim().isEmpty) return;
    if (!mounted) return;

    setState(() => _editing = true);
    try {
      final revised = await ContextCompressor.reviseSummaryBlockSegment(
        id: id,
        characterId: widget.characterId,
        fullSummary: fullSummary,
        segmentStart: segment.start,
        segmentEnd: segment.end,
        originalSegment: segment.text,
        issue: issue.trim(),
      );
      if (!mounted) return;
      if (revised.isEmpty) {
        _showSnack(
          L.pick(
            en: 'Revision failed: the summary model returned no content',
            zhTW: '修正失敗，摘要模型沒有返回內容',
          ),
        );
      }
      await _load();
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _reviseKeywordSegment(
    Map block,
    _EditableSummarySegment segment,
  ) async {
    final id = block['id'] as int?;
    final fullSummary = block['source_summary_content'] as String? ?? '';
    if (id == null || segment.text.trim().isEmpty) return;

    final issue = await _askRevisionIssue(segment.text);
    if (issue == null || issue.trim().isEmpty) return;
    if (!mounted) return;

    setState(() => _editing = true);
    try {
      final revised = await ContextCompressor.reviseKeywordSourceSummarySegment(
        id: id,
        characterId: widget.characterId,
        fullSummary: fullSummary,
        segmentStart: segment.start,
        segmentEnd: segment.end,
        originalSegment: segment.text,
        issue: issue.trim(),
        existingKeywords: block['keywords'] as String? ?? '',
      );
      if (!mounted) return;
      if (revised.isEmpty) {
        _showSnack(
          L.pick(
            en: 'Revision failed: the summary model returned no content',
            zhTW: '修正失敗，摘要模型沒有返回內容',
          ),
        );
      }
      await _load();
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<String?> _askRevisionIssue(String original) async {
    return showDialog<String>(
      context: context,
      builder: (ctx) => _SummaryRevisionDialog(original: original),
    );
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  String _formatTime(dynamic ts) {
    if (ts == null) return '';
    try {
      final dt = DateTime.parse(ts.toString());
      return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return ts.toString();
    }
  }
}

class _EditableSummarySegment {
  final int index;
  final int start;
  final int end;
  final String text;

  const _EditableSummarySegment({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
  });
}

class _SummaryRevisionDialog extends StatefulWidget {
  final String original;

  const _SummaryRevisionDialog({required this.original});

  @override
  State<_SummaryRevisionDialog> createState() => _SummaryRevisionDialogState();
}

class _SummaryRevisionDialogState extends State<_SummaryRevisionDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: YanciTheme.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        L.pick(en: 'Revise summary block', zhTW: '修正摘要段'),
        style: YanciTheme.headingMedium,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              L.pick(en: 'What is wrong with this block?', zhTW: '這段哪裡有問題？'),
              style: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              style: YanciTheme.bodyText.copyWith(fontSize: 13),
              decoration: InputDecoration(
                hintText: L.pick(
                  en: 'Example: a relationship is reversed, the latest promise is missing, or the emotion is too speculative…',
                  zhTW: '例：人物關係寫反了；漏掉最後的約定；這段情緒太武斷……',
                ),
                hintStyle: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.45),
                  fontSize: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(
                child: Text(
                  widget.original,
                  style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.pop(context);
          },
          child: Text(
            L.pick(en: 'Cancel', zhTW: '取消'),
            style: TextStyle(color: YanciTheme.textSecondary),
          ),
        ),
        TextButton(
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.pop(context, _ctrl.text);
          },
          child: Text(
            L.pick(en: 'Send to summary model', zhTW: '送給摘要模型'),
            style: TextStyle(color: YanciTheme.accent),
          ),
        ),
      ],
    );
  }
}
