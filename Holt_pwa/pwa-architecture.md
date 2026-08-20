# Holt PWA 模組架構

純 HTML/CSS/JS 的 iOS PWA，SPA 架構，5 個 tab 頁面。所有資料存在 IndexedDB，不上傳。

---

## 檔案總覽

```
Holt_pwa/
├── index.html          ← 唯一 HTML，包含所有頁面骨架和浮層 DOM
├── styles.css          ← 全部樣式，CSS custom properties 控制主題切換
├── app.js              ← 核心模組：DOM 工具、共享狀態、tab 切換、動態載入 UI 模組
├── ui-home.js          ← Tab 2：首頁問候 + 聊天視圖（流式對話、圖片、表情包）
├── ui-characters.js    ← Tab 3：角色輪盤 + 編輯頁 + 時間線 + 偷偷記住你
├── ui-settings.js      ← Tab 0：API 設定（provider/key/model/prompt cache）
├── ui-profile.js       ← Tab 4：個人資料 + 主題工坊 + 備份匯出入
├── db.js               ← IndexedDB 存儲層（角色、對話、消息、設定、表情包、時間線）
├── api.js              ← LLM 流式調用（OpenRouter/Anthropic/Gemini/xAI/自訂端點）
├── prompt-cache.js     ← 提示詞快取邏輯（滾動斷點 + request-only 狀態分層）
├── font-loader.js      ← 背景載入外部字體
├── backup-bundle.js    ← 加密備份匯出 / 匯入
├── splash.js           ← 開屏動畫控制
├── service-worker.js   ← 離線 cache-first 策略
└── manifest.webmanifest
```

---

## 模組依賴關係

```
index.html
  └─ app.js (type="module", 唯一 script tag)
       ├─ db.js          ← openDB()
       ├─ 動態 import:
       │   ├─ ui-home.js       ← 靜態 import app.js, db.js, api.js, prompt-cache.js
       │   ├─ ui-characters.js ← 靜態 import app.js, db.js, ui-home.js
       │   ├─ ui-settings.js   ← 靜態 import app.js, db.js, api.js, prompt-cache.js
       │   └─ ui-profile.js    ← 靜態 import app.js, db.js, font-loader.js, backup-bundle.js, ui-home.js
       └─ ui-profile.js.initTheme()
```

### 為什麼用動態 import

app.js 匯出 `$`, `state`, `toast`, `switchTab`, `registerTabHandler` 等工具函數。UI 模組反過來需要這些工具。如果用靜態 import 會造成循環依賴 TDZ 問題。

解法：app.js 在 `init()` 裡用 `await Promise.all([import(...)])` 動態載入所有 UI 模組。這樣 app.js 的匯出在 UI 模組求值時已經完全 live。

### Tab 註冊機制

每個 UI 模組在載入時呼叫 `registerTabHandler(tabIndex, renderFn)`，app.js 的 `switchTab()` 根據註冊表分派。

---

## 資料層（db.js）

IndexedDB `holt_pwa`，version 2。

| Object Store   | Key      | 索引                        | 用途          |
|----------------|----------|-----------------------------|---------------|
| characters     | id       | by_updated                  | 角色卡        |
| conversations  | id       | by_char, by_updated         | 對話          |
| messages       | id       | by_conv, by_conv_time       | 消息          |
| settings       | key      | —                           | key-value 設定 |
| stickers       | id       | by_pack                     | 表情包        |
| timeline       | id       | by_char, by_char_date       | 時間線節點    |

---

## 主題系統

14 個預設主題（7 淺 + 7 深），透過 CSS custom properties 即時切換。`ui-profile.js` 中的 `applyThemePreset()` 一次設定所有 CSS 變數。

主題工坊浮層裡日間/夜間各一排橫向滾動色卡，選中即套用（無需按完成）。選中的色卡放大 + accent 色邊框發光，未選中的縮小 + 降低對比度。

---

## 版本管理

每次改動需要同步更新三處版本號：

1. `index.html` 裡 `styles.css?v=N` 和 `app.js?v=N`
2. `service-worker.js` 裡 `CACHE_NAME` 的版本號和 `APP_SHELL` 裡對應的檔案版本
3. UI 模組檔案不帶版本號（由 service worker 統一快取）

---

## 離線策略（service-worker.js）

- install：預快取 APP_SHELL 所有檔案
- activate：清除舊版本快取
- fetch：
  - 導航請求 → 返回快取的 index.html（保持原子性，避免新舊混搭閃爍）
  - 同源靜態資源 → cache-first，miss 時 fetch 並寫入快取
  - 跨域 API 請求 → 不走快取
