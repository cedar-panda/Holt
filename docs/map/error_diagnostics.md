# 報錯與閃退診斷

## 它是做什麼的（一兩句話）
保存最近五筆經隱私過濾的 API／功能錯誤，並在下一次啟動匯入可捕捉的 Flutter／Dart 未處理錯誤。嚮導可預覽、擬回報郵件或匯出純文字日誌。

## 資料存在哪（資料表 / SharedPreferences key）
- SharedPreferences：`holt_local_error_log_v1`，最多五筆。
- App Support：`diagnostics/pending_crashes.jsonl`，只作程序終止前的同步暫存；下次啟動匯入後清空。
- App Support：`diagnostics/native_metric_diagnostics.jsonl`，保存 iOS MetricKit 延後送達的 crash／hang／CPU／磁碟寫入診斷，最多約 2MB 後輪替。
- Android App files：`diagnostics/android_native_diagnostics.jsonl`，保存上次程序退出原因與未處理 Java/Kotlin 例外的隱私過濾後堆疊。
- 匯出檔：系統暫存目錄中的 `holt-error-log-<time>.txt`。

## 誰寫入（檔案：函式）
- 一般功能錯誤：`lib/services/app_error_log_service.dart:AppErrorLogService.record`、`recordDiagnosis`
- 全域未處理錯誤：`lib/main.dart:_prepareGlobalErrorCapture` → `AppErrorLogService.recordUnhandledSync`
- 啟動匯入：`AppErrorLogService.prepareCrashCapture`、`_importCrashJournal`、`classifyMetricKitPayloadText`；MetricKit 依 payload 類型標為 crash、hang、excessive CPU 或 excessive disk writes，不再全部誤標 native crash。
- iOS 原生診斷：`ios/Runner/AppDelegate.swift:didReceive(_ payloads: [MXDiagnosticPayload])`
- Android 原生診斷：`android/app/src/main/kotlin/com/yanci/holt/MainActivity.kt:captureHistoricalProcessExits`、`installPrivacySafeCrashJournal`

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- 報錯頁：`lib/screens/error_diagnostics_screen.dart:_load`
- 嚮導顯示／匯出：`lib/screens/guide_chat_screen.dart:_load`、`_showErrorEmailDraft`、`_exportErrorLog`
- 嚮導 API 模式只在詢問錯誤／反饋時，由 `lib/services/guide_service.dart` 讀取隱私過濾後的 `guideEvidence`；不進一般聊天 Prompt。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
無；按時間讀取最新五筆。

## 日常 / RP 差異
沒有模式差異；診斷層只記技術錯誤，不保存對話正文、圖片或 Prompt。

## 相關開關
無。嚮導顯示受嚮導功能開關影響，但 `/error_diagnostics` 頁與本地記錄本身不依賴 API。

## 量大時的風險
- 固定保留五筆，不隨使用時間無限成長。
- 同步 crash journal 只在未處理錯誤發生時寫入，不在正常畫面或串流期間持續落盤。
- iOS 系統級 `.ips` 與 Jetsam 原檔位於系統診斷區，App 沙盒無權自行讀取；若 iOS 另行把 crash／hang／資源異常交付給 MetricKit，匯出檔會附上該原生 payload。MetricKit 交付時間由系統決定，並非事件後即時保證送達。
- Android 11+ 會在下次啟動讀取系統保留的 crash、native crash、ANR、low-memory 與 excessive-resource 退出原因；較舊 Android 仍可記錄進入默認未處理例外的 Java/Kotlin crash。原始例外訊息不保存，避免夾帶使用者文字。

## 相關測試檔
- `test/api_error_localizer_test.dart`
- `test/startup_and_motion_test.dart`

## ❓ 不確定的地方
- 原生 iOS crash 是否能留下本地 Dart journal 取決於錯誤是否先進入 Flutter／Dart handler；純原生 `SIGBUS`／Jetsam 不保證立即收到 MetricKit payload，必要時仍需 Mac 端拉取 `.ips`。
- Android 廠商 ROM 對 process-exit history 的保留數與交付時間不一；新診斷可縮小方向，不能單靠源碼確認這兩天的特定閃退根因。
