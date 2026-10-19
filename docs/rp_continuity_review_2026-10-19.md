# Codex RP 連續性報告 — 晏辭複核與修復規格（2026-10-19）

> 逐條對照代碼複核過。✅ 屬實　➕ 晏辭補充　⚠️ 未真機驗證

---

## 複核結論

| # | Codex 結論 | 複核 |
|---|---|---|
| 1 | 上下文限制模式漏前情 | ✅ 屬實。`_buildDynamicWindowSummaryPrompt`（約 1101 行）裡 `includeLatestSummaries: useContextDynamic && mode != rp`，RP 永遠不帶最新滾動摘要，只靠關鍵詞命中。`_hysteresisKeepFrom` 砍掉的那段如果沒命中，就從模型眼前消失了。 |
| 2 | 劇情狀態留下過期版本 | ✅ 屬實。`storeExtraction` 只按 `_canonicalKey` 完全相同才 update；body 只有 `permanent/recovering/healed` 三種狀態，不同的 tail（`fever`/`high_fever`/`illness`）會變成三行。 |
| 3 | 摘要模型收到的參考被舊資料擠滿 | ✅ 屬實，而且**比報告說的更嚴重**，見 ➕B |
| 4 | Cache 固定前情會變舊 | ✅ 屬實，是刻意設計（保緩存）。但標籤有誤導，見 ➕C |
| 5 | 兩個 1400 字上限不共用 | ✅ 屬實。靜態 pin 用 `getRpDynamicSummaryMaxChars()` 截斷，關鍵詞召回也用同一個值當上限，各算各的 |

### ➕A 注入端已經在「粗暴合併」不同傷病（Codex 漏看的一點）
`rp_story_state_service.dart` `_compactCurrentSnapshots`（約 336 行）：body/identity 以 `'$type|$owner'` 去重，**每個人物只保留最新的一條 body**。
- 例：謝某「左臂骨折（recovering）」之後又記了「發燒（recovering）」→ 注入時骨折被吞掉，模型會讓他用左手提劍。
- 這個去重原本是為了壓掉 #2 的重複版本而做的權宜之計，結果把不同傷病也一起壓掉了。
- **#2 修好之後，這裡要改成按 `state_key` 去重，而不是按人物。**

### ➕B 摘要模型的劇情狀態參考沒有篩選（#3 加重）
`buildRpArchiveContext`（約 2806 行起）：
- 人物和關係都按「本批原文提到的人＋active 人物」篩過；
- **狀態沒有篩**：`listStates(includeNonMain: true)` 直接取前 12 條，排序是 scene 優先、`updated_at` 降序；
- 結果：沒出場人物的狀態、已 `healed`/`fulfilled`/`resolved` 的終態、非主線層（夢境/假設）都在跟真正相關的狀態搶這 12 個位置。

### ➕C 固定前情的標籤寫著「最近」
Cache 模式下，開窗時釘死的那份摘要經由 `_formatWindowSummaryPrompt` 輸出成「最近 RP 窗口摘要」。可它其實是**開窗那一刻的快照**，窗口開得越久越舊，「最近」兩個字會讓模型把它當成現況。
- 改成「開窗前情（開窗時的快照，之後的發展以正文為準）」。
- ⚠️ 這是 static 區改動，跟其他 static 改動攢在同一批。

### ➕D 固定前情和關鍵詞召回可能重複（⚠️ 推測，要驗）
Cache 模式下，pin 的是「最新一份摘要」的原文；而關鍵詞召回的 segment 也可能來自同一份摘要（`excludeWindowId` 只排除本窗口，不排除 pin 的那份）。同一段劇情可能出現兩次，白佔字數。

---

## 修復規格（建議順序：2+3 → A → 1+5 → C → D）

### 第一步：#2 + #3 + ➕B 一起修——讓摘要模型「指認取代」
這三個是同一個根因：**程式不知道新舊狀態是同一件事**。最可靠的辦法是讓摘要模型自己說，再由程式核對。

1. **送給摘要模型的狀態參考**（`buildRpArchiveContext`）改為：
   - 只取 `subject_entity_key` 或 `object_entity_key` ∈ `involvedKeys` 的狀態，外加 `scene.current`；
   - `narrative_layer = 'main'`；
   - 先放 `_isActiveForRecall == true` 的，同一人物再補最多 2 條最近的終態（讓模型知道「已痊癒」，不會把舊傷又寫回來）；
   - 每條**必須附 `state_key`**；
   - 上限保持 12，但改按「人物」分配：每位出場人物至少保留 1 個位置，避免一個傷病很多的角色把別人擠掉。
2. **抽取格式加欄位**：每個 state candidate 可帶 `supersedes_state_keys: [...]`。
   - prompt 規則：同一件事（同一傷病、同一身分、同一約定）的新進展，**優先沿用參考裡的既有 `state_key`**；如果必須換 key，就把被取代的舊 key 填進 `supersedes_state_keys`；不同的傷病不得互相取代。
3. **程式核對**（`storeExtraction`，在同一個 transaction 內）：
   - 被取代的 key 必須存在、`state_type` 相同、`subject_entity_key` 相同（knowledge 還要 object 相同）、不是 `user_edited = 1`、而且它的 `_latestSourceId` 不晚於新狀態的 → 否則忽略這個 supersede，新狀態照常寫入；
   - 通過核對：舊行**不刪**，加一欄 `superseded_by`（新行 id）＋ `superseded_at`；
   - 需要 migration：`rp_story_states` 加 `superseded_by TEXT DEFAULT ''`、`superseded_at TEXT DEFAULT ''`；`_dbVersion + 1`；backup 的 export/import 要帶上新欄位。
4. **注入與參考一律排除 `superseded_by != ''` 的行**；劇情狀態頁照樣顯示它們（灰色、標「已被取代」），保留歷史。
5. **舊資料補救（可選）**：在劇情狀態頁給一個「合併」操作，讓昭昭手動選擇「A 取代 B」，寫入同一套欄位。不要自動猜。

### 第二步：➕A 注入去重改為按 key
- `_compactCurrentSnapshots`：body/identity 改用 `'$type|${state_key}'` 去重（被取代的行已經在上一步排除了）。
- 不在場人物的「每類最新一條」規則保留（省字數，這是合理的取捨）。
- 測試：同一人物有骨折和發燒兩條 → 兩條都注入；發燒被取代成「已退燒（healed）」→ 只剩骨折。

### 第三步：#1 + #5 前情橋接與共用預算
1. **只在真的砍了歷史時才補**：`_hysteresisKeepFrom` 回傳 `keepFrom > 0`（本輪確實有消息被截掉）時，RP 動態區補上一段「**橋接摘要**」：
   - 取本 continuity 中，來源範圍覆蓋「被截掉的最後一條消息」的那份最新有效摘要（沒有就取最新一份）；
   - 用 `fitRpSummaryToCharacterBudget` 截斷；
   - 標題寫「截斷前情（較早的正文已不在上下文中）」。
   - 注意順序：目前動態摘要是先並行算好、之後才算 `keepFrom` 的。要嘛把橋接放到 `keepFrom` 算完之後再補進 `liveStatePart`，要嘛提前用 `workingMessages` 長度和 limit 先判斷一次。
2. **共用一個總預算**：新設定 `rpSummaryInjectionTotalChars`（預設 2000，可調）。
   - 優先順序：橋接摘要 > 固定前情 > 關鍵詞召回。
   - 固定前情是 static，長度在開窗時就確定了 → 關鍵詞召回的上限 = 總預算 − 固定前情長度 − 橋接長度，最低保底 400 字（避免完全召回不了）。
   - 這樣不會動到 static 前綴，不影響緩存。
3. **去重**：橋接摘要、固定前情、關鍵詞段之間用現有的 fingerprint 做包含檢查，被包含的那段跳過。（這一條同時處理 ➕D。）

### 第四步：➕C 標籤改名（併入 static 批次）

---

## 驗收（⚠️ 都要真機）
1. 上下文限制開、上限 20 條：連續聊 40 條 RP，在第 5 條埋一個事實（例如「藥放在左邊抽屜」），第 35 條不提關鍵詞、直接問「藥呢」→ 模型應該答得出來（來自橋接摘要）。
2. 同一人物先骨折、再發燒、再退燒 → 劇情狀態頁有歷史；注入只剩骨折。
3. Debug 頁看摘要模型收到的狀態參考：只剩出場人物，而且都有 `state_key`。
4. Cache 模式開一個長窗口，確認固定前情的標籤，以及總字數 ≤ 設定的總預算。
5. 備份匯出再匯入：`superseded_by` 不會丟。
