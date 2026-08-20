import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../services/thinking_machines_service.dart';
import '../theme/app_theme.dart';
import 'api_key_field.dart';

class ThinkingMachinesSettingsCard extends StatelessWidget {
  final TextEditingController keyController;
  final TextEditingController modelController;
  final bool isTesting;
  final bool obscureKey;
  final bool isStarred;
  final String effort;
  final Color borderColor;
  final ValueChanged<String> onKeyChanged;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onEffortChanged;
  final ValueChanged<String> onTestConnection;
  final VoidCallback onToggleObscure;
  final Future<void> Function(String modelId) onToggleStar;

  const ThinkingMachinesSettingsCard({
    super.key,
    required this.keyController,
    required this.modelController,
    required this.isTesting,
    required this.obscureKey,
    required this.isStarred,
    required this.effort,
    required this.borderColor,
    required this.onKeyChanged,
    required this.onModelChanged,
    required this.onEffortChanged,
    required this.onTestConnection,
    required this.onToggleObscure,
    required this.onToggleStar,
  });

  @override
  Widget build(BuildContext context) {
    final model = modelController.text.trim().isEmpty
        ? ThinkingMachinesService.defaultModel
        : modelController.text.trim();

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Text(
              L.pick(
                en: 'First-party Inkling API via Tinker (beta)',
                zhTW: '透過 Tinker 使用第一方 Inkling API（beta）',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 11,
                color: YanciTheme.textSecondary.withValues(alpha: 0.65),
              ),
            ),
          ),
          ApiKeyField(
            controller: keyController,
            hintText: 'Tinker API Key',
            obscureText: obscureKey,
            onChanged: onKeyChanged,
            onToggleObscure: onToggleObscure,
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
                      tooltip: L.pick(
                        en: 'Test Inkling connection',
                        zhTW: '測試 Inkling 連線',
                      ),
                      onPressed: () =>
                          onTestConnection(keyController.text.trim()),
                    ),
            ],
          ),
          Divider(
            color: YanciTheme.textSecondary.withValues(alpha: 0.1),
            height: 1,
          ),
          TextField(
            controller: modelController,
            style: YanciTheme.bodyText.copyWith(fontSize: 13),
            onChanged: onModelChanged,
            decoration: InputDecoration(
              labelText: L.pick(en: 'Model', zhTW: '模型'),
              hintText: ThinkingMachinesService.defaultModel,
              labelStyle: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary.withValues(alpha: 0.6),
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  isStarred ? Icons.star_rounded : Icons.star_border_rounded,
                  size: 20,
                  color: isStarred
                      ? Colors.amber
                      : YanciTheme.textSecondary.withValues(alpha: 0.5),
                ),
                tooltip: L.pick(en: 'Star model', zhTW: '將模型加上星標'),
                onPressed: () => onToggleStar(model),
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              isDense: true,
            ),
          ),
          Divider(
            color: YanciTheme.textSecondary.withValues(alpha: 0.1),
            height: 1,
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  L.pick(en: 'Thinking effort', zhTW: '思考強度'),
                  style: YanciTheme.bodyText.copyWith(fontSize: 13),
                ),
              ),
              DropdownButton<String>(
                value: effort,
                underline: const SizedBox(),
                dropdownColor: YanciTheme.isDark
                    ? const Color(0xF0302830)
                    : Colors.white,
                items: const [
                  DropdownMenuItem(value: 'low', child: Text('Low')),
                  DropdownMenuItem(value: 'medium', child: Text('Medium')),
                  DropdownMenuItem(value: 'high', child: Text('High')),
                  DropdownMenuItem(value: 'xhigh', child: Text('XHigh')),
                ],
                onChanged: (value) {
                  if (value != null) onEffortChanged(value);
                },
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              L.pick(
                en: 'Uses Inkling native thinking blocks. Prompt caching and audio input are not supported by this compatible endpoint.',
                zhTW: '使用 Inkling 原生思考區塊；此相容端點目前不支援提示詞快取與音訊輸入。',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 10.5,
                color: YanciTheme.textSecondary.withValues(alpha: 0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
