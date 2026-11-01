import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Windows 寬螢幕版面。手機（Android／iOS）完全不走這裡：
/// 所有判斷先過 [DesktopLayout.isDesktop]，手機上一律原樣回傳。
abstract final class DesktopLayout {
  /// 視窗寬過這個值，側邊欄就釘在左邊；窄於它退回手機抽屜。
  static const double dockBreakpoint = 900;

  /// 釘住時側邊欄的固定寬度。
  static const double sidebarWidth = 320;

  /// 主內容（首頁、聊天）的最大寬度，避免一行字拉到一千像素。
  static const double contentMaxWidth = 760;

  /// 測試用：在非 Windows 的測試機上模擬桌面版。
  @visibleForTesting
  static bool? debugIsDesktopOverride;

  static bool get isDesktop =>
      debugIsDesktopOverride ?? (!kIsWeb && Platform.isWindows);

  static bool isDocked(BuildContext context) =>
      isDesktop && MediaQuery.sizeOf(context).width >= dockBreakpoint;
}

/// 側邊欄釘在左邊、主內容在右邊。背景鋪滿整個視窗，不跟著動。
class DesktopDockedShell extends StatelessWidget {
  final Widget background;
  final Widget sidebar;
  final Widget child;

  const DesktopDockedShell({
    super.key,
    required this.background,
    required this.sidebar,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: RepaintBoundary(child: background)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: DesktopLayout.sidebarWidth, child: sidebar),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeLeft: true,
                child: DesktopContentWidth(child: child),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 寬螢幕時把內容收在置中的一欄；手機或窄視窗原樣回傳。
class DesktopContentWidth extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const DesktopContentWidth({
    super.key,
    required this.child,
    this.maxWidth = DesktopLayout.contentMaxWidth,
  });

  @override
  Widget build(BuildContext context) {
    if (!DesktopLayout.isDesktop) return child;
    // 結構固定不變（只改寬度），拖動視窗跨過門檻時子頁面不會被重建、
    // 聊天捲動位置和輸入中的文字都留著。
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth < maxWidth
            ? constraints.maxWidth
            : maxWidth;
        return Center(
          child: SizedBox(
            width: width,
            // 頂欄這類高度不受限的地方就跟著內容高度。
            height: constraints.hasBoundedHeight ? constraints.maxHeight : null,
            child: MediaQuery(
              // 讓子頁面以為螢幕就是這一欄，依螢幕寬算尺寸的地方
              // （例如卡片比例）才不會用整個視窗去算。
              data: MediaQuery.of(context).copyWith(
                size: Size(width, MediaQuery.sizeOf(context).height),
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
