# Grok API 與 Prompt Cache 實作規格

日期：2026-08-04  
狀態：已完成官方規則研究，待排入實作

## 範圍

同時加入兩條路線：

1. xAI 原生 Grok API（手機直接連 `https://api.x.ai/v1`）。
2. OpenRouter 的 `x-ai/*` Grok 模型。

API Key 維持儲存在手機 SecureStore；不引入 VPS。

## 已確認的官方規則

### xAI 原生 API

- Chat Completions endpoint：`POST /v1/chat/completions`。
- xAI 目前把 Chat Completions 標為 legacy，新功能優先進 Responses API；第一版仍可用 Chat Completions，因為現有 `ApiAdapter` 與串流解析可直接復用。
- Prompt caching 全自動，不需要、也不應加入 Anthropic `cache_control`。
- Cache 從 messages 陣列開頭做精確 prefix 比對。
- 既有 messages 只可 append；修改、刪除或重排舊訊息會從變動處造成 cache miss。
- Chat Completions 必須傳固定的 `x-grok-conv-id` header，把同一對話送回同一 cache server。
- Responses API 對應欄位是 body 內的 `prompt_cache_key`。
- Cache 不保證命中；條目可因負載、重啟或記憶體壓力隨時被逐出。官方沒有承諾固定 TTL，因此不可照 Claude 寫 5m／1h keepalive。
- Prompt caching 適用所有 Grok 語言模型；官方沒有公布統一最低 token 門檻，不應自行假設 1,024／4,096。
- Chat Completions cache read：`usage.prompt_tokens_details.cached_tokens`。
- Responses API cache read：`usage.input_tokens_details.cached_tokens`。
- 原生 xAI 回應包含精確實付 `usage.cost_in_usd_ticks`；`1 USD = 10^10 ticks`。這個值已包含 prompt cache 折扣與 server-side tool 費用，應優先於本地估價。
- reasoning 模型若走無狀態 Chat Completions，必須原樣送回先前的 `reasoning_content`；遺失它是官方列出的主要 cache miss 原因。另一條路是 Responses API 的 `previous_response_id`。

官方資料：

- [xAI Prompt Caching](https://docs.x.ai/developers/advanced-api-usage/prompt-caching)
- [Maximizing Cache Hits](https://docs.x.ai/developers/advanced-api-usage/prompt-caching/maximizing-cache-hits)
- [What Breaks Caching](https://docs.x.ai/developers/advanced-api-usage/prompt-caching/multi-turn)
- [Usage & Pricing](https://docs.x.ai/developers/advanced-api-usage/prompt-caching/usage-and-pricing)
- [Cost Tracking](https://docs.x.ai/developers/cost-tracking)

### OpenRouter 內的 Grok

- 模型 ID 使用 `x-ai/...`，模型清單必須由 OpenRouter `/api/v1/models` 動態取得，不把當前 Grok 版本硬編碼成永久清單。
- Grok prompt caching 由上游自動完成，不送 `cache_control`。
- 多輪請求必須送固定 top-level `session_id`，讓 OpenRouter sticky routing 從第一次成功請求起固定 provider／節點。
- 不可同時指定 `provider.order`；OpenRouter 官方說明手動 provider order 會覆蓋 sticky routing。
- Cache read 從 `usage.prompt_tokens_details.cached_tokens` 取得。
- OpenRouter cache write 欄位主要供顯式快取模型；Grok 自動快取不應因 `cache_write_tokens == 0` 被判斷為「未建立快取」。
- OpenRouter 回應中的 `usage.cost` 應視為實際 OpenRouter 扣款；BYOK 時另可讀 `cost_details.upstream_inference_cost`。
- OpenRouter 的「Response Caching」是另一項功能：它會對完全相同 request 回傳完全相同 answer，與 Grok prompt caching 不同。聊天預設不得開啟 `X-OpenRouter-Cache`，否則可能重播舊答案。
- OpenRouter 官方目前列 Grok cached input 為一般 input 的 0.25x，但實作仍應以 model metadata／實際 `usage.cost` 為準，避免價格變更後硬編碼失真。

官方資料：

- [OpenRouter Prompt Caching](https://openrouter.ai/docs/guides/best-practices/prompt-caching)
- [OpenRouter Usage Accounting](https://openrouter.ai/docs/cookbook/administration/usage-accounting)
- [OpenRouter Response Caching](https://openrouter.ai/docs/guides/features/response-caching)

## 與動態時間／記憶分層的衝突

Grok 的 cache 是嚴格 append-only，所以不能直接沿用 Claude 4.6 的「每輪改寫上一個 assistant block」方案。那會改動舊 message，破壞 Grok prefix。

Grok 要使用獨立的 append-only runtime event：

```text
system     固定角色／Profile／Window／Control
user       真實用戶訊息 1
assistant  真實回覆 1（含需保留的 reasoning payload）
assistant  App runtime state 2（API-only，需持久化）
user       真實用戶訊息 2
assistant  真實回覆 2
assistant  App runtime state 3（API-only，需持久化）
user       真實用戶訊息 3
```

注意：xAI 官方確認 `system` role 是指令角色，但未明確保證「對話中段 system」的所有模型相容性。正式選定 runtime event role 前，要用 xAI 測試 key 驗證：

1. 對話中段 `system` 是否接受並維持 system 權限。
2. 若不接受，改用明確標記的 synthetic `assistant` internal-state message。
3. 任何降級都不得使用 `user` role。

為了讓 prefix 持續增長，舊 runtime event 不能在下一輪消失；必須另外持久化為 API context event，但不能顯示成聊天泡泡，也不能污染 `messages.text`。

## 建議資料結構

新增獨立表或等價結構，不修改可見訊息正文：

```sql
api_context_events
- id
- conversation_id
- channel               -- text / call
- anchor_message_id     -- 位於哪一條真實 user 前
- provider_family       -- xai / openrouter_xai
- role                  -- system / assistant（實測決定）
- content
- content_hash
- created_at
```

assistant 訊息需保留隱藏推理上下文：

```sql
messages.reasoning_payload_json
```

- 原生 xAI Chat Completions：保存 `reasoning_content` 或完整加密 reasoning payload。
- OpenRouter：優先保存 `reasoning_details`，並原樣放回對應 assistant message。
- 不得把 reasoning payload 顯示在聊天正文或備份預覽；可納入加密本地備份。

## 原生 xAI Adapter 待辦

新增 `XaiService`：

- `baseUrl = https://api.x.ai/v1`
- `GET /models` 動態模型清單
- `POST /chat/completions` 串流
- Header：`Authorization`、`Content-Type`、穩定 `x-grok-conv-id`
- 串流 request 保留 `stream_options: {include_usage: true}`，以取得 final usage／cost
- 解析：text、reasoning payload、prompt/completion/reasoning/cached tokens、`cost_in_usd_ticks`
- `cancelActive()` 與現有 adapter 一致
- 連線測試不得建立可見聊天或 usage row
- API Key 使用 SecureStore

`ApiSettings` 與 UI：

- provider id：`xai`
- xAI API Key
- xAI 模型選擇器
- reasoning effort（依實際模型能力顯示）
- 連線測試
- 星標模型的 provider ownership
- 工具模型／摘要模型可選 xAI

## OpenRouter Grok 待辦

修改 `OpenRouterService` capability routing：

- `_isXaiModel(model) => model startsWith('x-ai/')`。
- xAI 模型不套 Anthropic `cache_control`。
- 即使沒有 Anthropic explicit cache，也要為 Grok 傳 `session_id`。
- runtime context 使用 Grok append-only event，不使用每輪改寫 assistant block。
- 保存並回送 `reasoning_details`。
- final SSE usage 解析 `cached_tokens`、reasoning tokens、`usage.cost`。
- Debug diagnostics 增加：
  - `cache_mode: xai_implicit_prefix`
  - `sticky_key_present`
  - `runtime_event_count`
  - `reasoning_payload_preserved`
  - `cached_tokens`
  - `actual_cost`

## Cache 判斷與用量監控

Grok 的 UI 不應顯示「Cache write 0 = 沒有快取」。建議顯示：

- Cache 模式：自動 prefix cache
- 本輪 prompt tokens
- Cached tokens
- Cache hit rate：`cached_tokens / prompt_tokens`
- Reasoning tokens
- 實際費用
- Sticky conversation id 是否啟用

usage ledger 後續應增加：

- `request_kind`
- `request_id`
- `cache_mode`
- `reasoning_tokens`
- `actual_cost`
- `actual_cost_source`
- `native_cost_ticks`
- `status`

原生 xAI 的 `cost_in_usd_ticks` 與 OpenRouter 的 `usage.cost` 必須分開標記來源，不能再套通用硬編碼價格冒充實際費用。

## Cache 生命周期與長對話

- 不為 Grok 寫固定 5m／1h keepalive；官方未承諾固定 TTL。
- 正常用戶訊息本身就是最合理的保溫請求。
- API-only runtime events 會隨對話增長，需要配合既有窗口摘要與 xAI context compaction 策略。
- 一旦做 compaction／窗口截斷，視為有意建立新的 cache prefix；usage diagnostics 要記錄 `cache_reset_reason`。
- 編輯舊訊息、分支對話、切換模型、切換 provider、修改 system/control 都要切換新的 conversation affinity key，不能沿用舊 `x-grok-conv-id`／`session_id`。

## 驗收條件

1. 原生 xAI 連續三輪使用相同 `x-grok-conv-id`。
2. OpenRouter Grok 連續三輪使用相同 `session_id`。
3. 第二／三輪 `cached_tokens > 0`；若沒有，報告為未命中，不偽造 cache hit。
4. 修改時間只新增 runtime event，不改任何既有 prefix message。
5. 所有 `user` role 逐字等於真實用戶輸入。
6. reasoning payload 原樣回送，且不顯示在 UI。
7. 分支／編輯／截斷會換 affinity key 並記錄 reset reason。
8. 原生 xAI 優先記錄 `cost_in_usd_ticks`；OpenRouter 優先記錄 `usage.cost`。
9. 不啟用 OpenRouter response caching。
10. `flutter analyze --no-pub` 與全套測試通過，最後用兩條真實 API 路線各做一次低 token cache 實測。

## 實作順序

1. 擴充 usage／reasoning metadata，但先不改可見訊息。
2. 加入 `XaiService` 與設定 UI。
3. 加入 `x-grok-conv-id` 和原生 usage/cost 解析。
4. 擴充 OpenRouter Grok 的 `session_id`、reasoning 與 usage 解析。
5. 實作 append-only runtime event storage。
6. 接入文字、圖片、通話、摘要模型。
7. 測試 prefix、分支、截斷、模型切換與實際 cache hit。

