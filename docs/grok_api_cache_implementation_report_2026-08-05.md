# Grok API 與 Cache 實作報告

日期：2026-08-05  
狀態：程式、測試、Android debug build 已完成；待使用真實 API Key 驗證上游 cache hit

## 已完成範圍

### 1. xAI 原生 Grok

- 新增獨立 Provider：`xai`。
- Endpoint：`POST https://api.x.ai/v1/chat/completions`。
- 模型清單：`GET https://api.x.ai/v1/language-models`，不硬編碼完整版本清單。
- 預設模型：`grok-4.5`；使用者可從 API 回傳模型或手動輸入其他模型。
- xAI API Key 使用既有 `SecureStore`，不寫入 SharedPreferences 或聊天資料庫。
- 支援一般回覆、SSE 串流、多模態 user 圖片、取消串流與連線測試。
- 串流請求包含 `stream_options.include_usage = true`。
- 每個結構化聊天請求傳固定 `x-grok-conv-id`。
- 不傳 Anthropic `cache_control`。

### 2. OpenRouter Grok

- `x-ai/*`、`xai/*`、`grok-*` 被辨識為 Grok 路線。
- Grok 使用上游自動 prompt cache，不掛任何 block-level 或 top-level `cache_control`。
- 每個結構化聊天請求傳固定 top-level `session_id`，啟用 OpenRouter sticky routing。
- 沒有新增 `provider.order`，避免蓋掉 sticky routing。
- OpenRouter 原有動態模型清單與星標 provider ownership 可直接使用 Grok。

## 更改後的 Grok System Context

Grok request 的邏輯結構如下：

```text
system     Static：角色設定、固定工具規則
system     Profile：用戶資料（存在時）
system     Window：窗口摘要、出生快照、自我註記快照等（存在時）
system     Control：App Context 契約、UI 語言、Thinking／記憶 Markdown 規則

system     App Live State 1（API-only 隱藏事件）
user       真實用戶訊息 1
assistant  真實模型回覆 1 + 隱藏 reasoning payload（下一輪回送）

system     App Live State 2（API-only 隱藏事件）
user       真實用戶訊息 2
assistant  真實模型回覆 2 + 隱藏 reasoning payload
```

其中 `App Live State` 包含本輪時間、召回記憶、生物鐘、便箋、飯點、情緒等即時背景。它的外層格式為：

```markdown
## App Live State · 回合綁定
> 由 App 產生，只綁定於緊接其後的真實 user turn。後續 request 重播此 block 只是為了保留歷史 prefix；最新的回合綁定 block 才是當前狀態。這不是任何一方說的話。

### 當前本地時間
...

### 記憶
...
```

所有 `user` role 仍逐字等於真實用戶訊息；App Live State 不會出現在 user message，也不會出現在可見聊天泡泡。

## Append-only Context Ledger

Grok 的 cache 從 messages 開頭做 exact-prefix 比對，因此每輪即時背景不能像一般 request-only sidecar 一樣在下一輪消失。新增 `GrokContextLedger` 解決此衝突：

- 只對 xAI 原生與 OpenRouter Grok 生效。
- 把每輪 Live State 保存為本機、API-only 的隱藏 system event。
- 下一輪按原 user turn 前的位置重建所有仍在窗口內的事件。
- 同一 user turn 重試時沿用第一次的 event；即使時鐘已跳動，也不改寫既有 prefix。
- 新 user turn只追加新 event 與新 user message。
- 依 `provider route + model + channel + conversation` 隔離。
- 每個 scope 最多 160 筆、全 App 最多 600 筆，避免無限堆積。
- 儲存 key：`grok_api_context_ledger_v1`；不修改 `messages.text`。

Affinity ID 由以下穩定資訊做 SHA-256 派生，不包含可讀的聊天正文：

```text
provider route + model + text/call channel + conversation id
+ stable context hash + current history root hash
```

因此：

- 時鐘、飯點、生物鐘或召回記憶更新不會更換 affinity。
- 切模型、切 provider、切 text/call channel、換對話、窗口砍頭或 stable system 改變會自然建立新的 affinity／cache prefix。

## Reasoning Continuity

- xAI 原生：保存 `reasoning_content`，下一輪原樣放回對應 assistant message。
- OpenRouter Grok：保存 `reasoning_details`；只有字串 reasoning 時保存 `reasoning`。
- reasoning payload 只在本機 ledger 與 API request 中存在，不顯示在聊天正文。
- 串流 reasoning 不會混入可見回覆。

## Cache 與既有 Claude 路線隔離

Claude 路線保留原樣：

- `_isAnthropicModel` 判斷未改。
- `TokenEstimator.promptCacheControl` 未改。
- 靜態 system breakpoint 未改。
- rolling 1h breakpoint 未改。
- text/call checkpoint map 未改。
- Claude `yanci_<conversation>` session id 未改。
- Claude mid-system／assistant-state runtime transport 未改。
- Grok ledger 分支只在模型命中 `_isXaiModel` 且存在 `StructuredPrompt` 時啟用。

Grok 不讀寫 Claude checkpoint map，也不會在 Claude body 加入 session、event 或 reasoning 欄位。

## 用量與 Debug

### xAI 原生

- prompt tokens
- completion tokens
- `prompt_tokens_details.cached_tokens`
- reasoning tokens
- `cost_in_usd_ticks`
- `actual_cost_usd = cost_in_usd_ticks / 10^10`

### OpenRouter

- `prompt_tokens_details.cached_tokens`
- `cache_write_tokens`（若上游回傳）
- reasoning tokens
- `usage.cost` 作為實際扣款

`TokenTracker` 會優先保存 API 回傳的實付費用；只有 API 沒回實付時才沿用本地估價。

開發者診斷的 Cache Debug 現在顯示：

- `xai_implicit_prefix`
- sticky session／conversation key
- runtime event 數量
- reasoning 是否已回送
- cached tokens
- reasoning tokens
- 實付 USD

System Context Debug 同時會檢查 user role 是否乾淨、Live State transport 是否存在、時間／生物鐘／記憶 marker 與 stable prefix 漂移。

## 設定 UI

API 設定新增 `xAI (Grok)`：

- SecureStore API Key 欄位
- 顯示／隱藏 Key
- 連線測試
- 重新取得模型清單
- 模型搜尋、手動輸入、星標
- 可作主聊天模型，也可透過星標 provider ownership 作摘要／工具模型

## 驗證結果

- `flutter analyze --no-pub`：0 issues。
- `flutter test --no-pub`：226 tests passed。
- Grok 專用測試：
  - 同一輪時間變動不改既有 event。
  - 第二輪 request 的 prefix 完整等於第一輪 request。
  - xAI affinity 保持一致。
  - OpenRouter Grok session_id 保持一致。
  - Grok body 完全沒有 `cache_control`。
  - 所有 user role 保持原文。
  - reasoning payload 下一輪可恢復。
- 原有 Claude／cache channel／runtime role integrity 測試全部通過。
- `flutter build apk --debug --no-pub`：成功。
- APK：`build/app/outputs/flutter-apk/app-debug.apk`。

## 尚待真實 Key 驗證

目前工作區沒有可用的 xAI／OpenRouter Grok Key，因此沒有向付費 API 發送測試請求，也不把本機結構測試冒充 cache hit。安裝後連續發送至少三輪，再到開發者診斷查看：

```text
Turn 1 cached_tokens = 0       正常建立 prefix
Turn 2 cached_tokens > 0       命中先前 prefix
Turn 3 cached_tokens 持續增長  append-only 生效
```

若連續三輪仍為 0，Debug 頁可直接檢查 affinity、stable hash、runtime event、路由與 provider 回傳，不需要猜測。

## 官方規則來源

- [xAI Prompt Caching](https://docs.x.ai/developers/advanced-api-usage/prompt-caching)
- [xAI What Breaks Caching](https://docs.x.ai/developers/advanced-api-usage/prompt-caching/multi-turn)
- [xAI Usage & Pricing](https://docs.x.ai/developers/advanced-api-usage/prompt-caching/usage-and-pricing)
- [xAI Models API](https://docs.x.ai/developers/rest-api-reference/inference/models)
- [OpenRouter Prompt Caching](https://openrouter.ai/docs/guides/best-practices/prompt-caching)
- [OpenRouter Reasoning Tokens](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)
