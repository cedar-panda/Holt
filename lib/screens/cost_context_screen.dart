import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../services/static_token_estimator.dart';
import '../widgets/gradient_background.dart';
import '../widgets/yanci_sprite_overlay.dart';
import '../widgets/help_switch_tile.dart';

class CostContextScreen extends StatefulWidget {
  const CostContextScreen({super.key});

  @override
  State<CostContextScreen> createState() => _CostContextScreenState();
}

class _CostContextScreenState extends State<CostContextScreen> {
  Widget _buildGlassCard({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: YanciTheme.glassInputBg,
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            border: Border.all(color: YanciTheme.glassBorder, width: 0.5),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 10),
      child: Text(
        title,
        style: YanciTheme.bodySmall.copyWith(
          color: YanciTheme.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _softDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        height: 1,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.transparent,
              YanciTheme.glassBorder.withValues(alpha: 0.45),
              YanciTheme.glassBorder.withValues(alpha: 0.45),
              Colors.transparent,
            ],
            stops: const [0, 0.18, 0.82, 1],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: YanciTheme.spacingSm,
                  vertical: YanciTheme.spacingXs,
                ),
                child: SizedBox(
                  height: 48,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Center(
                        child: Text(
                          L.pick(en: 'Switches', zhTW: '開關'),
                          textAlign: TextAlign.center,
                          style: YanciTheme.headingMedium,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          icon: Icon(
                            Icons.arrow_back_ios_rounded,
                            size: 20,
                            color: YanciTheme.textPrimary,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 32),
                  children: [
                    _buildSectionTitle(
                      L.pick(en: 'Behavior / Output', zhTW: '對話行為/輸出格式'),
                    ),
                    _buildGlassCard(
                      child: Column(
                        children: [
                          FutureBuilder<bool>(
                            future: ApiSettings.getConciseMode(),
                            builder: (ctx, snap) => HelpSwitchTile(
                              title: L.get('settings_concise'),
                              description: L.get('settings_concise_desc'),
                              value: snap.data ?? false,
                              onChanged: (v) {
                                ApiSettings.saveConciseMode(v);
                                if (v) ApiSettings.saveFreeformMode(false);
                                setState(() {});
                                StaticTokenEstimator.showAfterToggle(context);
                              },
                            ),
                          ),
                          _softDivider(),
                          FutureBuilder<bool>(
                            future: ApiSettings.getFreeformMode(),
                            builder: (ctx, snap) => HelpSwitchTile(
                              title: L.get('settings_freeform'),
                              description: L.get('settings_freeform_desc'),
                              value: snap.data ?? false,
                              onChanged: (v) {
                                ApiSettings.saveFreeformMode(v);
                                if (v) ApiSettings.saveConciseMode(false);
                                setState(() {});
                                StaticTokenEstimator.showAfterToggle(context);
                              },
                            ),
                          ),
                          _softDivider(),
                          FutureBuilder<bool>(
                            future: MemorySettings.getSplitReply(),
                            builder: (ctx, snap) => HelpSwitchTile(
                              title: L.get('settings_split'),
                              description: L.get('settings_split_desc'),
                              value: snap.data ?? false,
                              onChanged: (v) {
                                MemorySettings.saveSplitReply(v);
                                setState(() {});
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    _buildSectionTitle(
                      L.pick(en: 'UI & Feedback', zhTW: '介面互動與反饋'),
                    ),
                    _buildGlassCard(
                      child: Column(
                        children: [
                          FutureBuilder<bool>(
                            future: UserSettings.getEnableVibration(),
                            builder: (ctx, snap) => HelpSwitchTile(
                              title: L.get('settings_vibration'),
                              description: L.get('settings_vibration_on'),
                              value: snap.data ?? true,
                              onChanged: (v) {
                                UserSettings.saveEnableVibration(v);
                                setState(() {});
                              },
                            ),
                          ),
                          _softDivider(),
                          FutureBuilder<bool>(
                            future: UserSettings.getShowChatAvatar(),
                            builder: (ctx, snap) => HelpSwitchTile(
                              title: L.pick(en: 'Chat Avatars', zhTW: '頭像顯示'),
                              description: L.pick(
                                en: 'Shows avatars next to chat bubbles.',
                                zhTW: '在對話氣泡旁顯示使用者的頭像。',
                              ),
                              value: snap.data ?? false,
                              onChanged: (v) {
                                UserSettings.saveShowChatAvatar(v);
                                setState(() {});
                              },
                            ),
                          ),
                          _softDivider(),
                          ValueListenableBuilder<bool>(
                            valueListenable: SpriteOverlaySettings.enabled,
                            builder: (ctx, on, _) => HelpSwitchTile(
                              title: L.pick(
                                en: 'Pixel Companion',
                                zhTW: '桌面像素精靈',
                              ),
                              description: L.pick(
                                en: 'Shows a tiny animated companion overlay.',
                                zhTW: '在畫面邊緣顯示一隻會動的像素小精靈。',
                              ),
                              value: on,
                              onChanged: (v) =>
                                  SpriteOverlaySettings.setEnabled(v),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: YanciTheme.spacingXxl),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
