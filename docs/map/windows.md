# 窗口與對話

## 它是做什麼的（一兩句話）
管理角色對話窗口、故事線與模式身分，並保存窗口的摘要游標、固定摘要、回覆版本、續接來源與 keep-alive 狀態。

## 資料存在哪（資料表 / SharedPreferences key）
- `conversations`：角色、`context_mode`、`continuity_id`、窗口摘要、游標、標題等。
- `messages`、`message_revisions`：正文、編輯與回覆版本。
- keep-alive 使用 SharedPreferences 的 `keepalive_*` 鍵，包含窗口、角色、模式、故事線、模型、提示快照與租約資訊。
- `ChatSessionIdentity` 將 conversation、character、mode、continuity、user persona、worldbook set 綁成快取身分。

## 誰寫入（檔案：函式）
- 建立／更新窗口：`lib/memory/database_conversations.dart:DatabaseHelper.createConversation`、`updateConversation`
- 故事線：`createRpStoryline`、`setDefaultRpStoryline`、`setRpStorylineArchived`
- 摘要窗口欄位：`ensureConversationWindowSummaryId`、`rotateConversationWindowSummaryId`、`setConversationPinnedSummaryIfAbsent`
- 編輯與回覆版本：`lib/memory/database_reply_variants.dart` 的編輯／版本操作。
- keep-alive：`lib/services/keep_alive_service.dart:KeepAliveService.rememberActiveWindow`、`start`

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- 窗口與歷史：`DatabaseHelper.getConversation`、`getPreviousConversationTurns`，進入訊息歷史。
- 續章來源：`lib/screens/chat_screen_rp_continuation.dart:_applyRpContinuationSource`，將選定的來源摘要與舊窗口尾部加入本次窗口內容。
- 固定窗口摘要／自我註記／貝殼快照：`chat_screen_prompt_parts.dart:_buildCommonStaticParts`，進 `windowPart`。
- keep-alive 恢復快照：`KeepAliveService.restore`、`claimVisibleWindow`，恢復已有的結構化提示與訊息。
- 回覆版本：`lib/screens/chat_screen_reply_variants.dart` 與 `database_reply_variants.dart` 綁定 user message revision。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
- 窗口列表：角色、故事線、模式與更新時間等資料庫條件。
- 歷史消息：conversation ID 與消息 ID／順序。
- 續章：由 user 選定來源窗口／摘要，不是向量召回。
- keep-alive：窗口身分與租約比對。

## 日常 / RP 差異
- 日常窗口綁 `context_mode=daily`。
- RP 窗口綁 `context_mode=rp`，另有 `continuity_id`／故事線與世界書範圍。
- RP 續章可選時間線／來源摘要；日常沒有 RP 故事投影。

## 相關開關
- 日常／RP 模式。
- keep-alive。
- 上下文限制、緩存命中與摘要設定。
- 回覆重生成／編輯流程。

## 量大時的風險
- `conversations` 與 `messages` 長大後，窗口列表、歷史載入與續接候選都會變慢。
- reply variants 與 revision 長期保留會增加查詢及儲存量。
- keep-alive 持有完整快照時，會增加本地序列化與背景任務成本。
- 快取 namespace 若身分欄位不一致，可能失效或錯用前綴；目前由 `ChatSessionIdentity` 防止跨窗口混用。
- 舊設定／備份若意外同時打開 cache 與上下文限制，`ModelCostPolicy` 依目前 provider／model 能力決定唯一有效模式；啟動與還原後同步正規化持久值，請求期仍保留唯讀 fail-closed 裁決。

## 相關測試檔
- `test/database_conversations_test.dart`
- `test/database_reply_variants_test.dart`
- `test/chat_session_identity_test.dart`
- `test/keep_alive_service_test.dart`

## ❓ 不確定的地方
- iOS 背景 keep-alive 的實際系統喚醒頻率不是由這些 Dart 服務單獨決定；目前代碼可確認 iOS 不註冊 Android WorkManager 背景任務，恢復時再處理。
- 續章畫面可顯示的摘要數量與 UI 文案不等於底層來源查詢上限，需以畫面與 service 共同核對。
