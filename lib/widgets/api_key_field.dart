import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class ApiKeyField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final bool obscureText;
  final ValueChanged<String> onChanged;
  final VoidCallback onToggleObscure;
  final List<Widget> trailingActions;

  const ApiKeyField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.obscureText,
    required this.onChanged,
    required this.onToggleObscure,
    this.trailingActions = const <Widget>[],
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      style: YanciTheme.bodyText.copyWith(fontSize: 14),
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: YanciTheme.bodySmall.copyWith(
          color: YanciTheme.textSecondary.withValues(alpha: 0.48),
        ),
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        isDense: true,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...trailingActions,
            IconButton(
              icon: Icon(
                obscureText
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 21,
              ),
              color: YanciTheme.textSecondary,
              tooltip: L.pick(
                en: obscureText ? 'Show API Key' : 'Hide API Key',
                zhTW: obscureText ? '顯示 API Key' : '隱藏 API Key',
              ),
              onPressed: onToggleObscure,
            ),
          ],
        ),
      ),
    );
  }
}
