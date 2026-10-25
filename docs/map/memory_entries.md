# 記憶條目

## 它是做什麼的（一兩句話）

保存可跨回合使用的耐久事實，並在每次生成前按角色、模式、故事線、觸發詞與相關性挑選少量內容注入。模型提出的新記憶、刪除與合併都先經重複檢查或待確認流程。

## 資料存在哪（資料表 / SharedPreferences key）

- `memories`：正文、分類、觸發詞、日常／RP、故事線、永久標記 `is_permanent`、常駐標記 `is_pinned`、狀態、來源窗口與情緒快照。
- `memories_fts`：由 `memories` 觸發器維護的 FTS5／FTS4 搜尋索引。
- `memory_embeddings`：以 `memory_id + provider + model` 為主鍵的衍生向量；內容 hash 變動時可判定失效。
- `archive`：封存時保存 `memories` 完整 JSON 快照；原條目改為 `status=deleted`。
- `pending_memory_actions`：新增、刪除、合併、連線等待確認提案。
- `memory_rejection_tombstones`：已拒絕的模型／摘要記憶，用於阻止改寫後再次出現。
- SharedPreferences：`memory_write_enabled`、`memory_mode`、`custom_memory_prompt`、`mem_budget_total`、`memory_send_limit_v1`、`memory_embedding_model_selection_v1`、`dream_curation_*`。

## 誰寫入（檔案：函式）

- `lib/services/memory_actions.dart`：`MemoryActions.processReply` 解析模型動作；每輪最多處理兩條新記憶。
- `lib/services/memory_guard_service.dart`：`MemoryGuardService.guardNewMemory` 是新記憶的單一交易式入口，先查拒絕墓碑、待確認提案與既有重複。
- `lib/memory/summarizer.dart`：`Summarizer.summarize` 可從一段對話提取最多兩條並送入同一 guard。
- `lib/screens/memory_screen_dialogs.dart`：`_MemoryDialogMethods._showAddMemoryDialog` 寫入手動記憶。
- `lib/services/memory_guard_service.dart`：`MemoryGuardService.execute` 執行使用者確認後的新增／刪除／合併／連線提案。
- `lib/memory/database_memories.dart`：`_MemoryStore.insertMemory`、`archiveMemory`、`restoreFromArchive`、`permanentlyDelete` 實際修改 SQLite。
- `lib/memory/database_memories.dart`：`setMemoryPinned` 單獨切換每輪常駐；不改永久保存／封存保護。
- `lib/services/dream_curation_service.dart`：`DreamCurationService.maybeTrigger` 按 scope 累積門檻，交給整理服務產生關聯／重複提案。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）

- `lib/memory/retriever.dart`：`Retriever.buildMemoryPrompt` 讀永久與活躍記憶、排序並套用條數／token 預算。
- `lib/services/rp_memory_service.dart`：`RpMemoryService.buildPrompt` 固定使用 RP scope 與經典記憶引擎；可接收本輪已注入摘要作為排重依據。
- `lib/screens/chat_screen_generation.dart`：`_ChatScreenState._sendMessageLocked` 把非空記憶區塊放入 `dynamicParts`。
- `lib/screens/chat_screen_generation.dart`：`_ChatScreenState._sendImageLocked` 對圖片訊息走同一類動態注入。
- `lib/screens/call_screen.dart`：`_CallScreenState._generateTurn` 依目前的 `memory_mode` 選擇 `story`／`romance` 分桶，不再把通話固定讀成 `romance`。
- Prompt 層：`liveStatePart`，只屬本次 request，不進聊天紀錄，也不進可快取前綴。
- `lib/screens/chat_screen_prompt_parts.dart`：`_ChatScreenState._buildCommonStaticParts` 把記憶動作能力說明放入 `staticPart`；只有功能／設定改變才影響前綴。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）

- 觸發詞：`RecallTextMatcher.bestKeywordMatch` 對本輪 user 正文比對。
- 字面／全文：`_MemorySearch.search` 使用 FTS5 BM25；裝置不支援 FTS5 時退到 FTS4 自算 BM25，再不足時用文字 fallback。
- 向量混合：`MemoryVectorRecallService.searchHybrid`；未設定向量模型或呼叫失敗時只保留字面結果。
- 排序：日常依觸發詞、全文結果與永久記憶；沒有命中的一般活躍／永久記憶不再填滿剩餘位置，只有 `is_pinned` 可無條件保底最多 3 條。RP 將同故事線候選交給劇情相關性排序；只有最多 2 條 pinned 記憶可無命中進入，其餘候選必須對本輪文字有實際相關分。
- RP 中文召回會移除常見代詞、虛詞與高頻口語詞；單一 2 字滑動片段不能獨自通過門檻，必須是既存觸發詞／完整 query 精確命中、命中至少一個 3 字以上詞，或有兩個以上有效短詞共現。日常召回沿用原規則。
- RP 候選在正式注入前會與固定窗口摘要、截斷前情摘要、續接摘要比較；完整包含或高度重疊的內容直接略過。此檢查發生在 DeferredPrompt 提交前，因此被略過的記憶不會增加 mention count 或寫入 triggered ID。
- 維護意圖：user 明確要求整理記憶時，改為在發送上限內注入較完整的帶短號清單。

## 日常 / RP 差異

- 日常 scope 為 `character_id + daily + main`；可選經典記憶或蛛網記憶。
- RP scope 為 `character_id + rp + continuity_id`，固定走經典記憶；單輪發送條數最多再限制為 8。
- RP 候選不使用蛛網清晰度／情緒共振排序；日常蛛網模式會使用清晰度與情緒距離。
- RP 的一般記憶另有 600 token 單輪硬上限，避免與摘要、人物關係、狀態、世界書和時間線共同注入時擠掉較近的劇情資料。
- RP 記憶區塊使用單行精簡說明頭；資料內容與審核流程不變，減少固定教學文字反覆佔用額度。
- RP 生成時，劇情狀態、人物／關係、動態世界書、記憶、RP 時間線會依序進 `fitPrioritizedRpReferencePartsToCharacterBudget`，共享剩餘連續性預算；記憶排序第四，不再與高優先的當前場景平均分配。
- 做夢整理按角色、context mode、故事線與 memory mode 分開計數；RP 整理只接受 `duplicate_candidate`，不建立蛛網關聯。

## 相關開關

- 模型自主寫入：`memory_write_enabled`；關閉時協議標籤仍會被剝離，但不落庫。
- 每輪發送條數：`memory_send_limit_v1`；日常可設 1～500，RP 另有 8 條硬上限。
- 注入 token 預算：`mem_budget_total`；蛛網另用 `spider_web_budget_total`；RP 會在使用者設定之上再套用 600 token 上限。
- 向量召回：`memory_embedding_model_selection_v1`；空模型即停用向量層。
- 永久保存與常駐注入分離：`is_permanent` 只控制保留／封存保護，`is_pinned` 才允許未命中時注入；記憶列表以鎖與圖釘分別顯示。
- 做夢整理：`dream_curation_enabled`、`dream_curation_threshold` 與各 scope 的 last-count key。

## 顯示層邊界

- `lib/widgets/memory_screen_header.dart`：`MemoryScreenHeader.build` 的標題列以 52px 作為最低高度，而非固定高度；App 字級或系統文字縮放較大時會隨內容向下延展，避免「記憶」大標題下方出現 RenderFlex 溢出。

## 量大時的風險

- `Retriever.buildMemoryPrompt` 每輪會先讀該 scope 的全部活躍與永久記憶，再在 Dart 端比觸發詞／排序；單一 scope 達數萬條時，讀取、物件建立與逐條比對會先增長。
- `MemoryGuardService.guardNewMemory` 會讀同 scope 全部活躍記憶做重複判定；墓碑查詢上限 1000，但活躍記憶沒有同類上限。
- 向量衍生表按記憶 × provider/model 增長；切換多個向量模型會為同一記憶保留多個索引版本。
- `MemoryVectorRecallService._searchVector` 讀取候選記憶時只取該範圍最新 1000 條；但 `loadStoredRows` 沒有 `LIMIT`，仍會把該範圍、該 provider/model 的全部記憶向量載入 Dart。向量歷史持續增長時，查詢、JSON 解碼與記憶體用量不會受 1000 條候選上限完整保護。
- 手動／做夢整理有批次與 token 預算；不會一次把整庫送給模型，但批次數會隨記憶量增加。

## 相關測試檔

- `test/memory_actions_duplicate_guard_test.dart`
- `test/memory_guard_service_test.dart`
- `test/memory_vector_recall_service_test.dart`
- `test/dream_curation_scope_test.dart`
- `test/context_mode_migration_test.dart`
- `test/context_mode_feature_test.dart`
- `test/database_schema_v33_test.dart`
- `test/manual_memory_curation_apply_test.dart`
- `test/memory_screen_header_test.dart`
- `test/backup_format_test.dart`

## ❓ 不確定的地方

- `Summarizer.summarize` 與 `Summarizer.consolidate` 仍存在，但以 `rg` 未找到 production 呼叫點；目前無法只靠靜態入口確認它們是否仍由外部或舊路徑使用。
- `is_permanent` 可由摘要提取／合併繼承並在封存 UI 受額外保護；是否另提供手動永久入口仍需按當前 UI 驗收。
