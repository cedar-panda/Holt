# Inkling／Claude 費用設定與用量監控報告

日期：2026-07-17

## 已確認規則

- 選擇 `thinking_machines` 並保存非空 Tinker API Key 時：
  - 強制關閉「緩存命中」
  - 強制關閉其子開關「專用摘要」
  - 強制關閉 Keep-Alive
  - 自動開啟「上下文發送限制」
  - 若上下文限制原本關閉，其「動態窗口摘要」保持關閉；若原本已開啟，保留使用者對動態摘要的選擇
- 選擇 Claude 家族模型且緩存未開啟時：只提醒開啟緩存，不自動修改設定。
- 開啟緩存母開關時：關閉上下文限制及其動態摘要。
- 關閉緩存母開關時：關閉緩存專用摘要與 Keep-Alive。
- 開啟上下文限制母開關時：關閉緩存、緩存專用摘要與 Keep-Alive。
- 關閉上下文限制母開關時：關閉動態窗口摘要。
- 規則只在明確的 provider／模型選擇與設定保存事件執行，不在發送請求時暗中改寫。
- Inkling 與有效 Key 仍為當前來源時，直接嘗試開啟 Cache 會被攔截並顯示原因；重新進入設定頁也會修復舊版遺留的 Cache 開啟狀態。

## Claude Cache 隔離

Claude 模型判斷同時檢查 provider 與模型家族；Thinking Machines 不會被歸入
OpenRouter、Bedrock 或 OpenAI Compatible 的 Claude Cache 路線。本次沒有修改：

- Claude `cache_control`
- 1 小時 TTL
- rolling breakpoint
- 動態 prompt 與 cached prefix 的分離方式
- Claude cache usage 欄位解析

既有 Claude Cache body／TTL 測試已重新通過。

## 用量監控與對話 Token

- Inkling 串流與非串流回覆會讀取第一方 `input_tokens`／`output_tokens`。
- 對話頂部 Token 數字使用 API 真實 usage 累計，不使用字數近似值冒充實際帳單量。
- Inkling usage 會寫入 `usage_logs`，供今日／本週／本月、模型分佈與估算費用使用。
- 修正一項 provider 競態：用量、cache 命中標記與 Keep-Alive 記錄改用「本次請求開始時的 provider 快照」，避免串流期間切換模型後把舊請求記到新來源。
- API 未回 usage 時不寫入零值請求，避免用量面板虛增請求數。

## 二次審計修正

- OpenAI Compatible 手動輸入 Claude 模型名時，保存後同樣會觸發一次 Cache 建議，不再只覆蓋模型列表點選。
- Keep-Alive 資格改用統一的 provider＋Claude／Gemini 家族判斷；不含 `anthropic` 前綴的自訂 Claude 模型不再被錯判。

## 驗證

- 費用設定狀態機：9 項通過。
- Inkling 當前來源直接重開 Cache 的 UI 攔截：1 項通過。
- Inkling service、usage、第一方錯誤與 provider 隔離：9 項通過。
- Inkling TokenTracker → 對話累計 → SQLite 用量彙總：2 項通過。
- Claude Cache 與通用 widget 回歸：13 項通過。
- 相關檔案 Flutter analyze：無 issue。

合計 34 項相關測試通過。

完整專案二次驗證：65 項通過、1 項既有 `backup_format_test` 失敗；失敗原因是程式目前會捨棄孤兒訊息，舊測試仍期待拋出 `FormatException`，與本次模型費用規則無關。完整專案 analyze 只有 `backup_service.dart` 兩個既有 `avoid_print` info。

## 信心水位

- 設定互斥、母子開關與 Inkling 強制策略：99%。
- Inkling usage 解析、對話累計與用量資料庫：98%。
- Claude Cache 未受影響：98%。
- 真機上的提示訊息時序、開關重繪與視覺操作感：90%；目前只有程式與測試驗證，尚未完成裝置 UI 驗收。

低於 95% 的項目只有真機 UI 驗收。建議實機依序驗證一次：開啟 Cache 與專用摘要，切換到已填 Key 的 Inkling，確認兩者關閉且上下文限制開啟；再切回 Claude，確認只出現提醒，直到使用者手動開啟 Cache 才關閉上下文限制。
