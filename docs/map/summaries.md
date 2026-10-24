# 摘要

## 它是做什麼的（一兩句話）

把已歸檔的對話壓縮成可替代原文窗口的摘要，並為 RP 摘要建立段落索引，讓後續只召回相關段落。

## 資料存在哪（資料表 / SharedPreferences key）

- `context_summaries`：摘要正文、來源消息範圍、窗口、模式、故事線、revision 與 archived 狀態。
- `context_summary_segments`：RP 摘要段落與段落順序。
- `context_keywords`：已被回收摘要的關鍵詞索引與來源正文副本。
- `context_summary_repairs`：失效摘要鏈的修復記錄。
- `conversations.summary_cursor_message_id`、`pinned_static_summary` 保存窗口游標與固定摘要。

## 誰寫入（檔案：函式）

- `lib/screens/chat_screen_compression.dart:_triggerContextCompression` 及 `_performContextCompression` 依 token／消息條件啟動壓縮。
- `lib/services/context_compressor.dart:ContextCompressor.compress` 串行化同一角色、模式、故事線的摘要工作。
- `lib/services/rp_summary_prompt.dart:RpSummaryPrompt.compose` 要求按當前劇情節點保留主線、活躍支線與未結線索；不再要求每個舊事件永遠留在滾動摘要。仍影響現在的重要不可逆事件壓成同段 1～2 句，已結且不再影響後文的事件可退出當前摘要。
- `lib/services/context_compressor.dart:ContextCompressor.compactRpSummaryToHardLimit` 依主線、未結衝突／伏筆／承諾與關係轉折等優先級保留完整事件短段；低優先級整段淘汰，不留下只有標題的空殼。
- `lib/memory/database_context_summaries.dart:_ContextSummaryStore.insertContextSummary` 與 `insertContextSummaryAndAdvanceCursor` 寫摘要、來源範圍、段落和游標。
- `lib/services/context_summary_repair_service.dart:ContextSummaryRepairService.processScope` 處理失效摘要鏈。
- `lib/services/context_compressor.dart:ContextCompressor.recycleSupersededSummaries` 把超出保留範圍的舊摘要轉成關鍵詞索引。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）

- `lib/screens/chat_screen_compression.dart:_buildStaticWindowSummaryPrompt` 讀窗口首次建立時固定的摘要，放入 window/static snapshot。
- `lib/screens/chat_screen_compression.dart:_buildDynamicWindowSummaryPrompt` 依 cache／上下文限制模式載入最新摘要或關鍵詞命中段落，放入 dynamic/live 區。
- RP 的「截斷前情」也由 `_buildDynamicWindowSummaryPrompt` 處理：啟用上下文限制且本輪歷史將超出消息條數上限時，額外補入最新一份有效摘要，並以 1200 字為上限；未發生截斷時不補這份。
- RP 動態摘要按「固定前情 → 截斷前情 → 關鍵詞召回」分配同一個 2000 字計算預算；關鍵詞召回使用 `max(400, 2000 - 固定前情字數 - 截斷前情字數)`，因此至少保留 400 字，極端情況下實際合計可略高於 2000 字。
- 生成流程再以約 4000 字元約束「窗口固定／動態摘要 + 續接摘要 + RP 劇情參考」整體連續性內容。RP 劇情參考現已包含一般記憶、RP 時間線、人物／關係、狀態與世界書，且自身另有 1800 字元單輪硬上限；角色卡與工具協議不在此額度。
- RP 續接窗口以 user 選定的篇章摘要取代普通固定／最新摘要，另保留 400 字元供命中事件段召回；`ContextCompressor.fitRpSummaryToCharacterBudget` 與 `fitRpReferencePartsToCharacterBudget` 負責按剩餘額度保留完整段落／完整行。
- `lib/services/context_compressor.dart:ContextCompressor.loadSummaryPack` 先用關鍵詞索引挑候選，再取候選全文；RP 可限制段數與字數。
- `lib/screens/chat_screen_generation.dart:_sendMessageLocked` 等待上述摘要結果並交給 `lib/screens/chat_screen_prompt_parts.dart:_buildCommonStaticParts` 組裝。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）

- 摘要段落召回使用 `RecallTextMatcher.bestKeywordMatches` 的關鍵詞字面匹配與分數排序。
- 先讀 `context_summary_segments` 和 `context_keywords` 的索引欄位，再按候選 ID 讀正文；不是 BM25 或向量檢索。
- 最新摘要是按來源範圍／建立順序讀取，不依賴關鍵詞。

## 日常 / RP 差異

- 日常可取最近摘要與一個關鍵詞召回結果。
- RP 有固定窗口摘要、最新摘要、分段關鍵詞召回與獨立字數預算；RP 摘要另會投影時間線、人物、關係與劇情狀態。
- RP 摘要由 `lib/services/rp_summary_prompt.dart:RpSummaryPrompt.compose` 使用獨立 prompt；世界書不在此 prompt 內。
- RP 摘要歸檔上下文只帶一份當前 user 人設與本輪原文實際提及人物的精簡欄位；不再重複送同一人物卡，也不送 evidence、來源消息 ID、建立時間等內部欄位。

## 相關開關

- 上下文發送限制與其摘要開關。
- cache／窗口摘要開關。
- RP 摘要最大字數、動態摘要段數、動態字數預算、續接摘要預算。
- 摘要模型與世界書自動整理是獨立設定。

## 量大時的風險

- `context_summaries`、段落和關鍵詞會隨窗口數增長；索引與來源範圍必須保持一致。
- 摘要鏈修訂會讓後續摘要失效並需要修復；原文消息需可由來源範圍重新取得。
- cache 靜態摘要、最新摘要與關鍵詞召回同時啟用時，總注入量受字數預算限制，但不同模式仍有不同組合。
- 兩段式召回只避免先載入整份摘要正文；第一段仍由 `getRecallIndexRows` 讀取該角色／模式／故事線範圍的全部關鍵詞欄位，再交給 Dart 逐條比對。資料以年累積時，關鍵詞讀取、物件建立與逐條匹配仍會變慢。
- 後續方向是建立 SQLite 詞索引表，先在資料庫縮小候選；同時把已了結、長期不再活動的事件標籤摺疊成篇章標籤，避免索引無界增長。這兩項目前是 backlog，不是既有實作。

## 相關測試檔

- `test/context_summary_repair_service_test.dart`
- `test/context_summary_recycling_test.dart`
- `test/context_compressor_timeline_test.dart`
- `test/memory_settings_summary_trigger_test.dart`
- `test/summary_model_settings_ui_test.dart`
- `test/retriever_window_scope_test.dart`

## ❓ 不確定的地方

- 摘要模型實際回傳內容是否完整遵守段落與關鍵詞 schema，需以運行日志或具體資料庫記錄確認；程式有本地解碼與補足邏輯，但這不等於模型每次都輸出完整欄位。
