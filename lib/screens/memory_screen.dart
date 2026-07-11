import 'dart:convert';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../widgets/gradient_background.dart';
import '../memory/database.dart';

import '../services/token_estimator.dart';
import '../models/memory.dart';
import '../services/settings_manager.dart';
import '../widgets/spider_web_graph_view.dart';
import '../widgets/memory_summary_tab.dart';

/// 記憶庫頁面 — V2：扁平列表 + 浮動回收站
class MemoryScreen extends StatefulWidget {
  final String characterId;
  final int initialTab;

  const MemoryScreen({
    super.key,
    this.characterId = 'default',
    this.initialTab = 0,
  });

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen>
    with SingleTickerProviderStateMixin {
  List<Memory> _memories = [];
  List<Map<String, dynamic>> _spiderLinks = [];
  int _archivedCount = 0;
  int _totalTokens = 0;
  late String _characterId;
  bool _loading = true;
  bool _isSpiderWebEnabled = false;
  bool _isGraphView = true;

  int _tabIndex = 0; // 0=記憶庫, 1=摘要
  bool _summaryModified = false;

  // 回收站氣泡動畫
  late AnimationController _archiveAnimCtrl;

  @override
  void initState() {
    super.initState();
    _characterId = widget.characterId;
    _tabIndex = widget.initialTab == 1 ? 1 : 0;
    _archiveAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _initCharacterId();
  }

  @override
  void dispose() {
    _archiveAnimCtrl.dispose();
    super.dispose();
  }

  Future<void> _initCharacterId() async {
    if (_characterId == 'default') {
      _characterId = await UserSettings.getActiveCharacterId();
    }
    final char = await DatabaseHelper.getCharacter(_characterId);
    if (char != null) {
      _isSpiderWebEnabled = (char['is_spider_web_enabled'] as int? ?? 0) == 1;
    }
    _loadMemories();
  }

  Future<String> _bucket() async =>
      (await MemorySettings.getMemoryMode()) == 'story' ? 'story' : 'romance';

  Future<void> _loadMemories() async {
    final bucket = await _bucket();
    final permanent = await DatabaseHelper.getPermanentMemories(
      bucket,
      characterId: _characterId,
    );
    final allActive = await DatabaseHelper.getActiveMemories(
      bucket,
      characterId: _characterId,
    );
    final archived = await DatabaseHelper.getArchivedCount(
      characterId: _characterId,
    );
    final links = await DatabaseHelper.getSpiderWebLinks(_characterId);

    // 合併去重（permanent 可能跟 allActive 重疊）
    final seen = <int>{};
    final merged = <Memory>[];
    for (final m in [...permanent, ...allActive]) {
      if (m.id != null && !seen.add(m.id!)) continue;
      merged.add(m);
    }

    int tokens = 0;
    for (final m in merged) {
      tokens += TokenEstimator.estimate(
        '[#${m.id}·${m.category}] ${m.content}',
      );
    }

    if (!mounted) return;
    setState(() {
      _memories = merged;
      _spiderLinks = links;
      _archivedCount = archived;
      _totalTokens = tokens;
      _loading = false;
    });
  }

  // ═══════════════════════════════════
  // 手動寫入記憶
  // ═══════════════════════════════════

  void _showAddMemoryDialog() {
    final categoryCtrl = TextEditingController(
      text: L.pick(en: 'Important Event', zhTW: '重要事件'),
    );
    final contentCtrl = TextEditingController();
    final triggersCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          L.pick(en: 'Write a memory', zhTW: '寫入記憶'),
          style: YanciTheme.headingMedium,
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: categoryCtrl,
                style: YanciTheme.bodyText,
                decoration: InputDecoration(
                  labelText: L.pick(
                    en: 'Category',
                    zhTW: '類別（情緒/關係/偏好/約定/習慣/重要事件）',
                  ),
                  labelStyle: YanciTheme.bodySmall,
                ),
              ),
              TextField(
                controller: contentCtrl,
                maxLines: 3,
                style: YanciTheme.bodyText,
                decoration: InputDecoration(
                  labelText: L.pick(
                    en: 'Content ("I" = char, "you" = user)',
                    zhTW: '內容（「我」= 角色，「你」= 用戶）',
                  ),
                  labelStyle: YanciTheme.bodySmall,
                ),
              ),
              TextField(
                controller: triggersCtrl,
                style: YanciTheme.bodyText,
                decoration: InputDecoration(
                  labelText: L.pick(
                    en: 'Triggers (comma separated, optional)',
                    zhTW: '觸發詞（逗號分隔，可空）',
                  ),
                  labelStyle: YanciTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              L.pick(en: 'Cancel', zhTW: '取消'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              final content = contentCtrl.text.trim();
              if (content.isEmpty) return;
              await DatabaseHelper.insertMemory(
                Memory(
                  characterId: _characterId,
                  mode: await _bucket(),
                  category: categoryCtrl.text.trim().isEmpty
                      ? (L.pick(en: 'Important Event', zhTW: '重要事件'))
                      : categoryCtrl.text.trim(),
                  content: content,
                  confidence: 'high',
                  triggers: triggersCtrl.text.trim(),
                ),
              );
              if (ctx.mounted) Navigator.pop(ctx);
              _loadMemories();
            },
            child: Text(
              L.pick(en: 'Save', zhTW: '保存'),
              style: TextStyle(
                color: YanciTheme.accent,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════
  // 整理
  // ═══════════════════════════════════

  // ═══════════════════════════════════
  // Token 預算設定（單一 slider）
  // ═══════════════════════════════════

  void _showBudgetSettings() async {
    var budget = await MemorySettings.getMemBudgetTotal();

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: YanciTheme.isDark
                ? const Color(0xFF1a1520).withValues(alpha: 0.98)
                : Colors.white.withValues(alpha: 0.98),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(YanciTheme.radiusLg),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                L.pick(en: 'Memory Token Budget', zhTW: '記憶注入預算'),
                style: YanciTheme.headingMedium,
              ),
              const SizedBox(height: 4),
              Text(
                L.pick(
                  en: 'How many tokens of memory to inject per turn',
                  zhTW: '每輪注入多少 token 的記憶',
                ),
                style: YanciTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Text(
                    '${budget}t',
                    style: YanciTheme.headingMedium.copyWith(
                      color: YanciTheme.accent,
                      fontSize: 20,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    L.pick(
                      en: 'Current: ≈${_totalTokens}t used',
                      zhTW: '目前 ≈${_totalTokens}t',
                    ),
                    style: YanciTheme.bodySmall.copyWith(
                      color: _totalTokens > budget
                          ? Colors.orange
                          : YanciTheme.textSecondary,
                    ),
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: YanciTheme.accent.withValues(alpha: 0.6),
                  inactiveTrackColor: YanciTheme.accent.withValues(alpha: 0.15),
                  thumbColor: YanciTheme.accent,
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                ),
                child: Slider(
                  value: budget.toDouble(),
                  min: 300,
                  max: 4000,
                  divisions: 37,
                  onChanged: (v) {
                    final newVal = v.round();
                    setSheetState(() => budget = newVal);
                    MemorySettings.saveMemBudgetTotal(newVal);
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                L.pick(
                  en: 'Memories exceeding the budget will not be injected this turn',
                  zhTW: '超出預算的記憶不會在該輪注入',
                ),
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════
  // 記憶方案設定
  // ═══════════════════════════════════

  // ═══════════════════════════════════
  // 回收站
  // ═══════════════════════════════════

  void _showArchive() async {
    final archived = await DatabaseHelper.getArchivedMemories(
      characterId: _characterId,
    );
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.85,
          minChildSize: 0.3,
          builder: (ctx, scrollCtrl) => Container(
            decoration: BoxDecoration(
              color: YanciTheme.isDark
                  ? const Color(0xFF1a1520).withValues(alpha: 0.98)
                  : Colors.white.withValues(alpha: 0.98),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(YanciTheme.radiusLg),
              ),
            ),
            child: Column(
              children: [
                const SizedBox(height: 16),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  L.pick(en: 'Dusty Box', zhTW: '積灰小盒子'),
                  style: YanciTheme.headingMedium,
                ),
                Text(
                  '${archived.length} ${L.pick(en: 'items', zhTW: '條')}',
                  style: YanciTheme.bodySmall,
                ),
                if (archived.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      final confirm = await _confirmDelete(
                        L.pick(
                          en: 'Permanently delete all archived memories?',
                          zhTW: '永久刪除積灰小盒子裡所有記憶？',
                        ),
                      );
                      if (confirm) {
                        for (final a in List.from(archived)) {
                          await DatabaseHelper.permanentlyDelete(
                            a['id'] as int,
                            characterId: _characterId,
                          );
                        }
                        setSheetState(() => archived.clear());
                        _loadMemories();
                      }
                    },
                    child: Text(
                      L.pick(en: 'Clear all', zhTW: '一鍵清空'),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Expanded(
                  child: archived.isEmpty
                      ? Center(
                          child: Text(
                            L.pick(
                              en: 'The dusty box is empty. Nice.',
                              zhTW: '小盒子是空的，挺好。',
                            ),
                            style: YanciTheme.bodySmall.copyWith(
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: scrollCtrl,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: archived.length,
                          itemBuilder: (ctx, i) {
                            final a = archived[i];
                            // 從 content_snapshot 解析原始記憶
                            Map<String, dynamic> snapshot = {};
                            try {
                              snapshot = jsonDecode(
                                a['content_snapshot'] as String? ?? '{}',
                              );
                            } catch (_) {}
                            final category =
                                snapshot['category'] as String? ?? '';
                            final content =
                                snapshot['content'] as String? ?? '';
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: YanciTheme.isDark
                                    ? Colors.white.withValues(alpha: 0.05)
                                    : Colors.grey.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(
                                  YanciTheme.radiusSm,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.grey.withValues(
                                            alpha: 0.15,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          category,
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: YanciTheme.textSecondary,
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      if (a['reason'] != null)
                                        Text(
                                          a['reason'] as String,
                                          style: TextStyle(
                                            fontSize: 9,
                                            color: YanciTheme.textSecondary
                                                .withValues(alpha: 0.4),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    content,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: YanciTheme.textSecondary,
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      // 恢復
                                      GestureDetector(
                                        onTap: () async {
                                          final id = a['id'] as int;
                                          final restored =
                                              await DatabaseHelper.restoreFromArchive(
                                                id,
                                                characterId: _characterId,
                                              );
                                          if (restored) {
                                            archived.removeAt(i);
                                            setSheetState(() {});
                                            _loadMemories();
                                          } else {
                                            if (mounted) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    L.pick(
                                                      en: 'Original memory not found',
                                                      zhTW: '原始記憶已不存在，無法恢復',
                                                    ),
                                                  ),
                                                  backgroundColor: Colors.orange
                                                      .withValues(alpha: 0.7),
                                                  behavior:
                                                      SnackBarBehavior.floating,
                                                  duration: const Duration(
                                                    milliseconds: 1500,
                                                  ),
                                                  margin: const EdgeInsets.only(
                                                    bottom: 80,
                                                    left: 16,
                                                    right: 16,
                                                  ),
                                                ),
                                              );
                                            }
                                          }
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: YanciTheme.accent.withValues(
                                              alpha: 0.1,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.restore_rounded,
                                                size: 14,
                                                color: YanciTheme.accent
                                                    .withValues(alpha: 0.6),
                                              ),
                                              const SizedBox(width: 2),
                                              Text(
                                                L.pick(
                                                  en: 'Restore',
                                                  zhTW: '恢復',
                                                ),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: YanciTheme.accent
                                                      .withValues(alpha: 0.7),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      // 永久刪除
                                      GestureDetector(
                                        onTap: () async {
                                          final confirm = await _confirmDelete(
                                            L.pick(
                                              en: 'Permanently delete?',
                                              zhTW: '永久刪除？',
                                            ),
                                          );
                                          if (confirm) {
                                            await DatabaseHelper.permanentlyDelete(
                                              a['id'] as int,
                                              characterId: _characterId,
                                            );
                                            archived.removeAt(i);
                                            setSheetState(() {});
                                            _loadMemories();
                                          }
                                        },
                                        child: Icon(
                                          Icons.delete_outline_rounded,
                                          size: 16,
                                          color: Colors.red.withValues(
                                            alpha: 0.4,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════
  // 確認彈窗
  // ═══════════════════════════════════

  Future<bool> _confirmDelete(String message) async {
    final ctrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: YanciTheme.bodyText.copyWith(fontSize: 14),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: ctrl,
                  onChanged: (v) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: L.pick(
                      en: 'Type "DELETE" to confirm',
                      zhTW: '請輸入 DELETE 以確認',
                    ),
                    hintStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
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
                onPressed: ctrl.text.trim() == 'DELETE'
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: Text(
                  L.pick(en: 'Delete', zhTW: '刪除'),
                  style: TextStyle(
                    color: ctrl.text.trim() == 'DELETE'
                        ? Colors.red.withValues(alpha: 0.7)
                        : Colors.grey,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    return result ?? false;
  }

  // ═══════════════════════════════════
  // Build
  // ═══════════════════════════════════

  // ═══════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  // 頂部欄
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: YanciTheme.spacingSm,
                      vertical: YanciTheme.spacingXs,
                    ),
                    child: SizedBox(
                      height: 52,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 40,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: IconButton(
                                icon: Icon(
                                  Icons.arrow_back_ios_rounded,
                                  size: 20,
                                  color: YanciTheme.textPrimary,
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                onPressed: () =>
                                    Navigator.of(context).pop(_summaryModified),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  L.get('memory_title'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: YanciTheme.headingMedium,
                                ),
                                Text(
                                  '${_memories.length} ${L.pick(en: 'memories', zhTW: '條')} · ≈${_totalTokens}t',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: YanciTheme.bodySmall.copyWith(
                                    fontSize: 10,
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: 0.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_isSpiderWebEnabled)
                                IconButton(
                                  icon: Icon(
                                    _isGraphView
                                        ? Icons.list_rounded
                                        : Icons.hub_rounded,
                                    size: 18,
                                    color: YanciTheme.accent,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 36,
                                    minHeight: 36,
                                  ),
                                  tooltip: _isGraphView
                                      ? (L.pick(
                                          en: 'List View',
                                          zhTW: '切換條目記憶',
                                        ))
                                      : (L.pick(
                                          en: 'Spider Web',
                                          zhTW: '切換蛛網記憶',
                                        )),
                                  onPressed: () {
                                    setState(() {
                                      _isGraphView = !_isGraphView;
                                    });
                                  },
                                ),
                              PopupMenuButton<String>(
                                icon: Icon(
                                  Icons.tune_rounded,
                                  size: 18,
                                  color: YanciTheme.accent,
                                ),
                                padding: EdgeInsets.zero,
                                tooltip: L.pick(
                                  en: 'Settings and add',
                                  zhTW: '設定與新增',
                                ),
                                onSelected: (value) {
                                  if (value == 'budget') {
                                    _showBudgetSettings();
                                  } else if (value == 'add') {
                                    if (_isSpiderWebEnabled) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            L.pick(
                                              en: 'Manual additions are disabled while Spider Web Memory is on. Let AI nodes expand it.',
                                              zhTW:
                                                  '開啟蛛網記憶時禁止手動新增，請交由 AI 節點自行擴展',
                                            ),
                                          ),
                                          backgroundColor: Colors.red.shade400,
                                        ),
                                      );
                                    } else {
                                      _showAddMemoryDialog();
                                    }
                                  }
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'budget',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.tune_rounded,
                                          size: 18,
                                          color: YanciTheme.textPrimary,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          L.pick(
                                            en: 'Memory injection budget',
                                            zhTW: '記憶注入預算',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'add',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.add_circle_outline,
                                          size: 18,
                                          color: _isSpiderWebEnabled
                                              ? YanciTheme.textSecondary
                                              : YanciTheme.textPrimary,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          L.pick(
                                            en: 'Add memory',
                                            zhTW: '新增記憶',
                                          ),
                                          style: TextStyle(
                                            color: _isSpiderWebEnabled
                                                ? YanciTheme.textSecondary
                                                : YanciTheme.textPrimary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  // 膠囊 TabBar
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: _buildCapsuleTabBar(),
                  ),

                  // 記憶列表或蛛網
                  Expanded(
                    child: _tabIndex == 0
                        ? (_loading
                              ? const Center(child: CircularProgressIndicator())
                              : (_isSpiderWebEnabled && _isGraphView)
                              ? SpiderWebGraphView(
                                  memories: _memories
                                      .map((m) => m.toMap())
                                      .toList(),
                                  links: _spiderLinks,
                                  onNodeTapped: (memoryMap) {
                                    showDialog(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        backgroundColor:
                                            YanciTheme.surfacePanel,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                        ),
                                        title: Text(
                                          memoryMap['category'] ?? '',
                                          style: YanciTheme.headingMedium,
                                        ),
                                        content: Text(
                                          memoryMap['content'] ?? '',
                                          style: YanciTheme.bodyText,
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(ctx),
                                            child: Text(
                                              L.pick(en: 'Close', zhTW: '關閉'),
                                              style: TextStyle(
                                                color: YanciTheme.textSecondary,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                )
                              : _memories.isEmpty
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(40),
                                    child: Text(
                                      L.pick(
                                        en: 'No memories yet.\nThey\'ll grow from your conversations.',
                                        zhTW: '還沒有記憶。\n它們會從你們的對話中長出來。',
                                      ),
                                      textAlign: TextAlign.center,
                                      style: YanciTheme.bodySmall.copyWith(
                                        color: YanciTheme.textSecondary
                                            .withValues(alpha: 0.5),
                                      ),
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    4,
                                    16,
                                    80,
                                  ),
                                  itemCount: _memories.length,
                                  itemBuilder: (ctx, i) {
                                    final m = _memories[i];
                                    return _memoryTile(m, i);
                                  },
                                ))
                        : MemorySummaryTab(
                            characterId: _characterId,
                            onSummaryModified: () {
                              _summaryModified = true;
                            },
                          ),
                  ),
                ],
              ),
            ),

            // 積灰小盒子浮動按鈕
            Positioned(
              right: 20,
              bottom: 20 + MediaQuery.of(context).padding.bottom,
              child: GestureDetector(
                onTap: () async {
                  // Q 彈動效：縮 → 彈回
                  _archiveAnimCtrl.forward(from: 0.0);
                  await Future.delayed(const Duration(milliseconds: 150));
                  _showArchive();
                },
                child: AnimatedBuilder(
                  animation: _archiveAnimCtrl,
                  builder: (ctx, child) {
                    // 0→0.5: scale 1.0→0.85, 0.5→1.0: scale 0.85→1.05→1.0
                    final t = _archiveAnimCtrl.value;
                    double scale;
                    if (t < 0.4) {
                      scale = 1.0 - 0.15 * (t / 0.4);
                    } else {
                      final b = (t - 0.4) / 0.6;
                      // overshoot then settle
                      scale = 0.85 + 0.2 * Curves.elasticOut.transform(b);
                    }
                    return Transform.scale(
                      scale: scale.clamp(0.8, 1.15),
                      child: child,
                    );
                  },
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.transparent,
                      border: Border.all(
                        color: YanciTheme.textSecondary.withValues(alpha: 0.15),
                        width: 1,
                      ),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(
                          Icons.inventory_2_outlined,
                          size: 20,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.45,
                          ),
                        ),
                        if (_archivedCount > 0)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: YanciTheme.accent.withValues(alpha: 0.7),
                              ),
                              child: Center(
                                child: Text(
                                  _archivedCount > 99
                                      ? '99'
                                      : '$_archivedCount',
                                  style: const TextStyle(
                                    fontSize: 8,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════
  // 膠囊 TabBar
  // ═══════════════════════════════════

  Widget _buildCapsuleTabBar() {
    final labels = [
      L.pick(en: 'Memories', zhTW: '記憶庫'),
      L.pick(en: 'Summary', zhTW: '摘要'),
    ];
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: YanciTheme.isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(17),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = constraints.maxWidth / labels.length;
          return Stack(
            children: [
              // Sliding capsule
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                left: _tabIndex * tabWidth,
                top: 2,
                bottom: 2,
                width: tabWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: YanciTheme.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(
                      color: YanciTheme.accent.withValues(alpha: 0.2),
                      width: 0.5,
                    ),
                  ),
                ),
              ),
              // Tab labels
              Row(
                children: List.generate(labels.length, (i) {
                  final selected = _tabIndex == i;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _tabIndex = i),
                      behavior: HitTestBehavior.opaque,
                      child: Center(
                        child: Text(
                          labels[i],
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: selected
                                ? YanciTheme.accent
                                : YanciTheme.textSecondary.withValues(
                                    alpha: 0.5,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          );
        },
      ),
    );
  }

  // ═══════════════════════════════════
  // 記憶卡片
  // ═══════════════════════════════════

  Widget _memoryTile(Memory m, int index) {
    return Dismissible(
      key: ValueKey(m.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
        ),
        child: Icon(
          Icons.delete_outline,
          color: Colors.red.withValues(alpha: 0.5),
        ),
      ),
      confirmDismiss: (_) async {
        if (m.isPermanent) {
          return await _confirmDelete(
            L.pick(
              en: 'This is a permanent memory. Delete?',
              zhTW: '這是永久記憶，確定刪除？',
            ),
          );
        }
        return true;
      },
      onDismissed: (_) {
        setState(() => _memories.removeAt(index));
        DatabaseHelper.deleteMemory(
          m.id!,
          archive: true,
          characterId: _characterId,
        ).then((_) => _loadMemories());
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: YanciTheme.isDark
              ? Colors.white.withValues(alpha: 0.06)
              : YanciTheme.aiBubble.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          border: m.isPermanent
              ? Border.all(
                  color: YanciTheme.accent.withValues(alpha: 0.2),
                  width: 0.5,
                )
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: YanciTheme.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    m.category,
                    style: TextStyle(fontSize: 10, color: YanciTheme.accent),
                  ),
                ),
                if (m.isPermanent) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.push_pin_rounded,
                    size: 10,
                    color: YanciTheme.accent.withValues(alpha: 0.4),
                  ),
                ],
                const Spacer(),
                Text(
                  L.pick(en: '← swipe to delete', zhTW: '← 左滑刪除'),
                  style: TextStyle(
                    fontSize: 9,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.2),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(m.content, style: YanciTheme.bodyText.copyWith(fontSize: 13)),
            if (m.triggers.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                m.triggers
                    .split(RegExp(r'[,，、]'))
                    .map((t) => '#${t.trim()}')
                    .join(' '),
                style: TextStyle(
                  fontSize: 10,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.4),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
