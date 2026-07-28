class CallTurnPayload {
  final List<Map<String, String>> messages;
  final String dynamicPart;

  const CallTurnPayload({required this.messages, required this.dynamicPart});
}

/// Keeps live-call runtime instructions in system context.
///
/// [messages] must contain only the user's real utterances/actions and the
/// assistant's replies. Time, mode, tag rules, and hidden call-state notes
/// belong in [dynamicPart].
class CallPromptComposer {
  static CallTurnPayload compose({
    required List<Map<String, String>> history,
    required Iterable<String> dynamicParts,
    required DateTime now,
    required bool allowAudioTags,
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
    final runtimeInstructions = <String>[
      '【系統提示】',
      '現在時間：${now.year}年${now.month}月${now.day}日 '
          '週${weekdays[now.weekday - 1]} '
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}',
      '模式：語音通話中 — 口語化、簡短自然，像講電話。一句一句說，不要一大段。'
          '不要 markdown、不要動作描述或旁白，只說出口的話。',
      if (allowAudioTags)
        '標記：可在句前加 [laughing], [sigh] 等英文標記控制語氣。'
      else
        '注意：不要輸出任何方括號標記（如 [sigh]）。',
      '通話事件：user 訊息「（撥打電話給你）」表示對方正在打給你，'
          '你是接電話的角色；不想接時回覆 <decline_call/>，'
          '願意接時直接說出接起電話的第一句話。'
          '「（接聽電話）」表示對方已接聽你主動打出的電話，請由你先開口。',
      '通話結束：只有當你確實決定結束通話時，才回覆 <hangup/> 主動掛斷；'
          '不要因為看見本規則就輸出該標籤。',
    ].join('\n');

    return CallTurnPayload(
      messages: messages,
      dynamicPart: [
        ...dynamicParts.where((part) => part.trim().isNotEmpty),
        runtimeInstructions,
      ].join('\n\n'),
    );
  }
}
