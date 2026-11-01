import 'package:flutter/material.dart';
import '../models/context_mode.dart';
import '../theme/app_theme.dart';
import '../memory/database.dart';
import '../services/settings_manager.dart';
import '../services/settings/context_mode_settings.dart';
import '../services/locale_strings.dart';
import '../services/static_token_estimator.dart';

class AbilityModulesScreen extends StatefulWidget {
  final Map<String, dynamic> character;

  const AbilityModulesScreen({super.key, required this.character});

  @override
  State<AbilityModulesScreen> createState() => _AbilityModulesScreenState();
}

class _AbilityModulesScreenState extends State<AbilityModulesScreen> {
  bool _isSpiderWebEnabled = false;
  bool _rpUsesClassicMemory = false;
  int _legacyBudget = 1000;
  bool _legacyMemoryWrite = false;

  @override
  void initState() {
    super.initState();
    _isSpiderWebEnabled =
        (widget.character['is_spider_web_enabled'] as int? ?? 0) == 1;
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final characterId = widget.character['id'] as String;
    _rpUsesClassicMemory =
        await ContextModeSettings.effectiveMode(characterId) == ContextMode.rp;
    _legacyBudget = await MemorySettings.getMemBudgetTotal();
    _legacyBudget = ((_legacyBudget / 100).round() * 100).clamp(300, 4000);
    _legacyMemoryWrite = await MemorySettings.getMemoryWriteEnabled();
    if (mounted) setState(() {});
  }

  Future<void> _toggleSpiderWeb(bool value) async {
    if (_rpUsesClassicMemory) return;
    setState(() {
      _isSpiderWebEnabled = value;
    });

    await DatabaseHelper.updateCharacter(widget.character['id'] as String, {
      'is_spider_web_enabled': value ? 1 : 0,
    });
    // 靜態 token 估值提示（僅 cache 開啟時彈）
    if (mounted) StaticTokenEstimator.showAfterToggle(context);
  }

  Future<void> _toggleLegacyMemoryWrite(bool value) async {
    setState(() {
      _legacyMemoryWrite = value;
    });
    await MemorySettings.saveMemoryWriteEnabled(value);
    if (mounted) StaticTokenEstimator.showAfterToggle(context);
  }

  Widget _buildModuleTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
    required bool locked,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: YanciTheme.isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        leading: Icon(
          icon,
          color: locked ? YanciTheme.accent : YanciTheme.accent,
          size: 28,
        ),
        title: Text(
          title,
          style: TextStyle(
            color: locked ? YanciTheme.accent : YanciTheme.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: Text(
            subtitle,
            style: TextStyle(
              color: YanciTheme.textSecondary.withValues(
                alpha: locked ? 0.8 : 0.6,
              ),
              fontSize: 12,
            ),
          ),
        ),
        trailing: locked
            ? Icon(Icons.lock_rounded, color: YanciTheme.accent, size: 20)
            : Switch(
                value: value,
                activeThumbColor: YanciTheme.accent,
                onChanged: onChanged,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final classicSelected = _rpUsesClassicMemory || !_isSpiderWebEnabled;
    final spiderSelected = !_rpUsesClassicMemory && _isSpiderWebEnabled;
    final charName =
        widget.character['name'] as String? ??
        L.pick(en: 'Character', zhTW: '角色');

    return Scaffold(
      backgroundColor: YanciTheme.isDark
          ? const Color(0xFF1E1E2E)
          : Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new,
            color: YanciTheme.textPrimary,
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(_isSpiderWebEnabled),
        ),
        title: Text(
          L.pick(en: 'Ability Modules', zhTW: '能力模組'),
          style: TextStyle(
            color: YanciTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Character Indicator
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: YanciTheme.accent.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        charName.isNotEmpty ? charName[0] : '？',
                        style: TextStyle(
                          color: YanciTheme.accent,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    L.pick(
                      en: 'Cognitive settings for $charName',
                      zhTW: '對 $charName 生效的認知配置',
                    ),
                    style: TextStyle(
                      color: YanciTheme.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Core Memory Strategy Toggle
              Container(
                decoration: BoxDecoration(
                  color: YanciTheme.isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.black.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _toggleSpiderWeb(false),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: classicSelected
                                ? YanciTheme.accent
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Center(
                            child: Text(
                              L.pick(en: 'Legacy Memory', zhTW: '經典記憶'),
                              style: TextStyle(
                                color: classicSelected
                                    ? Colors.white
                                    : YanciTheme.textSecondary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: _rpUsesClassicMemory
                            ? null
                            : () => _toggleSpiderWeb(true),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: spiderSelected
                                ? YanciTheme.accent
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.hub_outlined,
                                  size: 16,
                                  color: spiderSelected
                                      ? Colors.white
                                      : YanciTheme.accent.withValues(
                                          alpha: _rpUsesClassicMemory ? .35 : 1,
                                        ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  L.pick(
                                    en: 'Advanced Memory (Rec.)',
                                    zhTW: '進階記憶 (推薦)',
                                    zhCN: '进阶记忆 (推荐)',
                                  ),
                                  style: TextStyle(
                                    color: spiderSelected
                                        ? Colors.white
                                        : YanciTheme.accent.withValues(
                                            alpha: _rpUsesClassicMemory
                                                ? .35
                                                : 1,
                                          ),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_rpUsesClassicMemory) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.theater_comedy_outlined,
                      size: 15,
                      color: YanciTheme.accent,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        L.pick(
                          en: 'RP mode uses classic memory. Your daily memory choice is preserved.',
                          zhTW: 'RP 模式自動使用經典記憶；日常模式的記憶選擇會保留。',
                          zhCN: 'RP 模式自动使用经典记忆；日常模式的记忆选择会保留。',
                        ),
                        style: TextStyle(
                          color: YanciTheme.textSecondary.withValues(
                            alpha: .72,
                          ),
                          fontSize: 11,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 32),

              // dynamic content based on toggle
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: spiderSelected
                    ? _buildSpiderWebSection()
                    : _buildLegacySection(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSpiderWebSection() {
    return Column(
      key: const ValueKey('spider'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: YanciTheme.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: YanciTheme.accent.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Icon(Icons.hub_rounded, color: YanciTheme.accent, size: 28),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  L.pick(
                    en: 'Advanced Memory is active. Feature modules can be configured on the Switches page.',
                    zhTW: '已啟動進階記憶。其他功能模組可在「開關」主頁調整。',
                    zhCN: '已启用进阶记忆。其他功能模块可在“开关”主页调整。',
                  ),
                  style: TextStyle(
                    color: YanciTheme.accent,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLegacySection() {
    return Column(
      key: const ValueKey('legacy'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: YanciTheme.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: YanciTheme.accent.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Icon(
                Icons.inventory_2_outlined,
                color: YanciTheme.accent,
                size: 28,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  L.pick(
                    en: 'Legacy memory is active. Feature modules can be configured on the Switches page.',
                    zhTW: '已啟動經典記憶。其他功能模組可在「開關」主頁調整。',
                    zhCN: '已启用经典记忆。其他功能模块可在“开关”主页调整。',
                  ),
                  style: TextStyle(
                    color: YanciTheme.accent,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        Text(
          L.pick(en: 'Legacy Injection Budget', zhTW: '經典記憶注入預算'),
          style: TextStyle(
            color: YanciTheme.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              '${_legacyBudget}t',
              style: TextStyle(
                color: YanciTheme.accent,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: YanciTheme.accent,
            inactiveTrackColor: YanciTheme.accent.withValues(alpha: 0.2),
            thumbColor: YanciTheme.accent,
            overlayColor: YanciTheme.accent.withValues(alpha: 0.1),
            trackHeight: 4,
          ),
          child: Slider(
            value: _legacyBudget.toDouble().clamp(300.0, 4000.0),
            min: 300,
            max: 4000,
            divisions: 37,
            onChanged: (val) {
              setState(() => _legacyBudget = val.toInt());
            },
            onChangeEnd: (val) {
              MemorySettings.saveMemBudgetTotal(val.toInt());
            },
          ),
        ),
        const SizedBox(height: 24),

        Text(
          L.pick(en: 'Memory writing', zhTW: '記憶寫入', zhCN: '记忆写入'),
          style: TextStyle(
            color: YanciTheme.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        _buildModuleTile(
          icon: Icons.psychology_rounded,
          title: L.pick(en: 'Write Memory', zhTW: '自動寫入記憶'),
          subtitle: L.pick(
            en: 'Allow model to persist memories',
            zhTW: '允許模型將重要對話寫入長期記憶',
          ),
          value: _legacyMemoryWrite,
          onChanged: _toggleLegacyMemoryWrite,
          locked: false,
        ),
      ],
    );
  }
}
