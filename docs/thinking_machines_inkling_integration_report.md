# Thinking Machines Inkling API 整合報告

日期：2026-07-16

## 結論

Holt 已具備獨立的 `thinking_machines` API 來源。使用者可在 API 設定頁輸入
Tinker API Key，直接使用第一方模型 `thinkingmachines/Inkling`。

實際可用仍取決於 Tinker 帳號是否已開通 Anthropic-compatible inference，以及
帳號是否有可用額度。使用者實測已取得 Tinker 線上 402 回應，證明請求已抵達
服務端，但尚未完成一次成功內容生成。

## 接入方式

- Provider：`thinking_machines`
- 顯示名稱：`Thinking Machines (Inkling)`
- 模型預設值：`thinkingmachines/Inkling`
- Base URL：`https://tinker.thinkingmachines.dev/services/tinker-prod/anthropic/api`
- 推理端點：`POST /v1/messages`
- 連線測試：`POST /v1/messages/count_tokens`
- 認證：獨立 `x-api-key`，不使用 OpenRouter Key 或 OpenRouter headers
- API Key 儲存：獨立 SecureStore key `thinking_machines_api_key`

## 原始碼隔離

Inkling 協議實作位於獨立檔案：

- `lib/services/thinking_machines_service.dart`

該 service 不 import、繼承或呼叫 `OpenRouterService`，也不使用 OpenRouter URL、
模型列表、錯誤文案、usage 結構或 Authorization 設定。

為防止舊版「模型 ID 含 `/` 就推斷為 OpenRouter」的邏輯再次誤綁：

- `thinkingmachines/...` 永遠解析為 `thinking_machines`
- `tinker://...` 永遠解析為 `thinking_machines`
- 如果舊星標曾保存為 `openrouter`，解析時會修正為 `thinking_machines`
- 摘要、記憶整理、表情包視覺等工具模型按各自保存的 provider 建 adapter

## 已實作能力

- Anthropic Messages 非串流與 SSE 串流
- system prompt、多輪訊息與動態 prompt 注入
- Data URL 與 URL 圖片輸入
- Inkling 原生 thinking blocks
- `low`、`medium`、`high`、`xhigh` 思考強度
- 關閉思考時送出 `thinking: {type: disabled}`
- thinking block 對接 Holt 現有思考面板
- Anthropic `input_tokens` / `output_tokens` 用量讀取
- Inkling 64K 與 `:peft:262144` 價格估算
- 專屬 400、401、402、403、404、429、5xx 錯誤分類
- 繁體中文、簡體中文、英文即時錯誤文案
- 使用 `count_tokens` 驗證 Key、模型及帳號權限

## 能力限制

官方目前把相容推理標記為 beta，適合測試、評估與低流量用途。Holt 在選用
Thinking Machines 時會停用顯式 prompt caching 與 Keep-Alive Guard，因為官方
文件說明此 Anthropic-compatible endpoint 會忽略 `cache_control`。

音訊輸入暫未接入；官方目前只在相容端點明確支援文字與圖片。模型本身雖支援
更長 context，Holt 不會把模型卡的 1M 上限直接視為 Tinker 託管端點保證值。

## 驗證結果

- Dart targeted analysis：通過，無 issue
- Flutter full-project analysis：Inkling 相關程式無 issue；專案原有
  `lib/services/backup_service.dart` 兩個 `avoid_print` info，因此全專案命令退出碼為 1
- Inkling service + provider selection tests：18 項全部通過
- 已覆蓋：請求 body、獨立 header、圖片格式、非串流、SSE、thinking、usage、
  count_tokens、OpenRouter 隔離、英文與中文錯誤
- Flutter full test suite：Inkling 相關測試全部通過；專案既有
  `backup_format_test.dart` 一項失敗（程式捨棄孤兒訊息，測試仍期待拋出
  `FormatException`），與本次 API 接入無關

## 信心水位

- 本地架構與 provider 隔離：99%
- 依官方文件實作的協議正確性：97%
- 尚未成功生成內容時的線上端到端可用性：85%

低於 95% 的唯一項目是線上端到端驗證。使用者實測得到 HTTP 402，已驗證端點
可連線並進入服務端帳號／計費檢查，但帳號額度或計費設定仍阻止成功推理。處理
帳號狀態後，可先在設定頁點擊連線測試；成功後再發送一條普通文字與一張圖片
完成實機驗收。

## 官方依據

- https://tinker-docs.thinkingmachines.ai/tinker/compatible-apis/anthropic/
- https://thinkingmachines.ai/model-card/inkling/
- https://tinker-docs.thinkingmachines.ai/tinker/models/
