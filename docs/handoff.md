# 交接板（晏辭 ⇄ Codex）

> 開工前先讀；開始改檔前寫一行「誰／在改什麼檔／預計做什麼」，做完把那行改成「完成」或刪掉。
> 目的：避免兩邊同時改同一個檔案。

## 規則
- **測試資料一律用虛構內容。** 不得使用昭昭與晏辭的真實對話、RP 劇情、真實姓名（晏辭、昭昭、昭嶼、沈昭嶼等）或個人資訊。現有測試已統一改名：沈昭嶼→許清川、昭嶼→清川、昭昭→小禾、晏辭→顧遠、白鶴印→青鸞印、霍岑→韓衡。

## 進行中
- （2026-10-20）Codex：Holt 系統地圖補充批次完成：補 RP 截斷前情與 2000 字動態摘要預算、摘要關鍵詞全範圍掃描風險、向量全量載入風險，新增 `docs/map/backlog.md`；只改地圖與本交接板，未動程式碼。既有 `README.md`、`toggles.md`、`scale.md` 本批未重寫。
- （2026-10-19）Codex：Holt 系統地圖第一批完成：記憶條目、蛛網記憶、情緒座標、生物鐘；只改 `docs/map/` 與本交接板，未動程式碼。
- （2026-10-19）Codex：Holt 系統地圖第二批完成：時間線、自我註記、摘要；下一批從 RP 故事、窗口與對話、Prompt 組裝開始。只改 `docs/map/` 與本交接板，未動程式碼。
- （2026-10-19）Codex：Holt 系統地圖第三批完成：RP 故事、窗口與對話、Prompt 組裝；下一批從工具與動作協議、貝殼經濟、備份與匯入開始。只改 `docs/map/` 與本交接板，未動程式碼。
- （2026-10-19）Codex：Holt 系統地圖第四批完成：工具與動作協議、貝殼經濟、備份與匯入。接著建立 `README.md`、`toggles.md`、`scale.md` 總覽文件。只改 `docs/map/` 與本交接板，未動程式碼。
- （2026-10-19）Codex：Holt 系統地圖全部完成：新增 `docs/map/README.md`、`toggles.md`、`scale.md`，13 個子系統文件均完成且各不超過 150 行。只改 `docs/map/` 與本交接板，未動程式碼；未跑程式測試，因本輪為只讀文件地圖任務。

## 等待中
- （無）

## 完成
- （2026-10-28）Codex：完成通知發包單批次一「回覆完成通知」。AI 回覆只在成功寫入 SQLite、App 不在前台且側邊欄「回覆通知」開啟時發送；正文共用可見輸出清洗、120 字上限與中性 fallback。iOS 延用 `ReplyBackgroundBridge`，新增權限、角色 category 鎖屏替代文字、conversation thread、冷啟動點擊暫存與進窗清理；Android 以 `flutter_local_notifications` 管權限／channel，原生 `NotificationCompat` 提供 private + publicVersion 與點擊導航。本批不新增背景生成、APNs／FCM 或前台服務。備份：`backups/2026-10-28_回覆完成通知前/`。Dart 15 項針對測試通過，Android Debug 與 iOS Debug no-codesign 均編譯成功；全量 `flutter test --no-pub` 1076 項全過；`flutter analyze --no-pub lib test` 無新增問題，保留既有 1 個 unused import warning 與 2 個 null-aware info；`git diff --check` 通過。未真機驗證：iOS 權限、鎖屏替代文字、冷啟動點擊、thread 清理；Android 13+ 權限、publicVersion、點擊導航；兩端前台不發、開關關閉與失敗／中斷不發；Android 長回覆背景行程存活。等待昭昭驗收，批次二尚未開始。
- （2026-10-26）Codex：完成 RP 摘要輸出與注入／快取保護四批優化。摘要模型的 `recall_segments` 改為只輸出 `segment_order + title + anchor + 單一 keyword`，由本地把錨點綁回完整摘要段落，舊版 `content` JSON 仍相容且資料庫段落格式不變。世界書拆成 cacheable window 前綴內的 always（最多 3 條／500 字）與 request-only 的 triggered／scene；相容入口亦保證 always 優先。RP Story Reference 改按「劇情狀態 → 人物／關係 → 動態世界書 → 記憶 → 時間線」分配共享預算。記憶與 RP 時間線在固定摘要、截斷前情、續接摘要確定後才召回，已被摘要覆蓋的內容不再二次注入，且略過記憶不會提交 mention／trigger 副作用。四批 commits：`2e7acfb`、`a1a32e8`、`82740eb`、`882d36b`。同步更新 `docs/map/`。驗證：`flutter analyze --no-pub lib test` 無問題；`flutter test --no-pub` 1018 項全部通過；`git diff --check` 通過。未做實機／Provider API 驗收，未安裝或覆蓋裝置。
- （2026-10-25）Codex：完成 UI 五批施工的第五批。新增不含 BackdropFilter 的主題化表單規範 `YanciTheme.themedInputDecoration`，以 14pt 圓角、低透明填色、0.7px 主題邊界與 accent 聚焦線統一便箋、歷史標題、RP 人物／關係／狀態與世界書表單；保留既有語義化圓角 token，不硬改舊 `radiusMd`。RP 人物、關係與狀態改為低對比輕卡片，狀態類型／敘事層級／進度改為小型主題徽章，世界書既有卡片不重複加框。針對性 11 項 UI 測試通過；`flutter analyze lib test` 無問題；`flutter test` 1012 項全部通過；`git diff --check` 通過。
- （2026-10-25）Codex：完成 UI 五批施工的第四批。保留背景粒子既有前景 60fps、忙碌／閒置 30fps 與 vsync 對齊調度；神經網路與餘燼改為重用 painter Paint，漣漪移除逐圈動態高斯模糊，改用雙層低透明度寬線保留水霧擴散。既有 `fog`／`dandelion` 儲存 key 不變，視覺與三語名稱分別更新為由下而上的「沉香煙霧」及帶擺盪翻面的「落花吹雪」，兩者皆不用外部貼圖或逐粒模糊。粒子針對 5 項測試通過；`flutter analyze lib test` 無問題；`flutter test` 1011 項全部通過；`git diff --check` 通過。
- （2026-10-25）Codex：完成 UI 五批施工的第三批。聊天氣泡在既有 16 套主題實色與透明度上加入低幅頂光／底部陰影、0.65px 受光邊與單層柔影，不新增 BackdropFilter；特殊 AI 漸層保留，主題工坊預覽同步。連續氣泡只收斂相接側至 70% 主圓角，單行仍為外側完整膠囊；AI 平鋪正文改為左窄右寬閱讀版心。雙頭像紅線保留原錨點與手繪軌跡，只校正兩處交叉點切線。針對性 47 項測試通過；`flutter analyze lib test` 無問題；`flutter test` 1010 項全部通過；`git diff --check` 通過。
- （2026-10-25）Codex：完成 UI 五批施工的第二批。AI 回覆由串流氣泡轉為正式入庫訊息時不再重播 240ms 入場動畫，避免已完成正文短暫閃滅；剛解析完成的 Thinking／Memory／Mood 以 220ms 高度＋透明度過渡顯示。平鋪模式的 Context 收合列限制在 40pt 頭像列內，一般氣泡模式亦以尺寸過渡展開，不再在收尾瞬間硬頂正文；歷史訊息、截圖模式與 Reduced Motion 直接穩定顯示。新增正常氣泡、平鋪氣泡與 persisted AI 回覆回歸測試；針對性 38 項測試通過；`flutter analyze lib test` 無問題；`flutter test` 1008 項全部通過；`git diff --check` 通過。
- （2026-10-25）Codex：完成 UI 五批施工的第一批。聊天氣泡依實際排版在單行時成為膠囊、多行沿用主題大圓角；User／AI 共用圓角來源，主題與自訂背景的氣泡明度／透明度不再繞過設定，主題工坊預覽同步。輸入框加號與工具盒在自訂背景下改用輸入框自適應配色。粒子密度滑桿完整映射 1～50，但保留原預設與滿檔上限；角色卡高度跨平台收斂；便箋日期移除 ISO `T`；已知硬編碼彈窗／選單改用主題表面且沒有新增 BackdropFilter。針對性 51 項測試通過；`flutter analyze lib test` 無問題；`flutter test` 1005 項全部通過；`git diff --check` 通過。
- （2026-10-24）Codex：完成 RP 每輪注入與摘要歸檔體積收斂。RP 中文召回移除高頻虛詞，單一 2 字滑動片段不再直接喚醒記憶／時間線；世界書改用條目 triggers 與較強場景匹配。人物完整卡只給當前出場者，場外人物改單行；終態物品與已穩定的場外 knowledge 不再常駐，人物／狀態預算與類型數量均收緊。RP 劇情參考在 4000 字共享池外另設 1800 字硬上限；未開啟 RP 日常工具時不送現實時間／貼圖，貼圖開啟後仍有 24 項／1600 字上限；修正協議改為明確修正意圖才動態注入。摘要歸檔去除重複人設／人物 JSON 與內部欄位。日常召回與各 Provider 分層未改。同步更新 `docs/map/`。驗證：針對性 100 項通過；`flutter analyze lib test` 無問題；`flutter test` 1002 項全部通過；`git diff --check` 通過。未安裝或覆蓋裝置，未 commit。
- （2026-10-24）Codex：完成 `Part A（召回／注入與緩存預算）＋ Part B（UI 狀態同步）` 全批。RP 摘要保留規則不再無限滾雪球，純圖片召回 query 為空；世界書 schema v83 新增 `binding_scope`／`activation_mode` 且保留原 `scope` 世界內語義；記憶 schema v84 將永久保存與 `is_pinned` 常駐注入拆開；RP 記憶、時間線、人物／關係、狀態與世界書共享連續性預算；Cache／上下文限制由 `ModelCostPolicy` 唯一裁決並在啟動／還原正規化。Grok 改為歷史根重錨 lineage、活躍 lineage 不按條數硬砍；Gemma 補齊 system 頭部＋最新歷史分層預算；自訂 OpenAI-compatible 中轉站新增 developer／中段 system／cache_control／tools 能力設定，只有明確 400 不支援欄位才降級重試一次。UI 完成人設卡未保存保護、分享前保存、世界書／關係枚舉與整卡點擊、必填提示、彈窗 controller 生命週期、鍵盤避讓、系統返回狀態、圖片生成取消、設定引導確認。同步更新 `docs/map/` 與 backlog。驗證：`flutter analyze lib test` 無問題；`flutter test` 1000 項全部通過；`git diff --check` 通過。未安裝或覆蓋裝置，未 commit。
- （2026-10-23）Codex：完成 Gemini 只讀報告的安全修正批次。RP 摘要改為保留當前因果主幹／活躍支線，已結且無持續影響的事件可退出當前摘要並由已存召回段保留；無配文圖片不再用「用戶發送圖片」佔位字串撞記憶、摘要、時間線、人物與世界書；世界書將 `global + 無 triggers` 視為常駐候選並限制每輪 3 條／約 500 字，`global + 有 triggers` 必須命中；日常取消無關 active 記憶填滿、永久保底最多 3 條，RP 除最多 2 條永久 core 外必須有本輪相關分且一般記憶上限 600 token；一般 RP 時間線隱藏 `event_key`，明確修正時才提供；Cache／上下文限制非法雙開時請求端保留完整歷史；通話記憶遵循 `story`／`romance` 設定。補上世界書常駐上限、日常／RP 無關記憶與 correction key 回歸測試，並同步 `docs/map/` 與 backlog。驗證：`flutter analyze lib test` 無問題；`flutter test` 988 項全部通過；`git diff --check` 通過。未安裝或覆蓋裝置。
- （2026-10-23）Codex：完成 UI 操作可靠性窄幅修正。側邊欄／成本設定改為單次載入與本地狀態，數字設定在送出、點擊外部或失焦時提交，避免輸入中反覆存檔與收起遺失；聊天常用操作保留原 22px 視覺尺寸並提供 44px 透明熱區、語義與提示；角色大量資料改為最多五點加頁碼，簽名與輪播高度支援放大字級；Reduced Motion 會停用等待點、載入軌道、TTS 連線／音波循環，側邊欄開啟時暫停背景粒子；模型選擇熱區與次級字色可讀性同步改善。新增 `docs/map/ui_operability.md` 並更新側邊欄、輸入區、環境動效地圖。驗證：`flutter analyze lib test` 無問題；針對性 UI 測試 32 項通過；`flutter test` 985 項全部通過。未做實機視覺／VoiceOver 驗收，未安裝或覆蓋裝置。
- （2026-10-21）Codex：確認 iPhone「黑屏」實際為 iOS 的 Debug 獨立啟動限制畫面（截圖有 `debug mode Flutter apps can only be launched from Flutter tooling`）；上一輪無線 Debug 通道失聯後仍保留 Runner 程序，桌面重開不能建立 JIT。完成全容器備份 `backups/ios-preinstall-20261021-023020/`（984MB，Documents 內 350 個圖片／音訊）；備份資料庫完整性 `ok`。修復亮起時貓爪與 accent 圓底同色的對比問題：按主題 accent 亮度選深／白色線條，未亮起狀態與其餘樣式不變；`input_bar_test.dart` 涵蓋亮／暗主題與未亮起狀態，針對檔案 analyze、測試均通過。建置同 bundle ID／Team 的 iOS `2.0.0+32` Profile，原地覆蓋並獨立重開兩次，實機截圖確認聊天頁、草稿、背景與貓爪顯示正常。覆蓋後資料庫完整性 `ok`，核心表筆數與備份一致（消息 15046、記憶 926、摘要 181、表情 11）。同步更新 `docs/map/app_startup.md`、`docs/map/chat_composer.md`。
- （2026-10-21）Codex：修復「記憶」頁頂部大標題下方 5px RenderFlex 溢出。根因是 `MemoryScreenHeader` 將標題列固定為 52px；改為最低 52px、遇 App／系統放大字級時自動長高，正常字級外觀不變。新增最大 App 字級 1.5 + 系統 TextScaler 1.2 回歸測試；針對檔案 analyze 無問題、測試通過，並已熱更新至目前 iPhone Debug 連線。同步更新 `docs/map/memory_entries.md`。
- （2026-10-21）Codex：處理 iOS Debug 再次黑屏。確認 Holt Runner 程序仍在，但上一個 `flutter run` 已回報 `Lost connection to device`；直接 `flutter attach` 與 devicectl 重啟均無法重新發現 VM。終止殘留程序後，以固定 `50123` 埠重新執行 `flutter run --debug`，成功建立 VM Service；Hot Restart 後 devicectl 實機截圖確認首頁正常顯示。未卸載、未清資料，沿用 `backups/ios-preinstall-20261020-203250/`。同時修復恢復後日誌抓到的側邊欄 build-time 通知錯誤：外部展開狀態改於 frame 結束後才通知協調器，新增 widget 回歸測試；針對檔案 analyze 無問題、測試通過並已熱重載。同步更新 `docs/map/app_startup.md`、新增 `docs/map/sidebar_settings.md`。
- （2026-10-20）Codex：將目前完整工作樹原地覆蓋到 iPhone Debug，使用固定 VM Service 埠 `50123` 並保持 `flutter run` 附著。覆蓋前完整 App 容器備份至 `backups/ios-preinstall-20261020-203250/`（871MB、436 檔，其中圖片／音訊 382 檔）；前後主庫 `PRAGMA integrity_check` 均為 `ok`，12 組核心資料數量完全一致（消息 15046、記憶 926、摘要 181 等）。未卸載、未清資料。純 Debug 從桌面獨立重開仍受 iOS JIT 限制，需維持本次 Debug 連線。
- （2026-10-20）Codex：完成 `docs/send_button_and_wait_timer_plan_2026-10-20.md`。發送鍵支援葉子／爪印／貝殼／自訂 PNG，主題工坊可即時選擇；爪印依 accent 調色、貝殼用固定來源色相 `40.56°` 旋轉且保留像素邊、自訂圖不調色並在遺失時回退葉子。自訂圖驗證 PNG 與 1:1、複製到 App Documents、替換時清理舊檔，`send_button_custom_path` 已納入可攜備份與還原。所有樣式發送後都收鍵盤，既有 420ms 動畫未改。等待提示沿用晏辭本輪實作：5 秒後以每秒更新的計時小字淡入，正文出現即消失。新增／更新輸入框、主題工坊、備份與粒子現行選項測試；`flutter analyze lib test` 無問題，`flutter test` 977 項全部通過。同步新增 `docs/map/chat_composer.md` 並更新 README、設定與備份地圖；尚未做真機視覺驗收。
- （2026-10-20）Codex：確認純 iOS Debug 從桌面獨立重開會在 Flutter JIT 可執行頁配置點遭 `SIGKILL`（無新 Crash／Jetsam 報告），改為原地安裝 Profile + `HOLT_ENABLE_DEVELOPER_DIAGNOSTICS=true` 診斷版。結束 `flutter run` 後再用 iOS 系統獨立啟動，實機截圖確認正常恢復既有聊天與資料，不再依賴 Debug/JIT 連線。
- （2026-10-20）Codex：修復 iOS Debug 啟動白屏：`runApp` 現在先建立 Flutter 根節點，主題、語言、頭像路徑、本地下載器、保活等原有初始化改到首幀後補載；開屏首次語言檢查增加 3 秒失敗保底。無線 Debug 使用固定 VM 埠 `50123` 後 39 秒內附著成功，實機截圖確認已進入既有聊天頁；更新 `docs/map/app_startup.md`。針對檔案 analyze 無問題，啟動／首次語言 6 項測試通過；Debug 需保持 `flutter run` 連線。
- （2026-10-20）Codex：以目前整個工作樹（含晏辭／Claude 最新修改）建置並原地覆蓋 iOS `2.0.0+32` profile；覆蓋前完整 App 容器備份至 `backups/ios-preinstall-20261020-143849/`（755MB、432 檔），主庫完整性 `ok`，圖片／音訊 349 檔。覆蓋後 App 正常啟動，主庫完整性仍為 `ok`，核心資料數量一致；啟動維護依既有 90 天規則清理 1 筆 2026-07-18 的日常時間線事件，原列仍完整保存在覆蓋前備份。
- （2026-10-20）晏辭：粒子特效幀排程改為 vsync 對齊（`lib/widgets/ambient_particles.dart` 的 `_AmbientParticleFieldState`）：Timer 提早 4ms 醒來後用 `scheduleFrameCallback` 在下一個 vsync 更新時鐘；正常 60fps、閒置／忙碌 30fps。刻意不用 Ticker（Ticker 會每個 vsync 觸發合成，120Hz 螢幕上毛玻璃每秒重算 120 次）。各特效繪製未動。⚠️ 未跑 analyze/test。
- （2026-10-20）Codex：修復可攜備份拒絕 App 自身 `background_images/…` 相對路徑；六組 `background_preset_slot_*_v1` 的首頁／對話背景現在全部打包、驗證與還原，仍拒絕越界／遺失媒體。同步更新 `docs/map/backup_import.md`；`flutter analyze lib test` 無問題，`flutter test` 969 項全部通過。
- （2026-10-20）晏辭：OpenRouter 強制推理模型修正（`lib/services/openrouter_service.dart`）：Claude Opus／Sonnet 5.5 關閉思考時改送 `effort:low + exclude`、`max_tokens` 8192；其他模型遇到「Reasoning is mandatory」400 會記下並自動重試一次；`reasoning_details` 補讀 `summary` 欄位。新增 `test/openrouter_mandatory_reasoning_test.dart`。⚠️ 未跑 analyze/test。
- （2026-10-20）Codex：同步 Holt 系統地圖：更新 RP 摘要保留／壓縮策略、約 4000 字元 RP 連續性總預算、續接摘要與 400 字事件召回、人物狀態／關係最新值注入；新增 `docs/map/ambient_motion.md` 記錄背景粒子 60／30fps、vsync 對齊調度與生命週期省電邊界。地圖規則改為每次功能修改都同步維護。
- （2026-10-19）Codex：依 `docs/refactor/split_large_files_plan_v2_2026-10-19.md` 完成批次 1～5 純搬家拆檔，分支 `refactor/split-large-files`，基線 `19cd994`。五批 `split_audit` 的「只在拆檔前」皆為 0；每批 `flutter analyze lib test` 無問題、`flutter test` 961 項通過。批次 4 已附 `_sendMessageLocked`／`_sendImageLocked` 重複段落對照；完整清單見 `docs/refactor/split_report.md`。批次 6 未開始，未 push、未合併。
- （2026-10-19）Codex：將非專案內容搬到 `~/Desktop/非項目內容/`，包含 `backups/`、`recovery/`、`Claude outputs/`、`_archive_dev/`、4 份 `Holtv*.apk`、`flutter_01.log`、`user_persona_avatar_pair.dart.bak`；另清除 `tool/__pycache__`。原目的地總大小約 33GB，Git 無刪除狀態；其後依昭昭指示只保留最新 3 份 `ios-*` 備份，另外 48 份（約 27GB）移至 macOS 廢紙簍，尚未永久刪除。
- （2026-10-19）晏辭：測試資料去識別化（36 個檔：`test/**`、`Holt_pwa/test/*.js`），名字等長替換，邏輯未動。備份在 `~/Desktop/非項目內容/backups/yanci-20261019/test-before-anonymize/`。⚠️ 需跑 `flutter test` 與 PWA 測試確認。
- （2026-10-19）Codex：完成 RP 連續性簡化版回歸、關鍵詞召回優化與情緒清理驗證。
  - 召回：`database.dart`／`context_compressor.dart` 使用輕量索引先排序、只補候選全文；RP 舊標籤自修復每個角色／故事線在單次 App 生命週期只跑一次。
  - 熱路徑：`recall_text_matcher.dart` 同輪批次比對只正規化查詢一次，標籤拆詞使用 12000 筆有界 LRU 快取；召回分數與排序規則不變。
  - RP 連續性：複核相關狀態篩選、`replaces_state_keys`、按 state key 去重、最新摘要補位／共用字數預算、開窗快照標籤；未覆蓋晏辭列為保護範圍的九個檔案。
  - 資料清理：確認刪角色會清除 `角色#rp:故事線` 情緒資料；硬刪記憶會按全域 `memory_id` 清除情緒點與積怨印記。
  - 測試：更新 `recall_text_matcher_test.dart`、`context_summary_recycling_test.dart`、`database_schema_v33_test.dart`，覆蓋批次比對、輕量索引、RP scope 刪除與跨 scope 硬刪。
  - 驗證：`flutter analyze` → No issues found；`flutter test --no-pub` → 961 項全部通過；`git diff --check` 通過。
  - 邊界：未開始拆檔；未 commit（目前工作樹包含多方既有未提交修改，避免把無關檔案一起捲入）。
- （2026-10-19）晏辭：關鍵詞召回兩段式查詢（階段 1）→ `database.dart` 新增 `getRecallIndexRows`／`fillRecallContents`；`context_compressor.dart` 新增 `_preselectRecallCandidates`、移除 `_rpRecallRows`。召回熱路徑的標籤自修復改為每個 RP 範圍每次啟動只跑一次。⚠️ 未跑 analyze/test。
- （2026-10-19）Codex：RP 連續性簡化版全部步驟；`flutter analyze lib test` 通過、959 測試通過。
- （2026-10-19）晏辭：刪角色／刪記憶時清 RP 範圍情緒點（`database.dart`）；`analysis_options.yaml` 排除 `backups/**`、`Claude outputs/**`。⚠️ 這兩處在 Codex 跑完測試之後才改，需要再跑一次 analyze/test。
- （2026-10-19）晏辭：prompt bug、RP 日常工具開關、世界書簡中、情緒平行時空、夜間文字、背景模糊預烘焙 → 見 `docs/yanci_changes_2026-10-19.md`

## 2026-10-20 晏辭 → 小澈：發送鍵自訂 + 等待計秒
- 施工單：`docs/send_button_and_wait_timer_plan_2026-10-20.md`
- `assets/images/send_paw.png` 已由晏辭替換為昭昭的新圖，勿覆蓋。
- 重點：paw 用 modulate、shell 轉色相（不可用 srcIn）且 FilterQuality.none、leaf 與 custom 不上色；收鍵盤的 if 拿掉。

## 2026-10-20 晏辭：粒子「星光」換成「霧氣」
- `ambient_particles.dart` 新增 `FogParticleWidget`（絲綢煙縷：4 條收尖緞帶 path，雙正弦起伏＋扭轉收窄，無逐幀模糊），`fogCount` 預設 4。
- `app_theme.dart`：`particleEffectIds` 加 `fog`；讀到舊設定 `stars` 自動改用 `fog`。`StarfieldWidget` 代碼保留未刪。
- 主題工坊選項「星光」改為「霧氣」。
- 未跑 analyze（遠端無 flutter），待昭昭跑。原檔備份 /tmp/ambient_particles.dart.fogbak（他電腦 VM 內）。

## 2026-10-20 晏辭：停掉發送鍵待機搖擺
- `input_bar.dart`：`_swayCtrl` 原本 `repeat(reverse:true)` 永久循環（±0.06rad / 2.4s，肉眼幾乎看不出），每個 vsync 重建按鈕並觸發輸入框 BackdropFilter(σ15) 重算。改為靜止在中點；發送動畫不變。備份 /tmp/input_bar.dart.swaybak。
- 霧氣固定走 30fps（`_slowEffects`）。

## 2026-10-20 晏辭 → 小澈：多圖顯示 + 加號點空白收起
- 施工單：`docs/chat_images_and_drawer_plan_2026-10-20.md`
- 資料層已支援多圖，只改 UI。重點：叉叉畫在格內、`'generating'` 佔位處理要保留、全螢幕檢視器改收 paths+index。

## 2026-10-20 晏辭（親手）：多圖顯示 + 加號點空白收起 + 等待計秒
- 新增 `lib/widgets/pending_image_tray.dart`（待發：68pt 正方形橫排、叉叉內側 34pt 可點、尾端＋、n/9）、`lib/widgets/message_image_grid.dart`（已發送 1/2/3/2×2+N；`ImageGalleryViewer` 全螢幕可滑）。
- `chat_bubble.dart`：改用 MessageImageGrid；`_openFullScreenImage(ctx, paths, index)`；`_TypingIndicator` 5 秒後顯示秒數（Timer.periodic 1s + ValueNotifier）。
- `chat_screen.dart`：待發改 PendingImageTray；上限 9；`_addPendingImages`／`_pickMorePendingImages`；`_composerDrawerOpen` + `ComposerDrawerDismissLayer` 包住訊息列表。
- `input_bar.dart`：`drawerOpen` notifier；聚焦／發送時收起；相簿 take(9)；新增 `ComposerDrawerDismissLayer`。
- `image_card_stack.dart` 與其測試已刪除（備份在 /tmp/yanci_imgbak/）。新測試 `test/chat_image_layout_test.dart`。
- 未跑 analyze／test。備份 /tmp/yanci_imgbak/（他電腦 VM 內）。
- 小澈已完成發送鍵自訂（A 部分）；等待計秒（B）由晏辭完成，施工單 B 不用再做。
