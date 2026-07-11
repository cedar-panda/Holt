---
name: holt-fix-guide
description: Holt (Flutter) 修復審查清單——改動前必查緩存/安全/雙路徑/Web/iOS。修改或修復 Holt 代碼時使用。
---

# 雙路徑鐵律
- chat_screen.dart 有 text path + image path，改標籤解析/靜態 prompt 必同步兩邊
- 新標籤三件套：解析（雙路徑）+ 流式過濾 regex（防閃現）+ 氣泡端隱藏

# 緩存（最常中招）
- **鐵律**：模型標籤寫回、再注入 prompt 的數據，先問「進靜態還是動態？」靜態注入可變數據一律**快照+增量**：開窗凍結快照進靜態，窗內新增走動態增量，下次開窗重拍。已中招三次：表情包 prompt、習慣清單、selfNotes/persona_note
- OpenRouter body 禁 `provider.order`/`allow_fallbacks`（會禁用 sticky routing → cache 永不命中），只留 `session_id`
- 緩存門檻：Opus 4.5–4.8 統一 4096
- 靜態 prompt 任何改動 = 緩存重建一次，批量修改一起上
- 統計要讀 `prompt_tokens_details.cache_write_tokens`

# 安全基線（勿回退）
- AndroidManifest: `allowBackup="false"` + networkSecurityConfig（禁明文，僅 localhost/10.0.2.2 例外）；無全局 usesCleartextTraffic
- 所有 http：流式 `send().timeout(30s)` + client try/finally close；非流式 `timeout(180s)`；流式解碼 `Utf8Decoder(allowMalformed:true)`
- 簽名：key.properties/*.jks 不入 git；releaseKeystoreReady 半配置退 debug
- 文件寫入：換圖/換檔先刪同 scope 舊檔（防洩漏）
- 已知未修 C/D（改到相關文件順手評估）：importFromJson 不驗證輸入、LIKE 未轉義、SigV4 路徑未 URI encode、backup_meta db_version 硬編碼、毫秒 ID 碰撞、導出在外部存儲

# 注入 prompt 的時間
- 帶 HH:MM 的注入必標「這是習慣時間，不是現在的時間，以【時間】為準」

# Web
- 像素尺寸用 `pixelScaleFor(viewportWidth)` 動態，不碰全局常量；resize 走 didChangeDependencies 更新 scale + re-clamp 位置
- dart:io/Platform 調用加 kIsWeb 守衛；文件路徑類插件 web 行為不同

# iOS
- 局域網明文（LM Studio）：需 Info.plist ATS 例外，Android networkSecurityConfig 管不到 iOS
- 權限：NSMicrophoneUsageDescription（STT/通話）、NSSpeechRecognitionUsageDescription
- workmanager 週期後台 iOS 不保證執行（BGTaskScheduler），保活勿假設會跑；目前僅 Android 註冊
- SoLoud/Haptic/STT 插件 iOS 真機驗證後才算數

# 憑文檔寫、未真機驗證的 API
- flutter_soloud 4.0.8、workmanager 0.9、flame 1.37 —— 報錯先對 API 簽名，別懷疑邏輯

# 修復方法論（動手前）
1. 先找根因證據鏈，不對症貼膏藥。歷史根因都很小：緩存炸=selfNotes 前綴變、粒子跳=repeat 跳回 0、時間線清空=importFromJson 缺表
2. 改前三問：這數據進靜態還是動態？雙路徑都改了嗎？會炸緩存嗎（能批量就一起上）？
3. DB 加新表 = 必同步 exportToJson + importFromJson（導出有導入無 → 恢復即靜默丟失）
4. 衰減/冷卻類邏輯：微調寫回會不會重置錨點（updated_at 重置 → 衰減永不觸發，中招過）
5. 定時任務別信 Dart Timer 後台會跑：改 tick 制 + 錨點 persist prefs + onAppResumed 補針

# 遊戲（Flame）
- 常數全在 game/config.dart；素材只換 sprite/yanci_pixels.dart，其他不動
- scale 一律傳參，不碰全局常量
- NPC 本地模型 ≠ 聊天本地模型時互踢 buildAdapter 全局緩存 → 接對話前先做讓位策略（docs/讓位策略）
- 彈 sheet/離開頁面 pauseEngine，回來 resumeEngine
- 像素小人是晏辭本人（女），相關文案第一人稱
- 動畫循環：用 Ticker 連續時鐘（AnimationController.repeat 會跳回 0）；多動畫疊加頻率取整數倍（邊界相位差 2π 才無縫）；複雜 painter 加 RepaintBoundary + isComplex（防拖累全列表重繪）

# 主題/顏色教訓
- 亮色主題永遠白卡策略（氣泡奶白+背景壓實），別加深近白氣泡：HLS 對近白降亮度=飽和爆炸
- 有色相設計的氣泡色手動定值，自動腳本只驗只修文字對比度
- 改色後跑 WCAG：文字 ≥4.5、accent/nav ≥3.0

# 摘要/小模型
- compress prompt 必含：只記明確發生的、禁推測、前次摘要原樣保留只刪減追加（錯亂=腦補+鏈式傳話漂移）
