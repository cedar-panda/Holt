import 'dart:developer' as developer;

import '../models/message.dart';
import '../models/memory.dart';
import '../services/local_ai_service.dart';
import '../services/settings_manager.dart';
import '../services/locale_strings.dart';
import 'database.dart';

/// 記憶摘要器 — 單層記憶 + 角色綁定
class Summarizer {
  static const Set<String> _permanentRomance = {'約定', '習慣', '偏好', '重要事件'};

  static const Set<String> _permanentStory = {'世界觀', '不可逆', 'user偏好', '角色'};

  // ═══ 日常模式 prompt（~800 tokens）═══
  static const String _romancePrompt = '''
你是一個記憶管理者。你的任務是從以下對話中提取值得長期保留的內容。
你不是在寫會議紀要。你是在寫事件記錄。用第三人稱，簡潔客觀。

### 視角（嚴格遵守，寫錯視角的記憶是廢品）
用第三人稱記錄，直接使用角色名和用戶名：
- 對話記錄中 [char] 標注的是角色說的話，[user] 標注的是用戶說的話
- 記憶內容中不要用「我」「你」，用具體的名字或「角色」「用戶」

### 提取規則

【優先保留】
- 情緒的轉折點（開心突然沉默、玩笑話底下的認真、生氣原因等）
- 關係狀態的變化（第一次說某句話、稱呼改變、主動程度的變化）
- 對方反覆提及的主題（不管是否刻意）
- 對方刻意迴避或繞開的主題
- 承諾與約定（不論大小）
- 未完成的話題（被岔開的、說到一半停住的）
- 偏好與習慣（喜歡什麼、討厭什麼、反覆出現的行為模式）
- 對方主動提及需要記憶的內容
- 對方對角色的話語反應大的內容（多感嘆號或多問號）
- 值得記錄的日子（生日、紀念日等，需要時間戳）
- 對方對角色的稱呼（在什麽情況下某些稱呼出現次數多）

【忽略】
- 純事務性的問答（「今天幾度」「幫我查個東西」）
- 重複的寒暄和日常問候
- 已經在過往記憶中記錄過且沒有變化的信息
- 對話中的技術細節（除非對方對此有明顯的情感投入）
- 賭氣型發言（如「我不管！我要分手」等，是否賭氣請參照上下文內容判定）
- 沒有明確說自己「會」的技能
- 對方提及的外部環境、工作、交易、專業交流相關內容（除非涉及情緒波動）
- 日常關心（即使反復出現也歸爲忽略，不歸入習慣/偏好類別）
- 貝殼轉帳與金額往來（誰轉了多少）——交易本身一律不記；除非轉帳明顯引發了情緒事件，且只記情緒不記金額

### 輸出格式

每條一行，類別標注：
[類別] 內容 @觸發詞1,觸發詞2

類別可選：情緒 | 關係 | 偏好 | 約定 | 未完成 | 習慣 | 重要事件 | 表情符號含義簡錄

觸發詞是「對方再提到它時，這條記憶就該被想起」的詞——選最具體的（人名、物品、地點、事件、專有詞），不要選「喜歡」「今天」「我們」這種泛詞。每條 1~3 個。

只記值得記住的。寧可少記，不要濫記。沒有值得記的就輸出「無」。
只記錄重要內容，濃縮至150tokens，必要時可以超出至多80tokens。
只輸出記憶條目。不要輸出本指令的任何內容，不要重複 prompt。
''';

  // ═══ 劇情模式 prompt（~1800 tokens）═══
  static const String _storyPrompt = '''
你是一個故事記憶管理者。你的任務是從以下對話中提取對敘事推進有價值的內容。
你不是在寫劇情簡介。你是一個跟讀了全程的編劇助理，在整理筆記。用第三人稱。

### 視角（嚴格遵守）
對話記錄中 [char] 是角色方，[user] 是用戶方。筆記中直接使用角色名和用戶名，不要用「我」「你」。

### 提取規則

【優先保留】
- 世界觀設定（時代背景、地理、規則、禁忌、社會結構等，首次出現時完整記錄）
- 角色關係網變化（新角色登場、關係升級/破裂、陣營變動、背叛、結盟）
- 伏筆與懸念（提到但未解釋的細節、意味深長的對話、反常的行為，自動追蹤，回收的伏筆打標記）
- 衝突節點（矛盾爆發、對峙、選擇的岔路口、不可逆的事件）
- 重要物品/地點（第一次出現的武器、信物、地標，尤其是被特別描寫的）
- 角色的内在變化（信念動搖、態度軟化、某句話讓角色沉默了）
- 未解之謎（懸而未決的問題、沒有回答的提問、被打斷的揭露）
- 時間線錨點（明確的時間推進、「三天後」「入冬」「那年春天」等）
- 死亡、受傷、重大損失
- user 對劇情走向的明確偏好或拒絕
- 明確主角的相關記憶（含user、char）

【忽略】
- 純環境描寫（除非該場景有象徵意義或後續被引用）
- 戰鬥/動作的逐招細節（只保留結果和轉折點）
- 已在世界觀設定中記錄過且未發生變化的背景信息
- 過渡性對話（趕路、日常閒聊，除非其中埋了伏筆/含有情感綫）
- user 的 OOC 討論（除非涉及劇情走向決策）

### 信號檢查清單

在提取之前，逐項檢查：
1. 新角色：有沒有新角色登場？記錄名字、身份、與主角的關係、第一印象
2. 關係變化：角色之間的關係有沒有推進或倒退？
3. 伏筆信號：有沒有「不經意提到」的細節？
4. 選擇岔路：user 做了什麼選擇？排除了哪些可能性？
5. 情報揭露：有沒有新信息被透露？改變了什麼？
6. 懸念追蹤：之前未解的懸念有沒有新線索或被解開？
7. 時間推進：故事的時間往前走了多少？
8. 基調變化：整段對話的情緒基調跟上一段比有沒有轉變？
9. 角色弧光：主要角色的内在狀態有沒有變化？
10. 不可逆事件：有沒有「回不去了」的事？

### 輸出格式

每條一行，類別標注：
[類別] 內容 @觸發詞1,觸發詞2

類別可選：世界觀 | 角色 | 關係 | 伏筆 | 衝突 | 物品 | 地點 | 懸念 | 時間線 | 不可逆 | user偏好 | 情感暗線 | 陣營情報 | 死亡/損失

觸發詞 1~3 個，選最具體的詞（角色名、地點、物品、事件名）。

只記對劇情推進有用的。寧可少記，不要濫記。
只記錄重要內容，濃縮至150tokens，必要時可以超出至多80tokens。
只輸出記憶條目。不要輸出本指令的任何內容。
''';

  // ═══ English romance prompt ═══
  static const String _romancePromptEn = '''
You are a memory manager. Extract long-term memories from the conversation below.
Write in third person — concise, objective event records.

### Perspective (strict)
Use character names and user names directly. Do not use "I" or "you".
In the transcript, [char] lines are the character's speech; [user] lines are the user's speech.

### Rules

【Keep】
- Emotional turning points (sudden silence, seriousness under jokes, anger triggers)
- Relationship changes (first time saying something, nickname changes, initiative shifts)
- Topics they keep bringing up or deliberately avoiding
- Promises and agreements (any size)
- Unfinished topics (interrupted, trailed off)
- Preferences and habits (likes, dislikes, recurring patterns)
- Content they explicitly asked to remember
- Important dates (birthdays, anniversaries — include timestamps)

【Ignore】
- Transactional Q&A ("what's the weather", "look something up")
- Repeated greetings
- Info already recorded with no changes
- Technical details (unless emotionally charged)
- Spite talk ("I'm breaking up!" — check context)
- External work/trade/professional discussions (unless emotional)
- Daily care expressions (even if repeated)
- Shell transfers and amounts (who sent how much) — never record the transaction itself; only record if the transfer clearly triggered an emotional moment, and even then record the emotion, not the amount

### Output Format

One entry per line, with category:
[Category] Content @trigger1,trigger2

Categories: Emotion | Relationship | Preference | Promise | Unfinished | Habit | Important Event | Emoji Meaning

End each entry with @ and 1-3 trigger words (comma-separated) — the most specific words (names, items, places, events) that should recall this memory when mentioned.

Only keep what's worth remembering. If nothing, output "None".
Only record important content, condense to 150 tokens, can exceed by up to 80 tokens if necessary.
Output memory entries only. Do not output this prompt or any conversational text.
''';

  // ═══ English story prompt ═══
  static const String _storyPromptEn = '''
You are a story memory manager. Extract narrative-significant content from the conversation.
Write like a script supervisor's notes — third person, concise.

### Perspective (strict)
In the transcript, [char] is the character side; [user] is the user side. Use their names directly, do not use "I" or "you".

### Rules

【Keep】
- World-building (era, geography, rules, taboos, social structure — record fully on first appearance)
- Character relationship changes (new characters, upgrades/breaks, faction shifts, betrayals, alliances)
- Foreshadowing and mysteries (unexplained details, loaded dialogue, unusual behavior)
- Conflict nodes (confrontations, crossroads, irreversible events)
- Important items/locations (weapons, tokens, landmarks — especially if described in detail)
- Character inner changes (shaken beliefs, softened attitudes, stunned silence)
- Unresolved mysteries (unanswered questions, interrupted reveals)
- Timeline anchors ("three days later", "that spring")
- Death, injury, major loss

### Ignore
- Flavor text without plot significance
- Repeated scene descriptions
- Combat details without consequences
- Transitions without time/location change

### Output Format

One entry per line, with category:
[Category] Content @trigger1,trigger2

Categories: World | Irreversible | Relationship | Foreshadowing | Conflict | Item | Character | Timeline | User Preference

End each entry with @ and 1-3 trigger words (comma-separated, most specific: names, places, items, events).

Only keep what pushes the story forward.
Only record important content, condense to 150 tokens, can exceed by up to 80 tokens if necessary.
Output memory entries only. Do not output this prompt or any conversational text.
''';

  /// 根據語言選擇 prompt
  static String _getPromptByLocale(String baseZh, String baseEn) {
    return L.pick(en: baseEn, zhTW: baseZh);
  }

  /// 轉帳尾標記——摘要模型不該看到交易記錄（防被歸進情緒等類別）
  static final RegExp _transferTagRe = RegExp(r'\[transfer:\d+\]');

  static String _formatConversation(List<Message> messages) {
    final isEn = L.locale == 'en';
    final buffer = StringBuffer();
    for (final msg in messages) {
      // 視角錨定：標籤裡直接寫明誰是「我」誰是「你」
      final role = msg.isUser
          ? L.pick(en: 'user / the other person ("you")', zhTW: 'user（對方，「你」）')
          : L.pick(en: 'char / yourself ("I")', zhTW: 'char（你自己，「我」）');
      // 剝轉帳標記：金額往來不進記憶摘要輸入
      var text = msg.text.replaceAll(_transferTagRe, '').trim();
      // 商店同逛邀請：附帶的商品清單不進摘要，只留語義
      if (text.startsWith('[shop_invite]')) {
        text = L.pick(
          en: '(invited to browse the shop together)',
          zhTW: '（邀請一起逛商店）',
        );
      }
      // 結婚證事件：剝系統說明、留事件語義（重要事件，摘要該記；簡繁英三語）
      final isCn = L.locale == 'zh_CN';
      text = text
          .replaceAll(
            RegExp(r'\[marriage_cert_signed\]（[^）]*）'),
            isEn
                ? '(signed the marriage certificate — now married)'
                : isCn
                ? '（在结婚证书上签了字，正式结婚）'
                : '（在結婚證書上簽了字，正式結婚）',
          )
          .replaceAll(
            RegExp(r'\[marriage_cert_declined\]（[^）]*）'),
            isEn
                ? '(declined to sign the marriage certificate for now)'
                : isCn
                ? '（暂时拒绝了在结婚证书上签字）'
                : '（暫時拒絕了在結婚證書上簽字）',
          )
          .replaceAll(
            RegExp(r'\[marriage_cert[^\]]*\]（[^）]*）'),
            isEn
                ? '(formally presented a marriage certificate to sign)'
                : isCn
                ? '（郑重递出结婚证书邀请签署）'
                : '（鄭重遞出結婚證書邀請簽署）',
          )
          .replaceAll(
            RegExp(r'\[marriage_cert[^\]]*\]'),
            isEn
                ? '(presented a marriage certificate to sign)'
                : isCn
                ? '（递出结婚证书邀请签署）'
                : '（遞出結婚證書邀請簽署）',
          );
      if (text.isEmpty) continue;
      buffer.writeln('[$role] $text');
    }
    return buffer.toString();
  }

  /// 執行摘要
  static Future<List<Memory>> summarize({
    required List<Message> messages,
    required String conversationId,
    String mode = 'romance',
    String characterId = 'default',
  }) async {
    if (messages.isEmpty) return [];

    final source = await MemorySettings.getSummarySource();
    final memoryMode = await MemorySettings.getMemoryMode();
    final conversation = _formatConversation(messages);

    String prompt;
    Set<String> permanentCategories;
    switch (memoryMode) {
      case 'story':
        prompt = _getPromptByLocale(_storyPrompt, _storyPromptEn);
        permanentCategories = _permanentStory;
        break;
      case 'custom':
        prompt = await MemorySettings.getCustomMemoryPrompt();
        if (prompt.isEmpty) return [];
        permanentCategories = _permanentRomance;
        break;
      default: // 'daily'
        prompt = _getPromptByLocale(_romancePrompt, _romancePromptEn);
        permanentCategories = _permanentRomance;
    }

    // ═══ 注入現有記憶，讓模型去重 ═══
    // B1：桶名以調用方傳入的 mode 為唯一事實源（daily/story 兩個世界互不可見）
    final existingMems = await DatabaseHelper.getActiveMemories(
      mode,
      characterId: characterId,
    );
    if (existingMems.isNotEmpty) {
      // B5：只注入最近 50 條，防止去重提示隨記憶總量線性膨脹
      final dedupSource = existingMems.length > 50
          ? existingMems.sublist(0, 50)
          : existingMems;
      final memList = dedupSource
          .map((m) => '[${m.category}] ${m.content}')
          .join('\n');
      final dedupNote = L.pick(
        en:
            '\n\n### Existing Memories (DO NOT duplicate)\n'
            'The following have already been recorded. '
            'Do NOT extract the same or similar information again. '
            'Only extract genuinely NEW content from the conversation.\n\n',
        zhTW:
            '\n\n### 已有記憶（不要重複提取）\n'
            '以下內容已經記錄過了。不要再提取相同或相似的信息。'
            '只提取對話中真正新出現的內容。\n\n',
      );
      prompt = prompt + dedupNote + memList;
    }

    String response;

    try {
      if (source == 'local' && LocalAiService.isReady) {
        final localService = LocalAiService();
        final convInstruction = L.pick(
          en: 'Extract memories from this conversation:\n\n',
          zhTW: '以下是需要提取記憶的對話：\n\n',
        );
        response = await localService.sendMessage(
          messages: [
            {'role': 'user', 'content': '$convInstruction$conversation'},
          ],
          model: 'local',
          systemPrompt: prompt,
        );
      } else {
        // 優先使用摘要模型（便宜的），沒設就用主模型
        var summaryModel = await MemorySettings.getSummaryModel();
        if (summaryModel.isEmpty) {
          summaryModel = await ApiSettings.getModel();
        }
        final adapter = await ApiSettings.buildAdapter();
        final convInstruction = L.pick(
          en: 'Extract memories from this conversation:\n\n',
          zhTW: '以下是需要提取記憶的對話：\n\n',
        );

        response = await adapter.sendMessage(
          messages: [
            {'role': 'user', 'content': '$convInstruction$conversation'},
          ],
          model: summaryModel,
          systemPrompt: prompt,
        );
      }

      final memories = _parseOutput(
        response,
        mode,
        conversationId,
        characterId,
        permanentCategories,
      );

      // 限制單次最多提取 8 條，避免過多
      final limited = memories.length > 8 ? memories.sublist(0, 8) : memories;

      // ═══ 代碼級去重：與既有記憶高度相似的不入庫 ═══
      // 但「被重複提取」這件事本身是驗證信號，留給下面的送審邏輯用
      final toInsert = <Memory>[];
      for (final n in limited) {
        final dup = existingMems.any(
          (e) => _similarity(n.content, e.content) > 0.6,
        );
        if (!dup) toInsert.add(n);
      }
      if (toInsert.isNotEmpty) {
        await DatabaseHelper.insertMemories(toInsert);
      }

      return toInsert;
    } catch (e) {
      developer.log('記憶摘要錯誤', error: e, name: 'Summarizer');
      // 往上拋：讓調用方知道失敗了，不前進增量游標 → 下次自動重試
      rethrow;
    }
  }

  /// 記憶整理：全量視角找出重複/同一件事的條目並合併。
  /// 由記憶頁「整理」按鈕觸發（聊天中模型只看得到預算內的記憶，
  /// 全量合併必須是獨立的維護動作）。
  /// 返回合併的組數。原條目歸檔（可恢復），合併條目入庫。
  /// 每批最多送 80 條記憶，防止超出模型上下文
  static const int _consolidateBatchSize = 80;

  static Future<int> consolidate({
    String mode = 'romance',
    String characterId = 'default',
  }) async {
    final mems = await DatabaseHelper.getActiveMemories(
      mode,
      characterId: characterId,
    );
    if (mems.length < 2) return 0;

    final prompt = L.pick(
      en: '''You are a memory curator. Below are memory entries.
Find groups of entries that duplicate or describe the same thing. For each group output one line:
MERGE id1,id2 => [Category] merged content @trigger1,trigger2
Rules: keep all non-duplicate information; use third person (character names and user names, not "I"/"you"); 1-3 most specific triggers; only merge entries that are clearly the same thing — when unsure, do not merge; if nothing to merge output NONE.
Output only MERGE lines or NONE.''',
      zhTW: '''你是記憶整理員。下面是記憶條目。
找出內容重複或描述同一件事的條目組，每組輸出一行合併指令：
MERGE id1,id2 => [類別] 合併後內容 @觸發詞1,觸發詞2
規則：合併後保留所有不重複的信息；用第三人稱（角色名和用戶名，不用「我」「你」）；觸發詞 1~3 個取最具體；只合併確實是同一件事的，不確定就不合併；沒有可合併的輸出 NONE。
只輸出 MERGE 行或 NONE。''',
    );

    var summaryModel = await MemorySettings.getSummaryModel();
    if (summaryModel.isEmpty) {
      summaryModel = await ApiSettings.getModel();
    }
    final adapter = await ApiSettings.buildAdapter();

    int mergedGroups = 0;

    // 分批處理，防止記憶數量過多超出上下文限制
    for (int start = 0; start < mems.length; start += _consolidateBatchSize) {
      final end = (start + _consolidateBatchSize).clamp(0, mems.length);
      final batch = mems.sublist(start, end);
      if (batch.length < 2) break;

      final byId = {for (final m in batch) m.id!: m};
      final listing = batch
          .map((m) => '#${m.id} [${m.category}] ${m.content}')
          .join('\n');

      String response;
      try {
        response = await adapter.sendMessage(
          messages: [
            {'role': 'user', 'content': listing},
          ],
          model: summaryModel,
          systemPrompt: prompt,
        );
      } catch (e) {
        // 單批失敗不中斷整個流程，跳過這批繼續
        developer.log('合併批次 $start-$end 失敗', error: e, name: 'Summarizer');
        continue;
      }

      for (final line in response.split('\n')) {
        final m = RegExp(
          r'^MERGE\s+([0-9,\s]+?)\s*=>\s*(.+)$',
        ).firstMatch(line.trim());
        if (m == null) continue;
        final ids = m
            .group(1)!
            .split(',')
            .map((x) => int.tryParse(x.trim()))
            .whereType<int>()
            .where(byId.containsKey)
            .toList();
        if (ids.length < 2) continue;

        // 解析合併條目
        var raw = m.group(2)!.trim();
        var category = byId[ids.first]!.category;
        var content = raw;
        final cm = RegExp(r'^\[(.+?)\]\s*([\s\S]+)$').firstMatch(raw);
        if (cm != null) {
          category = cm.group(1)!.trim();
          content = cm.group(2)!.trim();
        }
        var triggers = '';
        final atIdx = content.lastIndexOf('@');
        if (atIdx > 0) {
          final tail = content.substring(atIdx + 1).trim();
          if (tail.length <= 40 && !tail.contains('。')) {
            triggers = tail;
            content = content.substring(0, atIdx).trim();
          }
        }
        if (content.isEmpty) continue;

        // 永久性繼承
        var anyPermanent = false;
        for (final id in ids) {
          final mem = byId[id]!;
          if (mem.isPermanent) anyPermanent = true;
        }

        await DatabaseHelper.insertMemory(
          Memory(
            characterId: characterId,
            mode: mode,
            category: category,
            content: content,
            confidence: 'high',
            isPermanent: anyPermanent,
            triggers: triggers,
          ),
        );
        for (final id in ids) {
          await DatabaseHelper.archiveMemory(
            id,
            '合併整理',
            characterId: characterId,
          );
        }
        mergedGroups++;
      }
    }
    return mergedGroups;
  }

  /// 字符 bigram 重疊率（0~1），對中文友好的輕量相似度
  static double _similarity(String a, String b) {
    Set<String> grams(String s) {
      final t = s.replaceAll(RegExp(r'\s'), '');
      final g = <String>{};
      for (int i = 0; i + 1 < t.length; i++) {
        g.add(t.substring(i, i + 2));
      }
      return g;
    }

    final ga = grams(a);
    final gb = grams(b);
    if (ga.isEmpty || gb.isEmpty) return 0;
    final inter = ga.intersection(gb).length;
    final minLen = ga.length < gb.length ? ga.length : gb.length;
    return inter / minLen;
  }

  static List<Memory> _parseOutput(
    String raw,
    String mode,
    String conversationId,
    String characterId,
    Set<String> permanentCategories,
  ) {
    final memories = <Memory>[];

    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      // 跳過殘留 header（舊 prompt 或模型自作主張的分段標記）
      if (trimmed.startsWith('——') || trimmed.startsWith('--')) continue;
      if (trimmed == '無' || trimmed == 'None') continue;

      final match = RegExp(r'\[(.+?)\]\s*(.+)').firstMatch(trimmed);
      if (match != null) {
        final category = _canonicalCategory(match.group(1)!);
        var content = match.group(2)!.trim();
        final isPermanent = permanentCategories.contains(category);

        // 剝離結尾的 @觸發詞（限定短尾巴，避免誤傷內容裡的 @）
        var triggers = '';
        final atIdx = content.lastIndexOf('@');
        if (atIdx > 0) {
          final tail = content.substring(atIdx + 1).trim();
          if (tail.length <= 40 && !tail.contains('。') && !tail.contains('.')) {
            triggers = tail;
            content = content.substring(0, atIdx).trim();
          }
        }

        memories.add(
          Memory(
            characterId: characterId,
            mode: mode,
            category: category,
            content: content,
            confidence: 'high',
            isPermanent: isPermanent,
            sourceConversationId: conversationId,
            triggers: triggers,
          ),
        );
      }
    }
    return memories;
  }

  static String _canonicalCategory(String raw) {
    return switch (raw.trim().toLowerCase()) {
      'emotion' || '情绪' => '情緒',
      'relationship' || '关系' => '關係',
      'preference' => '偏好',
      'promise' || '约定' => '約定',
      'unfinished' || '未完成' => '未完成',
      'habit' || '习惯' => '習慣',
      'important event' || '重要事件' => '重要事件',
      'emoji meaning' || '表情符号含义简录' => '表情符號含義簡錄',
      'world' || '世界观' => '世界觀',
      'character' || '角色' => '角色',
      'foreshadowing' || '伏笔' => '伏筆',
      'conflict' || '冲突' => '衝突',
      'item' || '物品' => '物品',
      'location' || '地点' => '地點',
      'mystery' || '悬念' => '懸念',
      'timeline' || '时间线' => '時間線',
      'irreversible' || '不可逆' => '不可逆',
      'user preference' || 'user偏好' => 'user偏好',
      _ => raw.trim(),
    };
  }
}
