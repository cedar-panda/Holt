import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../widgets/gradient_background.dart';
import '../memory/database.dart';

/// 收藏消息頁面 — 按角色顯示收藏的消息
class SavedMessagesScreen extends StatefulWidget {
  final String characterId;
  final String characterName;

  const SavedMessagesScreen({
    super.key,
    this.characterId = 'default',
    this.characterName = '',
  });

  @override
  State<SavedMessagesScreen> createState() => _SavedMessagesScreenState();
}

class _SavedMessagesScreenState extends State<SavedMessagesScreen> {
  List<Map<String, dynamic>> _messages = [];
  bool _isLoading = true;
  final TextEditingController _searchCtrl = TextEditingController();

  /// 展開全文的收藏 id（默認折疊，長對話不再撐爆列表）
  final Set<int> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final query = _searchCtrl.text.trim();
      final msgs = query.isEmpty
          ? await DatabaseHelper.getSavedMessages(
              characterId: widget.characterId,
            )
          : await DatabaseHelper.searchSavedMessages(
              query,
              characterId: widget.characterId,
            );
      setState(() {
        _messages = msgs;
        _isLoading = false;
      });
    } catch (_) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _delete(int id) async {
    await DatabaseHelper.deleteSavedMessage(id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              // 頂部
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: YanciTheme.spacingSm,
                  vertical: YanciTheme.spacingXs,
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.arrow_back_ios_rounded,
                        size: 20,
                        color: YanciTheme.textPrimary,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Text(
                        widget.characterName.isNotEmpty
                            ? '${widget.characterName} · ${L.get('char_tab_saved')}'
                            : L.get('char_tab_saved'),
                        textAlign: TextAlign.center,
                        style: YanciTheme.headingMedium,
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),

              // 搜索框
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: YanciTheme.spacingMd,
                ),
                child: Container(
                  height: 38,
                  decoration: BoxDecoration(
                    color: YanciTheme.isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.grey.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TextField(
                    controller: _searchCtrl,
                    style: YanciTheme.bodyText.copyWith(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: L.pick(
                        en: 'Search saved… (keyword or date like 7/3)',
                        zhTW: '搜索收藏……（關鍵詞或日期如 7/3）',
                      ),
                      hintStyle: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary.withValues(alpha: 0.35),
                        fontSize: 12,
                      ),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        size: 18,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.4),
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 9),
                    ),
                    onChanged: (_) => _load(),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // 內容
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.star_outline_rounded,
                              size: 48,
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.25,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              L.get('saved_empty'),
                              style: YanciTheme.bodySmall.copyWith(
                                color: YanciTheme.textSecondary.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(
                          horizontal: YanciTheme.spacingMd,
                          vertical: YanciTheme.spacingSm,
                        ),
                        itemCount: _messages.length,
                        itemBuilder: (ctx, i) => _buildItem(_messages[i]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 收藏內容渲染 markdown（跟聊天泡泡一致的排版）。
  /// 折疊態改用固定高度裁切——markdown 沒法按行數截，用限高保留「約 6 行」觀感。
  Widget _buildSavedContent(String content, {required bool collapsed}) {
    final md = MarkdownBody(
      data: content,
      selectable: false,
      softLineBreak: true,
      styleSheet: MarkdownStyleSheet(
        p: YanciTheme.bodyText.copyWith(fontSize: 13, height: 1.5),
        strong: YanciTheme.bodyText.copyWith(
          fontSize: 13,
          height: 1.5,
          fontWeight: FontWeight.w600,
        ),
        em: YanciTheme.bodyText.copyWith(
          fontSize: 13,
          height: 1.5,
          fontStyle: FontStyle.italic,
        ),
        listBullet: YanciTheme.bodyText.copyWith(fontSize: 13, height: 1.5),
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: YanciTheme.accent,
          backgroundColor: YanciTheme.isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04),
        ),
      ),
    );
    if (!collapsed) return md;
    // 固定高度 + 裁切上緣；OverflowBox 允許子超高，不觸發溢出警告。
    return ClipRect(
      child: SizedBox(
        height: 120,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minHeight: 0,
          maxHeight: double.infinity,
          child: md,
        ),
      ),
    );
  }

  Widget _buildItem(Map<String, dynamic> msg) {
    final id = msg['id'] as int;
    final content = msg['content'] as String? ?? '';
    final createdAt = msg['created_at'] as String? ?? '';
    String dateStr = '';
    if (createdAt.isNotEmpty) {
      try {
        final dt = DateTime.parse(createdAt);
        dateStr =
            '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      } catch (_) {}
    }

    final isExpanded = _expanded.contains(id);
    // 粗判是否需要折疊（超過 ~6 行的量）
    final needsCollapse =
        content.length > 150 || '\n'.allMatches(content).length >= 6;

    return Dismissible(
      key: ValueKey(id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Icon(
          Icons.delete_outline,
          color: YanciTheme.textSecondary.withValues(alpha: 0.5),
        ),
      ),
      // 防誤刪：長卡片滾動時很容易誤觸水平滑動，刪除前必須確認
      confirmDismiss: (_) async {
        HapticFeedback.mediumImpact();
        return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
                ),
                backgroundColor: YanciTheme.isDark
                    ? const Color(0xFF1E1E2E)
                    : Colors.white,
                title: Text(
                  L.pick(en: 'Remove from saved?', zhTW: '取消收藏？'),
                  style: TextStyle(
                    color: YanciTheme.textPrimary,
                    fontSize: 16,
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(
                      L.pick(en: 'Keep', zhTW: '留著'),
                      style: TextStyle(color: YanciTheme.textSecondary),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(
                      L.pick(en: 'Remove', zhTW: '取消收藏'),
                      style: TextStyle(color: YanciTheme.accent),
                    ),
                  ),
                ],
              ),
            ) ??
            false;
      },
      onDismissed: (_) => _delete(id),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: YanciTheme.isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.white.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: YanciTheme.isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.white.withValues(alpha: 0.7),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSavedContent(
              content,
              collapsed: needsCollapse && !isExpanded,
            ),
            if (needsCollapse)
              GestureDetector(
                onTap: () => setState(() {
                  isExpanded ? _expanded.remove(id) : _expanded.add(id);
                }),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    isExpanded
                        ? (L.pick(en: 'Collapse', zhTW: '收起'))
                        : (L.pick(en: 'Show more', zhTW: '展開全文')),
                    style: TextStyle(
                      fontSize: 11,
                      color: YanciTheme.accent.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  dateStr,
                  style: TextStyle(
                    fontSize: 10,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.4),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    Clipboard.setData(ClipboardData(text: content));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(L.get('chat_copied')),
                        backgroundColor: YanciTheme.accent,
                        behavior: SnackBarBehavior.floating,
                        duration: const Duration(milliseconds: 800),
                        margin: const EdgeInsets.only(
                          bottom: 80,
                          left: 16,
                          right: 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    );
                  },
                  child: Icon(
                    Icons.copy_rounded,
                    size: 14,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.3),
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
