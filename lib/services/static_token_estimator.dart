import 'package:flutter/material.dart';

import '../memory/database.dart';
import '../memory/emotion_coordinates.dart';
import 'bio_clock_service.dart';
import 'image_gen_service.dart';
import 'locale_strings.dart';
import 'memory_actions.dart';
import 'settings_manager.dart';
import 'shop_service.dart';
import 'spider_web_service.dart';
import 'sticker_service.dart';
import 'token_estimator.dart';
import 'tool_prompts.dart';
import 'x_post_settings.dart';

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
    final nickname = await UserSettings.getUserName();

    final parts = <String>[];

    final systemPrompt = await ApiSettings.getSystemPrompt();
    if (systemPrompt.isNotEmpty) parts.add(systemPrompt);
    if (charDesc.isNotEmpty) {
      parts.add(
        '${L.pick(en: '【Character Profile】', zhTW: '【角色設定】')}\n$charDesc',
      );
    }
    final selfNotes = await DatabaseHelper.getSelfNotes(charId);
    if (selfNotes.isNotEmpty) {
      parts.add(
        '${L.pick(en: '【Self-notes (previously written by you)】', zhTW: '【自我註記（你過去為自己記下的）】')}\n$selfNotes',
      );
    }
    // 貝殼快照句（長度近似固定）
    parts.add(
      L.pick(
        en: '【Shell Balance Snapshot】At the start of this chat window: your balance is 8888 shells; the user balance is 8888 shells. This static snapshot is kept stable for prompt caching. Later transfer/scratch changes are provided as deltas in dynamic context; always follow the latest delta when present.',
        zhTW:
            '【貝殼餘額快照】本聊天窗口開篇時：你的餘額 8888 貝殼；用戶餘額 8888 貝殼。此靜態快照為了穩定 prompt cache 不再改動；後續轉帳/刮刮卡變動會在動態上下文以增減量補充，有變動時以最新增減量為準。',
      ),
    );

    // 工具區
    final tools = <String>[];
    if (isSpiderWeb) {
      tools.add(
        await SpiderWebService.abilityPrompt(
          userNickname: nickname,
          characterId: charId,
          characterName: charName,
        ),
      );
    } else {
      if (await MemorySettings.getMemoryWriteEnabled()) {
        tools.add(
          MemoryActions.abilityPrompt(
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
    if (await ApiSettings.getApiProviderName() == 'openrouter' &&
        await MemorySettings.isAbilityEnabled('imagegen')) {
      tools.add(ImageGenService.abilityPrompt());
    }
    if (await ShopService.isEnabled()) tools.add(ToolPrompts.shop());
    tools.add(ToolPrompts.homeNote());
    tools.add(ToolPrompts.scratchCard());
    tools.add(ToolPrompts.transfer());
    tools.add(ToolPrompts.voiceCall());
    if (await XPostSettings.isEnabled(charId)) tools.add(ToolPrompts.xPost());
    final sticker = await StickerService.buildStickerPrompt(
      characterId: charId,
    );
    if (sticker.isNotEmpty) tools.add(sticker);
    parts.add('${ToolPrompts.toolHeader()}\n\n${tools.join('\n\n')}');

    if (await MemorySettings.isAbilityEnabled('bioclock')) {
      final habits = await BioClockService.habitListPrompt(charId);
      if (habits.isNotEmpty) parts.add(habits);
    }

    final conciseOn = await ApiSettings.getConciseMode();
    final freeformOn = await ApiSettings.getFreeformMode();
    if (conciseOn || freeformOn) {
      final style = <String>[];
      if (conciseOn) {
        style.add(
          ToolPrompts.concise(
            emotionEnabled: await MemorySettings.isAbilityEnabled('emotion'),
          ),
        );
      }
      if (freeformOn) {
        style.add(
          ToolPrompts.freeform(await ApiSettings.getFreeformMaxLines()),
        );
      }
      parts.add('${ToolPrompts.replyStyleHeader()}\n${style.join('\n')}');
    }

    return TokenEstimator.estimate(parts.join('\n\n'));
  }

  /// 開關切換後調用：cache 開啟才彈「當前靜態緩存 token：約 N」。
  static Future<void> showAfterToggle(BuildContext context) async {
    if (!await MemorySettings.getEnablePromptCaching()) return;
    final tokens = await estimate();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          L.pick(
            en: 'Static cache tokens: ~$tokens',
            zhTW: '當前靜態緩存 token：約 $tokens',
          ),
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
