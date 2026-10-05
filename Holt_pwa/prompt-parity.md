# Flutter → Holt PWA Prompt／Cache 對齊契約

Flutter 是 Prompt 文字、分段順序與 provider transport 的唯一真源。PWA 不是直接複製 Dart，而是逐字復刻輸出契約；同一組等價資料必須產生相同的 Prompt 層級與字串。

## 不可改動的邊界

- API Provider、模型與 Key 仍由 `api.js` 讀取目前設定；Prompt builder 不讀取、保存或輸出憑證。
- `cacheableParts` 依序為 `staticPart → profilePart → windowPart → resolvedControlPart`。
- `requestOnlyPart` 只放本輪時間、Thinking、召回、狀態與不可信工具證據；不得寫入聊天歷史或穩定 cache prefix。
- Provider transport 負責包 `## App Live State` 信封，不得改寫最後一條真實 user 訊息。
- Anthropic、Grok 與 Gemini 的 cache 協議仍由既有 `prompt-cache.js`／`api.js` 負責；功能 Prompt 不可自行繞過。
- 測試資料只能使用合成角色與合成對話，不得放真實 Key、Profile、記憶或聊天內容。

## 第一批已涵蓋

- 角色卡欄位正規化為 Flutter `【角色設定】` 靜態層。
- 使用者資料逐字對齊 Flutter `【用戶檔案】` 格式。
- 自我註記移入 window snapshot；同一對話窗口內保持穩定。
- 當前本地時間與 Thinking 指令移入 request-only live state。
- App Context 契約、Live State 信封、不可信 Evidence 信封與 Grok 回合綁定文字對齊 Flutter。
- OpenRouter／Gemini／Grok 使用同一份 StructuredPrompt；API 來源只決定 transport，不改 Prompt 內容。
- 網搜與繪圖已具備 PWA 執行器：網搜證據只進入當輪 request-only，繪圖由 `<draw>` 或直接生圖入口觸發。
- 窗口摘要、時間線召回、記憶／蛛網關聯、情緒、生物鐘、貝殼快照／增減量、便箋、悄悄話、刮刮卡、轉帳與表情包均有 PWA 本機執行器。
- 回覆風格與拆分回覆由模型選擇浮窗控制；文字收藏、聲音收藏與下載由聊天訊息操作完成。

## 暫未啟用

Flutter 的工具 Prompt 不可只注入文字而沒有執行器。以下項目仍未開放：商店、背包、通話與 X 發文。

PWA 仍不宣稱 Flutter 全量 parity：商店／背包與通話保持平台邊界；隱藏中的角色資源總覽入口暫不解鎖。

## 每批驗收

1. 更改：只處理一個功能群，不混入 UI 美化或 Flutter 產品邏輯變更。
2. 檢查：語法、diff、檔案行數、無用程式與敏感字串掃描。
3. 驗證：合成 fixture 比對 Prompt 字串、順序、cache 分層與 provider role transport。
4. 實際環境：以 origin 方式開 PWA，檢查 Service Worker 更新、對話送出、重載後資料與 Console／Network。
5. 報告：列出修改／新增／刪除檔案、各自職責、Cache／Prompt 影響與實機清單；通過後才進下一批。
