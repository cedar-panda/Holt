import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/chat_window_stats_service.dart';
import '../services/background_foreground_service.dart';
import '../services/locale_strings.dart';
import '../services/reasoning_effort.dart';
import '../theme/app_theme.dart';
import 'chat_model_picker.dart';

double _slowTriplePulse(double value) => math.sin(value * math.pi * 3).abs();

class ChatHeaderModelAttention extends StatefulWidget {
  const ChatHeaderModelAttention({
    super.key,
    required this.child,
    required this.accentColor,
    this.playAttention = false,
    this.onAttentionComplete,
  });

  final Widget child;
  final Color accentColor;
  final bool playAttention;
  final VoidCallback? onAttentionComplete;

  @override
  State<ChatHeaderModelAttention> createState() =>
      _ChatHeaderModelAttentionState();
}

class _ChatHeaderModelAttentionState extends State<ChatHeaderModelAttention>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 3000),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            widget.onAttentionComplete?.call();
          }
        });
    WidgetsBinding.instance.addPostFrameCallback((_) => _startIfNeeded());
  }

  @override
  void didUpdateWidget(covariant ChatHeaderModelAttention oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.playAttention && widget.playAttention) _startIfNeeded();
  }

  void _startIfNeeded() {
    if (!mounted || !widget.playAttention) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      widget.onAttentionComplete?.call();
      return;
    }
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final pulse = widget.playAttention
            ? _slowTriplePulse(_controller.value)
            : 0.0;
        return Opacity(
          opacity: 0.82 + pulse * 0.18,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: pulse <= 0
                  ? const <BoxShadow>[]
                  : <BoxShadow>[
                      BoxShadow(
                        color: widget.accentColor.withValues(
                          alpha: 0.13 * pulse,
                        ),
                        blurRadius: 10 * pulse,
                        spreadRadius: 0.8 * pulse,
                      ),
                    ],
            ),
            child: child,
          ),
        );
      },
    );
  }
}

class ChatWindowStatusButton extends StatefulWidget {
  const ChatWindowStatusButton({
    super.key,
    required this.color,
    required this.accentColor,
    required this.onPressed,
    this.playAttention = false,
    this.onAttentionComplete,
  });

  final Color color;
  final Color accentColor;
  final VoidCallback onPressed;
  final bool playAttention;
  final VoidCallback? onAttentionComplete;

  @override
  State<ChatWindowStatusButton> createState() => _ChatWindowStatusButtonState();
}

class _ChatWindowStatusButtonState extends State<ChatWindowStatusButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 3000),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            widget.onAttentionComplete?.call();
          }
        });
    WidgetsBinding.instance.addPostFrameCallback((_) => _startIfNeeded());
  }

  @override
  void didUpdateWidget(covariant ChatWindowStatusButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.playAttention && widget.playAttention) {
      _startIfNeeded();
    }
  }

  void _startIfNeeded() {
    if (!mounted || !widget.playAttention) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      widget.onAttentionComplete?.call();
      return;
    }
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: L.pick(
        en: 'Window model and activity',
        zhTW: '窗口模型與活動',
        zhCN: '窗口模型与活动',
      ),
      child: Tooltip(
        message: L.pick(
          en: 'Window model and activity',
          zhTW: '窗口模型與活動',
          zhCN: '窗口模型与活动',
        ),
        excludeFromSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: SizedBox.square(
            dimension: 44,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final pulse = widget.playAttention
                    ? _slowTriplePulse(_controller.value)
                    : 0.0;
                return Transform.scale(
                  scale: 1 + pulse * 0.055,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: pulse <= 0
                          ? const <BoxShadow>[]
                          : <BoxShadow>[
                              BoxShadow(
                                color: widget.accentColor.withValues(
                                  alpha: 0.16 * pulse,
                                ),
                                blurRadius: 11 * pulse,
                                spreadRadius: 1.5 * pulse,
                              ),
                            ],
                    ),
                    child: Icon(
                      CupertinoIcons.slider_horizontal_3,
                      size: 20,
                      color: Color.lerp(
                        widget.color,
                        widget.accentColor,
                        pulse * 0.7,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class ChatWindowStatusSheet extends StatefulWidget {
  const ChatWindowStatusSheet({
    super.key,
    required this.modelName,
    required this.liveTokenCount,
    required this.initialSnapshot,
    required this.loadSnapshot,
    required this.modelEntries,
    required this.currentModelId,
    required this.currentProvider,
    required this.initialReasoningEffort,
    this.initialThinkingEnabled = true,
    required this.onReasoningEffortChanged,
    this.onThinkingEnabledChanged = _noopThinkingChange,
    required this.onModelSelected,
    required this.onUnavailableProviderSelected,
    required this.onLongScreenshot,
    required this.longScreenshotBusy,
    required this.onEditMemory,
    required this.onArchiveMemory,
    required this.accentColor,
    this.backgroundPalette,
  });

  final String modelName;
  final int liveTokenCount;
  final ChatWindowStatsSnapshot initialSnapshot;
  final Future<ChatWindowStatsSnapshot> Function() loadSnapshot;
  final List<ChatModelPickerEntry> modelEntries;
  final String currentModelId;
  final String currentProvider;
  final String initialReasoningEffort;
  final bool initialThinkingEnabled;
  final Future<void> Function(String effort, String provider)
  onReasoningEffortChanged;
  final Future<void> Function(bool enabled, String provider)
  onThinkingEnabledChanged;
  static Future<void> _noopThinkingChange(bool _, String _) async {}
  final Future<void> Function(ChatModelPickerEntry entry) onModelSelected;
  final ValueChanged<ChatModelPickerEntry> onUnavailableProviderSelected;
  final VoidCallback onLongScreenshot;
  final bool longScreenshotBusy;
  final Future<void> Function(
    ChatWindowMemoryRecord memory,
    String content,
    String triggers,
  )
  onEditMemory;
  final Future<bool> Function(ChatWindowMemoryRecord memory) onArchiveMemory;
  final Color accentColor;
  final BackgroundForegroundPalette? backgroundPalette;

  @override
  State<ChatWindowStatusSheet> createState() => _ChatWindowStatusSheetState();
}

class _ChatWindowStatusSheetState extends State<ChatWindowStatusSheet> {
  late ChatWindowStatsSnapshot _snapshot = widget.initialSnapshot;
  late String _modelId = widget.currentModelId;
  late String _provider = widget.currentProvider;
  late String _modelName = widget.modelName;
  late String _reasoningEffort = ReasoningEffort.normalize(
    widget.initialReasoningEffort,
  );
  late bool _thinkingEnabled = widget.initialThinkingEnabled;
  bool _modelExpanded = false;

  int get _displayTokens =>
      math.max(widget.liveTokenCount, _snapshot.recordedTokens);

  String get _reasoningLabel => !_thinkingEnabled
      ? L.pick(en: 'Off', zhTW: '關', zhCN: '关')
      : switch (_reasoningEffort) {
          ReasoningEffort.low => L.pick(en: 'Low', zhTW: '低', zhCN: '低'),
          ReasoningEffort.medium => L.pick(en: 'Medium', zhTW: '中', zhCN: '中'),
          ReasoningEffort.high => L.pick(en: 'High', zhTW: '高', zhCN: '高'),
          _ => L.pick(en: 'Auto', zhTW: '自動', zhCN: '自动'),
        };

  Future<void> _changeReasoningEffort(String effort) async {
    await widget.onReasoningEffortChanged(effort, _provider);
    if (mounted) {
      setState(() => _reasoningEffort = ReasoningEffort.normalize(effort));
    }
  }

  Future<void> _changeThinkingEnabled(bool enabled) async {
    await widget.onThinkingEnabledChanged(enabled, _provider);
    if (mounted) setState(() => _thinkingEnabled = enabled);
  }

  Future<void> _selectModel(ChatModelPickerEntry entry) async {
    await widget.onModelSelected(entry);
    if (!mounted) return;
    setState(() {
      _modelId = entry.id;
      _provider = entry.provider;
      _modelName = entry.label;
    });
  }

  Future<void> _openMemories() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChatWindowMemorySheet(
        initialMemories: _snapshot.memories,
        onEditMemory: widget.onEditMemory,
        onArchiveMemory: widget.onArchiveMemory,
        accentColor: widget.accentColor,
      ),
    );
    final refreshed = await widget.loadSnapshot();
    if (mounted) setState(() => _snapshot = refreshed);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final maxSheetHeight = MediaQuery.sizeOf(context).height * 0.9;
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: BoxConstraints(maxHeight: maxSheetHeight),
        decoration: BoxDecoration(
          color: YanciTheme.themedOverlaySurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(
            top: BorderSide(color: YanciTheme.themedOverlayBorder, width: 0.6),
          ),
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 10, 20, 18 + bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 15),
              InkWell(
                key: const ValueKey('chat-window-model-toggle'),
                borderRadius: BorderRadius.circular(14),
                onTap: widget.modelEntries.isEmpty
                    ? null
                    : () => setState(() => _modelExpanded = !_modelExpanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        CupertinoIcons.slider_horizontal_3,
                        size: 18,
                        color: widget.accentColor,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _modelName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: YanciTheme.bodyText.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Container(
                        constraints: const BoxConstraints(minWidth: 32),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: widget.accentColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          _reasoningLabel,
                          style: YanciTheme.bodySmall.copyWith(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: widget.accentColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      AnimatedRotation(
                        turns: _modelExpanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 20,
                          color: widget.accentColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedSize(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: AnimatedCrossFade(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  firstCurve: Curves.easeOutCubic,
                  secondCurve: Curves.easeOutCubic,
                  sizeCurve: Curves.easeOutCubic,
                  crossFadeState: _modelExpanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  firstChild: const SizedBox(width: double.infinity),
                  secondChild: SizedBox(
                    width: double.infinity,
                    height: math
                        .min(390, 150 + widget.modelEntries.length * 68)
                        .toDouble(),
                    child: ChatModelPickerPanel(
                      entries: widget.modelEntries,
                      currentModelId: _modelId,
                      currentProvider: _provider,
                      initialReasoningEffort: _reasoningEffort,
                      initialThinkingEnabled: _thinkingEnabled,
                      accentColor: widget.accentColor,
                      backgroundPalette: widget.backgroundPalette,
                      embedded: true,
                      onReasoningEffortChanged: _changeReasoningEffort,
                      onThinkingEnabledChanged: _changeThinkingEnabled,
                      onModelSelected: _selectModel,
                      onUnavailableProviderSelected:
                          widget.onUnavailableProviderSelected,
                    ),
                  ),
                ),
              ),
              InkWell(
                key: const ValueKey('chat-window-long-screenshot'),
                borderRadius: BorderRadius.circular(14),
                onTap: widget.longScreenshotBusy
                    ? null
                    : widget.onLongScreenshot,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 28,
                        child: Center(
                          child: widget.longScreenshotBusy
                              ? SizedBox(
                                  width: 17,
                                  height: 17,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.7,
                                    color: widget.accentColor,
                                  ),
                                )
                              : Icon(
                                  Icons.panorama_vertical_outlined,
                                  size: 19,
                                  color: widget.accentColor,
                                ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          L.pick(
                            en: 'Conversation long screenshot',
                            zhTW: '對話長截圖',
                            zhCN: '对话长截图',
                          ),
                          style: YanciTheme.bodyText.copyWith(
                            fontWeight: FontWeight.w500,
                            color: widget.longScreenshotBusy
                                ? YanciTheme.textSecondary.withValues(
                                    alpha: 0.45,
                                  )
                                : YanciTheme.textPrimary,
                          ),
                        ),
                      ),
                      Icon(
                        CupertinoIcons.chevron_forward,
                        size: 14,
                        color: YanciTheme.textSecondary.withValues(
                          alpha: widget.longScreenshotBusy ? 0.24 : 0.48,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _MetricTile(
                      label: L.pick(
                        en: 'Tokens',
                        zhTW: 'Tokens',
                        zhCN: 'Tokens',
                      ),
                      value: _formatCount(_displayTokens),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricTile(
                      label: L.pick(en: 'Summaries', zhTW: '摘要', zhCN: '摘要'),
                      value: '${_snapshot.summaryCount}',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricTile(
                      label: L.pick(en: 'Worldbook', zhTW: '世界書', zhCN: '世界书'),
                      value: '${_snapshot.worldbookCount}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _MetricTile(
                      label: L.pick(
                        en: 'Cache hits',
                        zhTW: 'Cache 命中',
                        zhCN: 'Cache 命中',
                      ),
                      value: _snapshot.cacheReportingAvailable
                          ? '${_snapshot.cacheHitCount}'
                          : '—',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricTile(
                      label: L.pick(
                        en: 'Memories',
                        zhTW: '已入庫記憶',
                        zhCN: '已入库记忆',
                      ),
                      value: '${_snapshot.memories.length}',
                      onTap: _openMemories,
                      trailing: CupertinoIcons.chevron_forward,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  L.pick(
                    en: 'Older token and worldbook calls made before window tracking are not estimated.',
                    zhTW: '啟用窗口歸屬前的舊 Token 與世界書調用不作推算。',
                    zhCN: '启用窗口归属前的旧 Token 与世界书调用不作推算。',
                  ),
                  style: YanciTheme.bodySmall.copyWith(
                    fontSize: 10,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.48),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    this.onTap,
    this.trailing,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 66),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: YanciTheme.textSecondary.withValues(alpha: 0.045),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: YanciTheme.bodySmall.copyWith(
                  fontSize: 10,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.62),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      value,
                      maxLines: 1,
                      style: YanciTheme.bodyText.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (trailing != null)
                    Icon(
                      trailing,
                      size: 13,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ChatWindowMemorySheet extends StatefulWidget {
  const ChatWindowMemorySheet({
    super.key,
    required this.initialMemories,
    required this.onEditMemory,
    required this.onArchiveMemory,
    required this.accentColor,
  });

  final List<ChatWindowMemoryRecord> initialMemories;
  final Future<void> Function(
    ChatWindowMemoryRecord memory,
    String content,
    String triggers,
  )
  onEditMemory;
  final Future<bool> Function(ChatWindowMemoryRecord memory) onArchiveMemory;
  final Color accentColor;

  @override
  State<ChatWindowMemorySheet> createState() => _ChatWindowMemorySheetState();
}

class _ChatWindowMemorySheetState extends State<ChatWindowMemorySheet> {
  late final List<ChatWindowMemoryRecord> _memories =
      List<ChatWindowMemoryRecord>.of(widget.initialMemories);
  int? _busyId;

  Future<void> _edit(ChatWindowMemoryRecord memory) async {
    final content = TextEditingController(text: memory.content);
    final triggers = TextEditingController(text: memory.triggers);
    try {
      final result = await showModalBottomSheet<(String, String)>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: Material(
            color: YanciTheme.themedOverlaySurface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: content,
                    minLines: 3,
                    maxLines: 8,
                    decoration: InputDecoration(
                      labelText: L.pick(
                        en: 'Memory',
                        zhTW: '記憶內容',
                        zhCN: '记忆内容',
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: triggers,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: L.pick(
                        en: 'Recall keywords',
                        zhTW: '召回關鍵詞',
                        zhCN: '召回关键词',
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheetContext, (
                        content.text,
                        triggers.text,
                      )),
                      child: Text(L.pick(en: 'Save', zhTW: '儲存', zhCN: '保存')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      if (result == null || result.$1.trim().isEmpty || !mounted) return;
      setState(() => _busyId = memory.id);
      await widget.onEditMemory(memory, result.$1, result.$2);
      final index = _memories.indexWhere((item) => item.id == memory.id);
      if (index >= 0 && mounted) {
        setState(() {
          _memories[index] = ChatWindowMemoryRecord(
            id: memory.id,
            category: memory.category,
            content: result.$1.trim(),
            triggers: result.$2.trim(),
            isPermanent: memory.isPermanent,
            createdAt: memory.createdAt,
          );
          _busyId = null;
        });
      }
    } finally {
      content.dispose();
      triggers.dispose();
      if (mounted && _busyId == memory.id) setState(() => _busyId = null);
    }
  }

  Future<void> _archive(ChatWindowMemoryRecord memory) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          L.pick(
            en: 'Move to the dusty box?',
            zhTW: '移至積灰的小盒子？',
            zhCN: '移至积灰的小盒子？',
          ),
        ),
        content: Text(
          memory.isPermanent
              ? L.pick(
                  en: 'This is a permanent memory. It will leave active recall but can still be restored.',
                  zhTW: '這是一條永久記憶。移出活躍召回後仍可從積灰的小盒子恢復。',
                  zhCN: '这是一条永久记忆。移出活跃召回后仍可从积灰的小盒子恢复。',
                )
              : L.pick(
                  en: 'It will leave active recall and can be restored later.',
                  zhTW: '它會離開活躍召回，之後仍可恢復。',
                  zhCN: '它会离开活跃召回，之后仍可恢复。',
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              L.pick(en: 'Move', zhTW: '移出', zhCN: '移出'),
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busyId = memory.id);
    final archived = await widget.onArchiveMemory(memory);
    if (!mounted) return;
    setState(() {
      if (archived) _memories.removeWhere((item) => item.id == memory.id);
      _busyId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.76,
      minChildSize: 0.48,
      maxChildSize: 0.94,
      builder: (_, scrollController) => Material(
        color: YanciTheme.themedOverlaySurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: <Widget>[
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
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      L.pick(
                        en: 'Memories from this window',
                        zhTW: '此窗口已入庫記憶',
                        zhCN: '此窗口已入库记忆',
                      ),
                      style: YanciTheme.headingMedium.copyWith(fontSize: 17),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _memories.isEmpty
                  ? Center(
                      child: Text(
                        L.pick(
                          en: 'No confirmed memories from this window',
                          zhTW: '此窗口尚無已確認記憶',
                          zhCN: '此窗口尚无已确认记忆',
                        ),
                        style: YanciTheme.bodyText.copyWith(
                          color: YanciTheme.textSecondary,
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
                      itemCount: _memories.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final memory = _memories[index];
                        final busy = _busyId == memory.id;
                        return Container(
                          padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
                          decoration: BoxDecoration(
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.045,
                            ),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      memory.category.isEmpty
                                          ? L.pick(
                                              en: 'Memory',
                                              zhTW: '記憶',
                                              zhCN: '记忆',
                                            )
                                          : memory.category,
                                      style: YanciTheme.bodySmall.copyWith(
                                        color: widget.accentColor,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      memory.content,
                                      style: YanciTheme.bodyText,
                                    ),
                                    if (memory.triggers.trim().isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        memory.triggers,
                                        style: YanciTheme.bodySmall.copyWith(
                                          color: YanciTheme.textSecondary
                                              .withValues(alpha: 0.56),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              if (busy)
                                const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                    ),
                                  ),
                                )
                              else
                                PopupMenuButton<String>(
                                  color: YanciTheme.themedOverlaySurface,
                                  elevation: 0,
                                  shadowColor: Colors.transparent,
                                  surfaceTintColor: Colors.transparent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    side: BorderSide(
                                      color: YanciTheme.themedOverlayBorder,
                                      width: 0.6,
                                    ),
                                  ),
                                  onSelected: (value) {
                                    if (value == 'edit') {
                                      _edit(memory);
                                    } else if (value == 'archive') {
                                      _archive(memory);
                                    }
                                  },
                                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                                    PopupMenuItem<String>(
                                      value: 'edit',
                                      child: Text(
                                        L.pick(
                                          en: 'Edit',
                                          zhTW: '編輯',
                                          zhCN: '编辑',
                                        ),
                                      ),
                                    ),
                                    PopupMenuItem<String>(
                                      value: 'archive',
                                      child: Text(
                                        L.pick(
                                          en: 'Move to dusty box',
                                          zhTW: '移至積灰的小盒子',
                                          zhCN: '移至积灰的小盒子',
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
    );
  }
}

String _formatCount(int value) {
  if (value < 1000) return '$value';
  if (value < 1000000) return '${(value / 1000).toStringAsFixed(1)}k';
  return '${(value / 1000000).toStringAsFixed(1)}m';
}
