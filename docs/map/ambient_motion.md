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
- `lib/widgets/ambient_particles.dart:_buildParticleField` 依主題選擇神經網路、星光、雨絲、漣漪、餘燼、流螢光斑或落花吹雪，將同一個 clock 傳給當前可見 painter。
- `lib/widgets/ambient_particles.dart` 從 `ambient_particles_extra.dart` 對外匯出 `FireworkWidget` 等新增樣式；主題工坊與粒子 Widget 測試可共用同一粒子入口，不改各 painter 的動畫邏輯。
- `lib/theme/app_theme.dart:YanciTheme._refreshParticleBackdrop` 只計算目前主題的漸層平均底色；`_refreshParticleTones` 再以該底色調整 `starColor`／`starGlow`。`particleTone` 讀取底色時不會反過來啟動完整色調刷新，避免主題工坊及其他粒子頁面發生遞迴紅屏。
- `fog` 與 `dandelion` 是相容既有資料的穩定儲存 key；`fog` 目前以徑向漸層畫遠近景光斑，並加入多邊形散景、橫向光束與圓形 ghost 等鏡頭光暈變體，不需要遷移舊偏好或外部貼圖。診斷／測試用的 `bokeh-particles-*` ValueKey 保持不變。
- `lib/screens/home_screen.dart`、`lib/screens/character_card_screen.dart`、`lib/screens/chat_screen.dart`、`lib/screens/call_screen.dart`、`lib/screens/initial_setup_screen.dart` 掛載背景粒子；語音通話沿用同一樣式與密度、以 busy 檔刷新，首次設定同樣受主題開關、減少動態與生命週期調度控制。
- `lib/screens/home_screen_carousel.dart:_HomeCardRegionBlurState` 在首頁輪盤靜止時量測中心卡片螢幕座標，使用 `lib/widgets/gradient_background.dart:BakedCardRegionBlur` 裁取共用 LRU 內的預烘焙背景；滑動時只淡出貼圖，不新增即時模糊。
- 這個系統只影響畫面，不注入任何 Prompt。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
無。粒子樣式由主題設定直接選擇。

## 日常 / RP 差異
沒有模式差異；是否顯示取決於頁面、主題與粒子開關。

## 相關開關
- 主題工坊的粒子特效開關、樣式、密度與配色。
- 密度滑桿 `1～50` 會映射到 `0.4～1.6` 倍粒子量；`12` 仍是 `1.0` 倍預設值，滿檔上限也未提高。映射分成 `1→12` 與 `12→50` 兩段，避免中間大段數值實際顯示相同數量。
- 系統「減少動態效果」會停止 clock；App 退到背景、路由不可見或 `TickerMode` 關閉時也停止。
- 語音通話推到最上層時，首頁／角色／聊天的 `ModalRoute.isCurrent` 變為 false，各自停止粒子 clock；只有通話頁的粒子繼續，不會同時跑兩套背景動畫。
- `HoltSidebarShell` 展開側邊欄時會把固定背景包進停用的 `TickerMode`，關閉後恢復；視覺上保留最後一幀，避免粒子讓 sigma-50 側邊欄毛玻璃每幀重算。

## 量大時的風險
- 所有粒子共用一個可見 clock，但較高刷新率仍會增加 painter 重繪與 GPU／螢幕功耗。
- 目前前景目標約 60fps；20 秒無操作或聊天忙碌時約 30fps。`Timer` 只負責在目標時間前喚醒，真正更新由 `scheduleFrameCallback` 對齊下一個 vsync，避免獨立計時器與螢幕刷新錯拍。
- 慢速 `fog` 固定走 30fps；本輪保留既有 60／30fps 排程，不把所有動畫降成低幀率。主題工坊的粒子卡預設收起；開啟粒子 Switch 會自動展開，收起只影響設定 UI，不改實際背景開關。
- 神經網路與餘燼重用 painter 內的 `Paint`；漣漪以兩層低透明度寬線模擬水霧，不再為每圈逐幀建立動態 `MaskFilter`。流螢光斑／鏡頭光暈重用 fill／stroke Paint，以徑向漸層與簡單幾何繪製，不使用逐粒高斯模糊；密度滑桿會實際改變粒子數量。各主題 `starGlow` alpha 受可讀性測試限制，不高於 `0x1C`。落花吹雪同樣不依賴逐粒高斯模糊。
- 動態粒子若與大面積 `BackdropFilter` 重疊，可能令模糊層跟著重算；`RepaintBoundary` 不能保證消除所有合成成本。
- 首頁角色卡局部模糊只包含原背景圖，不包含其上的粒子；這是避免 60fps 粒子迫使局部模糊每幀重算的刻意邊界。

## 相關測試檔
- `test/ambient_particles_test.dart`
- `test/particle_tone_regression_test.dart`
- `test/theme_workshop_background_test.dart`
- `test/ui_operability_test.dart`
- `test/gradient_background_transition_test.dart`

## ❓ 不確定的地方
- 60／30fps 在不同 60、90、120Hz 裝置上的實際 frame pacing 與電量成本，靜態代碼無法證明，需實機 Performance Overlay／profile trace 與電池測試。
