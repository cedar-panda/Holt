import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'api_key_field.dart';

class ApiAwsBedrockSettingsCard extends StatelessWidget {
  final TextEditingController accessKeyIdController;
  final TextEditingController secretAccessKeyController;
  final TextEditingController regionController;
  final bool obscureSecretAccessKey;
  final Color borderColor;
  final ValueChanged<String> onAccessKeyIdChanged;
  final ValueChanged<String> onSecretAccessKeyChanged;
  final ValueChanged<String> onRegionChanged;
  final VoidCallback onToggleObscureSecretAccessKey;

  const ApiAwsBedrockSettingsCard({
    super.key,
    required this.accessKeyIdController,
    required this.secretAccessKeyController,
    required this.regionController,
    required this.obscureSecretAccessKey,
    required this.borderColor,
    required this.onAccessKeyIdChanged,
    required this.onSecretAccessKeyChanged,
    required this.onRegionChanged,
    required this.onToggleObscureSecretAccessKey,
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

  InputDecoration _textFieldDecoration({
    required String hintText,
    double? fontSize,
  }) {
    final hintStyle = YanciTheme.bodySmall.copyWith(
      color: YanciTheme.textSecondary.withValues(alpha: 0.4),
    );
    return InputDecoration(
      hintText: hintText,
      hintStyle: fontSize == null
          ? hintStyle
          : hintStyle.copyWith(fontSize: fontSize),
      border: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      isDense: true,
    );
  }

  Widget _buildDivider() {
    return Divider(
      color: YanciTheme.textSecondary.withValues(alpha: 0.1),
      height: 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _buildGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: accessKeyIdController,
            style: YanciTheme.bodyText.copyWith(fontSize: 13),
            onChanged: onAccessKeyIdChanged,
            decoration: _textFieldDecoration(hintText: 'AWS Access Key ID'),
          ),
          _buildDivider(),
          ApiKeyField(
            controller: secretAccessKeyController,
            hintText: 'AWS Secret Access Key',
            obscureText: obscureSecretAccessKey,
            onChanged: onSecretAccessKeyChanged,
            onToggleObscure: onToggleObscureSecretAccessKey,
          ),
          _buildDivider(),
          TextField(
            controller: regionController,
            style: YanciTheme.bodyText.copyWith(fontSize: 13),
            onChanged: onRegionChanged,
            decoration: _textFieldDecoration(
              hintText: 'Region (e.g. us-east-1)',
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
