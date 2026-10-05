# RP 模式契約

狀態：第一版已實作。維持自由 RP，不加入 App 內建 RP 生成風格。

## 產品原則

- Holt 支援自由 RP，不提供強制的 App 內建 RP 生成 Prompt。
- 使用者自行在角色卡、RP communication profile 與未來世界書中描述玩法。
- RP 與日常可同時存在於同一角色，但窗口、記憶、滾動摘要與時間線必須分流。
- 窗口建立後固定為 RP；切換 UI 模式只影響新窗口。

## RP 記憶服務

- 使用獨立的 `RpMemoryService` 業務邏輯，不將 RP 分支塞入日常蛛網服務。
- 底層 SQLite、備份、FTS、安全提案與通用 repository 可以共用，避免複製無意義程式碼。
- RP 固定使用 `MemoryEngine.ordinary`，不讀 `is_spider_web_enabled`。
- 所有寫入、召回、去重、封存與顯示查詢都必須帶：`character_id + context_mode=rp + continuity_id`。
- 第一版由 `RpMemoryService` 綁定普通記憶核心；Prompt 只描述可保存的劇情事實與搜尋 scope，不規定 RP 文風。
- 本輪召回結果只注入既有 `liveStatePart` 的記憶區塊。

## RP 滾動摘要服務

- 使用獨立的 RP 摘要組裝／Prompt 策略，但可共用摘要模型調用與底層儲存能力。
- 摘要來源只能是同一 RP 窗口；跨窗口召回只能在同角色、同 `continuity_id` 的 RP 摘要內進行。
- 摘要產物必須帶 `context_mode=rp`、`source_conversation_id` 與 `continuity_id`。
- 動態滾動摘要注入 `liveStatePart`；若新窗口採用專用 frozen 摘要，則在建立時快照到 `windowPart`。
- `RpSummaryPrompt` 是獨立的 RP 劇情卷宗契約：輸出完整替換摘要、時間線、劇情狀態、人物與人物關係；不沿用日常摘要格式，也不負責世界書提取。
- RP 注入保留同一故事線最近四份有效摘要；更舊摘要轉為事件標籤，命中後最多召回三份不同來源摘要，仍以故事線、正文相關度與版本有效性決定是否注入。
- RP 摘要軟上限預設依該故事線原文總量在 3000～10000 字間自動調整；關閉自動調整後使用 User 設定的固定上限。

### 摘要來源範圍與舊窗口重整

- 每個新摘要保存 `continuity_id`、`source_window_id`、`source_conversation_id`、`source_message_start_id` 與 `source_message_end_id`。
- 新建立的摘要若兩個端點都存在，`source_span_status=exact`；舊版無法可靠還原端點的摘要標記為 `unknown`，不能被自動當成覆蓋目標。
- 手動重新摘要若精確選中同一故事線、同一窗口、同一消息範圍，會將原摘要作為 revision target 注入模型，輸出同範圍的完整替換版本。
- 替換版本沿用原摘要的故事位置與父摘要，不以本次操作時間把舊窗口插到故事末端。
- 被替換摘要之後依賴它的有效摘要進入失效／修復鏈；新版本先建立，再按原始消息範圍逐項修復後續摘要。
- 無法證明來源範圍時只允許新增摘要或由 User 手動指定，不猜測原摘要的覆蓋範圍。
- 自定義摘要規則若存在，會與當前模式的摘要基礎規則一同用於重整；沒有自定義內容時不注入空區塊。
- 日常與 RP 各自保存一份自定義摘要偏好；偏好只能調整側重與表達，不能覆蓋 JSON、來源證據、故事線、敘事層級與修訂規則。

## RP 時間線服務

- 使用獨立 `rp_character_timeline` 儲存與獨立 dedupe domain，不改寫日常 `character_timeline` 的唯一索引。
- 最低資料語義：`character_id`、`continuity_id`、`source_conversation_id`、來源消息／證據、`story_time_text`、`sequence_order`、場景、事件、狀態與建立時間。
- 劇情日期可採世界設定年份或劇情內時間；不得用裝置日期替換正文已存在的故事時間。
- 只記錄正文有證據的事件，不替代滾動摘要。
- 本輪時間線召回只注入既有 `liveStatePart` 的時間線區塊。
- `RpCharacterTimelineService` 驗證來源消息與原文證據；state 與 event 各自去重。每次摘要最多輸出 8 個時間線候選。

## Continuity

所有 RP 窗口初始使用 `continuity_id=main`。未來可讓同一角色擁有多條平行故事；不同 continuity 的 RP 記憶、摘要與時間線不得互相召回。日常同樣保存 `main`，以維持一致的窗口身分契約。

## UI 與搜尋邊界

- RP 標籤使用紅色文字標籤；日常使用藍色文字標籤。
- 標籤只呈現資料真相，不得依目前全域開關重算。
- 全域搜尋可明確跨模式，但結果必須保留 `[RP]`／`[日常]` 標籤。

## 驗收

- RP 服務不讀日常蛛網設定，不寫入日常時間線。
- 同角色兩個不同 continuity 的召回結果為零交叉。
- RP 動態資料改變不會改動 cacheable prefix。
- App 未提供 RP 生成 Prompt 時，RP 仍可只靠使用者角色卡運作。
