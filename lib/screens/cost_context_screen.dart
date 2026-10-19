import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../models/context_mode.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../services/settings/context_mode_settings.dart';
import '../services/settings/guide_settings.dart';
import '../memory/database.dart';
import 'ability_modules_screen.dart';
import '../services/static_token_estimator.dart';
import '../services/tool_feature_settings.dart';
import '../widgets/gradient_background.dart';
import '../widgets/yanci_sprite_overlay.dart';
import '../widgets/help_switch_tile.dart';
import '../widgets/context_mode_pill.dart';

enum CostContextSection { behavior, modules, avatars, memory }

class CostContextScreen extends StatefulWidget {
  const CostContextScreen({super.key, this.section});

  final CostContextSection? section;

  @override
  State<CostContextScreen> createState() => _CostContextScreenState();
}

class _CostContextScreenState extends State<CostContextScreen> {
  bool _globalRpEnabled = false;
  bool _signatureEnabled = true;
  bool _emotionEnabled = true;
  bool _guideEnabled = true;
  ToolFeatureState _toolFeatures = const ToolFeatureState();

  String get _screenTitle => switch (widget.section) {
    CostContextSection.behavior => L.pick(
      en: 'Behavior / Output',
      zhTW: '對話行為／輸出格式',
      zhCN: '对话行为／输出格式',
    ),
    CostContextSection.modules => L.pick(
      en: 'Feature modules',
      zhTW: '功能模組',
      zhCN: '功能模块',
    ),
    CostContextSection.avatars => L.pick(
      en: 'Chat avatars',
      zhTW: '頭像顯示',
      zhCN: '头像显示',
    ),
    CostContextSection.memory => L.pick(
      en: 'Memory & Role',
      zhTW: '記憶與角色功能',
      zhCN: '记忆与角色功能',
    ),
    null => L.pick(en: 'Preferences', zhTW: '偏好設定', zhCN: '偏好设置'),
  };

  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    final results = await Future.wait<Object>(<Future<Object>>[
      ContextModeSettings.getGlobalRpEnabled(),
      CharacterSignatureSettings.isEnabled(),
      MemorySettings.isAbilityEnabled('emotion'),
      ToolFeatureSettings.load(),
      GuideSettings.isEnabled(),
    ]);
    if (!mounted) return;
    setState(() {
      _globalRpEnabled = results[0] as bool;
      _signatureEnabled = results[1] as bool;
      _emotionEnabled = results[2] as bool;
      _toolFeatures = results[3] as ToolFeatureState;
      _guideEnabled = results[4] as bool;
    });
  }

  Future<void> _toggleSignature(bool value) async {
    setState(() => _signatureEnabled = value);
    await CharacterSignatureSettings.setEnabled(value);
  }

  Future<void> _toggleEmotion(bool value) async {
    setState(() => _emotionEnabled = value);
    await MemorySettings.setAbilityEnabled('emotion', value);
    if (mounted) StaticTokenEstimator.showAfterToggle(context);
  }

  Future<void> _toggleToolFeature(
    ToolFeatureState next,
    Future<void> Function() persist,
  ) async {
    setState(() => _toolFeatures = next);
    await persist();
    if (mounted) StaticTokenEstimator.showAfterToggle(context);
  }

  Widget _featureSwitch({
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return HelpSwitchTile(
      title: title,
      description: description,
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _buildFeatureModules() {
    final rows = <Widget>[
      _featureSwitch(
        title: L.pick(en: 'Guide', zhTW: '嚮導', zhCN: '向导'),
        description: L.pick(
          en: 'Show the Guide on Home when an API is configured. Opening it is local; sending a message may use API credit.',
          zhTW: '已設定 API 時在首頁顯示嚮導。打開頁面不消耗額度，送出訊息才可能使用 API。',
          zhCN: '已设置 API 时在首页显示向导。打开页面不消耗额度，送出消息才可能使用 API。',
        ),
        value: _guideEnabled,
        onChanged: (value) {
          setState(() => _guideEnabled = value);
          unawaited(GuideSettings.setEnabled(value));
        },
      ),
      _featureSwitch(
        title: L.pick(
          en: 'Character signature',
          zhTW: '角色個性簽名',
          zhCN: '角色个性签名',
        ),
        description: L.pick(
          en: 'Generate one opening and one closing signature per window.',
          zhTW: '每個窗口最多生成開頭與結束各一條，關閉後不再消費。',
          zhCN: '每个窗口最多生成开头与结束各一条，关闭后不再消费。',
        ),
        value: _signatureEnabled,
        onChanged: (value) => unawaited(_toggleSignature(value)),
      ),
      _featureSwitch(
        title: L.pick(en: 'Emotion coordinates', zhTW: '情緒座標', zhCN: '情绪坐标'),
        description: L.pick(
          en: 'Inject emotion rules and the current emotional state.',
          zhTW: '注入情緒規則與當前情緒狀態。',
          zhCN: '注入情绪规则与当前情绪状态。',
        ),
        value: _emotionEnabled,
        onChanged: (value) => unawaited(_toggleEmotion(value)),
      ),
      _featureSwitch(
        title: L.pick(en: 'Draw', zhTW: '畫畫', zhCN: '画画'),
        description: L.pick(
          en: 'Allow the model to generate images.',
          zhTW: '允許模型生成圖片。',
          zhCN: '允许模型生成图片。',
        ),
        value: _toolFeatures.imageGenerationEnabled,
        onChanged: (value) => unawaited(
          _toggleToolFeature(
            _toolFeatures.copyWith(imageGenerationEnabled: value),
            () => ToolFeatureSettings.setImageGenerationEnabled(value),
          ),
        ),
      ),
      _featureSwitch(
        title: L.pick(
          en: 'Shell Economy Interactions',
          zhTW: '貝殼虛擬幣互動',
          zhCN: '贝壳虚拟币互动',
        ),
        description: L.pick(
          en: 'Show shell balance and allow shop, backpack, scratch-card and transfer interactions.',
          zhTW: '顯示貝殼餘額，並開啟商店、背包、刮刮卡與轉帳互動。',
          zhCN: '显示贝壳余额，并开启商店、背包、刮刮卡与转账互动。',
        ),
        value: _toolFeatures.shellEconomyEnabled,
        onChanged: (value) => unawaited(
          _toggleToolFeature(
            _toolFeatures.copyWith(shellEconomyEnabled: value),
            () => ToolFeatureSettings.setShellEconomyEnabled(value),
          ),
        ),
      ),
      _featureSwitch(
        title: L.pick(en: 'Diary', zhTW: '日記', zhCN: '日记'),
        description: L.pick(
          en: 'Allow one optional character diary entry per day in Daily mode.',
          zhTW: '允許角色在日常模式下每天選擇寫一份日記。',
          zhCN: '允许角色在日常模式下每天选择写一份日记。',
        ),
        value: _toolFeatures.diaryEnabled,
        onChanged: (value) => unawaited(
          _toggleToolFeature(
            _toolFeatures.copyWith(diaryEnabled: value),
            () => ToolFeatureSettings.setDiaryEnabled(value),
          ),
        ),
      ),
      _featureSwitch(
        title: L.pick(en: 'Tool prompts', zhTW: '工具系統提示詞', zhCN: '工具系统提示词'),
        description: L.pick(
          en: 'Turn off app tool instructions while keeping profiles, memories, summaries and RP context.',
          zhTW: '關閉 App 工具指令；角色卡、記憶、摘要與 RP 內容照常注入。',
          zhCN: '关闭 App 工具指令；角色卡、记忆、摘要与 RP 内容照常注入。',
        ),
        value: _toolFeatures.toolPromptsEnabled,
        onChanged: (value) => unawaited(
          _toggleToolFeature(
            _toolFeatures.copyWith(toolPromptsEnabled: value),
            () => ToolFeatureSettings.setToolPromptsEnabled(value),
          ),
        ),
      ),
      _featureSwitch(
        title: L.pick(
          en: 'Model-generated home greeting',
          zhTW: '模型輸出問候語',
          zhCN: '模型输出问候语',
        ),
        description: L.pick(
          en: 'Allow the model to leave one short homepage greeting through the hidden <home> marker. This is independent from other tool prompts.',
          zhTW: '允許模型透過隱藏的 <home> 標記在首頁留下短問候語；此開關與其他工具提示詞分開。',
          zhCN: '允许模型通过隐藏的 <home> 标记在首页留下短问候语；此开关与其他工具提示词分开。',
        ),
        value: _toolFeatures.modelGreetingEnabled,
        onChanged: (value) => unawaited(
          _toggleToolFeature(
            _toolFeatures.copyWith(modelGreetingEnabled: value),
            () => ToolFeatureSettings.setModelGreetingEnabled(value),
          ),
        ),
      ),
      _featureSwitch(
        title: L.pick(en: 'Write email', zhTW: '撰寫郵件', zhCN: '撰写邮件'),
        description: L.pick(
          en: 'Allow the model to prepare email drafts through the app tool.',
          zhTW: '允許模型使用 App 工具整理並建立郵件草稿。',
          zhCN: '允许模型使用 App 工具整理并建立邮件草稿。',
        ),
        value: _toolFeatures.emailDraftEnabled,
        onChanged: (value) => unawaited(
          _toggleToolFeature(
            _toolFeatures.copyWith(emailDraftEnabled: value),
            () => ToolFeatureSettings.setEmailDraftEnabled(value),
          ),
        ),
      ),
      _featureSwitch(
        title: L.pick(
          en: 'Daily-life tools in RP',
          zhTW: 'RP 中使用日常工具',
          zhCN: 'RP 中使用日常工具',
        ),
        description: L.pick(
          en: 'RP is a parallel world. When off, shells, shop, transfers, scratch cards, home notes, email drafts, X posts and marriage prompts are not sent in RP windows.',
          zhTW: 'RP 是平行時空。關閉時，RP 窗口不會注入貝殼、商店、轉帳、刮刮卡、首頁便箋、郵件草稿、X 發文與婚姻提示。',
          zhCN: 'RP 是平行时空。关闭时，RP 窗口不会注入贝壳、商店、转账、刮刮卡、首页便笺、邮件草稿、X 发文与婚姻提示。',
        ),
        value: _toolFeatures.rpDailyLifeToolsEnabled,
        onChanged: (value) => unawaited(
          _toggleToolFeature(
            _toolFeatures.copyWith(rpDailyLifeToolsEnabled: value),
            () => ToolFeatureSettings.setRpDailyLifeToolsEnabled(value),
          ),
        ),
      ),
    ];

    // UI_SLOT: feature_modules_direct_switches
    // The dedicated sidebar destination is already the module group: no
    // second disclosure or card is needed. Keep the legacy preferences fold.
    if (widget.section == CostContextSection.modules) {
      return Column(
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0) _softDivider(),
            rows[index],
          ],
        ],
      );
    }
    return _buildGlassCard(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          maintainState: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Text(
            L.pick(en: 'Feature modules', zhTW: '功能模組', zhCN: '功能模块'),
            style: YanciTheme.bodyText.copyWith(fontSize: 14),
          ),
          subtitle: Text(
            L.pick(
              en: 'Enable tools and prompts as needed to reduce unnecessary Token usage.',
              zhTW: '按需開啟工具與提示詞，減少不必要的 Token 消耗。',
              zhCN: '按需开启工具与提示词，减少不必要的 Token 消耗。',
            ),
            style: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: 0.72),
            ),
          ),
          iconColor: YanciTheme.accent,
          collapsedIconColor: YanciTheme.textSecondary,
          children: <Widget>[
            const SizedBox(height: 4),
            for (var index = 0; index < rows.length; index++) ...<Widget>[
              if (index > 0) _softDivider(),
              rows[index],
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _setGlobalRp(bool enabled) async {
    await ContextModeSettings.setGlobalRpEnabled(enabled);
    if (!mounted) return;
    setState(() => _globalRpEnabled = enabled);

    final activeCharacterId = await UserSettings.getActiveCharacterId();
    final mode = enabled || activeCharacterId.isEmpty
        ? ContextMode.rp
        : await ContextModeSettings.effectiveMode(activeCharacterId);
    final differs =
        activeCharacterId.isNotEmpty &&
        await ContextModeSettings.latestWindowDiffers(activeCharacterId, mode);
    if (!mounted) return;

    final base = enabled
        ? L.pick(
            en: 'RP mode is on. This changes every character to RP state.',
            zhTW: '已打開RP模式，請注意這會使角色都更改為RP狀態',
            zhCN: '已打开RP模式，请注意这会使角色都更改为RP状态',
          )
        : L.pick(
            en: 'RP mode is off. Back to daily mode.',
            zhTW: '已關閉RP模式，回歸日常狀態',
            zhCN: '已关闭RP模式，回归日常状态',
          );
    final next = !differs
        ? ''
        : enabled
        ? L.pick(
            en: ' Open a new window to begin RP.',
            zhTW: ' 請開啟新窗口進行RP',
            zhCN: ' 请开启新窗口进行RP',
          )
        : L.pick(
            en: ' Open a new window to return to your daily life.',
            zhTW: ' 請開啟新窗口開始你們的日常',
            zhCN: ' 请开启新窗口开始你们的日常',
          );
    showContextModeNotice(context, '$base$next');
  }

  Widget _buildNavigationTile({
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minTileHeight: 56,
      leading: Icon(icon, color: YanciTheme.accent),
      title: Text(title, style: YanciTheme.bodyText.copyWith(fontSize: 14)),
      subtitle: Text(
        description,
        style: YanciTheme.bodySmall.copyWith(
          color: YanciTheme.textSecondary.withValues(alpha: 0.72),
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: YanciTheme.textSecondary,
      ),
      onTap: onTap,
    );
  }

  Future<void> _openMemoryMode() async {
    final activeId = await UserSettings.getActiveCharacterId();
    final characters = await DatabaseHelper.getCharacters();
    Map<String, dynamic>? character;
    for (final item in characters) {
      if (item['id'] == activeId) {
        character = item;
        break;
      }
    }
    character ??= characters.isEmpty ? null : characters.first;
    if (!mounted) return;
    if (character == null) {
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          title: Text(L.pick(en: 'Memory mode', zhTW: '記憶模式', zhCN: '记忆模式')),
          content: Text(
            L.pick(
              en: 'Create a character first to configure memory mode.',
              zhTW: '請先建立角色，才能設定記憶模式。',
              zhCN: '请先建立角色，才能设置记忆模式。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(L.pick(en: 'OK', zhTW: '知道了', zhCN: '知道了')),
            ),
          ],
        ),
      );
      return;
    }
    final selectedCharacter = character;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AbilityModulesScreen(character: selectedCharacter),
      ),
    );
  }

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
                          _screenTitle,
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
                    if (widget.section == null ||
                        widget.section == CostContextSection.behavior) ...[
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
                                  StaticTokenEstimator.showAfterToggle(context);
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                    ],
                    if (widget.section == null ||
                        widget.section == CostContextSection.modules) ...[
                      _buildSectionTitle(
                        L.pick(
                          en: 'Features & Token Usage',
                          zhTW: '功能與 Token 消耗',
                          zhCN: '功能与 Token 消耗',
                        ),
                      ),
                      _buildFeatureModules(),
                      const SizedBox(height: 28),
                    ],
                    if (widget.section == null ||
                        widget.section == CostContextSection.memory) ...[
                      _buildSectionTitle(
                        L.pick(
                          en: 'Memory & Role',
                          zhTW: '記憶與角色功能',
                          zhCN: '记忆与角色功能',
                        ),
                      ),
                      _buildGlassCard(
                        child: Column(
                          children: [
                            KeyedSubtree(
                              key: const Key('global_rp_mode_switch'),
                              child: HelpSwitchTile(
                                title: L.pick(
                                  en: 'Global RP mode',
                                  zhTW: '全域 RP 模式',
                                  zhCN: '全局 RP 模式',
                                ),
                                description: L.pick(
                                  en: 'Only new windows change. Existing windows keep their original mode.',
                                  zhTW: '只影響新窗口；既有窗口保持建立時的模式。',
                                  zhCN: '只影响新窗口；已有窗口保持创建时的模式。',
                                ),
                                value: _globalRpEnabled,
                                onChanged: (value) =>
                                    unawaited(_setGlobalRp(value)),
                              ),
                            ),
                            _softDivider(),
                            _buildNavigationTile(
                              icon: Icons.hub_outlined,
                              title: L.pick(
                                en: 'Memory mode',
                                zhTW: '記憶模式',
                                zhCN: '记忆模式',
                              ),
                              description: L.pick(
                                en: 'Choose classic memory or Spider Web memory.',
                                zhTW: '選擇經典記憶或蛛網記憶。',
                                zhCN: '选择经典记忆或蛛网记忆。',
                              ),
                              onTap: _openMemoryMode,
                            ),
                            _softDivider(),
                            FutureBuilder<bool>(
                              future: MemorySettings.isAbilityEnabled(
                                'bioclock',
                              ),
                              builder: (ctx, snap) => HelpSwitchTile(
                                title: L.pick(
                                  en: 'Bio Clock',
                                  zhTW: '生物鐘',
                                  zhCN: '生物钟',
                                ),
                                description: L.pick(
                                  en: 'Inject fatigue and daily-rhythm cues.',
                                  zhTW: '注入疲勞與日常作息提示。',
                                  zhCN: '注入疲劳与日常作息提示。',
                                ),
                                value: snap.data ?? true,
                                onChanged: (v) {
                                  MemorySettings.setAbilityEnabled(
                                    'bioclock',
                                    v,
                                  );
                                  setState(() {});
                                  StaticTokenEstimator.showAfterToggle(context);
                                },
                              ),
                            ),
                            _softDivider(),
                            FutureBuilder<bool>(
                              future: MemorySettings.getTimelineEnabled(),
                              builder: (ctx, snap) => HelpSwitchTile(
                                title: L.pick(
                                  en: 'Timeline',
                                  zhTW: '時間線',
                                  zhCN: '时间线',
                                ),
                                description: L.pick(
                                  en: 'Show and inject character timeline context.',
                                  zhTW: '顯示並注入角色時間線內容。',
                                  zhCN: '显示并注入角色时间线内容。',
                                ),
                                value: snap.data ?? true,
                                onChanged: (v) {
                                  MemorySettings.saveTimelineEnabled(v);
                                  setState(() {});
                                },
                              ),
                            ),
                            _softDivider(),
                            FutureBuilder<bool>(
                              future: MemorySettings.getSelfNotesEnabled(),
                              builder: (ctx, snap) => HelpSwitchTile(
                                title: L.pick(
                                  en: 'Secretly remembering you',
                                  zhTW: '偷偷記住你',
                                  zhCN: '偷偷记住你',
                                ),
                                description: L.pick(
                                  en: 'Keep the quiet self-notes panel and prompt.',
                                  zhTW: '保留安靜的自我註記面板與提示。',
                                  zhCN: '保留安静的自我注记面板与提示。',
                                ),
                                value: snap.data ?? true,
                                onChanged: (v) {
                                  MemorySettings.saveSelfNotesEnabled(v);
                                  setState(() {});
                                  StaticTokenEstimator.showAfterToggle(context);
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                    ],
                    if (widget.section == null) ...[
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
                            // 桌面像素精靈：已隱藏。僅在舊用戶仍開啟時顯示，讓他們能關閉；關閉後即消失。
                            ValueListenableBuilder<bool>(
                              valueListenable: SpriteOverlaySettings.enabled,
                              builder: (ctx, on, _) {
                                if (!on) return const SizedBox.shrink();
                                return Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _softDivider(),
                                    HelpSwitchTile(
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
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ] else if (widget.section ==
                        CostContextSection.avatars) ...[
                      // UI_SLOT: avatar_visibility_settings
                      _buildSectionTitle(
                        L.pick(en: 'Chat avatars', zhTW: '頭像顯示', zhCN: '头像显示'),
                      ),
                      _buildGlassCard(
                        child: FutureBuilder<bool>(
                          future: UserSettings.getShowChatAvatar(),
                          builder: (ctx, snap) => HelpSwitchTile(
                            title: L.pick(
                              en: 'Chat avatars',
                              zhTW: '頭像顯示',
                              zhCN: '头像显示',
                            ),
                            description: L.pick(
                              en: 'Shows avatars next to chat bubbles.',
                              zhTW: '在對話氣泡旁顯示使用者的頭像。',
                              zhCN: '在对话气泡旁显示使用者的头像。',
                            ),
                            value: snap.data ?? false,
                            onChanged: (value) {
                              UserSettings.saveShowChatAvatar(value);
                              setState(() {});
                            },
                          ),
                        ),
                      ),
                    ],
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
