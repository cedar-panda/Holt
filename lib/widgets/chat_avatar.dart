import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Shared avatar presentation for assistant turns and their live activities.
class ChatAvatar extends StatelessWidget {
  const ChatAvatar({super.key, required this.avatarPath, required this.isUser});

  final String? avatarPath;
  final bool isUser;

  @override
  Widget build(BuildContext context) {
    final path = avatarPath;
    final hasAvatar =
        path != null && path.isNotEmpty && File(path).existsSync();
    return Container(
      width: 40,
      height: 40,
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: YanciTheme.accent.withValues(alpha: 0.08),
        border: Border.all(
          color: YanciTheme.accent.withValues(alpha: 0.12),
          width: 1,
        ),
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
