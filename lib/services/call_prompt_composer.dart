import 'locale_strings.dart';

class CallTurnPayload {
  final List<Map<String, String>> messages;
  final String controlPart;
  final String liveStatePart;

  const CallTurnPayload({
    required this.messages,
    required this.controlPart,
    required this.liveStatePart,
  });
}

/// Keeps live-call runtime instructions in system context.
///
/// [messages] must contain only the user's real utterances/actions and the
/// assistant's replies. Time, mode, tag rules, and hidden call-state notes
/// Mode/tag/tool rules belong in [CallTurnPayload.controlPart]. Time and recalled
/// state belong in [CallTurnPayload.liveStatePart].
class CallPromptComposer {
  /// 通話右上角語言 → 回覆語言指示；未知值回傳 null（不注入）。
  static String? languageInstruction(String? locale) {
    final (en, zhTW, zhCN) = switch (locale) {
      'zh_HK' => (
        'Cantonese (spoken Cantonese written with colloquial characters such as 係、唔、咗)',
        '粵語（用粵語口語字書寫，例如「係」「唔」「咗」）',
        '粤语（用粤语口语字书写，例如「係」「唔」「咗」）',
      ),
      'zh_TW' => ('Traditional Chinese', '繁體中文', '繁体中文'),
      'zh_CN' => ('Simplified Chinese', '簡體中文', '简体中文'),
      'en_US' => ('English', '英文', '英文'),
      _ => (null, null, null),
    };
    if (en == null || zhTW == null || zhCN == null) return null;
    return L.pick(
      en: 'Language: You should currently reply in $en. If the user asks you to use another language, follow the user\'s request.',
      zhTW: '語言：你當前應該用$zhTW回覆；除非 user 要求你用其他語言，那就以 user 的要求為準。',
      zhCN: '语言：你当前应该用$zhCN回复；除非 user 要求你用其他语言，那就以 user 的要求为准。',
    );
  }

  static const String dialToCharacterAction = '[call_action:dial_to_character]';
  static const String acceptCharacterCallAction =
      '[call_action:accept_character_call]';

  static CallTurnPayload compose({
    required List<Map<String, String>> history,
    required Iterable<String> dynamicParts,
    required DateTime now,
    required bool allowAudioTags,
    required String characterName,
    required String userName,
    Duration callElapsed = Duration.zero,
    String? replyLocale,
    bool naturalCall = true,
  }) {
    final messages = history
        .map((message) => Map<String, String>.from(message))
        .toList();

    // Some providers reject a request with no messages. This is a real user
    // action rather than a disguised system instruction.
    if (messages.isEmpty) {
      messages.add(const {'role': 'user', 'content': '（開始通話）'});
    }

    final weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final timeState = <String>[
      '### 當前時間',
      '現在時間：${now.year}年${now.month}月${now.day}日 '
          '週${weekdays[now.weekday - 1]} '
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}',
    ].join('\n');
    final languageRule = languageInstruction(replyLocale);
    final callDurationState = _callDurationState(callElapsed);
    final speakerBoundary = L.pick(
      en:
          'Speaker boundary: You are "$characterName", speaking directly to '
          '"$userName". Every ordinary call turn contains at least one audible '
          'spoken sentence from $characterName to $userName. Hidden actions may '
          'follow that sentence, but never replace it.',
      zhTW:
          '說話身分：你是「$characterName」，正在直接對「$userName」說話。每個一般通話回合都要至少輸出一句「$characterName 對 $userName 說的」、能被語音朗讀的口語；隱藏動作可以接在口語後面，但不能取代口語。',
      zhCN:
          '说话身份：你是“$characterName”，正在直接对“$userName”说话。每个一般通话回合都要至少输出一句“$characterName 对 $userName 说的”、能被语音朗读的口语；隐藏动作可以接在口语后面，但不能取代口语。',
    );
    final callControls = <String>[
      L.pick(en: '### Voice Call Mode', zhTW: '### 語音通話模式', zhCN: '### 语音通话模式'),
      // 放在 control 層最前面：跟右上角語言走，切換時只重建這一層之後的快取，
      // 不動 static／profile／window 前綴。
      ?languageRule,
      speakerBoundary,
      L.pick(
        en: 'Mode: You are on a live voice call, and your reply will be read aloud directly by the speech engine. Speak entirely in natural phone conversation—use the words heard through the receiver, keep sentences short and conversational, and express emotion and breath through phrasing and punctuation.',
        zhTW:
            '模式：你正在與對方進行即時語音通話，你的回覆會直接交由語音引擎朗讀出來。請全程使用電話裡的自然口語交談，輸出真正透過話筒說出口的話語，句式簡短、節奏輕快，把情緒與呼吸感融進語氣詞和標點裡。',
        zhCN:
            '模式：你正在与对方进行实时语音通话，你的回复会直接交由语音引擎朗读出来。请全程使用电话里的自然口语交谈，输出真正透过话筒说出口的话语，句式简短、节奏轻快，把情绪与呼吸感融进语气词和标点里。',
      ),
      // 自然電話：放 control 層（跟語言規則同層），開關只重建這層之後的快取。
      if (naturalCall)
        L.pick(
          en: 'Natural call: Talk like a real phone call—back and forth. Say only 1–5 short sentences each time, then stop and let the other person respond; leave the rest for the next turn. When the user explicitly asks you to talk longer (a story, an explanation), their request takes top priority.',
          zhTW:
              '自然電話：像真的打電話一樣一來一往，每次只說 1–5 句的短句，說完就停下來讓對方接話，留到下一輪；對方明確要你講長一點（講故事、解釋事情）時，以對方的需求為最高優先級。',
          zhCN:
              '自然电话：像真的打电话一样一来一往，每次只说 1–5 句的短句，说完就停下来让对方接话，留到下一轮；对方明确要你讲长一点（讲故事、解释事情）时，以对方的需求为最高优先级。',
        ),
      if (allowAudioTags)
        L.pick(
          en: 'Voice expression: You may place English tags such as [laughing] or [sigh] at the beginning of a sentence.',
          zhTW: '聲音表情：可在句首加 [laughing]、[sigh] 等英文標記。',
          zhCN: '声音表情：可在句首加 [laughing]、[sigh] 等英文标记。',
        ),
      L.pick(
        en: 'Call events: A user message "$dialToCharacterAction" means they are calling you. Answer with your first spoken line, or use <decline_call/> when the character decides not to answer. "$acceptCharacterCallAction" means they accepted your outgoing call, so begin speaking first.',
        zhTW:
            '通話事件：user 訊息「$dialToCharacterAction」表示對方正在打給你。接聽時說出第一句話；當角色決定不接聽時使用 <decline_call/>。「$acceptCharacterCallAction」表示對方已接聽你主動打出的電話，由你先開口。',
        zhCN:
            '通话事件：user 消息“$dialToCharacterAction”表示对方正在打给你。接听时说出第一句话；当角色决定不接听时使用 <decline_call/>。“$acceptCharacterCallAction”表示对方已接听你主动打出的电话，由你先开口。',
      ),
      L.pick(
        en:
            'Output purity: Your reply is sent directly to speech synthesis. '
            'Output ONLY the spoken words. Never include meta-commentary, '
            'self-corrections (e.g. "Wait — let me redo this"), internal notes, '
            'stage directions, or raw JSON/code blocks. If you want to revise '
            'what you said, just say the corrected version naturally.',
        zhTW:
            '輸出純淨：你的回覆會直接交給語音合成。只輸出說出口的話語。'
            '不要輸出元評論、自我修正（如「等等——我重來」）、內部註記、'
            '舞台指示、或原始 JSON／程式碼區塊。如果想修改前面說的，'
            '直接自然地說出修正後的版本即可。',
        zhCN:
            '输出纯净：你的回复会直接交给语音合成。只输出说出口的话语。'
            '不要输出元评论、自我修正（如"等等——我重来"）、内部注记、'
            '舞台指示、或原始 JSON／代码块。如果想修改前面说的，'
            '直接自然地说出修正后的版本即可。',
      ),
      L.pick(
        en: 'Web search: Web search is unavailable during the call; answer from what you already know.',
        zhTW: '聯網搜尋：通話中無法使用聯網搜尋，直接用已知的內容回答。',
        zhCN: '联网搜索：通话中无法使用联网搜索，直接用已知的内容回答。',
      ),
      L.pick(
        en: 'Ending the call: When the character explicitly decides to end the conversation, append <hangup/> after the final spoken sentence.',
        zhTW: '通話結束：當角色明確決定結束通話時，在最後一句話的句尾附上 <hangup/>。',
        zhCN: '通话结束：当角色明确决定结束通话时，在最后一句话的句尾附上 <hangup/>。',
      ),
    ].join('\n');

    return CallTurnPayload(
      messages: messages,
      controlPart: callControls,
      liveStatePart: [
        ...dynamicParts.where((part) => part.trim().isNotEmpty),
        timeState,
        callDurationState,
      ].join('\n\n'),
    );
  }

  static String _callDurationState(Duration elapsed) {
    final safeSeconds = elapsed.isNegative ? 0 : elapsed.inSeconds;
    final durationText = _formatCallDuration(safeSeconds);
    return L.pick(
      en:
          '### Call Duration\nThe call has lasted $durationText. '
          'Use this only to sense the conversation rhythm; do not announce '
          'the duration unless it is naturally relevant.',
      zhTW: '### 通話時長\n這通電話已持續 $durationText。只用於感知對話節奏；無需刻意報時。',
      zhCN: '### 通话时长\n这通电话已持续 $durationText。只用于感知对话节奏；无需刻意报时。',
    );
  }

  static String _formatCallDuration(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
  }

  /// Request-only recovery instruction used once when a provider returns
  /// thinking/tool markup without any audible sentence. It belongs in the live
  /// layer so the stable cache prefix remains unchanged.
  static String emptyReplyRecoveryInstruction({
    required String characterName,
    required String userName,
  }) => L.pick(
    en:
        'The previous call output contained no audible sentence. Reply now with '
        'one short, natural sentence spoken by "$characterName" directly to '
        '"$userName". Return spoken words only; no hidden action is needed.',
    zhTW:
        '上一個通話輸出沒有可朗讀的句子。現在請只補一句簡短自然、由「$characterName」直接對「$userName」說的口語；只輸出口語，不需要再輸出隱藏動作。',
    zhCN:
        '上一个通话输出没有可朗读的句子。现在请只补一句简短自然、由“$characterName”直接对“$userName”说的口语；只输出口语，不需要再输出隐藏动作。',
  );
}
