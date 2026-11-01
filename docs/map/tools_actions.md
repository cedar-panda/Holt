# 工具與動作協議

## 它是做什麼的（一兩句話）
把模型想執行的功能動作統一成 Holt action，再交給本地工具執行器、記憶處理器或功能服務。可接受原生 tool call、JSON，並保留 XML 相容通道。

## 資料存在哪（資料表 / SharedPreferences key）
- 協議本身主要是請求／回覆記憶體物件：`ToolCall`、`HoltAction`、`ToolResult`。
- 實際結果寫入各功能自己的資料表，例如 `memories`、`pending_memory_actions`、`emotion_points`、`character_diaries`、`chat_diagnostics`。
- 功能開關由 `lib/services/tool_feature_settings.dart` 及其設定儲存處管理。

## 誰寫入（檔案：函式）
- 模型動作解碼：`lib/services/model_action_protocol.dart:ModelActionProtocol.decodeToolCalls`、`decodeJson`
- 舊格式正規化：`ModelActionProtocol.normalizeForLegacyProcessors`
- 執行與權限：`lib/services/tool_runner.dart:ToolRunner.run`
- 各功能 processor：`lib/services/memory_actions.dart:MemoryActions` 及日記、情緒、生物鐘、商店、婚姻、郵件等服務。
- 執行結果由各功能服務寫回自己的資料表或 SharedPreferences。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- 靜態工具說明：`lib/services/tool_prompts.dart:ToolPrompts`，由 `chat_screen_prompt_parts.dart:_buildCommonStaticParts` 分組加入 static prompt。
- 輸入框悄悄話：`ToolPrompts.whisper` 在穩定工具說明中定義 `whisper.set`；`lib/services/whisper_service.dart:WhisperService.runtimeInstruction` 在每輪 request-only 動態區帶入目前角色名與 user persona 名，限定內容只能是角色以自己的口吻對 user 說的短話。這個限制只作用於輸入框提示，不把日常模式變成 RP 身分鎖。
- 日常模式的模型主動來電以 `call.start` JSON action 為優先格式；`ToolPrompts.voiceCall` 同時提供 `<call>開場白</call>` 相容格式給無法穩定輸出結構化 JSON 的模型。兩者都由 `ModelActionProtocol.normalizeForLegacyProcessors` 匯入既有來電執行路徑，串流顯示由 `ModelStreamDecoder` 隱藏。
- RP 時間線／劇情狀態修正說明由 `lib/services/memory_actions.dart:MemoryActions.rpCorrectionRuntimeInstruction` 產生；只在 `isRpCorrectionIntent` 判定本輪確實為修正意圖時進 request-only 動態區，不常駐 static prompt。
- 動作結果與本輪證據由 `chat_screen_generation.dart:_sendMessageLocked` 組入 live state 或回覆處理流程。
- `chat.search` 的 SQLite 結果由 `chat_screen_generation.dart:_sendMessageLocked` 組成 request-only 二段檢索內容；`ConversationTimeContext.formatAbsoluteTimestamp` 把每條 `created_at` 格式化為完整年／月／日、星期與時：分，不再只給日期。
- 公開網路搜尋成功證據由 `WebSearchFollowUp.evidenceFor` 放入 request-only evidence；`WebSearchFollowUp.ensureGroundedReply` 會檢查最終正文，若較弱主模型只留下短確認句、沒有任何可辨識的搜索事實，則以已驗證且清理過的搜索供應端答案補足正文（最多 2200 字），避免「搜索成功但角色沒回答內容」。已有實質答案時不重複追加。部分失敗只向主模型提供「部分未取得可靠證據」的語義狀態。若全部來源失敗，`WebSearchFollowUp.hasNoVerifiedEvidence` 會跳過主模型故障講解，直接使用本地三語提示；服務商、API key、路由、限流與 HTTP 錯誤只保留在 Thinking／診斷，不進角色正文，也不會拿舊聊天中的錯誤冒充本輪結果。
- 郵件草稿由 `lib/services/email_draft_launcher.dart:EmailDraftLauncher.buildUri` 交接給外部郵件 App；主旨與正文採 mailto 百分號編碼，空格固定為 `%20`，避免 Gmail 把表單編碼的 `+` 顯示成正文。
- `ToolRunner` 從 `ToolRegistry` 讀取定義、權限與執行器；受保護操作先經 permission policy。
- 動作標籤與隱藏結構化內容在回覆呈現前由協議／處理器分離，正文只保留可見文字。
- 隱藏標籤清單只有一份：`lib/services/protocol_tags.dart:ProtocolTags`（block／standalone）。串流解碼、`VisibleModelOutput`、氣泡、`_stripInternalToolCalls`、聯網搜尋收尾都讀它；裸輸出的 `{\"actions\":[…]}` JSON 動作包絡也由串流解碼器按括號深度暫存並從正文隱藏，未閉合時 fail closed。新增標籤只要：①加進 ProtocolTags ②寫處理器。文字與圖片只有一條發送路徑（`_sendMessageLocked`），不用兩邊各改一次。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
協議層不做記憶檢索。模型可以透過 `memory.force_recall`、聊天搜尋／網路搜尋等 action 請求其他服務處理；`memory.force_recall` 的下一輪執行由 `Retriever.buildMemoryPrompt` 同時比對正文與 triggers，成功送達才消耗請求並喚醒清晰度。

## 日常 / RP 差異
- 工具框架兩種模式共用。
- 可用功能、注入規則與資料 scope 由模式與功能開關決定；RP 額外使用故事、時間線、世界書相關動作。
- `ToolRunner` 的 permission requirement 可按模式覆寫。

## 相關開關
- `tool_feature_settings.dart` 的功能模組開關。
- 記憶、情緒、生物鐘、日記、畫圖、搜尋、郵件、社交、婚姻、貝殼等功能開關。
- API provider 是否支援原生 tool call／結構化輸出。
- 自訂 OpenAI-compatible 中轉站可在 API 設定展開「中轉站能力設定」，明示 developer role、中段 system、cache_control 與 tools。tools 此處表示運輸能力，實際是否送工具仍由功能與 adapter 路徑決定。

## 量大時的風險
- 多數工具 prompt 在 static 區；改動會使穩定前綴改變並可能影響 cache。RP 修正協議是按需加入的 request-only 例外，不改變後續一般回合的快取前綴。
- 動作過多或無效 JSON 會增加解析與重試成本；協議目前對無效 JSON 採失敗關閉。
- 本地 mutation、網路與外部副作用若權限政策放行，失控動作可能造成資料變更。

## 相關測試檔
- `test/model_action_protocol_test.dart`
- `test/tool_runner_test.dart`
- `test/memory_actions_test.dart`
- `test/tool_feature_settings_test.dart`
- `test/openai_compatible_capability_test.dart`
- `test/prompt_locale_test.dart`
- `test/model_stream_decoder_test.dart`
- `test/whisper_service_test.dart`
- `test/chat_search_follow_up_test.dart`
- `test/conversation_time_context_test.dart`
- `test/email_draft_test.dart`
- `test/web_search_follow_up_test.dart`
- `test/web_search_service_test.dart`
- `test/web_search_thinking_node_test.dart`

## ❓ 不確定的地方
- 某個 provider 是否真正支援原生 tool call，不能只由模型名稱推斷，應以 adapter 能力與實際回覆判定。
- 各功能 processor 的完整 action 清單會隨功能增加；這裡記錄協議層與主要入口，不代替工具 prompt 原文。
