import 'dart:io';

import 'package:flutter/material.dart';

import '../services/mood_glow_service.dart';
import '../theme/app_theme.dart';

/// Shared avatar presentation for assistant turns and their live activities.
class ChatAvatar extends StatelessWidget {
  const ChatAvatar({super.key, required this.avatarPath, required this.isUser});

  final String? avatarPath;
  final bool isUser;

  @override
  Widget build(BuildContext context) {
    if (isUser) return _buildCore(null);
    // 角色頭像：心情流光。顏色只在換色時用 1.4 秒滑過去，平時是靜態光圈，
    // 不跑逐幀動畫（聊天列表裡可能同時有很多個頭像）。
    return ListenableBuilder(
      listenable: Listenable.merge([
        MoodGlowService.activeColor,
        MoodGlowService.blendMode,
      ]),
      builder: (context, _) {
        final mood = MoodGlowService.activeColor.value;
        final target = mood == null ? null : MoodGlowService.displayColor(mood);
        if (target == null) return _buildCore(null);
        return TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: target),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : MoodGlowService.transition,
          curve: Curves.easeInOutCubic,
          builder: (context, glow, _) => _buildCore(glow),
        );
      },
    );
  }

  Widget _buildCore(Color? glow) {
    final path = avatarPath;
    final hasAvatar =
        path != null && path.isNotEmpty && File(path).existsSync();
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: YanciTheme.accent.withValues(alpha: 0.08),
        border: Border.all(
          color:
              glow?.withValues(alpha: 0.7) ??
              YanciTheme.accent.withValues(alpha: 0.12),
          width: glow == null ? 1 : 1.4,
        ),
        boxShadow: glow == null
            ? null
            : [
                BoxShadow(
                  color: glow.withValues(alpha: 0.45),
                  blurRadius: 9,
                  spreadRadius: 0.5,
                ),
              ],
        image: hasAvatar
            ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover)
            : null,
      ),
      child: hasAvatar
          ? null
          : Icon(
              isUser ? Icons.person_rounded : Icons.smart_toy_outlined,
              size: 20,
              color: YanciTheme.accent.withValues(alpha: 0.3),
            ),
    );
  }
}
