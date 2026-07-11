import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../memory/database.dart';
import '../services/context_compressor.dart';
import '../services/locale_strings.dart';
import '../services/token_estimator.dart';

/// 摘要 Tab — 視窗摘要卡片流 + 關鍵詞召回區
class MemorySummaryTab extends StatefulWidget {
  final String characterId;
  final VoidCallback? onSummaryModified;

  const MemorySummaryTab({
    super.key,
    required this.characterId,
    this.onSummaryModified,
  });

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

  Future<void> _loadData() async {
    final summaries = await DatabaseHelper.getContextSummaries(
      widget.characterId,
    );
    final keywords = await DatabaseHelper.getContextKeywords(
      widget.characterId,
    );
    if (!mounted) return;
    setState(() {
      _summaries = summaries.reversed.toList(); // 新→舊
      _keywords = keywords;
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
    final newContent = _editCtrl.text.trim();
    if (newContent.isEmpty) return;
    final newTokens = TokenEstimator.estimate(newContent);
    await DatabaseHelper.updateContextSummary(
      id: id,
      content: newContent,
      tokenCount: newTokens,
    );
    _notifyModified();
    setState(() => _editingSummaryId = null);
    _loadData();
  }

  Future<void> _regenerate(Map<String, dynamic> summary) async {
    final id = summary['id'] as int;
    final original = summary['content'] as String;
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
      issue: L.pick(
        en: 'Please rewrite this summary to be more accurate and concise.',
        zhTW: '請重寫這段摘要，使其更準確簡潔。',
      ),
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
          children: [
            // 視窗摘要卡片流
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
    final createdAt = summary['created_at'] as String? ?? '';
    final isLocked = (summary['locked'] as int? ?? 0) == 1;
    final windowId = (summary['source_window_id'] as String? ?? '').trim();
    final isExpanded = _expandedSummaryId == id;
    final isEditing = _editingSummaryId == id;

    // Date label
    final date = DateTime.tryParse(createdAt);
    final dateStr = date != null
        ? '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}'
        : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: YanciTheme.glassInputBg,
        borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
        border: Border.all(
          color: isLocked
              ? YanciTheme.accent.withValues(alpha: 0.35)
              : YanciTheme.textSecondary.withValues(alpha: 0.08),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: date + badges
          Row(
            children: [
              Text(
                dateStr,
                style: TextStyle(
                  fontSize: 10,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                ),
              ),
              if (windowId.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  '#$windowId',
                  style: TextStyle(
                    fontSize: 9,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                    fontFamily: 'monospace',
                  ),
                ),
              ],
              const Spacer(),
              if (isLocked) const Text('🔒', style: TextStyle(fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),

          // Content
          GestureDetector(
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
                  : SizedBox(
                      width: double.infinity,
                      child: Text(
                        content,
                        maxLines: isExpanded ? null : 3,
                        overflow: isExpanded
                            ? TextOverflow.visible
                            : TextOverflow.ellipsis,
                        style: YanciTheme.bodyText.copyWith(fontSize: 13),
                      ),
                    ),
            ),
          ),

          // Action bar (visible when expanded)
          if (isExpanded) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                // 編輯
                _actionIcon(
                  icon: isEditing ? Icons.check_rounded : Icons.edit_outlined,
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
                  icon: isLocked ? Icons.lock_rounded : Icons.lock_open_rounded,
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
    );
  }

  Widget _actionIcon({
    required IconData icon,
    required String tooltip,
    Color? color,
    required VoidCallback onTap,
  }) {
    final c = color ?? YanciTheme.textSecondary.withValues(alpha: 0.45);
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        child: Icon(icon, size: 18, color: c),
      ),
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
