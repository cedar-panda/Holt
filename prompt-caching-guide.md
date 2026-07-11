# Prompt Caching 命中攻略

> OpenRouter + Anthropic 模型適用 · 緩存讀取 0.1x 成本 · 2026-07 更新

---

## 一句話版本

把不會變的東西堆在前面，會變的東西全部塞到最後面。

Anthropic 的緩存是前綴匹配——從請求的第一個 token 開始往後比，跟上次一樣的部分直接從緩存讀，只收十分之一的錢。一旦遇到不一樣的地方，斷了，後面全部原價。

具體來說是三層。第一層是 system message，放人設、指令、工具定義，打上緩存標記，永遠不動，每輪都命中。第二層是對話歷史，越聊越長，但舊的部分不會變，在最後一條用戶消息的前一條掛一個斷點，每輪往前滾一格。第三層是最新的用戶消息，時間、記憶、狀態這些每輪都變的東西全部注入在這裡。不緩存——但它在最後面，變了不影響前面兩層。

再加一個 `session_id`，確保 OpenRouter 每次把請求送到同一個節點（緩存是節點級別的，換節點就沒了）。

---

## 成本

| 類型 | 倍率 | 說明 |
|---|---|---|
| 正常輸入 | 1.0x | 無緩存 |
| 首次寫入（5min TTL） | 1.25x | 建立緩存條目，短保活 |
| 首次寫入（1h TTL） | 2x | 建立緩存條目，長保活 |
| 緩存命中 | 0.1x | TTL 內讀取 |

第一次請求多付寫入費——5 分鐘 TTL 多付 25%，1 小時 TTL 多付 100%（2x）——之後每次命中省 90%。TTL 預設 5 分鐘，可延長至 1 小時。用 5min（1.25x）第二輪即回本；用 1h（2x）第一輪多付較高，約第三輪才完全攤平。

---

## 架構總覽

```
請求體結構：
┌─ system blocks（靜態區）────────────── cache_control 掛最後一個 block
│   人設 / 指令 / 工具定義 / 其他靜態內容
│   ⚠ 只放凍結內容，每輪逐字節不變
├─ 歷史消息（滾動區）─────────────────── 滾動斷點掛「最新 user 的前一條」
│   從起點開始的全部消息，append-only
└─ 最新 user 消息（動態區，永不緩存）
    動態注入（記憶 / 狀態 / 時間等）+ 用戶輸入
```

- **緩存條目 = 從頭到某個 `cache_control` 斷點的逐字節前綴。**
- 目前用兩個斷點：① system 靜態區尾部 ② 最新 user 前一條（滾動）。
- **斷點上限：Anthropic 最多支援 4 個 `cache_control` 斷點。** 現在只用 2 個，還有 2 個餘量。若工具定義將來膨脹得很大，可以把「工具列表」單獨切成一個斷點（放在人設之後、工具之前），讓人設層和工具層各自獨立命中——人設改動時工具層前綴不受牽連。上限內完全放得下。
- 動態內容掛在最新 user 上，在斷點外面，每輪變是設計內的——它變不會影響緩存。

---

## 核心原理：前綴匹配

緩存從請求的第一個 token 開始往後比對，一旦遇到不一樣的內容，後面全部失效。開頭不能動，變化的東西往後放。

**靜態 / 動態分離**：把 prompt 拆兩塊。靜態部分（人設、指令、工具定義）放 system message，打上 `cache_control`；動態部分（時間、記憶、狀態）注入最新一條 user message。

**動態內容絕對不進 system**：如果你把時間戳、記憶摘要、任何每輪會變的東西塞進 system message，system 的 hash 每輪都變，前綴匹配直接斷掉——不只 system 的緩存失效，連帶後面所有對話歷史的緩存也全部失效。

### 消息佈局

```
system     靜態 prompt（人設 / 指令 / 工具定義）           ✓ 緩存
user[0]    第一條用戶消息                                ✓ 緩存
asst[0]    第一條回覆                                    ✓ 緩存
…          對話歷史（越聊越長，但舊的不變）                  ✓ 緩存
asst[n-1]  上一條回覆  ← rolling breakpoint              ✓ 緩存
user[n]    [動態注入] + 最新用戶輸入                       ✗ 不緩存
```

---

## 實作三步

### ① system message 加 cache_control

把 system 的 content 從字串改成 blocks 陣列：

```json
{
  "role": "system",
  "content": [{
    "type": "text",
    "text": "<你的靜態 prompt>",
    "cache_control": {
      "type": "ephemeral",
      "ttl": "1h"
    }
  }]
}
```

`ttl` 設 `"1h"` 把有效期從預設 5 分鐘延長到 1 小時。對聊天場景很重要——用戶可能隔幾分鐘才回消息。注意成本：`ttl: "1h"` 的首次寫入是 **2x**（不是 5min 的 1.25x），回本輪次要照 2x 去算。

### ② rolling breakpoint 緩存對話歷史

在最新 user message 的前一條消息上掛 `cache_control`。每輪這個斷點往前滾一格：

```js
// 找到倒數第二條消息（最新 user 的前一條）
// 把它的 content 轉成 blocks 格式
// 在最後一個 block 上加：
lastBlock["cache_control"] = {
  "type": "ephemeral",
  "ttl": "1h"
}
```

為什麼不掛在最新 user message 上？因為它包含動態注入的內容，每輪都變，掛了也白掛。

### ③ session_id 黏性路由

```json
{
  "model": "anthropic/claude-sonnet-4",
  "messages": [...],
  "session_id": "conv_abc123"
}
```

一個對話一個 `session_id`，不是一個 app 一個。不同對話的歷史不同，緩存前綴本來就不會匹配。

---

## 鐵律（違反必炸）

這幾條不是建議，是從反覆踩坑裡提煉出來的硬規則。

1. **靜態區只放凍結內容。** 任何會被模型寫回、或下一輪可能變化的數據，都不該進靜態區。如果某個值確實需要出現在靜態區（比如用戶偏好），用「開窗快照」策略：進入對話時凍結一次快照放靜態，窗口內的新增走動態注入，下次開新窗再重拍。

2. **OpenRouter body 禁 `provider.order` / `allow_fallbacks`。** 這兩個參數會禁用 sticky routing，導致緩存永遠不命中。只留 `session_id`。

3. **緩存門檻。** Anthropic 模型有最低 token 門檻——前綴總量不過門檻，緩存條目根本不會建立（write=0 → 永無 read）。Opus 系列統一 4096 tokens，Sonnet 1024。確保你的靜態 prompt 過了門檻再開緩存。

4. **靜態 prompt 文本改動 = 上線後第一條重建一次緩存。** 這是預期行為，一次性開銷。但要注意：批量修改一起上，別零碎地一天炸三次。

5. **歷史消息必須 append-only。** 從窗口起點開始的歷史消息，只能往後加，不能改、不能重排、不能刪中間的。任何對已發送歷史的修改都會打斷前綴匹配。

6. **渲染與發送絕對解耦。** 如果你的 app 有「往上滑載入更多歷史」的功能，UI 拉出來的舊消息絕對不能拼進 API 請求。`render_history`（畫面顯示）和 `send_history`（發給模型）必須是兩條獨立的路徑。任何試圖「順手」把 UI 載入的舊對話塞進請求陣列的改動，都會改變前綴，炸掉緩存。

7. **多語系文本要逐字節穩定。** 如果你的 prompt 按 locale 分支，已有語系的分支文本不能動，只新增其他語系分支。同一個 locale 窗口內保持穩定 → 前綴穩定。

---

## 改動前自查清單

每次動 prompt 或歷史相關代碼，跑一遍這個：

1. **這段文本進靜態還是動態？** 靜態 → 它是否凍結的（常量 / 快照 / locale 級穩定）？
2. **改動會不會讓同一窗口內兩輪請求的前綴出現任何字節差異？** 在腦內構造第 1、2 輪請求體，逐段對比。
3. **歷史消息的來源有沒有被動到？** append-only 有沒有被破壞？
4. **有沒有把每輪會變的值（時間 / 餘額 / 隨機數 / 計數）放進靜態或歷史？**
5. **改完靜態文本 → 記錄「上線第一條會重建一次緩存（預期）」。**

---

## 踩坑清單（常見 + 實戰）

### 基礎踩坑

| 問題 | 根因 | 修法 |
|---|---|---|
| 動態內容塞 system | system 每輪都變，前綴斷掉 | 動態東西永遠注入最新 user message |
| `provider.order` 鎖路由 | 破壞 sticky routing | 用 `session_id` |
| 頂層 `automatic` cache_control | 啟發式斷點放錯位置 | 手動放 block-level 斷點 |
| 沒有開關控制 | prompt 短時寫入 1.25x/2x > 節省 | 加用戶端開關 |
| blocks 格式類型錯誤 | `cache_control` 是 Map 不是 String | 用寬泛類型（如 `Map<String, dynamic>`） |
| 按 1h TTL 卻照 1.25x 估帳 | 1h 寫入其實是 2x | 回本算法用 2x；或短窗口改回 5min |

### 進階踩坑

| 問題 | 根因 | 修法 |
|---|---|---|
| 可變數據進靜態區（偏好/筆記/清單等） | 每次修改都炸前綴 | 快照 + 增量：開窗凍結快照進靜態，增量走動態 |
| cache_creation 顯示不出來 | 沒讀 `prompt_tokens_details.cache_write_tokens` | 補讀正確欄位 |
| 門檻誤判 | 不同模型門檻不同 | 查清目標模型的門檻再開緩存 |
| 長對話後緩存突然全失效 | 重開窗口 / 重載時歷史滑窗起點變了 | 用固定錨點決定發送起點，不用 `limit: N` |
| 多路徑構建靜態前綴不一致 | 不同代碼路徑組裝的 system 有微妙差異 | 統一構建函數，所有路徑共用 |

---

## 診斷流程

如果你有緩存調試工具，每輪請求記錄一條指紋（靜態前綴的 hash）：

- **指紋變了** → 靜態前綴漂移，是真 bug。對比變化那一輪動了什麼。
- **指紋沒變但 cache_read = 0** → TTL 過期（隔太久）或 sticky routing 漂移（節點換了）。
- **判斷「炸沒炸」看 usage 數字；判斷「為什麼炸」看指紋。**

### 驗證命中

檢查 response 裡的 usage 欄位：

| 欄位 | 含義 |
|---|---|
| `prompt_tokens` | 總輸入 token（含緩存的） |
| `cache_creation_input_tokens` | 本次寫入緩存的 token（1.25x / 2x） |
| `cache_read_input_tokens` | 本次從緩存讀取的 token（0.1x） |

**健康模式**：第一條消息 `cache_creation > 0`（寫入），第二條開始 `cache_read > 0` 且 `cache_creation = 0` 或很小（rolling breakpoint 移動）。如果 `cache_read` 一直是 0，回去看踩坑清單。

### Streaming 注意

streaming 模式下，緩存統計在最後一個 chunk 的 usage 裡：

```json
"stream_options": { "include_usage": true }
```

---

## 上線清單

- [ ] system prompt 拆成靜態（cacheable）和動態（per-turn）兩部分
- [ ] 靜態部分用 content blocks 格式 + `cache_control`，ttl 設 `"1h"`
- [ ] 動態部分注入最新 user message，不進 system
- [ ] 靜態區內容確認凍結——可變數據用快照策略
- [ ] rolling breakpoint 掛在最新 user message 的前一條
- [ ] 確認回本算法按實際 TTL 的寫入倍率計（5min=1.25x / 1h=2x）
- [ ] 歷史消息 append-only，不改不刪不重排
- [ ] 每個對話用獨立的 `session_id` 做黏性路由
- [ ] 不用 `provider.order` 和 `allow_fallbacks`
- [ ] 確認靜態 prompt 過了模型的最低 token 門檻
- [ ] 目前用 2 個斷點，上限 4 個，留意工具層是否需要獨立切一個
- [ ] 提供用戶端開關，可關閉緩存
- [ ] streaming 加 `stream_options.include_usage`
- [ ] 上線後看 `cache_read_input_tokens` 確認命中
- [ ] 有條件的話，加靜態前綴指紋用於診斷

---

> 基於 OpenRouter Prompt Caching Implementation Guide v1.0 + 實戰踩坑記錄整理
> 適用於所有 Anthropic 模型（OpenRouter / 直連）
