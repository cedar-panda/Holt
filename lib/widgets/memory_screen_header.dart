import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class MemoryScreenHeader extends StatelessWidget {
  final bool isSpiderWebEnabled;
  final bool isGraphView;
  final int memoryCount;
  final int totalTokens;
  final int activeLayerIndex;
  final int layerCount;
  final int memorySendLimit;
  final VoidCallback onBack;
  final VoidCallback onToggleGraph;
  final VoidCallback onSendLimitPressed;
  final VoidCallback onBudgetPressed;
  final VoidCallback onAddMemory;
  final VoidCallback onManualAddBlocked;

  const MemoryScreenHeader({
    super.key,
    required this.isSpiderWebEnabled,
    required this.isGraphView,
    required this.memoryCount,
    required this.totalTokens,
    required this.activeLayerIndex,
    required this.layerCount,
    required this.memorySendLimit,
    required this.onBack,
    required this.onToggleGraph,
    required this.onSendLimitPressed,
    required this.onBudgetPressed,
    required this.onAddMemory,
    required this.onManualAddBlocked,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
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
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  onPressed: onBack,
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
                    '$memoryCount ${L.pick(en: 'memories', zhTW: '條', zhCN: '条')} · ≈${totalTokens}t${layerCount > 0 && isGraphView ? ' · ${activeLayerIndex + 1}/$layerCount' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: YanciTheme.bodySmall.copyWith(
                      fontSize: 10,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isSpiderWebEnabled)
                  IconButton(
                    icon: Icon(
                      isGraphView ? Icons.list_rounded : Icons.hub_rounded,
                      size: 18,
                      color: YanciTheme.accent,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    tooltip: isGraphView
                        ? L.pick(en: 'List View', zhTW: '切換條目記憶')
                        : L.pick(en: 'Spider Web', zhTW: '切換蛛網記憶'),
                    onPressed: onToggleGraph,
                  ),
                IconButton(
                  onPressed: onSendLimitPressed,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  tooltip: L.pick(
                    en: 'Chat memory send limit: $memorySendLimit',
                    zhTW: '對話記憶發送限制：$memorySendLimit 條',
                    zhCN: '对话记忆发送限制：$memorySendLimit 条',
                  ),
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(
                        Icons.outbox_rounded,
                        size: 18,
                        color: YanciTheme.accent,
                      ),
                      Positioned(
                        right: -9,
                        top: -9,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 18),
                          height: 18,
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: YanciTheme.accent,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            '$memorySendLimit',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.tune_rounded,
                    size: 18,
                    color: YanciTheme.accent,
                  ),
                  padding: EdgeInsets.zero,
                  tooltip: L.pick(en: 'Settings and add', zhTW: '設定與新增'),
                  onSelected: (value) {
                    if (value == 'budget') {
                      onBudgetPressed();
                    } else if (value == 'add') {
                      if (isSpiderWebEnabled) {
                        onManualAddBlocked();
                      } else {
                        onAddMemory();
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
                            color: isSpiderWebEnabled
                                ? YanciTheme.textSecondary
                                : YanciTheme.textPrimary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            L.pick(en: 'Add memory', zhTW: '新增記憶'),
                            style: TextStyle(
                              color: isSpiderWebEnabled
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
    );
  }
}
