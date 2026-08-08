# System Context 分層與幽靈消費修復報告

日期：2026-08-02（第二輪修訂）

## 結論

聊天、圖片與通話請求現在使用四層邏輯 context：

1. `staticPart`：角色規則與固定工具能力。
2. `profilePart`：用戶資料。
3. `windowPart`：開窗時拍攝、允許在窗口內穩定快取的狀態快照。
4. `turnPart`：本輪即時時間、記憶召回、生物鐘與狀態變化。

前三層使用真正的 system role。`turnPart` 為兼容各家 API，放進最新 user request 的獨立 App runtime sidecar block，位於歷史 cache breakpoint 之後。它不寫入資料庫、不顯示在聊天介面，也不與用戶原文合併成同一字串；但在 API 協議層仍使用 user role，這是保留跨模型歷史 cache 的兼容性取捨。

舊版 `cacheStableDynamicPart` 已從資料結構與正式請求路徑移除。Claude Prompt Cache 開啟時，前三層與既有對話歷史可繼續命中；每輪 sidecar 不帶 cache 標記，不能再用首輪快照替換 `turnPart`。

第二輪已另外完成三項：所有摘要入口統一格式、記憶／摘要關鍵詞召回修復、自我註記語義去重。三者都沒有把每輪變動塞回可快取 system 前綴。

## 更改後的實際 System Context

### 1. staticPart：跨輪固定規則

按以下順序組裝：

- 全局 system prompt（若不是角色描述的舊版鏡像）
- 角色設定
- 可用工具總說明
- 蛛網記憶能力，或普通記憶能力
- 情緒座標能力（開啟時）
- 生物鐘記錄能力（開啟時）
- 圖片生成能力（支持且開啟時）
- 商店、便箋、刮刮卡、轉帳、語音通話能力
- X 發文能力（開啟時）

這一層只描述「角色是誰、能做什麼、固定規則是什麼」。

### 2. profilePart：用戶資料

- 用戶姓名、資料與用戶設定產生的 profile prompt

它仍是獨立 system 區塊，不會偽裝成 user 消息。

### 3. windowPart：窗口快照

按以下順序組裝：

- 開窗時釘住的角色自我註記
- 婚姻狀態
- 開窗時貝殼餘額
- 開窗時釘住的窗口摘要
- 開窗時可用表情包清單
- 開窗時生物鐘習慣清單

本輪新增的自我註記、餘額變化、習慣變化不會修改這層，而是進入 `turnPart`，避免為了一次變化重建整個窗口前綴。

### 4. turnPart：每輪即時 App Runtime Context

文字消息按以下順序組裝：

- 本輪命中的長期記憶
- 動態窗口摘要與關鍵詞召回
- 貝殼與背包變化
- 本輪刮刮卡、購買失敗與一起逛商店狀態
- 結婚證與 X 發文當前狀態
- 當前情緒狀態
- 生物鐘當前時段提醒、帶冷卻的去重、校準或構建期飯點提示
- 本窗口新增習慣
- 本窗口新增或修訂的自我註記；若與窗口快照近似，明示以新版本為準
- 第一輪角色生活狀態快照與生物鐘構建提示
- 時間線回憶
- 疲勞提示
- 當前本地日期、星期、時分與 UTC offset
- 本輪思考、拆分回覆與回覆風格規則
- 蛛網多關鍵詞碰撞通知

時間格式示例：

```text
【當前本地時間】2026年8月1日 週六 15:42（UTC+08:00）
```

這一整層每次真實文字或圖片請求都重新生成。Claude Cache 開啟時仍發送本輪值，不再回退到開窗時間。Adapter 會在傳輸時加上隨 App UI locale 變化的來源信封：

```text
【App 即時背景｜由應用程式產生，不是用戶說的話】
目前 App UI 語言是繁體中文。請使用繁體中文回覆……

（turnPart）

【下一個 content block 才是用戶實際訊息，請回應該訊息】
```

`zh_TW / zh_CN / en` 分別使用繁體中文、簡體中文和英文。切換 UI 語言會合理地旋轉一次語言相關 system/window cache；時間更新本身不會旋轉穩定 cache。

通話使用相同分層：聊天窗口傳入 `staticPart / profilePart / windowPart`，每個通話輪次重新生成包含記憶、情緒、通話模式和當前時間的 `turnPart`。

## 各適配器的發送方式

### OpenRouter Claude

一條 system message 內只放可快取內容，之後是歷史與最新 user：

```text
[system: static]
[system: profile]
[system: window + cache_control]
[cached conversation history + rolling breakpoint]
[latest user: App runtime sidecar block]
[latest user: actual user block]
```

`turn` 不帶快取標記。時間戳只改變 sidecar，不改變 system 或 rolling-history breakpoint 前綴。

### OpenAI-compatible Claude

使用三條依序排列的穩定 system messages；快取標記放在最後一個可快取層。設定完 rolling breakpoint 後，再把 `turn` 作為最新 user 的獨立 sidecar block。

### AWS Bedrock Claude

使用 Anthropic `system` blocks；最後一個可快取 block 帶 `cache_control`。`turn` 不再放在頂層 system，而是在歷史 breakpoint 後加入最新 user 的獨立 sidecar block。

### Gemini

Gemini explicit `cachedContent` 只包含 `static/profile/window`，可在有每輪動態 context 時繼續復用。`turn` 是最新 user 的第一個獨立 part，實際用戶輸入是下一個 part。沒有 explicit cache 時，穩定內容仍放在 `systemInstruction` 開頭，以利用 Gemini 2.5+ 的 implicit prefix cache。

### DeepSeek、Qwen

穩定內容使用 system messages；`turn` 使用緊鄰最新 user 前的獨立、request-only user sidecar message。這避免依賴部分相容 API 不支持的多段 content schema。

### Thinking Machines

穩定內容使用頂層 system；`turn` 使用最新 user 的獨立 text sidecar block。

### 本地模型

本地 runtime 沒有遠端 prompt cache，因此仍將四層合成完整 system instruction，確保模型能看見每輪時間與狀態，而不存在 cache 中斷成本。

## 幽靈消費修復

新增 `DeferredPrompt` 與 `DeferredPromptBatch`：

```text
只讀產生候選提示
        ↓
加入本輪 turnPart
        ↓
模型請求開始成功返回／成功完成
        ↓
提交冷卻、計數或隊列消費
```

已改為延遲提交的狀態：

- 生物鐘 `lastInjectAt`
- 生物鐘習慣 `lastTriggeredAt`
- 生物鐘 `lastCalibrateAt`
- 生物鐘構建期早餐／午餐／晚餐／睡眠時段送達記錄
- 生物鐘同組去重提示的送達冷卻
- 記憶 `mention_count`
- 蛛網記憶觸發與清晰度更新
- 強制回想隊列消費
- 一起逛商店剩餘輪數
- 購買失敗提示清除

請求在發送前失敗、被取消或沒有真正開始返回時，上述狀態不會消費；重試仍能得到同一提示。提交本身是冪等的，同一請求的多個串流 chunk 不會重複增加計數。

## 保活行為

Keep-Alive 只用於續接既有 cache，不是角色可見的新對話輪次，因此持久化最後一次真實請求的四層 context 原樣續期。下一條真實文字、圖片或通話消息仍會重新建立新的 `turnPart`。

舊版保存的 `dynamic` key 只作一次遷移讀取；舊的 `stableDynamic` 不再恢復成窗口內容，下一次持久化會清除舊 key。

## 摘要格式統一

自動摘要、手動摘要、整塊 AI 修訂、局部修訂回填、關鍵詞來源摘要、記憶頁手動編輯，現在共用同一個模型無關的入庫契約：

```markdown
## 前情提要
（壓縮後的既有背景；沒有時為 —）

## 本次摘要
**1. 重要事件與決定**
* **主題：** 明確事實
```

英文 UI 對應 `Prior Context / This Update`，簡體 UI 對應簡體區塊名稱。模型回傳舊標題、英文標題、Markdown code fence、「手動摘要」外殼或純敘事文字時，儲存前都會轉成同一結構；純敘事內容會安全包進「重要事件與決定／摘要」條目，不憑空分類或改寫事實。

舊資料在記憶頁顯示、注入動態摘要或被重新編輯時也會以統一格式讀取。已存在對話的 `pinned_static_summary` 不做批次改寫：它是窗口出生時釘死的 cache 快照，強改會令舊窗口前綴失效；新窗口取得的摘要均為新契約格式。

摘要模型請求是獨立內部請求，不加入聊天消息歷史，也不復用聊天 prompt cache。因此本次摘要 prompt 與正規化器更新不會旋轉聊天 cache。

## 關鍵詞召回修復

長期記憶與壓縮摘要關鍵詞現在共用同一套本地匹配器：

- 英文大小寫不敏感。
- 全形英數轉半形，空白與標點差異不再造成漏召回。
- 支援逗號、頓號、分號、換行、直線分隔，以及 `別名=正式名`、斜線別名。
- 多詞關鍵詞可在句中分散命中。
- 四字以上拉丁產品／模型名允許一次保守拼寫誤差；中文不做模糊字距，避免誤召回。
- 多條命中先按匹配強度排序，再受原有 token budget 約束，避免低相關記憶先占滿預算。
- 壓縮摘要不再只取「最新一個碰巧包含字串」的 block，而是先比較全部候選，再召回最相關段落。

匹配與排序只決定本輪 `turnPart` 的內容，不改 `staticPart/profilePart/windowPart`。`mention_count` 仍在模型請求成功送達後才提交，因此召回修復沒有重新引入幽靈消費。

## 自我註記去重

`persona_note` 入庫改為 transaction 內原子讀寫，並在 12 條 FIFO 之前執行保守近似去重：

- 忽略項目符號、標點、空白、大小寫與全形差異。
- 相同、包含度高或雙字組高度重疊的註記視為同一條。
- 新版本資訊更完整時原位替換；否則忽略，不消耗新槽位。
- 被忽略的重複註記不再產生「已寫入自我註記」操作紀錄。

窗口的舊 self-note 快照仍保持不變以保 cache；本輪若有原位修訂，放在 `turnPart` 的「新增或修訂」段，並明示它覆蓋相似舊版本。

## Cache 影響審計

| 改動 | 實際所在層／請求 | 會否刷新既有聊天 cache |
|---|---|---|
| 摘要 prompt 與輸出正規化 | 獨立摘要模型請求 | 否 |
| 新生成摘要 | 新窗口的固定快照，或本輪 `turnPart` | 舊窗口否；新窗口本來就建立新 cache |
| 舊摘要讀取正規化 | 記憶 UI／動態摘要 sidecar | 否 |
| 記憶與摘要關鍵詞命中 | 本輪 `turnPart` | 否 |
| 自我註記去重入庫 | 本地資料庫 | 否 |
| 自我註記新增／修訂提示 | 本輪 `turnPart` | 否 |

結論：本輪修改沒有增加任何每輪變動的 cacheable system block。能命中的 `static + profile + window + 歷史 breakpoint` 逐字保持；只允許 breakpoint 後的 request-only runtime sidecar 每輪變化。

## 未包含在本批的項目

- 記憶管理防護：新增記憶時的重複提示。
- 記憶管理防護：模型或 UI 刪除／合併前的用戶確認。

依照本輪範圍，這兩項留到下一批，不在這次偷偷改變刪除／合併權限。

## 驗證

- Flutter analyzer：0 issues
- Request 完整性測試：用戶原文不被修改；App sidecar 與原文是不同 block/message
- Claude cache 測試：只改動動態時間時，system 與 rolling-history cached prefix 完全相同
- Gemini cache 測試：有動態 runtime 時仍使用既有 explicit cachedContent
- Locale 測試：runtime sidecar 嚴格跟隨 `zh_TW / zh_CN / en` App UI 語言
- 生物鐘測試：提示未提交前不進冷卻，提交後才冷卻
- 生物鐘構建測試：飯點提示未送達可重試；成功後同日期／時段不重複，下一飯點仍可觸發
- 記憶測試：提示未提交前 `mention_count` 不變，提交後只增加一次
- 摘要契約測試：GPT 式純文字、舊英文標題與手動摘要外殼都轉成同一 Markdown 結構
- 召回測試：大小寫、全形、標點、別名分隔與短泛詞防誤觸發
- 自我註記測試：標點重複被忽略，資訊更完整的近似版本原位替換
- 全量 Flutter 測試：205 passed
