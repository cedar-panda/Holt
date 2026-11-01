# RP 故事

## 它是做什麼的（一兩句話）
保存 RP 故事線中的人物、別名、人物關係、劇情狀態、角色時間線與世界書。這些資料都綁定角色與故事線，不是全域日常記憶。

## 資料存在哪（資料表 / SharedPreferences key）
- `rp_storylines`
- `rp_story_characters`
- `rp_story_entity_aliases`
- `rp_story_relationships`
- `rp_story_relationship_events`
- `rp_story_states`
- `rp_character_timeline`
- `rp_worldbook_entries`：`scope` 保存世界內適用範圍文字；`binding_scope` 決定故事線專屬／角色共用；`activation_mode` 決定常駐／關鍵詞／場景觸發。
- `rp_worldbook_sync_state`
- `rp_worldbook_review_items`
- `rp_story_projection_revisions`
- 摘要來源與有效性在 `context_summaries`、`context_summary_segments`

## 誰寫入（檔案：函式）
- 摘要完成後：`lib/services/context_compressor.dart:ContextCompressor._compressQueued`
- 人物與關係：`lib/services/rp_story_service.dart:RpStoryService.storeExtraction`
- 劇情狀態：`lib/services/rp_story_state_service.dart:RpStoryStateService.storeExtraction`
- 角色時間線：`lib/services/rp_character_timeline_service.dart:RpCharacterTimelineService.storeSummaryCandidates`
- 世界書批次：`lib/services/rp_worldbook_service.dart:RpWorldbookService.maybeProcessAfterSummary`
- 人工世界書：`RpWorldbookService.createManualEntry`、`updateManualEntry`、`setArchived`
- 模型修正既有狀態：`lib/services/rp_story_correction_service.dart:RpStoryCorrectionService.applyReplyActions`

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- 人物／關係：`RpStoryService.recallPrompt`，由生成流程加入 request-only 的 RP 參考內容；只用本輪與最近 3 條訊息的姓名／別名判定當前出場，完整人物卡只給明確出場人物，其他活躍人物改為單行摘要；相同有向／互相關係只注入最新一筆。
- 劇情狀態：`RpStoryStateService.recallPrompt`，加入 live state；人物的 body／identity 以「人物 + 類型」只注入最新狀態，通常隱藏內部 `state_key`，只有明確修正上下文才顯示鍵值。遺失／摧毀／轉移物品不再永久常駐，場外 knowledge 只保留尚在懷疑／調查中的活躍項。
- 角色時間線：`RpCharacterTimelineService.recallPrompt`，加入 request-only 的 RP 時間線參考；一般回合隱藏內部 `event_key`，只有 user 明確要求修正時間線時才附上。
- 世界書：`RpWorldbookService.recallAlwaysOnPrompt` 把最多 3 條／500 字常駐設定放入故事線綁定的 cacheable `windowPart`；`recallTriggeredPrompt` 只把本輪命中的 triggered／scene 條目放入 request-only 參考。相容入口 `recallPrompt` 也固定先保留 always，再使用剩餘額度裝動態條目，常駐設定不會再被高分觸發項擠掉。`triggered` 只依條目自身 triggers 命中，`scene` 依 triggers、完整 scope 片語或較強場景詞共現命中；`character_global` 可跨該角色故事線讀取，`storyline` 只讀目前故事線。
- 生成端由 `ContextCompressor.fitPrioritizedRpReferencePartsToCharacterBudget` 依「劇情狀態 → 人物／關係 → 動態世界書 → 一般記憶 → RP 時間線」分配共享預算；高優先項未用完的額度才向後流動。
- 來源摘要與續接內容由 `ContextCompressor.buildRpArchiveContext` 組合；歸檔請求只保留一份 user 人設與一份本輪實際提及人物的精簡結構，不重複傾倒 evidence、來源 ID、建立時間等內部欄位。
- 顯示與人工編輯入口：`lib/screens/rp_story_relationship_screen.dart` 與 `lib/screens/rp_worldbook_screen.dart`。搜尋、文字欄位與枚舉選擇共用 `YanciTheme.themedInputDecoration`；人物、關係、劇情狀態以輕量卡片分組，狀態類型／層級／進度以徽章顯示。這些視覺調整不改資料寫入或 Prompt 注入。
- 角色頁的劇情檔案入口與每條故事線都使用主題化柔光卡；故事線內四個資源入口為 2×2 膠囊格。關係仍保留方向語意，顯示改為 `A › B`；最新變化、形成經過與引用原文改用層級差異，不刪除資訊。世界書條目類別、綁定範圍與召回模式以小徽章顯示。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
- 人物、關係、狀態：以故事線、角色與有效狀態篩選；不是記憶 FTS5。人物參考預算預設 1000 tokens；完整人物最多 3、場外精簡人物最多 6。狀態預算預設 800 tokens，另按 scene／identity／knowledge／body／promise／item／plot 設全域上限，同一主客體同類最多 2 條。
- 時間線：以事件內容／故事時間的嚴格關聯詞過濾；單一一般 2 字片段不足以召回，明確修正意圖可例外用短鍵尋找目標。
- 世界書：先按角色／故事線綁定範圍與狀態取候選，再依 `activation_mode` 比對；常駐項每輪最多 3 條且約 500 字，命中型與場景型不佔常駐配額。
- 目前沒有在這些服務中看到向量召回。

## 日常 / RP 差異
這一整組資料只在 RP 故事範圍生效；日常模式使用一般角色資料、日常時間線與日常記憶，不建立 RP 人物／世界書投影。

## 相關開關
- RP 模式切換。
- 世界書自動整理開關與整理間隔設定。
- 摘要模型／摘要觸發設定間接控制自動提取時機。

## 量大時的風險
- 人物、關係與狀態雖有限制，但故事線數量和世界書歷史仍會增加資料庫查詢量。生成端在共享總池之外，再把整份 `rpStoryContext` 限制為最多 1800 字元。
- 世界書召回有整體字數上限；always 常駐背景另有 3 條／約 500 字上限並在穩定窗口前綴中優先保留，動態條目超過後依相關性省略。編輯常駐世界書會在下一輪合理地改變此前綴並重建一次 cache。
- 人物、關係、狀態、時間線與動態世界書會與摘要／續接內容共享 RP 連續性總預算，生成流程按狀態、人物、世界書、記憶、時間線的順序保留完整行，避免各自上限相加。
- 多個來源摘要同時失效或重跑時，投影版本與來源有效性需要一起維持。

## 相關測試檔
- `test/rp_story_service_test.dart`
- `test/rp_story_state_service_test.dart`
- `test/rp_worldbook_service_test.dart`
- `test/context_summary_recycling_test.dart`
- `test/database_schema_v33_test.dart`

## ❓ 不確定的地方
- `RpStoryService.recallPrompt` 的完整文字格式會隨 prompt 實作變化，這裡只記資料流與層級。
- 世界書整理的預設間隔應以 `MemorySettings` 與當前設定讀取為準，地圖不固定寫死數字。
