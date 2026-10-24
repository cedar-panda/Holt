# App 啟動與首幀

## 它是做什麼的（一兩句話）
負責建立 Flutter 根節點、顯示開屏，再補載主題、語言、媒體路徑、下載器、保活與維護工作。首幀不依賴任何可選 platform plugin，避免 iOS plugin channel 卡住時停在原生白屏。

## 資料存在哪（資料表 / SharedPreferences key）
- 啟動流程本身不另存資料。
- 主題、語言、保活、小人等仍使用各自既有的 SharedPreferences key。
- 頭像修復仍更新 `characters.avatar_path`、`user_personas.avatar_path` 與使用者頭像偏好。

## 誰寫入（檔案：函式）
- `lib/main.dart`：`main`、`_initializeAfterFirstFrame`、`_startupStep`
- `lib/screens/splash_screen.dart`：`_startSequence`
- 各啟動服務只寫回自己原有的通知器或資料層。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- `lib/main.dart`：`YanciApp.build` 讀主題與語言通知器建立 UI。
- 本流程不注入模型 Prompt。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
無。

## 日常 / RP 差異
沒有模式差異；兩種模式共用同一個 App 啟動流程。

## 相關開關
- 主題、粒子、小人、keep-alive 等沿用各自開關。
- Debug VM 連線不是 App 內設定；無線 iOS Debug 依賴 Dart VM 服務發現或固定埠附著。

## 量大時的風險
- 頭像路徑修復會掃角色與 user persona；資料量很大時仍可能耗時，但已不再阻塞首幀。
- 啟動服務仍依序補載；單項 timeout 只保護後續步驟，不代表底層 Future 被取消。
- iOS 無線 Debug 的 Bonjour/mDNS 受 VPN、區網與 CoreDevice 隧道影響，可能長時間停留在原生啟動畫面；固定 VM 埠可避開隨機服務發現延遲。
- 純 Debug 使用 JIT；從後台強制結束後由桌面獨立重開，可能在可執行記憶頁配置時遭 iOS `SIGKILL`。需要可獨立重啟又保留診斷入口時，使用 Profile 並傳入 `HOLT_ENABLE_DEVELOPER_DIAGNOSTICS=true`。
- `flutter run` 顯示 `Lost connection to device` 後，即使裝置上仍留有 Runner 程序，畫面也可能停在黑屏；`flutter attach` 不一定能重新發現該 VM。開發時先終止殘留程序，再重新執行固定埠的 `flutter run` 建立 JIT／VM 連線；這不需要卸載或清除 App 資料。
- iOS 14+ 的 Debug 版若與 Flutter 工具失聯，從桌面獨立重開會顯示「debug mode Flutter apps can only be launched from Flutter tooling」的黑底系統提示。需要脫離電腦正常重開時，使用原地覆蓋的 Profile／Release 版；覆蓋前先備份完整 App 容器並驗證資料庫和媒體。

## 相關測試檔
- `test/startup_and_motion_test.dart`
- `test/first_launch_language_test.dart`
- `test/avatar_image_path_service_test.dart`

## ❓ 不確定的地方
- 不同 iOS／Xcode 版本下無線 Dart VM 服務發現延遲沒有穩定上限；這是開發連線條件，不代表 profile/release 啟動耗時。
