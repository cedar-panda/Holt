import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../theme/app_theme.dart';
import '../memory/database.dart';
import '../services/context_compressor.dart';
import '../services/locale_strings.dart';
import '../services/token_estimator.dart';
import '../models/context_mode.dart';

/// 摘要 Tab — 無底色條目流 + 關鍵詞召回區
class MemorySummaryTab extends StatefulWidget {
  final String characterId;
  final ContextMode? contextMode;
  final String continuityId;
  final VoidCallback? onSummaryModified;

  const MemorySummaryTab({
    super.key,
    required this.characterId,
    this.contextMode,
    this.continuityId = 'main',
    this.onSummaryModified,
  });

  /// 只改閱讀排版，不改資料庫中的摘要原文，也不影響之後注入模型的內容。
  static String formatForReading(String raw) {
    final source = raw
        .replaceAll('\r\n', '\n')
        .split('\n')
        .where((line) => !_isGenericSummaryHeading(line))
        .join('\n')
        .trim();
    if (source.isEmpty) return '';
    if (containsMarkdown(source)) return source;

    final result = <String>[];
    for (final rawBlock in source.split(RegExp(r'\n+'))) {
      final block = rawBlock.trim();
      if (block.isEmpty) continue;
      if (block.characters.length <= 90 ||
          (block.startsWith('【') && block.endsWith('】'))) {
        result.add(block);
        continue;
      }

      final sentences = <String>[];
      final sentence = StringBuffer();
      for (final character in block.characters) {
        sentence.write(character);
        if ('。！？!?'.contains(character)) {
          final value = sentence.toString().trim();
          if (value.isNotEmpty) sentences.add(value);
          sentence.clear();
        }
      }
      final tail = sentence.toString().trim();
      if (tail.isNotEmpty) sentences.add(tail);
      if (sentences.length <= 1) {
        result.add(block);
        continue;
      }

      var paragraph = '';
      for (final item in sentences) {
        final candidate = '$paragraph$item';
        if (paragraph.isNotEmpty && candidate.characters.length > 90) {
          result.add(paragraph);
          paragraph = item;
        } else {
          paragraph = candidate;
        }
      }
      if (paragraph.isNotEmpty) result.add(paragraph);
    }
    return result.join('\n\n');
  }

  /// The canonical daily-summary headings remain in storage and injection,
  /// but are redundant inside the visual archive where every row is already a
  /// summary. Strip them only from the reading surface.
  static bool _isGenericSummaryHeading(String line) {
    return RegExp(
      r'^\s*#{1,6}\s*'
      r'(?:前情提要|前情摘要|先前摘要|本次摘要|最新摘要|'
      r'Prior Context|Previous Summary|Prior Summary|This Update|'
      r'Latest Summary|Recent Summary)\s*[:：]?\s*$',
      caseSensitive: false,
    ).hasMatch(line);
  }

  /// Markdown 摘要保留原始換行與標記，避免自動分段拆壞標題或條列。
  static bool containsMarkdown(String source) {
    return RegExp(
      r'(^|\n)\s{0,3}(?:#{1,6}\s+|[-+*]\s+|>\s+|\d+[.)]\s+)|'
      r'\*\*[^*\n]+\*\*|__[^_\n]+__|`[^`\n]+`|'
      r'\[[^\]\n]+\]\([^)]+\)',
    ).hasMatch(source);
  }

  @override
  State<MemorySummaryTab> createState() => _MemorySummaryTabState();
}

class _MemorySummaryTabState extends State<MemorySummaryTab>
    with TickerProviderStateMixin {
  List<Map<String, dynamic>> _summaries = [];
  List<Map<String, dynamic>> _keywords = [];
  bool _loading = true;
  int? _expandedSummaryId;
  int? _editingSummaryId;
  bool _keywordsExpanded = false;
  int? _expandedKeywordId;
  final TextEditingController _editCtrl = TextEditingController();

  // Stagger animation
  late AnimationController _staggerCtrl;

  @override
  void initState() {
    super.initState();
    _staggerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _loadData();
  }

  @override
  void dispose() {
    _staggerCtrl.dispose();
    _editCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MemorySummaryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.characterId != widget.characterId ||
        oldWidget.contextMode != widget.contextMode ||
        oldWidget.continuityId != widget.continuityId) {
      _loadData();
    }
  }

  Future<void> _loadData() async {
    if (mounted) setState(() => _loading = true);
    final modes = widget.contextMode == null
        ? const <ContextMode>[ContextMode.daily, ContextMode.rp]
        : <ContextMode>[widget.contextMode!];
    final summaryGroups = await Future.wait([
      for (final mode in modes)
        DatabaseHelper.getContextSummaries(
          widget.characterId,
          contextMode: mode,
          continuityId: mode == ContextMode.rp ? widget.continuityId : 'main',
        ),
    ]);
    final keywordGroups = await Future.wait([
      for (final mode in modes)
        DatabaseHelper.getContextKeywords(
          widget.characterId,
          contextMode: mode,
          continuityId: mode == ContextMode.rp ? widget.continuityId : 'main',
        ),
    ]);
    final summaries = summaryGroups.expand((group) => group).toList()
      ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
    final keywords = keywordGroups.expand((group) => group).toList()
      ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
    if (!mounted) return;
    setState(() {
      _summaries = summaries.reversed.map((row) {
        final mode = ContextMode.fromStorage(row['context_mode']);
        return <String, dynamic>{
          ...row,
          'content': mode == ContextMode.rp
              ? ContextCompressor.normalizeRpSummaryFormat(
                  row['content'] as String? ?? '',
                )
              : ContextCompressor.normalizeSummaryFormat(
                  row['content'] as String? ?? '',
                ),
        };
      }).toList(); // 新→舊
      _keywords = keywords.map((row) {
        final mode = ContextMode.fromStorage(row['context_mode']);
        return <String, dynamic>{
          ...row,
          'source_summary_content': mode == ContextMode.rp
              ? ContextCompressor.normalizeRpSummaryFormat(
                  row['source_summary_content'] as String? ?? '',
                )
              : ContextCompressor.normalizeSummaryFormat(
                  row['source_summary_content'] as String? ?? '',
                ),
        };
      }).toList();
      _loading = false;
    });
    _staggerCtrl.forward(from: 0.0);
  }

  void _notifyModified() {
    widget.onSummaryModified?.call();
  }

  // ═══ 操作 ═══

  Future<void> _toggleLock(Map<String, dynamic> summary) async {
    final id = summary['id'] as int;
    final currentlyLocked = (summary['locked'] as int? ?? 0) == 1;
    await DatabaseHelper.updateSummaryLockState(
      id: id,
      locked: !currentlyLocked,
    );
    _notifyModified();
    _loadData();
  }

  Future<void> _saveEdit(Map<String, dynamic> summary) async {
    final id = summary['id'] as int;
    final mode = ContextMode.fromStorage(summary['context_mode']);
    final newContent = mode == ContextMode.rp
        ? ContextCompressor.normalizeRpSummaryFormat(_editCtrl.text)
        : ContextCompressor.normalizeSummaryFormat(_editCtrl.text);
    if (newContent.isEmpty) return;
    // Let EditableText release its MediaQuery/Focus dependencies before the
    // editing subtree is replaced by Markdown. Replacing it in the same frame
    // as an active IME teardown can trip InheritedElement deactivation asserts
    // on debug devices.
    FocusManager.instance.primaryFocus?.unfocus();
    final newTokens = TokenEstimator.estimate(newContent);
    await DatabaseHelper.updateContextSummary(
      id: id,
      content: newContent,
      tokenCount: newTokens,
    );
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _notifyModified();
    setState(() => _editingSummaryId = null);
    await _loadData();
  }

  Future<void> _regenerate(Map<String, dynamic> summary) async {
    final id = summary['id'] as int;
    final original = summary['content'] as String;
    final mode = ContextMode.fromStorage(summary['context_mode']);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(
          L.pick(en: 'Regenerate Summary', zhTW: '重新生成摘要'),
          style: YanciTheme.headingMedium,
        ),
        content: Text(
          L.pick(
            en: 'This will rewrite this summary using the current model.',
            zhTW: '將用當前模型重寫此窗摘要',
          ),
          style: YanciTheme.bodyText,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              L.pick(en: 'Cancel', zhTW: '取消'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              L.pick(en: 'Confirm', zhTW: '確認'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final revised = await ContextCompressor.reviseSummaryBlock(
      id: id,
      characterId: widget.characterId,
      originalSummary: original,
      issue: mode == ContextMode.rp
          ? L.pick(
              en: 'Rewrite this dossier using the story text as the sole factual source. Preserve the complete event sequence, relationship formation, and concrete causes of important choices.',
              zhTW: '以劇情正文為唯一事實依據重寫這份卷宗，保持事件脈絡、人物關係形成過程與重要選擇具體前因的完整性。',
              zhCN: '以剧情正文为唯一事实依据重写这份卷宗，保持事件脉络、人物关系形成过程与重要选择具体前因的完整性。',
            )
          : L.pick(
              en: 'Please rewrite this summary to be more accurate and concise.',
              zhTW: '請重寫這段摘要，使其更準確簡潔。',
            ),
      contextMode: mode,
    );
    if (revised.isNotEmpty) {
      _notifyModified();
      _loadData();
    }
  }

  Future<void> _deleteSummary(Map<String, dynamic> summary) async {
    final id = summary['id'] as int;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(
          L.pick(en: 'Delete Summary', zhTW: '刪除摘要'),
          style: YanciTheme.headingMedium,
        ),
        content: Text(
          L.pick(
            en: 'This summary will be permanently deleted.',
            zhTW: '此摘要將被永久刪除。',
          ),
          style: YanciTheme.bodyText,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              L.pick(en: 'Cancel', zhTW: '取消'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              L.pick(en: 'Delete', zhTW: '刪除'),
              style: TextStyle(color: Colors.red.shade400),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await DatabaseHelper.deleteContextSummary(id);
    _notifyModified();
    _loadData();
  }

  Future<void> _showFullSummary({
    required String content,
    required String dateLabel,
  }) {
    final readable = MemorySummaryTab.formatForReading(content);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.74,
          minChildSize: 0.48,
          maxChildSize: 0.94,
          builder: (_, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: YanciTheme.surfacePanel,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(YanciTheme.radiusLg),
                ),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: YanciTheme.textSecondary.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                L.pick(en: 'Full summary', zhTW: '摘要全文'),
                                style: YanciTheme.headingMedium.copyWith(
                                  fontSize: 17,
                                ),
                              ),
                              if (dateLabel.isNotEmpty)
                                Text(
                                  dateLabel,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontFamily: 'monospace',
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: 0.5,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: L.pick(en: 'Close', zhTW: '關閉'),
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: Icon(
                            Icons.close_rounded,
                            color: YanciTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.08),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(22, 20, 22, 36),
                      child: MarkdownBody(
                        key: const ValueKey('summary-markdown-reader'),
                        data: readable,
                        selectable: true,
                        softLineBreak: true,
                        styleSheet: _summaryMarkdownStyle(
                          fontSize: 14,
                          lineHeight: 1.75,
                          spacious: true,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ═══ Build ═══

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_summaries.isEmpty && _keywords.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Text(
            L.pick(
              en: 'No summaries yet.\nThey\'ll be created as conversations grow.',
              zhTW: '還沒有摘要。\n隨著對話累積會自動生成。',
            ),
            textAlign: TextAlign.center,
            style: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }

    return AnimatedBuilder(
      animation: _staggerCtrl,
      builder: (_, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 16, 80),
          children: [
            // 視窗摘要條目流
            ..._buildSummaryCards(),
            // 關鍵詞召回區
            if (_keywords.isNotEmpty) ...[
              const SizedBox(height: 24),
              _buildKeywordSection(),
            ],
          ],
        );
      },
    );
  }

  List<Widget> _buildSummaryCards() {
    final total = _summaries.length;
    return List.generate(total, (i) {
      // Stagger: 30ms per card, max 10 cards animated
      final delay = (i < 10) ? i * 0.1 : 1.0;
      final animEnd = (delay + 0.3).clamp(0.0, 1.0);
      final opacity = _staggerCtrl.value < delay
          ? 0.0
          : ((_staggerCtrl.value - delay) / (animEnd - delay)).clamp(0.0, 1.0);

      return Opacity(
        opacity: i < 10 ? opacity : 1.0,
        child: _buildSummaryCard(_summaries[i], i),
      );
    });
  }

  Widget _buildSummaryCard(Map<String, dynamic> summary, int index) {
    final id = summary['id'] as int;
    final content = (summary['content'] as String? ?? '').trim();
    final presentation = _SummaryReadingPresentation.from(content);
    final contextMode = ContextMode.fromStorage(summary['context_mode']);
    final createdAt = summary['created_at'] as String? ?? '';
    final isLocked = (summary['locked'] as int? ?? 0) == 1;
    final isExpanded = _expandedSummaryId == id;
    final isEditing = _editingSummaryId == id;
    final needsFullReader =
        content.characters.length > 120 || '\n'.allMatches(content).length >= 4;

    // Date label
    // RP uses the device timestamp only as hidden ordering metadata. Showing
    // it as story time would create a false chronology for fictional scenes.
    final date = contextMode == ContextMode.rp
        ? null
        : DateTime.tryParse(createdAt);
    final dateStr = date != null
        ? '${date.month.toString().padLeft(2, '0')} / '
              '${date.day.toString().padLeft(2, '0')}  '
              '${date.hour.toString().padLeft(2, '0')}:'
              '${date.minute.toString().padLeft(2, '0')}'
        : '';

    final isFirst = index == 0;
    final isLast = index == _summaries.length - 1;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (_summaries.length > 1)
          Positioned(
            left: 1.5,
            top: isFirst ? 20 : 0,
            bottom: isLast ? null : 0,
            height: isLast ? 20 : null,
            child: ExcludeSemantics(
              child: Container(
                width: 1,
                color: YanciTheme.textSecondary.withValues(alpha: 0.1),
              ),
            ),
          ),
        Positioned(
          left: 0,
          top: 18,
          child: ExcludeSemantics(
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: YanciTheme.accent.withValues(alpha: 0.58),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Quiet chronology anchor. Mode and internal window IDs stay in
              // the data model but do not compete with the story on this page.
              Row(
                children: [
                  if (dateStr.isNotEmpty)
                    Text(
                      dateStr,
                      style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        letterSpacing: 0.15,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                      ),
                    ),
                  if (presentation.isCore) ...[
                    const SizedBox(width: 8),
                    Text(
                      presentation.coreLabel,
                      style: TextStyle(
                        fontSize: 9.5,
                        letterSpacing: 0.15,
                        color: YanciTheme.accent.withValues(alpha: 0.58),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (isLocked)
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 12,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.42),
                    ),
                ],
              ),
              const SizedBox(height: 9),

              // Story title + body form a single reading target.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: isEditing
                    ? null
                    : () {
                        setState(() {
                          _expandedSummaryId = isExpanded ? null : id;
                          if (!isExpanded) _editingSummaryId = null;
                        });
                      },
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: isEditing
                      ? TextField(
                          controller: _editCtrl,
                          maxLines: null,
                          style: YanciTheme.bodyText.copyWith(fontSize: 13),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: L.pick(
                              en: 'Edit summary...',
                              zhTW: '編輯摘要...',
                            ),
                            hintStyle: TextStyle(
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.3,
                              ),
                            ),
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (presentation.title != null) ...[
                                Text(
                                  presentation.title!,
                                  style: YanciTheme.bodyText.copyWith(
                                    fontSize: 15,
                                    height: 1.32,
                                    fontWeight: FontWeight.w600,
                                    color: YanciTheme.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 9),
                              ],
                              if (presentation.body.isNotEmpty)
                                _buildSummaryMarkdown(
                                  presentation.body,
                                  maxHeight: needsFullReader
                                      ? (isExpanded ? 220 : 108)
                                      : null,
                                ),
                            ],
                          ),
                        ),
                ),
              ),

              // Action bar (visible when expanded)
              if (isExpanded) ...[
                if (!isEditing && needsFullReader)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: const ValueKey('summary-full-reader-button'),
                      onPressed: () => _showFullSummary(
                        content: content,
                        dateLabel: dateStr,
                      ),
                      icon: const Icon(Icons.menu_book_outlined, size: 15),
                      label: Text(L.pick(en: 'Read all', zhTW: '閱讀全文')),
                      style: TextButton.styleFrom(
                        foregroundColor: YanciTheme.accent.withValues(
                          alpha: 0.8,
                        ),
                        minimumSize: const Size(44, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    // 編輯
                    _actionIcon(
                      icon: isEditing
                          ? Icons.check_rounded
                          : Icons.edit_outlined,
                      tooltip: L.pick(
                        en: isEditing ? 'Save' : 'Edit',
                        zhTW: isEditing ? '保存' : '編輯',
                      ),
                      onTap: () {
                        if (isEditing) {
                          _saveEdit(summary);
                        } else {
                          _editCtrl.text = content;
                          setState(() => _editingSummaryId = id);
                        }
                      },
                    ),
                    const SizedBox(width: 16),
                    // 鎖定
                    _actionIcon(
                      icon: isLocked
                          ? Icons.lock_rounded
                          : Icons.lock_open_rounded,
                      tooltip: L.pick(
                        en: isLocked ? 'Unlock' : 'Lock',
                        zhTW: isLocked ? '解鎖' : '鎖定',
                      ),
                      color: isLocked ? YanciTheme.accent : null,
                      onTap: () => _toggleLock(summary),
                    ),
                    const SizedBox(width: 16),
                    // 重新生成
                    _actionIcon(
                      icon: Icons.refresh_rounded,
                      tooltip: L.pick(en: 'Regenerate', zhTW: '重新生成'),
                      onTap: () => _regenerate(summary),
                    ),
                    const SizedBox(width: 16),
                    // 刪除
                    _actionIcon(
                      icon: Icons.delete_outline_rounded,
                      tooltip: L.pick(en: 'Delete', zhTW: '刪除'),
                      color: Colors.red.withValues(alpha: 0.6),
                      onTap: () => _deleteSummary(summary),
                    ),
                    const Spacer(),
                    // Token count
                    Text(
                      '≈${summary['token_count'] ?? 0}t',
                      style: TextStyle(
                        fontSize: 10,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryMarkdown(String content, {double? maxHeight}) {
    final body = MarkdownBody(
      key: const ValueKey('summary-markdown-preview'),
      data: MemorySummaryTab.formatForReading(content),
      selectable: false,
      softLineBreak: true,
      styleSheet: _summaryMarkdownStyle(
        fontSize: 14,
        lineHeight: 1.48,
        spacious: false,
      ),
    );
    if (maxHeight == null) return body;

    // Markdown 無 maxLines；固定高度裁切維持摘要卡密度，全文由閱讀器承接。
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white, Colors.white, Colors.transparent],
        stops: [0, 0.82, 1],
      ).createShader(bounds),
      child: ClipRect(
        child: SizedBox(
          height: maxHeight,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minHeight: 0,
            maxHeight: double.infinity,
            child: body,
          ),
        ),
      ),
    );
  }

  MarkdownStyleSheet _summaryMarkdownStyle({
    required double fontSize,
    required double lineHeight,
    required bool spacious,
  }) {
    final body = YanciTheme.bodyText.copyWith(
      fontSize: fontSize,
      height: lineHeight,
    );
    final heading = YanciTheme.bodyText.copyWith(
      fontSize: fontSize + (spacious ? 1.5 : 0.5),
      height: lineHeight,
      fontWeight: FontWeight.w600,
      color: YanciTheme.textPrimary,
    );
    return MarkdownStyleSheet(
      p: body,
      strong: body.copyWith(
        fontWeight: FontWeight.w600,
        color: YanciTheme.textPrimary,
      ),
      em: body.copyWith(fontStyle: FontStyle.italic),
      h1: heading,
      h2: heading,
      h3: heading,
      h4: heading,
      h5: heading,
      h6: heading,
      listBullet: body.copyWith(color: YanciTheme.accent),
      blockSpacing: spacious ? 13 : 7,
      listIndent: spacious ? 22 : 18,
      code: body.copyWith(
        fontFamily: 'monospace',
        fontSize: fontSize - 1,
        color: YanciTheme.accent,
        backgroundColor: YanciTheme.accent.withValues(alpha: 0.06),
      ),
      blockquote: body.copyWith(color: YanciTheme.textSecondary),
      blockquotePadding: const EdgeInsets.only(left: 12, top: 3, bottom: 3),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: YanciTheme.accent.withValues(alpha: 0.35),
            width: 2,
          ),
        ),
      ),
      codeblockPadding: const EdgeInsets.all(10),
      codeblockDecoration: BoxDecoration(
        color: YanciTheme.accent.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: YanciTheme.textSecondary.withValues(alpha: 0.12),
          ),
        ),
      ),
    );
  }

  Widget _actionIcon({
    required IconData icon,
    required String tooltip,
    Color? color,
    required VoidCallback onTap,
  }) {
    final c = color ?? YanciTheme.textSecondary.withValues(alpha: 0.45);
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      iconSize: 18,
      color: c,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      icon: Icon(icon),
    );
  }

  // ═══ 關鍵詞召回區 ═══

  Widget _buildKeywordSection() {
    // Parse all keywords from all blocks
    final chips = <_KeywordChip>[];
    // Category colors matching spider web 5-color system
    final categoryColors = [
      const Color(0xFF7C4DFF), // 紫
      const Color(0xFF26A69A), // 青
      const Color(0xFFFF7043), // 橘
      const Color(0xFF42A5F5), // 藍
      const Color(0xFFEF5350), // 紅
    ];

    for (var ki = 0; ki < _keywords.length; ki++) {
      final block = _keywords[ki];
      final kwText = (block['keywords'] as String? ?? '').trim();
      final sourceSummary = (block['source_summary_content'] as String? ?? '')
          .trim();
      if (kwText.isEmpty) continue;
      final kws = kwText
          .split(RegExp(r'[,，、]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty);
      for (final kw in kws) {
        chips.add(
          _KeywordChip(
            keyword: kw,
            sourceSummary: sourceSummary,
            color: categoryColors[ki % categoryColors.length],
            blockId: block['id'] as int,
          ),
        );
      }
    }

    if (chips.isEmpty) return const SizedBox.shrink();

    // Show first 2 rows (~10 chips) or all
    final showAll = _keywordsExpanded;
    final displayChips = showAll ? chips : chips.take(10).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.tag_rounded,
              size: 14,
              color: YanciTheme.textSecondary.withValues(alpha: 0.4),
            ),
            const SizedBox(width: 4),
            Text(
              L.pick(en: 'Keyword Recall', zhTW: '關鍵詞召回'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: YanciTheme.textSecondary.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: displayChips.map((chip) {
            final isOpen = _expandedKeywordId == chip.blockId;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _expandedKeywordId = isOpen ? null : chip.blockId;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: chip.color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: chip.color.withValues(alpha: 0.2),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      chip.keyword,
                      style: TextStyle(
                        fontSize: 11,
                        color: chip.color.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                ),
                if (isOpen && chip.sourceSummary.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.all(10),
                    width: MediaQuery.of(context).size.width - 56,
                    decoration: BoxDecoration(
                      color: YanciTheme.glassInputBg,
                      borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                      border: Border.all(
                        color: chip.color.withValues(alpha: 0.15),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      chip.sourceSummary,
                      style: YanciTheme.bodyText.copyWith(
                        fontSize: 12,
                        color: YanciTheme.textPrimary.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
              ],
            );
          }).toList(),
        ),
        if (!showAll && chips.length > 10) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => setState(() => _keywordsExpanded = true),
            child: Text(
              L.pick(
                en: 'Show all ${chips.length} keywords',
                zhTW: '展開全部 ${chips.length} 個關鍵詞',
              ),
              style: TextStyle(
                fontSize: 11,
                color: YanciTheme.accent.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
        if (showAll && chips.length > 10) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => setState(() => _keywordsExpanded = false),
            child: Text(
              L.pick(en: 'Collapse', zhTW: '收起'),
              style: TextStyle(
                fontSize: 11,
                color: YanciTheme.accent.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SummaryReadingPresentation {
  final String? title;
  final String? category;
  final String body;
  final bool isCore;

  const _SummaryReadingPresentation({
    required this.title,
    required this.category,
    required this.body,
    required this.isCore,
  });

  String get coreLabel {
    final core = L.pick(en: 'Core', zhTW: '核心', zhCN: '核心');
    return category == null ? '❖ $core' : '❖ $core · $category';
  }

  factory _SummaryReadingPresentation.from(String raw) {
    final readable = MemorySummaryTab.formatForReading(raw);
    final lines = readable.split('\n');
    final weightHeading = RegExp(
      r'^\s*#{1,6}\s*[\-—]*\s*'
      r'(?:核心|支線|支线|氛圍|氛围|觀察區|观察区|'
      r'Core|Side Story|Atmosphere|Observation)\s*[\-—]*\s*$',
      caseSensitive: false,
    );
    final coreHeading = RegExp(
      r'^\s*#{1,6}\s*[\-—]*\s*(?:核心|Core)\s*[\-—]*\s*$',
      caseSensitive: false,
    );
    final itemHeading = RegExp(r'^\s*\*\*\[([^\]]+)\]\s*(.+?)\*\*\s*$');

    final isCore = lines.any(coreHeading.hasMatch);
    String? title;
    String? category;
    var titleIndex = -1;
    var leadWeightIndex = -1;

    // A title is promoted only when it is the first real content in the row.
    // This avoids pulling a later plot item above a preceding character file.
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (weightHeading.hasMatch(line)) {
        leadWeightIndex = i;
        continue;
      }
      final match = itemHeading.firstMatch(line);
      if (match != null) {
        category = match.group(1)?.trim();
        title = match.group(2)?.trim();
        titleIndex = i;
      }
      break;
    }

    if (titleIndex >= 0) {
      lines.removeAt(titleIndex);
      if (leadWeightIndex >= 0 && leadWeightIndex < lines.length) {
        lines.removeAt(leadWeightIndex);
      }
    }

    return _SummaryReadingPresentation(
      title: title == null || title.isEmpty ? null : title,
      category: category == null || category.isEmpty ? null : category,
      body: lines.join('\n').trim(),
      isCore: isCore,
    );
  }
}

class _KeywordChip {
  final String keyword;
  final String sourceSummary;
  final Color color;
  final int blockId;

  const _KeywordChip({
    required this.keyword,
    required this.sourceSummary,
    required this.color,
    required this.blockId,
  });
}
