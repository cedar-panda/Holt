import 'package:flutter/material.dart';

import '../memory/database.dart';
import '../memory/emotion_coordinates.dart';
import 'api_adapter.dart';
import 'bio_clock_service.dart';
import 'image_gen_service.dart';
import 'locale_strings.dart';
import 'memory_actions.dart';
import 'settings_manager.dart';
import 'spider_web_service.dart';
import 'sticker_service.dart';
import 'token_estimator.dart';
import 'tool_prompts.dart';
import 'tool_feature_settings.dart';
import 'x_post_settings.dart';
import 'settings/context_mode_settings.dart';
import '../models/context_mode.dart';
import 'rp_memory_service.dart';
import 'user_persona_service.dart';
import '../widgets/themed_notice.dart';

/// 靜態緩存 token 估值器。
/// 與 chat_screen._buildCommonStaticParts 同源（工具文本共用 ToolPrompts），
/// 差異：快照類（窗口摘要/貝殼快照）用現值近似 → 顯示「約 N」。
class StaticTokenEstimator {
  static Future<int> estimate() async {
    final charId = await UserSettings.getActiveCharacterId();
    final char = await DatabaseHelper.getCharacter(charId);
    final charDesc = char?['description'] as String? ?? '';
    final isSpiderWeb = (char?['is_spider_web_enabled'] as int? ?? 0) == 1;
    final charName = await UserSettings.getCharacterName();
    final whisperModelOverride =
        (char?['whisper_model_override'] as int? ?? 1) == 1;
    final contextMode = await ContextModeSettings.effectiveMode(charId);
    final persona = (await UserPersonaService.resolveForNewWindow(
      characterId: charId,
      contextMode: contextMode,
    )).persona;
    final nickname = persona.displayName;
    final toolFeatures = await ToolFeatureSettings.loadForContext(contextMode);

    final parts = <String>[];

    final systemPrompt = persona.promptContent;
    if (systemPrompt.isNotEmpty) parts.add(systemPrompt);
    if (charDesc.isNotEmpty) {
      parts.add(
        '${L.pick(en: '【Character Profile】', zhTW: '【角色設定】')}\n$charDesc',
      );
    }
    final selfNotesEnabled =
        contextMode == ContextMode.daily &&
        await MemorySettings.getSelfNotesEnabled();
    final selfNotes = selfNotesEnabled
        ? await DatabaseHelper.getSelfNotesForPrompt(
            charId,
            limit: await MemorySettings.getSelfNotesInjectionLimit(),
          )
        : '';
    if (selfNotes.isNotEmpty) {
      parts.add(
        '${L.pick(en: '【Self-notes (previously written by you)】', zhTW: '【自我註記（你過去為自己記下的）】')}\n$selfNotes',
      );
    }
    // 貝殼快照句（長度近似固定）
    if (toolFeatures.toolPromptsEnabled &&
        toolFeatures.shellEconomyEnabled &&
        toolFeatures.coinSnapshotEnabled) {
      parts.add(
        L.pick(
          en: '【Shell Balance Snapshot】At the start of this chat window: your balance is 8888 shells; the user balance is 8888 shells. This static snapshot is kept stable for prompt caching. Later daily grants, transfers, and scratch-card changes are provided as deltas in dynamic context; always follow the latest delta when present.',
          zhTW:
              '【貝殼餘額快照】本聊天窗口開篇時：你的餘額 8888 貝殼；用戶餘額 8888 貝殼。此靜態快照為了穩定 prompt cache 不再改動；後續每日發放、轉帳與刮刮卡變動會在動態上下文以增減量補充，有變動時以最新增減量為準。',
          zhCN:
              '【贝壳余额快照】本聊天窗口开篇时：你的余额 8888 贝壳；用户余额 8888 贝壳。此静态快照为了稳定 prompt cache 不再改动；后续每日发放、转账与刮刮卡变动会在动态上下文以增减量补充，有变动时以最新增减量为准。',
        ),
      );
    }

    // 工具區
    final tools = <String>[];
    if (toolFeatures.toolPromptsEnabled &&
        contextMode == ContextMode.daily &&
        isSpiderWeb) {
      tools.add(
        await SpiderWebService.abilityPrompt(
          userNickname: nickname,
          characterId: charId,
          characterName: charName,
          emotionEnabled: await MemorySettings.isAbilityEnabled('emotion'),
          bioclockEnabled: await MemorySettings.isAbilityEnabled('bioclock'),
        ),
      );
    } else if (toolFeatures.toolPromptsEnabled) {
      if (await MemorySettings.getMemoryWriteEnabled()) {
        tools.add(
          contextMode == ContextMode.rp
              ? RpMemoryService.abilityPrompt(
                  userNickname: nickname,
                  characterName: charName,
                )
              : MemoryActions.abilityPrompt(
                  userNickname: nickname,
                  characterName: charName,
                ),
        );
      }
      if (await MemorySettings.isAbilityEnabled('emotion')) {
        tools.add(EmotionCoordinates.abilityPrompt());
      }
      if (await MemorySettings.isAbilityEnabled('bioclock')) {
        tools.add(BioClockService.abilityPrompt());
      }
    }
    if (toolFeatures.toolPromptsEnabled &&
        toolFeatures.imageGenerationEnabled &&
        await MemorySettings.isAbilityEnabled('imagegen') &&
        await ImageGenService.isConfigured()) {
      tools.add(ImageGenService.abilityPrompt());
    }
    if (toolFeatures.toolPromptsEnabled && toolFeatures.shopEnabled) {
      tools.add(ToolPrompts.shop());
    }
    if (toolFeatures.modelGreetingEnabled) {
      tools.add(ToolPrompts.homeNote());
    }
    if (toolFeatures.toolPromptsEnabled && whisperModelOverride) {
      tools.add(
        ToolPrompts.whisper(characterName: charName, userNickname: nickname),
      );
    }
    if (toolFeatures.toolPromptsEnabled && toolFeatures.scratchEnabled) {
      tools.add(ToolPrompts.scratchCard());
    }
    if (toolFeatures.toolPromptsEnabled && toolFeatures.transferEnabled) {
      tools.add(ToolPrompts.transfer());
    }
    if (toolFeatures.toolPromptsEnabled && contextMode == ContextMode.daily) {
      tools.add(ToolPrompts.voiceCall());
    }
    if (toolFeatures.toolPromptsEnabled &&
        toolFeatures.dailyLifeToolsAllowed(contextMode) &&
        await XPostSettings.isEnabled(charId)) {
      tools.add(ToolPrompts.xPost());
    }
    if (toolFeatures.toolPromptsEnabled) {
      final sticker = await StickerService.buildStickerPrompt(
        characterId: charId,
      );
      if (sticker.isNotEmpty) tools.add(sticker);
    }
    if (tools.isNotEmpty) {
      parts.add('${ToolPrompts.toolHeader()}\n\n${tools.join('\n\n')}');
    }

    if (toolFeatures.toolPromptsEnabled &&
        await MemorySettings.isAbilityEnabled('bioclock')) {
      final habits = await BioClockService.habitListPrompt(charId);
      if (habits.isNotEmpty) parts.add(habits);
    }

    return TokenEstimator.estimate(parts.join('\n\n'));
  }

  /// 開關切換後調用：cache 開啟且目前已有命中時，先提示可能增加成本。
  static Future<void> showAfterToggle(BuildContext context) async {
    if (!await MemorySettings.getEnablePromptCaching()) return;
    if (CacheSession.hasCacheHitForCurrentConversation) {
      if (!context.mounted) return;
      showThemedPillNotice(
        context,
        L.pick(
          en: 'This will break the current cache hit and may incur extra cost.',
          zhTW: '將會打斷現有緩存命中，可能造成額外消耗',
          zhCN: '将会打断现有缓存命中，可能造成额外消耗',
        ),
        duration: const Duration(seconds: 3),
      );
      return;
    }
    final tokens = await estimate();
    if (!context.mounted) return;
    showThemedPillNotice(
      context,
      L.pick(
        en: 'Static cache tokens: ~$tokens',
        zhTW: '當前靜態緩存 token：約 $tokens',
      ),
      duration: const Duration(seconds: 2),
    );
  }
}
