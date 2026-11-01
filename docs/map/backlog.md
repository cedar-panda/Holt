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

### 使用者貝殼錢包不分 user persona（2026-10-27 昭昭回報）

- 位置：`lib/services/scratch_service.dart:ScratchService.userAccountId`（全域單一 key）；轉帳、商店、刮刮卡、每日發放、首頁／側邊欄／輸入欄都直接用它。
- 現況：切換「我的」裡的 user 角色，貝殼餘額都一樣。
- 昭昭已拍板：舊全域餘額歸「我的」當前選中的 user persona；背包也按 persona 分開。
- 範圍：`ScratchService.userAccountId` 約 20 個呼叫點（轉帳、商店、刮刮卡、每日發放、prompt 內餘額、首頁／側邊欄／輸入欄）；`shop_service.dart` 背包 SQL 多處寫死 `owner_id = 'user'`。需 SharedPreferences 錢包遷移＋backpack 表 owner 遷移、備份相容，聊天內以窗口綁定的 persona 為準，首頁／側邊欄以當前選中 persona 為準。

### 通話與文字聊天 cache 不共用（2026-10-27）

- static/profile/window 已對齊；但通話 control 層不同、Claude 只在 control 尾設斷點、Gemini namespace 含 cacheChannel，所以不會互相命中。
- 後續方向：Claude 在 window 尾加一個斷點（注意 4 個斷點上限與 rolling 斷點數）；Gemini 讓不含 control 的靜態快照跨 channel 共用。需實測 usage 再決定。

### 通話中聯網搜尋（2026-10-27 昭昭提出，暫緩）

- 想法：角色先說「等我一下」，再搜尋；搜尋中狀態顯示「對方正忙碌，請稍候」，結果回來後角色接著說。
- 需要：通話路徑支援搜尋標籤的二段請求、跳過文字聊天的查詢確認卡、通話狀態 UI；目前通話 control 層寫明「通話中無法聯網搜尋」。

### 開源模型注意力分散、不會用指令（2026-10-27，昭昭要先自己捋 cache 邏輯）

- A. 用到才說：偶爾才用的工具（打電話、心情流光…）從 control 移到「本輪可能用得上才注入」的動態層。
  - cache 注意：觸發判斷只能放 request-only 動態層，不能讓 static／control 隨觸發變動；同一窗口內 control 必須穩定。
  - 移出 control 本身會讓 cache 重建一次，應批次一起改。
  - 觸發條件要可預期（關鍵詞／上一輪狀態），不能每輪抖動；觸發時多出的 token 不進 cache。
  - 模型可能在沒注入說明的輪次自己寫出標籤：解析與過濾仍要常駐，只是不提示。
- B. 沒寫標籤也接得住：偵測「我打給你」等句子，在氣泡下顯示確認按鈕；純 UI，不動 prompt，不影響 cache。
- C. 按模型分級：標記弱模型自動關閉非必要功能；切換時 control 會變（等同改設定，重建一次）。
- 昭昭決定（2026-10-27）：做 A＋B，不做 C；A 的 cache 邏輯昭昭先自己捋。

### 打完電話後打字，模型回覆不顯示（2026-10-27 昭昭回報，Sonnet 5.5）

- 尚未定位。已排除：心情流光標籤（在 `_extractXPostAndStrip` 的 `_openTagRe`（現為 `ProtocolTags.openToEnd`）之前已被 `MoodGlowService.processReply` 剝除）。
- 需要：重現後重進窗口是否看得到回覆（生成了但沒顯示 vs 沒生成）；報錯頁匯出的日誌；System Context Debug 的最後一次請求。

### 通話成本與掛斷摘要（2026-10-27 昭昭提出）

- 通話歷史目前最多帶 500 條（`_maxCallHistoryEntries`），每通第一輪要寫整段 cache；Claude 走 OpenRouter 時 TTL 為 1h（寫入 2 倍價）。可考慮：通話歷史縮短＋窗口摘要補前情；通話頻道改 5 分鐘 TTL（寫入 1.25 倍）。
- 掛斷後若有摘要模型：跑一次「濃縮這次通話記錄的內容，保留重點，若是太生活化沒有什麼重點則無需紀錄，簡潔即可。」結果附在 `[call_event:ended mm:ss]` 那則隱藏事件後面，讓文字聊天的模型知道通話內容。
- 不建議掛斷後把文字聊天當新窗口重建 cache：歷史是 append-only，原 cache 前綴仍有效，重建反而更貴。
