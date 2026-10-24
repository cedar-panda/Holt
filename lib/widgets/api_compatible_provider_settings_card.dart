import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import 'api_key_field.dart';

class ApiCompatibleProviderSettingsCard extends StatelessWidget {
  final TextEditingController baseUrlController;
  final TextEditingController apiKeyController;
  final TextEditingController modelController;
  final bool obscureApiKey;
  final bool isTesting;
  final bool isFetchingModels;
  final Color borderColor;
  final ValueChanged<String> onBaseUrlChanged;
  final ValueChanged<String> onApiKeyChanged;
  final ValueChanged<String> onModelChanged;
  final VoidCallback onToggleObscureApiKey;
  final VoidCallback onTestConnection;
  final VoidCallback onFetchModels;
  final bool supportsDeveloperRole;
  final bool supportsMidConversationSystem;
  final bool supportsCacheControl;
  final bool supportsTools;
  final ValueChanged<bool> onDeveloperRoleChanged;
  final ValueChanged<bool> onMidConversationSystemChanged;
  final ValueChanged<bool> onCacheControlChanged;
  final ValueChanged<bool> onToolsChanged;

  const ApiCompatibleProviderSettingsCard({
    super.key,
    required this.baseUrlController,
    required this.apiKeyController,
    required this.modelController,
    required this.obscureApiKey,
    required this.isTesting,
    required this.isFetchingModels,
    required this.borderColor,
    required this.onBaseUrlChanged,
    required this.onApiKeyChanged,
    required this.onModelChanged,
    required this.onToggleObscureApiKey,
    required this.onTestConnection,
    required this.onFetchModels,
    required this.supportsDeveloperRole,
    required this.supportsMidConversationSystem,
    required this.supportsCacheControl,
    required this.supportsTools,
    required this.onDeveloperRoleChanged,
    required this.onMidConversationSystemChanged,
    required this.onCacheControlChanged,
    required this.onToolsChanged,
  });

  Widget _capabilitySwitch({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile.adaptive(
      dense: true,
      contentPadding: EdgeInsets.zero,
      visualDensity: const VisualDensity(vertical: -3),
      title: Text(title, style: YanciTheme.bodySmall),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _buildGlassCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: YanciTheme.spacingMd,
        vertical: YanciTheme.spacingXs,
      ),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: child,
    );
  }

  InputDecoration _textFieldDecoration({
    required String hintText,
    double fontSize = 11,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: YanciTheme.bodySmall.copyWith(
        color: YanciTheme.textSecondary.withValues(alpha: 0.4),
        fontSize: fontSize,
      ),
      suffixIcon: suffixIcon,
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
            controller: baseUrlController,
            style: YanciTheme.bodyText.copyWith(fontSize: 13),
            onChanged: onBaseUrlChanged,
            decoration: _textFieldDecoration(
              hintText: 'Base URL (e.g. https://api.example.com/v1)',
            ),
          ),
          _buildDivider(),
          ApiKeyField(
            controller: apiKeyController,
            hintText: 'API Key',
            obscureText: obscureApiKey,
            onChanged: onApiKeyChanged,
            onToggleObscure: onToggleObscureApiKey,
            trailingActions: [
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
                      onPressed: onTestConnection,
                    ),
            ],
          ),
          _buildDivider(),
          TextField(
            controller: modelController,
            style: YanciTheme.bodyText.copyWith(fontSize: 13),
            onChanged: onModelChanged,
            decoration: _textFieldDecoration(
              hintText: 'Model name (e.g. gpt-4o)',
              suffixIcon: isFetchingModels
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.refresh, size: 18),
                      tooltip: L.get('settings_model_refresh'),
                      onPressed: onFetchModels,
                    ),
            ),
          ),
          _buildDivider(),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text(
                L.pick(
                  en: 'Relay capability profile',
                  zhTW: '中轉站能力設定',
                  zhCN: '中转站能力设置',
                ),
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary,
                ),
              ),
              children: <Widget>[
                _capabilitySwitch(
                  title: 'developer role',
                  value: supportsDeveloperRole,
                  onChanged: onDeveloperRoleChanged,
                ),
                _capabilitySwitch(
                  title: L.pick(
                    en: 'Mid-conversation system messages',
                    zhTW: '對話中段 system 訊息',
                    zhCN: '对话中段 system 消息',
                  ),
                  value: supportsMidConversationSystem,
                  onChanged: onMidConversationSystemChanged,
                ),
                _capabilitySwitch(
                  title: 'cache_control',
                  value: supportsCacheControl,
                  onChanged: onCacheControlChanged,
                ),
                _capabilitySwitch(
                  title: L.pick(en: 'Tool calls', zhTW: '工具呼叫', zhCN: '工具调用'),
                  value: supportsTools,
                  onChanged: onToolsChanged,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
