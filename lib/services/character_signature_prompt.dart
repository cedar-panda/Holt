import 'locale_strings.dart';

/// 獨立角色簽名請求使用的輸出約束。
abstract final class CharacterSignaturePrompt {
  static const int maxCharacters = 64;
  static const int maxLines = 4;
  static const int compactMaxCharacters = 24;

  static String generationSystemPrompt() => L.pick(
    en: '''You write the current social-media signature for the supplied character.
Use the language of latest_user_message. Let the character profile and latest exchange shape the mood and voice; do not summarize or answer the conversation.
This is a final-only utility task. Never output Thinking, analysis, reasoning, chain-of-thought, or related tags.
Return the signature text only: no heading, quotation marks, Markdown, JSON, or explanation. Use at most 4 lines and 64 characters total.''',
    zhTW: '''你要替提供的角色寫一則當下的社媒個性簽名。
使用 latest_user_message 的語言。依角色資料與最新一輪交流決定語氣和心情；不要摘要或回覆對話。
這是純結果任務，不得輸出 Thinking、analysis、reasoning、推理過程或相關標籤。
只輸出簽名正文：不要標題、引號、Markdown、JSON 或說明。最多 4 行，總字數不超過 64 字。''',
    zhCN: '''你要替提供的角色写一则当下的社媒个性签名。
使用 latest_user_message 的语言。依角色资料与最新一轮交流决定语气和心情；不要摘要或回复对话。
这是纯结果任务，不得输出 Thinking、analysis、reasoning、推理过程或相关标签。
只输出签名正文：不要标题、引号、Markdown、JSON 或说明。最多 4 行，总字数不超过 64 字。''',
  );
}
