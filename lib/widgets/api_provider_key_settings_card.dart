import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'api_key_field.dart';

class ApiProviderKeySettingsCard extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final bool obscureText;
  final bool isTesting;
  final Color borderColor;
  final ValueChanged<String> onChanged;
  final VoidCallback onToggleObscure;
  final VoidCallback? onTestConnection;
  final String? testTooltip;

  const ApiProviderKeySettingsCard({
    super.key,
    required this.controller,
    required this.hintText,
    required this.obscureText,
    required this.isTesting,
    required this.borderColor,
    required this.onChanged,
    required this.onToggleObscure,
    this.onTestConnection,
    this.testTooltip,
  });

  Widget _buildGlassCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: YanciTheme.spacingMd,
        vertical: YanciTheme.spacingXs,
      ),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        border: Border.all(color: borderColor, width: 0.75),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final showTestAction = onTestConnection != null;
    return _buildGlassCard(
      child: ApiKeyField(
        controller: controller,
        hintText: hintText,
        obscureText: obscureText,
        onChanged: onChanged,
        onToggleObscure: onToggleObscure,
        trailingActions: [
          if (showTestAction)
            isTesting
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.wifi_protected_setup, size: 18),
                    tooltip: testTooltip,
                    onPressed: onTestConnection,
                  ),
        ],
      ),
    );
  }
}
