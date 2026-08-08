import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class LongScreenshotMessageOption {
  final String speaker;
  final String preview;
  final String time;

  const LongScreenshotMessageOption({
    required this.speaker,
    required this.preview,
    required this.time,
  });
}

class LongScreenshotOptions {
  final int startIndex;
  final int endIndex;
  final bool expandThinking;
  final bool includeMemory;
  final bool includeEmotion;

  const LongScreenshotOptions({
    required this.startIndex,
    required this.endIndex,
    required this.expandThinking,
    required this.includeMemory,
    required this.includeEmotion,
  });

  int get messageCount => endIndex - startIndex + 1;
}

Future<LongScreenshotOptions?> showLongScreenshotOptionsSheet({
  required BuildContext context,
  required List<LongScreenshotMessageOption> messages,
  int maxSelectionCount = 50,
}) {
  return showModalBottomSheet<LongScreenshotOptions>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (_) => LongScreenshotOptionsSheet(
      messages: messages,
      maxSelectionCount: maxSelectionCount,
    ),
  );
}

class LongScreenshotOptionsSheet extends StatefulWidget {
  final List<LongScreenshotMessageOption> messages;
  final int maxSelectionCount;

  const LongScreenshotOptionsSheet({
    super.key,
    required this.messages,
    this.maxSelectionCount = 50,
  }) : assert(maxSelectionCount > 0);

  @override
  State<LongScreenshotOptionsSheet> createState() =>
      _LongScreenshotOptionsSheetState();
}

class _LongScreenshotOptionsSheetState
    extends State<LongScreenshotOptionsSheet> {
  static const double _rowExtent = 66;

  late int _startIndex;
  late int _endIndex;
  late bool _editingStart;
  bool _expandThinking = false;
  bool _includeMemory = false;
  bool _includeEmotion = false;
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _endIndex = widget.messages.length - 1;
    _startIndex = math.max(
      0,
      widget.messages.length - widget.maxSelectionCount,
    );
    _editingStart = true;
    _scrollController = ScrollController(
      initialScrollOffset: _startIndex * _rowExtent,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _selectMessage(int index) {
    setState(() {
      if (_editingStart) {
        _startIndex = index;
        if (_endIndex < _startIndex) _endIndex = _startIndex;
        if (_endIndex - _startIndex + 1 > widget.maxSelectionCount) {
          _endIndex = math.min(
            widget.messages.length - 1,
            _startIndex + widget.maxSelectionCount - 1,
          );
        }
        _editingStart = false;
      } else {
        _endIndex = index;
        if (_startIndex > _endIndex) _startIndex = _endIndex;
        if (_endIndex - _startIndex + 1 > widget.maxSelectionCount) {
          _startIndex = math.max(0, _endIndex - widget.maxSelectionCount + 1);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedCount = _endIndex - _startIndex + 1;
    return FractionallySizedBox(
      heightFactor: 0.88,
      child: Material(
        color: YanciTheme.surfacePanel,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(YanciTheme.radiusLg),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            const SizedBox(height: 9),
            Container(
              width: 34,
              height: 3,
              decoration: BoxDecoration(
                color: YanciTheme.textSecondary.withValues(alpha: 0.24),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 10, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      L.pick(en: 'Long screenshot', zhTW: '長截圖'),
                      style: YanciTheme.headingMedium,
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: L.pick(en: 'Close', zhTW: '關閉'),
                    child: IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                      color: YanciTheme.textSecondary,
                      tooltip: L.pick(en: 'Close', zhTW: '關閉'),
                    ),
                  ),
                ],
              ),
            ),
            CheckboxListTile(
              key: const ValueKey('longshot-thinking-toggle'),
              value: _expandThinking,
              onChanged: (value) =>
                  setState(() => _expandThinking = value ?? false),
              controlAffinity: ListTileControlAffinity.trailing,
              activeColor: YanciTheme.accent,
              contentPadding: const EdgeInsets.symmetric(horizontal: 18),
              title: Text(
                L.pick(en: 'Expand Thinking', zhTW: '展開思考'),
                style: YanciTheme.bodyText.copyWith(
                  fontSize: 14,
                  color: YanciTheme.textPrimary,
                ),
              ),
              subtitle: Text(
                L.pick(
                  en: 'Show the full thinking text in the image.',
                  zhTW: '在圖片中顯示完整思考內容。',
                ),
                style: YanciTheme.bodySmall.copyWith(fontSize: 11.5),
              ),
            ),
            CheckboxListTile(
              key: const ValueKey('longshot-memory-toggle'),
              value: _includeMemory,
              onChanged: (value) =>
                  setState(() => _includeMemory = value ?? false),
              controlAffinity: ListTileControlAffinity.trailing,
              activeColor: YanciTheme.accent,
              contentPadding: const EdgeInsets.symmetric(horizontal: 18),
              title: Text(
                L.pick(en: 'Include memory', zhTW: '包含記憶'),
                style: YanciTheme.bodyText.copyWith(
                  fontSize: 14,
                  color: YanciTheme.textPrimary,
                ),
              ),
              subtitle: Text(
                L.pick(
                  en: 'Show memory reads and operations. Off by default for privacy.',
                  zhTW: '顯示記憶讀取與操作記錄；為保護隱私，預設關閉。',
                ),
                style: YanciTheme.bodySmall.copyWith(fontSize: 11.5),
              ),
            ),
            CheckboxListTile(
              key: const ValueKey('longshot-emotion-toggle'),
              value: _includeEmotion,
              onChanged: (value) =>
                  setState(() => _includeEmotion = value ?? false),
              controlAffinity: ListTileControlAffinity.trailing,
              activeColor: YanciTheme.accent,
              contentPadding: const EdgeInsets.symmetric(horizontal: 18),
              title: Text(
                L.pick(en: 'Include emotion', zhTW: '包含情緒'),
                style: YanciTheme.bodyText.copyWith(
                  fontSize: 14,
                  color: YanciTheme.textPrimary,
                ),
              ),
              subtitle: Text(
                L.pick(
                  en: 'Show emotion coordinates and emotion logs.',
                  zhTW: '顯示情緒座標與情緒記錄。',
                ),
                style: YanciTheme.bodySmall.copyWith(fontSize: 11.5),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          L.pick(
                            en: '$selectedCount selected · up to ${widget.maxSelectionCount}',
                            zhTW:
                                '已選 $selectedCount 條 · 最多 ${widget.maxSelectionCount} 條',
                          ),
                          key: const ValueKey('longshot-range-summary'),
                          style: YanciTheme.bodySmall.copyWith(
                            color: YanciTheme.textPrimary.withValues(
                              alpha: 0.72,
                            ),
                          ),
                        ),
                      ),
                      Text(
                        L.pick(
                          en: 'Choose the start, then the end',
                          zhTW: '先選起點，再選終點',
                        ),
                        style: YanciTheme.bodySmall.copyWith(fontSize: 10.5),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _BoundaryButton(
                          key: const ValueKey('longshot-start-selector'),
                          active: _editingStart,
                          label: L.pick(en: 'Start', zhTW: '起點'),
                          value: '${_startIndex + 1}',
                          onTap: () => setState(() => _editingStart = true),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _BoundaryButton(
                          key: const ValueKey('longshot-end-selector'),
                          active: !_editingStart,
                          label: L.pick(en: 'End', zhTW: '終點'),
                          value: '${_endIndex + 1}',
                          onTap: () => setState(() => _editingStart = false),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              color: YanciTheme.textSecondary.withValues(alpha: 0.10),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemExtent: _rowExtent,
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: widget.messages.length,
                itemBuilder: (context, index) {
                  final message = widget.messages[index];
                  final selected = index >= _startIndex && index <= _endIndex;
                  final isStart = index == _startIndex;
                  final isEnd = index == _endIndex;
                  return Semantics(
                    selected: selected,
                    button: true,
                    label: L.pick(
                      en: '${message.speaker}, message ${index + 1}, ${message.preview}',
                      zhTW:
                          '${message.speaker}，第 ${index + 1} 條，${message.preview}',
                    ),
                    child: InkWell(
                      key: ValueKey<String>('longshot-message-$index'),
                      onTap: () => _selectMessage(index),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 12),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: selected
                              ? YanciTheme.accent.withValues(alpha: 0.075)
                              : Colors.transparent,
                          border: Border(
                            left: BorderSide(
                              color: selected
                                  ? YanciTheme.accent.withValues(alpha: 0.58)
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 42,
                              child: Text(
                                message.time,
                                style: YanciTheme.bodySmall.copyWith(
                                  fontSize: 10.5,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    message.speaker,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: YanciTheme.bodySmall.copyWith(
                                      fontSize: 11,
                                      color: YanciTheme.textPrimary.withValues(
                                        alpha: 0.66,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    message.preview,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: YanciTheme.bodyText.copyWith(
                                      fontSize: 12.5,
                                      color: YanciTheme.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (isStart || isEnd)
                              Container(
                                margin: const EdgeInsets.only(left: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: YanciTheme.accent.withValues(
                                    alpha: 0.14,
                                  ),
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: Text(
                                  isStart && isEnd
                                      ? L.pick(en: 'Start · End', zhTW: '起 · 終')
                                      : isStart
                                      ? L.pick(en: 'Start', zhTW: '起')
                                      : L.pick(en: 'End', zhTW: '終'),
                                  style: YanciTheme.bodySmall.copyWith(
                                    fontSize: 9.5,
                                    color: YanciTheme.accent,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(L.pick(en: 'Cancel', zhTW: '取消')),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      key: const ValueKey('longshot-confirm'),
                      onPressed: () => Navigator.of(context).pop(
                        LongScreenshotOptions(
                          startIndex: _startIndex,
                          endIndex: _endIndex,
                          expandThinking: _expandThinking,
                          includeMemory: _includeMemory,
                          includeEmotion: _includeEmotion,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: YanciTheme.accent,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(118, 46),
                      ),
                      icon: const Icon(
                        Icons.panorama_vertical_outlined,
                        size: 18,
                      ),
                      label: Text(L.pick(en: 'Capture', zhTW: '開始截圖')),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BoundaryButton extends StatelessWidget {
  final bool active;
  final String label;
  final String value;
  final VoidCallback onTap;

  const _BoundaryButton({
    super.key,
    required this.active,
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: '$label $value',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: active
                ? YanciTheme.accent.withValues(alpha: 0.11)
                : YanciTheme.glassInputBg,
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
            border: Border.all(
              color: active
                  ? YanciTheme.accent.withValues(alpha: 0.55)
                  : YanciTheme.textSecondary.withValues(alpha: 0.12),
            ),
          ),
          child: Row(
            children: [
              Text(
                label,
                style: YanciTheme.bodySmall.copyWith(
                  color: active ? YanciTheme.accent : YanciTheme.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                value,
                style: YanciTheme.bodyText.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: YanciTheme.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
