# Holt PWA

獨立的 iOS PWA 核心，與原生 Flutter App 分開部署、分開管理瀏覽器快取。

## 核心功能

- **聊天**：流式 SSE 回覆、消息持久化到 IndexedDB、上下文管理
- **多 Provider**：OpenRouter、Grok (x.ai)、任意 OpenAI 兼容中轉站（BYOK）
- **角色卡**：創建/編輯/切換角色，每個角色獨立對話記錄
- **圖片發送**：選圖後 base64 透過 vision API 發送
- **首頁**：角色列表 + 對話記錄管理
- **開屏**：沿用 Holt App 的 Logo 落下、逐字淡入、星光散開與退場動畫
- **設定**：Provider 選擇、API Key、模型設定
- **備份**：匯出為密碼加密的 `.holt.backup`（ZIP 內層 + AES-256-GCM 外層），並保留舊 `.json`／`.holt.zip` 匯入
- **離線殼**：Service Worker 緩存靜態資源

## 暫不做

- 打電話 / 語音輸入
- 本地模型
- 禮物商店 / 背包
- 表情包（入口保留，功能未接入）

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

API Key 存在裝置的 IndexedDB 中，不上傳。CSP `connect-src` 已放行 OpenRouter 和 x.ai，自訂中轉站需要是 HTTPS。
