import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class ThinkingSheetCoordinator {
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  bool _open = false;

  void notify() {
    if (_open) _revision.value++;
  }

  Future<void> show({
    required BuildContext context,
    required Color titleColor,
    required WidgetBuilder contentBuilder,
  }) async {
    if (_open) return;
    _open = true;
    _revision.value++;
    await showThinkingDetailSheet(
      context: context,
      revision: _revision,
      titleColor: titleColor,
      contentBuilder: contentBuilder,
    );
    _open = false;
  }

  void dispose() => _revision.dispose();
}

Future<void> showThinkingDetailSheet({
  required BuildContext context,
  required ValueListenable<int> revision,
  required Color titleColor,
  required WidgetBuilder contentBuilder,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (_) => ThinkingDetailSheet(
      revision: revision,
      titleColor: titleColor,
      contentBuilder: contentBuilder,
    ),
  );
}

/// Thinking 的雙段式上拉面板：首次停在閱讀高度，再上拉至全屏。
class ThinkingDetailSheet extends StatelessWidget {
  const ThinkingDetailSheet({
    super.key,
    required this.revision,
    required this.titleColor,
    required this.contentBuilder,
  });

  final ValueListenable<int> revision;
  final Color titleColor;
  final WidgetBuilder contentBuilder;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      key: const ValueKey('thinking-detail-sheet'),
      initialChildSize: 0.58,
      minChildSize: 0.32,
      maxChildSize: 1.0,
      snap: true,
      snapSizes: const [0.58, 1.0],
      expand: false,
      builder: (context, scrollController) {
        return Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: YanciTheme.isDark
                  ? const Color(0xFF211F24)
                  : const Color(0xFFFDFBFC),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(32),
              ),
              border: Border.all(
                color: YanciTheme.glassBorder.withValues(alpha: 0.7),
                width: 0.6,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: YanciTheme.isDark ? 0.24 : 0.10,
                  ),
                  blurRadius: 24,
                  offset: const Offset(0, -6),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  SizedBox(
                    height: 58,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned(
                          top: 8,
                          child: Container(
                            width: 42,
                            height: 4,
                            decoration: BoxDecoration(
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.24,
                              ),
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 8,
                          bottom: 2,
                          child: IconButton(
                            key: const ValueKey('thinking-sheet-close'),
                            tooltip: L.pick(
                              en: 'Close Thinking',
                              zhTW: '關閉 Thinking',
                              zhCN: '关闭 Thinking',
                            ),
                            onPressed: () => Navigator.of(context).pop(),
                            icon: Icon(
                              Icons.close_rounded,
                              color: titleColor,
                              size: 22,
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 14,
                          child: Text(
                            'Thinking',
                            key: const ValueKey('thinking-sheet-title'),
                            style: TextStyle(
                              color: titleColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              fontFamily: YanciTheme.fontFamily,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    thickness: 0.6,
                    color: YanciTheme.glassBorder.withValues(alpha: 0.55),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<int>(
                      valueListenable: revision,
                      builder: (context, _, _) {
                        return ListView(
                          key: const ValueKey('thinking-sheet-scroll-view'),
                          controller: scrollController,
                          padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
                          children: [contentBuilder(context)],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
