# Holt PWA

獨立的 iOS PWA 核心，與原生 Flutter App 分開部署、分開管理瀏覽器快取。

## 核心功能

- **聊天**：流式 SSE 回覆、消息持久化到 IndexedDB、上下文管理
- **多 Provider**：OpenRouter、Grok (xAI)、Google Gemini、HTTPS OpenAI 相容中轉站（BYOK）
- **角色卡**：創建/編輯/切換角色，每個角色獨立對話記錄
- **圖片發送**：選圖後 base64 透過 vision API 發送
- **生成圖片**：四來源獨立選擇生圖模型；支援直接生成與 `<draw>` 對話協議
- **原生網搜**：明確搜尋意圖才連線；可自動使用各來源的收藏模型
- **跨窗口搜尋**：以純文字索引搜尋舊對話訊息，不載入 Base64 圖片
- **陪伴上下文**：窗口摘要、時間線召回、長期記憶／蛛網關聯、情緒座標、生物鐘與貝殼快照／增減量
- **聊天工具**：便箋、悄悄話、刮刮卡、轉帳、表情包，以及文字／聲音收藏與聲音下載
- **回覆控制**：精簡回覆、建議行數與 2～4 段聊天氣泡拆分
- **首頁**：角色列表 + 對話記錄管理
- **開屏**：沿用 Holt App 的 Logo 落下、逐字淡入、星光散開與退場動畫
- **設定**：Provider、API Key、模型、連線測試、來源隔離收藏排序、搜尋與生圖設定
- **備份**：匯出為密碼加密的 `.holt.backup`（ZIP 內層 + AES-256-GCM 外層），並保留舊 `.json`／`.holt.zip` 匯入
- **離線殼**：Service Worker 緩存靜態資源

## 暫不做

- 打電話 / 語音輸入
- 本地模型
- 禮物商店 / 背包
- 語音播放
- 角色資源總覽頁（聊天內的文字／聲音收藏與表情包已可使用；隱藏中的舊資源入口暫不解鎖）

## 本機預覽

在 `Holt_pwa/` 內啟動靜態伺服器：

```bash
python3 -m http.server 8080
```

再用瀏覽器開啟 `http://localhost:8080`。

**注意**：ES module 需要從 HTTP server 載入，不能直接 `file://` 開。Service Worker 在 localhost 可啟用；iPhone 真機須 HTTPS。

## 文件結構

```
Holt_pwa/
├── index.html          聊天頁
├── home.html           首頁（角色列表）
├── settings.html       設定頁
├── app.js              聊天核心邏輯
├── backup-bundle.js    ZIP 與 Holt AES-256-GCM 備份封裝
├── db.js               IndexedDB 存儲層
├── api.js              LLM API 調用層
├── styles.css          全部樣式
├── manifest.webmanifest
├── service-worker.js
├── _headers            安全標頭範例
└── assets/
    ├── fonts/
    └── images/
```

## Release

部署時發布 `Holt_pwa/` 整個資料夾的靜態檔案。每次修改後把 `service-worker.js` 的 `CACHE_NAME` 版本號往上調。

API Key 存在目前瀏覽器來源的 IndexedDB，不寫入備份。聊天、網搜與生圖請求會直接傳送到使用者選擇的 API 來源；完整說明見 `privacy.html`。

正式部署必須使用可信 HTTPS，並確認主機實際套用 `_headers`。每次變更靜態資源後，同步更新 `index.html` 的 CSS/JS query version、`service-worker.js` 的 `CACHE_NAME` 與 APP_SHELL；這些是快取資源版本，不是產品版本。

純邏輯與發布不變量測試：

```bash
node --test test/*.test.js
```
