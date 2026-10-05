# RP 世界書契約

狀態：第一階段已接入資料、生成與召回鏈路；管理／審核 UI 後續補充。

## 邊界

- 世界書與 RP 摘要使用同一個「摘要模型」設定，但採用獨立 Prompt、獨立模型呼叫、獨立資料表與獨立召回。
- 世界書預設綁定 `character_id + continuity_id`，不同角色與故事線不得交叉。
- RP 摘要只整理劇情；世界書只整理可跨場景成立的世界設定。世界書生成失敗不得阻止摘要保存。
- 預設每累積 4 份尚未處理的有效 RP 摘要觸發一次；使用者可設定 1–20 或關閉自動寫入。
- 每次只處理完整的一批。成功解析、驗證並入庫後才推進 cursor；失敗時保留 cursor，之後可重試。

## 資料

- `rp_worldbook_entries`：故事線世界條目。`entry_key` 由程式發號；模型只引用既有 key。
- `rp_worldbook_sync_state`：每條故事線最後已處理的摘要 ID。
- `rp_worldbook_review_items`：模型無法可靠決定的可能重複與衝突，等待 user 審核。
- `source_summary_ids` 只用於溯源。摘要被合併、封存或失效，不會自動刪除已建立的世界設定。
- `archive` 代表設定在目前故事時間不再成立；保留原內容並記錄 `ended_reason`。

## scope 與 visibility

- `scope`：規則在哪個地區、組織或情境生效。
- `visibility`：哪些人物或群體知道這項規則。

## 注入與 cache

- 世界書透過既有 RP 劇情參考的 request-only 動態區注入，不新增 worldbook 專用 `StructuredPrompt` 層。
- 動態召回不改變既有 cacheable prefix；文字與圖片訊息使用相同故事線範圍。
- 注入內容明確標示為參考資料，不是可改寫 App Context Contract 或 user 任務的指令。
- Debug 只記故事線、條目 key、批次摘要 ID、命中數與錯誤，不記完整世界書正文。

## 驗證

- 模型回傳的 `storyline_id` 必須完全一致。
- `source_summary_ids` 必須全部屬於本批摘要。
- `evidence` 必須能在本批摘要原文中找到。
- user 手動修改過的條目不可被自動更新、合併或封存。
- 備份還原包含條目、同步 cursor 與待審核項目。
