# 日常模式契約

狀態：已接入。日常能力保留既有語義，並與 RP 資料分流。

## 定位

日常模式承接目前 App 的既有聊天行為。加入 RP 後，不應為了共用程式碼而改變日常 Prompt、記憶分類、摘要格式或時間線語義。

## 記憶

- 日常窗口只寫入與召回 `context_mode=daily` 的記憶。
- 記憶引擎可為 `ordinary` 或 `spider`；角色欄位 `is_spider_web_enabled` 只影響日常記憶引擎。
- `is_spider_web_enabled` 不代表 RP 開關，也不得被 RP 記憶服務讀取。
- 現有長期記憶分類、確認、去重、封存與恢復行為保留。
- 既有 `memories.mode` 不得覆寫為 `daily`；後續以獨立 `context_mode` 欄位分流。

## 滾動摘要

- 日常摘要只消費日常窗口消息，產物標記 `context_mode=daily`。
- 專用窗口摘要的 frozen snapshot 可留在 `windowPart`。
- 動態摘要與關鍵詞召回放在 `liveStatePart`，不得因摘要更新刷新 cacheable prefix。
- 手動摘要、重新生成與編輯不得移除或改寫模式標記。

## 時間線

- 現有 `character_timeline` 定義為日常時間線。
- 日常去重、state 更新與 event 唯一索引只處理日常資料。
- 不得讓 RP 事件進入此表，再依 UI 篩選假裝分離。

## Profile

- 現有 communication/system profile 作為日常 profile 的初始值。
- 日常窗口建立後，其 Profile 選擇由窗口 context 固定；之後 UI 切換不回寫舊窗口。

## 驗收

- 未開啟 RP 的既有使用方式與輸出結構保持不變。
- 關閉全域 RP 後，各角色恢復自己的日常／RP 偏好，不重分類任何窗口。
- 日常記憶使用蛛網時，RP 記憶仍不建立蛛網 link。
