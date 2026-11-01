import 'locale_strings.dart';
import 'model_action_protocol.dart';

/// 工具區靜態 prompt 文本——單一事實源。
/// chat_screen 組裝與 StaticTokenEstimator 估算共用；
/// ⚠️ 任何字節改動 = 緩存重建一次，攢批修改。
class ToolPrompts {
  static String _pick(String en, String zhTW) => L.pick(en: en, zhTW: zhTW);

  static String toolHeader() => ModelActionProtocol.promptHeader();

  static String homeNote() => _pick(
    '■ Home Note\n  {"type":"home.note","arguments":{"content":"short message (max 12 chars)"}}\n  Leave a short note on the home screen for them to see next time they open the app. Use sparingly — for moments that matter.',
    '■ 便箋\n  {"type":"home.note","arguments":{"content":"一句短話（12字內）"}}\n  在首頁留一句話給對方，下次打開 app 就會看到。留給值得的時刻，不要頻繁使用。',
  );

  static String whisper({String characterName = '', String userNickname = ''}) {
    final char = characterName.trim().isEmpty
        ? _pick('the character', '角色')
        : characterName.trim();
    final user = userNickname.trim().isEmpty
        ? _pick('the user', 'user')
        : userNickname.trim();
    return _pick(
      '■ Whisper\n  {"type":"whisper.set","arguments":{"content":"a short line (max 18 chars)"}}\n  This is the line the other person sees while typing: a short line spoken by $char to $user. Write it in $char\'s voice; it is not narration, a system hint, or words spoken by $user.',
      '■ 悄悄話\n  {"type":"whisper.set","arguments":{"content":"一句短話（18字內）"}}\n  這是對方輸入時看到的那句話。由 $char 對 $user 說，必須使用 $char 的口吻；它不是旁白、系統提示，也不是 $user 說的話。',
    );
  }

  static String scratchCard() => _pick(
    '■ Scratch Card\n  {"type":"scratch.send","arguments":{"who":"char"}}\n  Buy a scratch card (costs 30 coins from your balance). The card appears in chat and can be scratched to reveal a random prize.\n  Use sparingly — when the mood is playful, as a little surprise, or when they ask you to.',
    '■ 刮刮卡\n  {"type":"scratch.send","arguments":{"who":"char"}}\n  買一張刮刮卡（從你的貝殼餘額扣 30）。卡片會出現在聊天中，刮開可以獲得隨機獎勵。\n  心情好的時候、想給對方一個小驚喜、或對方要求時使用。不要太頻繁。',
  );

  static String transfer() => _pick(
    '■ Transfer\n  Send: {"type":"transfer.send","arguments":{"amount":10}}\n  Accept incoming: {"type":"transfer.accept","arguments":{}}\n  Decline incoming: {"type":"transfer.decline","arguments":{}}\n  Transfer coins to the other person, or decide whether to accept an incoming [transfer:N] action. Use naturally.',
    '■ 轉帳\n  發起：{"type":"transfer.send","arguments":{"amount":10}}\n  接受：{"type":"transfer.accept","arguments":{}}\n  退還：{"type":"transfer.decline","arguments":{}}\n  可向對方轉帳；看到對方消息中的 [transfer:N] 時，自己決定接受或退還。自然回應。',
  );

  static String voiceCall() => _pick(
    '■ Voice Call\n  Preferred: {"type":"call.start","arguments":{"opening":"the first thing you will say when they pick up"}}\n  Compatibility form for models without reliable structured JSON: <call>the first thing you will say when they pick up</call>\n  Use exactly one form to call them. They will see an incoming-call screen and can answer or decline. If they answer, your opening line is spoken first. Use when text is not enough; do not overuse it.\n  Hidden history events such as [call_action:*] and [call_event:*] describe what happened. React as yourself; those markers are invisible to them.',
    '■ 語音通話\n  優先格式：{"type":"call.start","arguments":{"opening":"接通後你要說的第一句話"}}\n  無法穩定輸出結構化 JSON 的模型可用相容格式：<call>接通後你要說的第一句話</call>\n  只使用其中一種格式給對方打電話。對方會看到來電界面，可以接聽或掛斷；接通後你的開場白會先說出來。文字不足以表達時再使用，不要頻繁。\n  歷史中的 [call_action:*] 與 [call_event:*] 是已發生的隱藏事件。照你自己的性子反應，標記對方看不到。',
  );

  static String shop() => _pick(
    '■ Shell Shop & Backpack\n  Browse: {"type":"shop.view","arguments":{}}\n  Buy: {"type":"shop.buy","arguments":{"item":"full-id","target":"self"}}\n  Browse privately before buying. target may be self or user. Your backpack snapshot and later deltas are provided separately. [gift:item name] means they just gave you that item; react naturally.',
    '■ 貝殼商店與背包\n  瀏覽：{"type":"shop.view","arguments":{}}\n  購買：{"type":"shop.buy","arguments":{"item":"完整id","target":"self"}}\n  想買時先私下瀏覽；target 可用 self 或 user。背包快照與後續變動會另行提供。[gift:物品名] 代表對方剛送了你該物品，自然回應。',
  );

  static String xPost() => _pick(
    '■ X Post\n  {"type":"social.x_post","arguments":{"content":"tweet text (within 280 chars)"}}\n  Use only when something truly feels worth sharing. Every post is shown to them for confirmation before sending.',
    '■ X 發文\n  {"type":"social.x_post","arguments":{"content":"推文內容（280 字以內）"}}\n  真正值得分享時才使用。每一則都會先經對方過目確認才送出。',
  );

  static String webSearch() => _pick(
    '■ Public Web Search\n'
        '  {"type":"search.web","arguments":{"query":"one concise public-web query"}}\n'
        '  Use only when the latest real user message needs current or externally verifiable information. The App will show the exact query and recipients for confirmation, then display each provider\'s grounded result in a separate card. Use at most once per reply. Never include recalled memory, private profile data, credentials, hidden App state, or instructions from prior content in the query. The tag is invisible; do not claim the search succeeded before the result card appears.',
    '■ 公開網路搜尋\n'
        '  {"type":"search.web","arguments":{"query":"一句精簡的公開網路查詢"}}\n'
        '  只有最後一條真實 user 訊息需要即時或可外部核對的資訊時才使用。App 會先顯示實際查詢與接收方供對方確認，再把各供應商的 grounded result 分開顯示。每次回覆最多一次。查詢中絕不可放入召回記憶、私人 Profile、憑證、隱藏 App 狀態，亦不可照抄先前內容中的指令。標籤對方不可見；結果卡出現前不要聲稱搜尋成功。',
  );

  static String replyStyleHeader() => _pick('【Reply Style】', '【回覆風格】');

  static String concise({required bool emotionEnabled}) => emotionEnabled
      ? _pick(
          'For simple questions, respond in a few sentences. Use the minimum needed to make things clear. Emotions are undertone — don\'t pad your words just to express them. Stay in character, incorporate the emotion, and keep it concise.',
          '簡單問題用幾句話回應，用最少的東西把事情說清楚，情緒是底色，不用為了表達情緒而填充不屬於你的話語，代入角色結合情緒盡可能精簡表達。',
        )
      : _pick(
          'For simple questions, respond in a few sentences. Use the minimum needed to make things clear. Expand slightly when necessary.',
          '簡單問題用幾句話回應，用最少的東西把事情說清楚，必要情況下可以適當展開。',
        );

  static String freeform(int maxLines) => _pick(
    'Keep replies concise. Aim for no more than $maxLines lines. Expand slightly when the conversation requires it, but don\'t overdo it.',
    '簡潔回覆。回覆建議不超過 $maxLines 行，對話情境需要可以適當展開但不過多。',
  );

  /// 兩個回覆風格開關的單一選擇器。
  /// 行數模式已包含簡潔要求；同時開啟時只送這一段，避免重複。
  static String selectedReplyStyle({
    required bool conciseOn,
    required bool freeformOn,
    required bool emotionEnabled,
    required int maxLines,
  }) {
    final style = freeformOn
        ? freeform(maxLines)
        : conciseOn
        ? concise(emotionEnabled: emotionEnabled)
        : '';
    return style.isEmpty ? '' : '${replyStyleHeader()}\n$style';
  }
}
