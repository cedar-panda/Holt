import 'package:flutter/material.dart';

import '../models/memory.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class MemoryListTile extends StatelessWidget {
  final Memory memory;
  final bool showDivider;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onToggleSelection;
  final Future<void> Function()? onDeletePressed;

  const MemoryListTile({
    super.key,
    required this.memory,
    required this.showDivider,
    required this.selected,
    required this.selectionMode,
    required this.onToggleSelection,
    required this.onDeletePressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _SwipeDeleteReveal(
          key: ValueKey(memory.id),
          enabled: !selectionMode,
          onDeletePressed: onDeletePressed,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: onToggleSelection,
            onTap: selectionMode ? onToggleSelection : null,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: selected
                    ? YanciTheme.accent.withValues(alpha: 0.09)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                border: selected
                    ? Border.all(
                        color: YanciTheme.accent.withValues(alpha: 0.48),
                        width: 0.9,
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
                          memory.category,
                          style: TextStyle(
                            fontSize: 10,
                            color: YanciTheme.accent,
                          ),
                        ),
                      ),
                      if (memory.isPermanent) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.push_pin_rounded,
                          size: 10,
                          color: YanciTheme.accent.withValues(alpha: 0.4),
                        ),
                      ],
                      const Spacer(),
                      if (selectionMode)
                        Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 20,
                          color: selected
                              ? YanciTheme.accent
                              : YanciTheme.textSecondary,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    memory.content,
                    style: YanciTheme.bodyText.copyWith(fontSize: 13),
                  ),
                  if (memory.triggers.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      memory.triggers
                          .split(RegExp(r'[,，、]'))
                          .map((trigger) => '#${trigger.trim()}')
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
          ),
        ),
        if (showDivider) const _MemoryFadeDivider(),
      ],
    );
  }
}

class _MemoryFadeDivider extends StatelessWidget {
  const _MemoryFadeDivider();

  @override
  Widget build(BuildContext context) {
    final line = YanciTheme.textSecondary.withValues(alpha: 0.16);
    return ExcludeSemantics(
      child: SizedBox(
        height: 10,
        child: Center(
          child: Container(
            height: 0.7,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.transparent, line, line, Colors.transparent],
                stops: const [0, 0.46, 0.54, 1],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwipeDeleteReveal extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final Future<void> Function()? onDeletePressed;

  const _SwipeDeleteReveal({
    super.key,
    required this.child,
    required this.enabled,
    required this.onDeletePressed,
  });

  @override
  State<_SwipeDeleteReveal> createState() => _SwipeDeleteRevealState();
}

class _SwipeDeleteRevealState extends State<_SwipeDeleteReveal> {
  static const double _actionWidth = 88;
  double _offset = 0;
  bool _dragging = false;

  @override
  void didUpdateWidget(_SwipeDeleteReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _offset != 0) _close();
  }

  void _close() {
    if (!mounted) return;
    setState(() {
      _dragging = false;
      _offset = 0;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!widget.enabled) return;
    setState(() {
      _dragging = true;
      _offset = (_offset + (details.primaryDelta ?? 0)).clamp(
        -_actionWidth,
        0.0,
      );
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (!widget.enabled) return;
    final velocity = details.primaryVelocity ?? 0;
    final reveal = velocity < -240 || (velocity <= 240 && _offset < -36);
    setState(() {
      _dragging = false;
      _offset = reveal ? -_actionWidth : 0;
    });
  }

  Future<void> _delete() async {
    _close();
    await widget.onDeletePressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final revealWidth = (-_offset).clamp(0.0, _actionWidth);
    return ClipRRect(
      borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
      child: Stack(
        children: [
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            width: revealWidth,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerRight,
                minWidth: _actionWidth,
                maxWidth: _actionWidth,
                child: SizedBox(
                  width: _actionWidth,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: widget.onDeletePressed == null ? null : _delete,
                      child: Semantics(
                        button: true,
                        label: L.pick(
                          en: 'Delete memory',
                          zhTW: '刪除記憶',
                          zhCN: '删除记忆',
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.delete_outline_rounded,
                              color: Colors.red.shade400,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              L.pick(en: 'Delete', zhTW: '刪除', zhCN: '删除'),
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.red.shade400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            child: AnimatedContainer(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(_offset, 0, 0),
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}
