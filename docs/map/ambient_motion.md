# 背景粒子與動效調度

## 它是做什麼的（一兩句話）
在首頁、角色與對話等可見頁面繪製主題背景粒子，並集中控制刷新頻率、頁面可見性、App 生命週期與減少動態效果。

## 資料存在哪（資料表 / SharedPreferences key）
- 粒子樣式、密度、顏色與開關由 `YanciTheme` 的主題設定保存；動畫相位只存在記憶體中的 `ValueNotifier<double>`。
- 粒子本身沒有資料表，也不把逐幀狀態寫入本地。

## 誰寫入（檔案：函式）
- `lib/widgets/ambient_particles.dart:_AmbientParticleFieldState._onFrame` 在排程器交付的下一個 vsync 更新共用連續時鐘。
- `lib/widgets/ambient_particles.dart:_AmbientParticleFieldState._handlePointerEvent` 更新最近互動時間並從靜置頻率恢復。
- 各 painter 在初始化時生成自己的粒子位置與視覺參數，不在每幀改寫資料庫。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- `lib/widgets/ambient_particles.dart:_buildParticleField` 依主題選擇神經網路、星光、雨絲、漣漪、餘燼或蒲公英，將同一個 clock 傳給當前可見 painter。
- `lib/screens/home_screen.dart`、`lib/screens/character_card_screen.dart`、`lib/screens/chat_screen.dart` 掛載背景粒子。
- 這個系統只影響畫面，不注入任何 Prompt。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
無。粒子樣式由主題設定直接選擇。

## 日常 / RP 差異
沒有模式差異；是否顯示取決於頁面、主題與粒子開關。

## 相關開關
- 主題工坊的粒子特效開關、樣式、密度與配色。
- 系統「減少動態效果」會停止 clock；App 退到背景、路由不可見或 `TickerMode` 關閉時也停止。
- `HoltSidebarShell` 展開側邊欄時會把固定背景包進停用的 `TickerMode`，關閉後恢復；視覺上保留最後一幀，避免粒子讓 sigma-50 側邊欄毛玻璃每幀重算。

## 量大時的風險
- 所有粒子共用一個可見 clock，但較高刷新率仍會增加 painter 重繪與 GPU／螢幕功耗。
- 目前前景目標約 60fps；20 秒無操作或聊天忙碌時約 30fps。`Timer` 只負責在目標時間前喚醒，真正更新由 `scheduleFrameCallback` 對齊下一個 vsync，避免獨立計時器與螢幕刷新錯拍。
- 動態粒子若與大面積 `BackdropFilter` 重疊，可能令模糊層跟著重算；`RepaintBoundary` 不能保證消除所有合成成本。

## 相關測試檔
- `test/ambient_particles_test.dart`
- `test/theme_workshop_background_test.dart`
- `test/ui_operability_test.dart`

## ❓ 不確定的地方
- 60／30fps 在不同 60、90、120Hz 裝置上的實際 frame pacing 與電量成本，靜態代碼無法證明，需實機 Performance Overlay／profile trace 與電池測試。
