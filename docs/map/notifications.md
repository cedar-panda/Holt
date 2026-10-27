# 回覆完成通知

## 它是做什麼的（一兩句話）
只在使用者已送出的那一輪 AI 回覆成功寫入 SQLite、且 App 已離開前台時，發出本機完成通知。它不排程角色主動訊息，也不在背景啟動新的模型請求。

## 資料存在哪（資料表 / SharedPreferences key）
- 開關：SharedPreferences `reply_notifications_enabled`，預設 `true`。
- 首次權限請求記號：SharedPreferences `reply_notifications_permission_attempted`。
- 通知不另存正文；Android 已送達項由系統 NotificationManager 保存，iOS 由 UserNotifications 保存。
- Android channel：`holt_reply`；iOS category：`reply.<characterId>`。

## 誰寫入（檔案：函式）
- 共用內容與平台分流：`lib/services/reply_notification_service.dart:ReplyNotificationService.notifyCompletion`
- 開關與權限：`ReplyNotificationService.setEnabled`、`requestPermissionOnFirstSend`、`requestPermission`
- 回覆完成點：`lib/screens/chat_screen_generation.dart:_sendMessageLocked`
- Android 通知：`android/app/src/main/kotlin/com/yanci/holt/MainActivity.kt:showReplyCompletionNotification`
- iOS 通知：`ios/Runner/ReplyBackgroundBridge.swift:notifyCompletion`

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- 側邊欄：`lib/widgets/sidebar/sidebar_feature_settings.dart:_SidebarFeatureSettingsState._loadAvatars`
- 回覆內容先經 `VisibleModelOutput.finalOnly` 與 `TtsService.stripFunctionalMarkers`；最多 120 個可見字元。
- 標題使用 `lib/utils/character_display_name.dart:characterCardTitle`。
- 此功能不讀取、不修改、不注入任何 Prompt 層。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
無。

## 日常 / RP 差異
日常與 RP 共用相同完成條件、隱私與導航規則；不讀模式資料。

## 相關開關
- 側邊欄「回覆通知」預設開啟；關閉後 iOS／Android 都不發。
- 第一次送出訊息時在前台請求通知權限一次；從關切回開會再次向系統請求。
- Android 13+ 需要 `POST_NOTIFICATIONS`；拒絕時不影響正常回覆。
- iOS 要求 alert／sound／badge；拒絕後不會每輪反覆詢問。

## 平台行為與隱私
- 前台不發通知；失敗、中斷、手動停止或只有未完成回覆時不發。
- Android 私密版顯示角色標題與正文；鎖屏公開版只顯示「角色回覆你了」。是否套用公開版仍由系統「隱藏敏感內容」設定決定。
- iOS 以每角色 category 的 `hiddenPreviewsBodyPlaceholder` 提供鎖屏替代文字；實際顯示仍受系統「顯示預覽」設定控制。
- `conversationId` 只放在 notification payload／thread，不顯示給使用者；點擊後開啟 `/chat`。
- 冷啟動時原生先暫存 conversationId，Dart handler 與導航完成後再開窗；已在同一窗口時不重複 push。
- 進入窗口會清除該 conversation thread 已送達的完成通知。

## 量大時的風險
- iOS category 依角色建立；角色數極大時系統 category 集合會增加，但每次只替換當前角色的同 ID category。
- Android 以 conversationId 作 tag/group；同一窗口的新通知會覆蓋舊通知，不會無限堆同窗口內容。
- Android 本批沒有以前台服務延長生成；App 行程被系統終止時，長回覆不會完成也不會通知。

## 相關測試檔
- `test/reply_notification_service_test.dart`
- `test/ios_reply_background_task_test.dart`
- `test/sidebar_feature_settings_test.dart`

## ❓ 不確定的地方
- iOS 鎖屏替代文字、冷啟動通知點擊與 thread 清理尚未真機驗證。
- Android 13+ 權限、publicVersion 鎖屏效果、通知點擊與不同廠牌省電策略尚未真機驗證。
- iOS 背景租約能否撐到特定 provider 的超長回覆仍由系統決定；本功能不延長既有租約。
