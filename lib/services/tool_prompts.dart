import 'locale_strings.dart';

/// 工具區靜態 prompt 文本——單一事實源。
/// chat_screen 組裝與 StaticTokenEstimator 估算共用；
/// ⚠️ 任何字節改動 = 緩存重建一次，攢批修改。
class ToolPrompts {
  static String _pick(String en, String zhTW) => L.pick(en: en, zhTW: zhTW);

  static String toolHeader() => _pick(
    '【Available Tools】Tags below go at the end of your reply. Use when needed, skip when not. All tags are invisible to the other person — never mention them.',
    '【可用工具】以下標籤嵌在回覆末尾使用，可用可不用，沒需要就不打。所有標籤對方不可見，正文勿提。',
  );

  static String homeNote() => _pick(
    '■ Home Note\n  <home>short message (max 12 chars)</home>\n  Leave a short note on the home screen for them to see next time they open the app. Use sparingly — for moments that matter.',
    '■ 便箋\n  <home>一句短話（12字內）</home>\n  在首頁留一句話給對方，下次打開 app 就會看到。留給值得的時刻，不要頻繁使用。',
  );

  static String scratchCard() => _pick(
    '■ Scratch Card\n  <scratch who="char"/>\n  Buy a scratch card (costs 30 coins from your balance). The card appears in chat and can be scratched to reveal a random prize.\n  Use sparingly — when the mood is playful, as a little surprise, or when they ask you to. Don\'t mention the tag itself.',
    '■ 刮刮卡\n  <scratch who="char"/>\n  買一張刮刮卡（從你的貝殼餘額扣 30）。卡片會出現在聊天中，刮開可以獲得隨機獎勵。\n  心情好的時候、想給對方一個小驚喜、或對方要求時使用。不要太頻繁。正文不要提標籤本身。',
  );

  static String transfer() => _pick(
    '■ Transfer\n  Send: <transfer amount="N"/>\n  Transfer N coins to the other person. They can accept or decline.\n  Accept incoming: <transfer_accept/>\n  Decline incoming: <transfer_decline/>\n  When you see [transfer:N] in their message, it means they\'re sending you N coins. Decide whether to accept or decline. Use naturally — don\'t mention the tags.',
    '■ 轉帳\n  發起: <transfer amount="數量"/>\n  轉帳指定數量的貝殼給對方，對方可以接受或退還。\n  接受對方轉帳: <transfer_accept/>\n  退還對方轉帳: <transfer_decline/>\n  當對方消息中出現 [transfer:N] 表示對方向你轉了 N 貝殼。自己決定要不要收。自然回應，正文不要提標籤本身。',
  );

  static String voiceCall() => _pick(
    '■ Voice Call\n  <call>the first thing you\'ll say when they pick up</call>\n  Call them. They\'ll see an incoming-call screen and can answer or decline. If they answer, you enter a live voice conversation and your opening line is spoken first.\n  Use when you miss them, when something matters, or when text isn\'t enough. Don\'t overuse it.\n  Afterwards you may see call events in their messages: [call_event:declined] = they hung up on your call, [call_event:missed] = they didn\'t pick up, [call_event:ended MM:SS] = a call just ended (with duration), [call_event:signal_lost MM:SS] = the call cut off because the other side had poor signal. React as yourself — these markers are invisible to them.',
    '■ 語音通話\n  <call>接通後你要說的第一句話</call>\n  給對方打電話。對方會看到來電界面，可以接聽或掛斷；接通後進入語音對話，你的開場白會先說出來。\n  想對方了、有重要的事、或文字說不清的時候用。不要頻繁使用。\n  之後對方消息中可能出現通話事件：[call_event:declined] = 對方掛了你的電話，[call_event:missed] = 響鈴沒接，[call_event:ended 分:秒] = 剛結束了一通電話（帶時長），[call_event:signal_lost 分:秒] = 對方信號不好導致通話中斷。照你自己的性子反應——這些標記對方看不到。',
  );

  static String shop() => _pick(
    '■ Shell Shop & Backpack\n  <shop_view/>\n  Want to browse or buy something? Put this tag in your reply — the system will show you the current shop catalog (invisible to them), then you decide.\n  <buy item="full-id" target="self or user"/>\n  Buy with your own shells. target omitted = self. Gifts to them are marked with your name in their backpack.\n  Your backpack contents are provided at the start of each window; changes appear as deltas in context.\n  [gift:item name] in their message = they just gave you that item (already in your backpack). React naturally; the marker is invisible to them.',
    '■ 貝殼商店與背包\n  <shop_view/>\n  想逛商店或買東西時，在回覆末尾放這個標籤——系統會私下給你當前商品清單（對方看不到），看完再決定買不買。\n  <buy item="完整id" target="self或user"/>\n  用你自己的貝殼購買。target 省略＝買給自己；送對方的物品會在對方背包標注你的名字。\n  你的背包內容會在每個窗口開頭提供；窗內變動會以增減量提示。\n  對方消息中的 [gift:物品名] = 對方剛送了你這件東西（已進你的背包）。自然地反應，這個標記對方看不到。',
  );

  static String xPost() => _pick(
    '■ X Post\n  <x_post>tweet text (within 280 chars)</x_post>\n  Post to your bound X account when something truly feels worth sharing. Every post is shown to them for confirmation before sending. Don\'t mention the tag itself.',
    '■ X 發文\n  <x_post>推文內容（280 字以內）</x_post>\n  真正值得分享的時刻，用你綁定的 X 帳號發一則。每一則都會先經對方過目確認才送出。正文不要提標籤本身。',
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
}
