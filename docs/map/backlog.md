# 系統地圖過程發現的待辦

這裡只收錄閱讀源碼時發現、但不屬於本次文件地圖任務的問題與後續方向。此文件不是已完成清單；本輪沒有修改對應程式碼。

## 正確性與測試

### 情緒 grudge 在請求成功前已更新浮現時間

- 位置：`lib/memory/emotion_coordinates.dart:EmotionCoordinates.statePrompt`
- 現況：`statePrompt` 呼叫 `_tryGrudgeSurface`；成功抽中 grudge 後，組裝提示時就更新 `grudge_seals.surfaced_at`。
- 風險：若後續模型請求失敗、取消或未送達，該次 grudge 仍被視為已浮現，並進入冷卻期。
- 後續方向：比照其他 deferred prompt effect，把「準備注入」與「請求成功後提交 surfaced_at」分離。

### RP 情緒故事線隔離缺少行為測試

- 位置：`lib/memory/emotion_coordinates.dart:EmotionCoordinates.scopeId`
- 現況：RP 透過 `角色 ID#rp:故事線 ID` 隔離情緒資料；現有 schema／刪除測試能看到這種 scope，但未找到直接驗證兩條 RP 故事線在寫入、讀取、衰減與 grudge 浮現時互不影響的完整行為測試。
- 風險：未來修改情緒流程時，可能只保住資料列格式，卻讓讀寫入口錯用 base character ID。
- 後續方向：增加 route A／route B 的端到端 service test，覆蓋打點、`statePrompt`、grudge 與清理。

## 量大時的風險

### 摘要關鍵詞召回仍會全範圍掃描索引欄位

- 位置：`DatabaseHelper.getRecallIndexRows`、`ContextCompressor._preselectRecallCandidates`
- 現況：兩段式召回先載入該 scope 的全部關鍵詞欄位，在 Dart 逐條比對，再只補候選全文。
- 風險：避免了全摘要正文常駐記憶體，但多年關鍵詞累積後，第一段查詢與逐條匹配仍會變慢。
- 後續方向：SQLite 詞索引表；把已了結標籤摺疊成篇章標籤。

### 向量候選有限制，但已存向量載入沒有上限

- 位置：`lib/services/memory_vector_recall_service.dart:MemoryVectorRecallService._searchVector`
- 現況：記憶候選只取最新 1000 條，`loadStoredRows` 卻讀取該 scope、provider、model 的全部 `memory_embeddings`。
- 風險：大量舊向量仍會增加 SQLite 讀取、JSON 解碼、Dart 物件與記憶體成本。
- 後續方向：讓向量查詢只讀候選 memory ID，或把近鄰檢索交給可索引的向量儲存層；需先量測再選方案。

### Live State 尚未有跨所有子系統的統一總預算

- 位置：`lib/screens/chat_screen_generation.dart:_sendMessageLocked`、`lib/services/context_compressor.dart`
- 現況：RP 摘要、普通記憶、RP 時間線、人物／關係、狀態與世界書已共享連續性字數邊界；但即時時間、工具結果、日記等仍各自限額。
- 風險：極端情況下，多個子系統同輪命中仍可能把各自上限相加。
- 後續方向：先以實機 debug prompt 量測，再決定是否建立保底配額加共享餘額的協調器；不能用固定順序裁切讓後排系統飢餓。

## 之後要做（昭昭已拍板，2.0 不做）

### 長按發送鍵：只發送不觸發回覆

- 需求：長按發送鍵＝送出但不讓角色回覆，可連發多句再一起回。
- 狀態：2.0 先不做；需要重新設計發送／生成觸發邏輯與互動構思。
- 記錄日期：2026-10-20
