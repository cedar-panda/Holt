import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/locale_strings.dart';
import '../../theme/app_theme.dart';
import '../coin_amount_text.dart';
import 'holt_sidebar_shell.dart';
import 'sidebar_accordion.dart';
import 'sidebar_behavior_settings.dart';
import 'sidebar_feature_settings.dart';
import 'sidebar_model_settings.dart';
import 'sidebar_visual_tokens.dart';

// UI_SLOT: sidebar_header
// UI_SLOT: sidebar_models_section
// UI_SLOT: sidebar_behavior_section
// UI_SLOT: sidebar_usage_section

class HoltControlSidebar extends StatefulWidget {
  const HoltControlSidebar({
    super.key,
    this.guideVisible = false,
    this.onGuideTap,
    this.shellEconomyVisible = false,
    this.shellBalance = 0,
    this.onShopTap,
    this.onBackpackTap,
  });

  final bool guideVisible;
  final VoidCallback? onGuideTap;
  final bool shellEconomyVisible;
  final int shellBalance;
  final VoidCallback? onShopTap;
  final VoidCallback? onBackpackTap;

  @override
  State<HoltControlSidebar> createState() => _HoltControlSidebarState();
}

class _HoltControlSidebarState extends State<HoltControlSidebar> {
  late final SidebarAccordionCoordinator _coordinator;
  late final ScrollController _scrollController;
  bool _modelsExpanded = true;
  bool _behaviorExpanded = false;
  bool _featuresExpanded = false;
  bool _hasMoreBelow = false;

  @override
  void initState() {
    super.initState();
    _coordinator = SidebarAccordionCoordinator();
    _scrollController = ScrollController()..addListener(_refreshScrollHint);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshScrollHint());
  }

  @override
  void dispose() {
    _coordinator.dispose();
    _scrollController
      ..removeListener(_refreshScrollHint)
      ..dispose();
    super.dispose();
  }

  void _refreshScrollHint() {
    if (!mounted || !_scrollController.hasClients) return;
    final hasMore = _scrollController.position.extentAfter > 18;
    if (hasMore != _hasMoreBelow) setState(() => _hasMoreBelow = hasMore);
  }

  void _scrollFurther() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = (position.pixels + position.viewportDimension * 0.72).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      _scrollController.jumpTo(target);
    } else {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  // ── section title: text only, without underline/divider decoration ──

  Widget _sectionTitle(
    String label, {
    required bool expanded,
    required VoidCallback onTap,
  }) {
    final accent = SidebarVisualTokens.accent;
    return Semantics(
      button: true,
      expanded: expanded,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 6),
          child: Row(
            children: [
              // accent dot
              Container(
                width: 3.5,
                height: 3.5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: 0.72),
                ),
              ),
              const SizedBox(width: 8),

              // label
              Text(
                label,
                style: YanciTheme.bodySmall.copyWith(
                  color: accent.withValues(alpha: 0.9),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
              const Spacer(),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 16,
                  color: accent.withValues(alpha: 0.68),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _collapsibleGroup({required bool expanded, required Widget child}) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: expanded ? 1 : 0),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: value,
          child: Opacity(
            opacity: value,
            child: IgnorePointer(ignoring: !expanded, child: child),
          ),
        ),
      ),
    );
  }

  Widget _usageEntry() {
    final textSecondary = SidebarVisualTokens.secondary;
    final accent = SidebarVisualTokens.accent;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 3, 4, 8),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: Icon(
              Icons.bar_chart_rounded,
              size: 18,
              color: accent.withValues(alpha: 0.82),
            ),
            title: Text(
              L.pick(en: 'Usage', zhTW: '用量', zhCN: '用量'),
              style: YanciTheme.bodyText.copyWith(
                color: textSecondary,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            trailing: Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: textSecondary.withValues(alpha: 0.62),
            ),
            onTap: () {
              HapticFeedback.lightImpact();
              HoltSidebarShell.of(context).close();
              Navigator.of(context).pushNamed('/usage');
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = SidebarVisualTokens.accent;

    return SafeArea(
      // only pad top — bottom handled by ListView padding
      bottom: false,
      child: SidebarAccordionScope(
        coordinator: _coordinator,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // UI_SLOT: sidebar_header
            if (widget.guideVisible || widget.shellEconomyVisible)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    if (widget.guideVisible)
                      // UI_SLOT: sidebar_guide_entry
                      Tooltip(
                        message: L.pick(
                          en: 'Open Guide',
                          zhTW: '打開嚮導',
                          zhCN: '打开向导',
                        ),
                        child: Semantics(
                          button: true,
                          label: L.pick(
                            en: 'Open Guide',
                            zhTW: '打開嚮導',
                            zhCN: '打开向导',
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              HapticFeedback.lightImpact();
                              HoltSidebarShell.of(context).close();
                              widget.onGuideTap?.call();
                            },
                            child: SizedBox(
                              height: 48,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      width: 30,
                                      height: 34,
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Icon(
                                            Icons.person_outline_rounded,
                                            size: 23,
                                            color: accent,
                                            shadows: [
                                              Shadow(
                                                color: accent.withValues(
                                                  alpha: 0.4,
                                                ),
                                                blurRadius: 8,
                                              ),
                                            ],
                                          ),
                                          Positioned(
                                            right: 0,
                                            top: 0,
                                            child: Text(
                                              '?',
                                              style: TextStyle(
                                                color: accent,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                fontFamily:
                                                    YanciTheme.fontFamily,
                                                decoration: TextDecoration.none,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    Text(
                                      L.pick(
                                        en: 'Guide',
                                        zhTW: '嚮導',
                                        zhCN: '向导',
                                      ),
                                      style: YanciTheme.bodySmall.copyWith(
                                        color: accent,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        shadows: [
                                          Shadow(
                                            color: accent.withValues(
                                              alpha: 0.28,
                                            ),
                                            blurRadius: 7,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    const Spacer(),
                    if (widget.shellEconomyVisible) ...[
                      // UI_SLOT: sidebar_shell_balance_shop
                      Tooltip(
                        message: L.pick(
                          en: 'Open Shell Shop',
                          zhTW: '點擊餘額進入貝殼商店',
                          zhCN: '点击余额进入贝壳商店',
                        ),
                        child: Semantics(
                          button: true,
                          label: L.pick(
                            en: 'Shell balance ${widget.shellBalance}; open shop',
                            zhTW: '貝殼餘額 ${widget.shellBalance}；進入商店',
                            zhCN: '贝壳余额 ${widget.shellBalance}；进入商店',
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: widget.onShopTap,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 44),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Image.asset(
                                      'assets/images/shell_coin.png',
                                      width: 19,
                                      height: 19,
                                      filterQuality: FilterQuality.none,
                                    ),
                                    const SizedBox(width: 5),
                                    CoinAmountText(widget.shellBalance),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // UI_SLOT: sidebar_shell_backpack
                      IconButton(
                        tooltip: L.pick(en: 'Backpack', zhTW: '背包', zhCN: '背包'),
                        onPressed: widget.onBackpackTap,
                        icon: const Icon(Icons.backpack_outlined, size: 20),
                        color: accent.withValues(alpha: 0.86),
                        constraints: const BoxConstraints.tightFor(
                          width: 44,
                          height: 44,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

            // ── scrollable body ──
            Expanded(
              child: Stack(
                children: <Widget>[
                  NotificationListener<ScrollMetricsNotification>(
                    onNotification: (_) {
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _refreshScrollHint(),
                      );
                      return false;
                    },
                    child: ListView(
                      controller: _scrollController,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.only(bottom: 46),
                      physics: const BouncingScrollPhysics(),
                      children: [
                        // ━━ 模型與連線 ━━  // UI_SLOT: sidebar_models_section
                        _sectionTitle(
                          L.pick(
                            en: 'Models & connections',
                            zhTW: '模型與連線',
                            zhCN: '模型与连接',
                          ),
                          expanded: _modelsExpanded,
                          onTap: () {
                            _dismissKeyboard();
                            setState(() => _modelsExpanded = !_modelsExpanded);
                          },
                        ),
                        _collapsibleGroup(
                          expanded: _modelsExpanded,
                          child: const SidebarModelSettings(),
                        ),

                        // ━━ 系統行為 ━━  // UI_SLOT: sidebar_behavior_section
                        _sectionTitle(
                          L.pick(
                            en: 'System behavior',
                            zhTW: '系統行為',
                            zhCN: '系统行为',
                          ),
                          expanded: _behaviorExpanded,
                          onTap: () {
                            _dismissKeyboard();
                            setState(
                              () => _behaviorExpanded = !_behaviorExpanded,
                            );
                          },
                        ),
                        _collapsibleGroup(
                          expanded: _behaviorExpanded,
                          child: const SidebarBehaviorSettings(),
                        ),

                        // UI_SLOT: sidebar_features_section
                        _sectionTitle(
                          L.pick(
                            en: 'Feature modules',
                            zhTW: '功能模組開關',
                            zhCN: '功能模块开关',
                          ),
                          expanded: _featuresExpanded,
                          onTap: () {
                            _dismissKeyboard();
                            setState(
                              () => _featuresExpanded = !_featuresExpanded,
                            );
                          },
                        ),
                        _collapsibleGroup(
                          expanded: _featuresExpanded,
                          child: const SidebarFeatureSettings(),
                        ),
                      ],
                    ),
                  ),
                  if (_hasMoreBelow)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 5,
                      child: Center(
                        child: Semantics(
                          button: true,
                          label: L.pick(
                            en: 'More settings below',
                            zhTW: '下方還有設定',
                            zhCN: '下方还有设置',
                          ),
                          child: InkResponse(
                            key: const ValueKey('sidebar-more-below'),
                            onTap: _scrollFurther,
                            radius: 22,
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: Colors.transparent,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: SidebarVisualTokens.secondary
                                      .withValues(alpha: 0.24),
                                  width: 0.8,
                                ),
                              ),
                              child: Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 21,
                                color: SidebarVisualTokens.accent.withValues(
                                  alpha: 0.72,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // UI_SLOT: sidebar_usage_section
            // Pinned outside the scroll body so first-time users never need to
            // infer that another destination exists below the fold.
            _usageEntry(),
          ],
        ),
      ),
    );
  }
}
