# 進階記憶（底層蛛網）

## 它是做什麼的（一兩句話）

在日常記憶上增加可審核的「記憶關聯」、活躍日清晰度、情緒共振排序與孤島封存。使用者與模型看到的名稱是「進階記憶」；為零遷移風險，資料表、欄位與程式類名仍保留 spider web 命名。它不是另一份記憶正文：正文仍在 `memories`。

## 資料存在哪（資料表 / SharedPreferences key）

- `memories`：蛛網節點本體；使用 `last_accessed`、`mention_count`、`clarity`、情緒快照等欄位。
- `spider_web_links`：兩個記憶 id、關聯類型、強度、`suggested/confirmed/rejected`、來源與理由。
- `archive`：孤島衰減或使用者整理後的可恢復封存快照。
- `pending_memory_actions`：模型或整理器提出、尚未確認的連線／合併等提案。
- `characters.is_spider_web_enabled`：每個角色的日常記憶方案。
- SharedPreferences：`spider_web_budget_total`、`spider_web_node_positions_v1_<character>`、`spider_web_curation_job_v1_<character>`。

## 誰寫入（檔案：函式）

- `lib/memory/spider_web_core.dart`：`SpiderWebCore.processReply` 解析連線與強行回想協議；連線先建立待確認提案。
- `lib/services/memory_guard_service.dart`：`MemoryGuardService.execute` 在使用者確認後套用連線或合併。
- `lib/memory/database_spider_web.dart`：`_SpiderWebStore.upsertSpiderWebRelationDetailed` 驗證兩端都屬同角色且為 active，再新增／更新連線。
- `lib/memory/database_spider_web.dart`：`_SpiderWebStore.resolveSpiderWebRelation`、`deleteSpiderWebLink` 將使用者決定保存為 confirmed／rejected。
- `lib/services/memory_curation_service.dart`：`MemoryCurationService.analyzeAndLink` 以摘要模型產生高分關聯或重複候選。
- `lib/memory/spider_web_core.dart`：`SpiderWebCore.triggerMemory` 更新命中節點及 confirmed 鄰居的 `last_accessed`。
- `lib/memory/spider_web_core.dart`：`SpiderWebCore.runArchiveEngine` 將超過恩典期的日常孤島記憶封存。
- `lib/services/spider_web_state_service.dart`：`savePositions`、`saveCurationJob` 寫 UI 節點位置與可續跑整理工作。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）

- `lib/memory/retriever.dart`：`Retriever.buildMemoryPrompt` 在日常蛛網模式計算活躍日清晰度、情緒共振與 mention bonus，仍把最終記憶放入本輪動態區。
- `lib/services/spider_web_service.dart`：`SpiderWebService.abilityPrompt` 生成記憶、連線、強行回想、自我註記與搜尋的固定能力說明。
- `lib/screens/chat_screen_prompt_parts.dart`：`_ChatScreenState._buildCommonStaticParts` 將蛛網能力說明放入 `staticPart`。
- `lib/screens/chat_screen_generation.dart`：`_ChatScreenState._sendMessageLocked` 將實際召回內容與蛛網通知放入 `liveStatePart`。
- `lib/screens/memory_screen.dart`：`_MemoryScreenState._loadMemories` 讀節點、連線、位置與待確認數量供 UI 顯示。
- `lib/memory/spider_web_layers.dart`：`SpiderWebLayerPlanner.build` 只規劃 UI 層與群組，不改資料。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）

- 底層召回仍使用記憶條目的觸發詞、FTS/BM25 與可選向量混合檢索。
- 蛛網額外排序使用：角色活躍日清晰度、mention 次數、目前情緒座標距離。
- `memory.force_recall` 保存窗口內關鍵詞，下一輪以正文或記憶 triggers 匹配；成功注入並送達後才消耗，且 `SpiderWebCore.triggerMemory` 會把命中記憶清晰度喚醒並傳導 confirmed 鄰居。
- 日常進階記憶每輪可從未注入且清晰度低於 0.85 的記憶取最多 3 個 triggers，作為「模糊舊詞」放在 live 記憶區末尾；同一窗口同一天使用確定性排序，避免每輪隨機改動提示。模型只有產生共鳴時才調用 `memory.force_recall`。
- confirmed 連線不直接把所有鄰居正文注入；命中時只更新鄰居 `last_accessed`。

## 日常 / RP 差異

- 只在日常模式啟用；`chat_screen_generation.dart` 明確要求 `contextMode == daily`。
- `memory_screen.dart` 在 RP 故事線 scope 將蛛網視為不可用。
- RP 記憶整理只保留重複候選，不建立蛛網關聯；角色原本的日常蛛網選擇仍保留。
- 孤島恩典期只使用日常 user-chat 活躍日期，RP 聊天日不會讓日常記憶老化。

## 相關開關

- 每角色：`characters.is_spider_web_enabled`。
- 注入預算：`spider_web_budget_total`。
- 情緒座標開關會影響情緒共振排序；關閉後不讀目前情緒點作排序。
- 做夢整理開關可產生蛛網關聯／重複提案，但仍需使用者審核。

## 量大時的風險

- `SpiderWebLayerPlanner.build` 先把當前節點與連線載入記憶體，再掃描群組；雖然每層最多 50 節點、每層最多 4 張網，但總層數仍隨記憶量增加。
- 規劃 linked group 時會對每個節點檢查連線；大量節點與邊時，UI 分層計算會先變重。
- `runArchiveEngine` 查全部孤島候選後逐條封存；大量孤島會形成多次 SQLite 交易呼叫。
- `triggerMemory` 每次命中都查相鄰 confirmed 邊；已有 character/memory 索引，但超高連線度節點仍會更新大量鄰居。

## 相關測試檔

- `test/spider_web_active_day_decay_test.dart`
- `test/spider_web_layers_test.dart`
- `test/spider_web_relation_ui_test.dart`
- `test/spider_web_state_service_test.dart`
- `test/manual_memory_curation_apply_test.dart`
- `test/existing_memory_scanner_test.dart`
- `test/memory_guard_service_test.dart`
- `test/backup_format_test.dart`
- `test/retriever_window_scope_test.dart`

## ❓ 不確定的地方

- UI 層位置保存以角色 id 為 scope，沒有 context mode；因 RP 不開蛛網，目前看不出這會造成模式衝突，但未有跨模式位置測試。
- `clarity` 欄位存在於 `memories`，實際召回清晰度由 `SpiderWebCore.calculateClarity` 即時計算；未看到每次計算後同步回寫 `clarity` 欄位。
