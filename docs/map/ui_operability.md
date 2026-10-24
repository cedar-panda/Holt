# UI 操作可靠性

## 它是做什麼的（一兩句話）
統一高頻操作的點擊容錯、文字放大、多角色資料量與減少動態行為；只調整本地 UI，不改聊天或記憶資料。

## 資料存在哪（資料表 / SharedPreferences key）
- 操作熱區、語意、字體重排與動效狀態不入庫。
- 角色數量與角色資料沿用既有 characters 資料；頁面指示器只讀目前列表與 `_currentPage`。
- 偏好設定值仍由原 service／SharedPreferences 保存，詳見 `sidebar_settings.md`。

## 誰寫入（檔案：函式）
- 設定頁本地狀態：`lib/screens/cost_context_screen.dart:_CostContextScreenState._loadSettings` 與各 `_toggle*` 方法。
- 側邊欄數字提交：`lib/widgets/sidebar/sidebar_behavior_settings.dart:_CommittedCountFieldState._commit`。
- 角色輪盤目前頁：`lib/screens/character_list_screen.dart:PageView.builder.onPageChanged`。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- 氣泡工具熱區：`lib/widgets/chat_bubble.dart:_buildToolbarTapTarget`。
- 待發內容取消與滾底：`lib/widgets/input_bar.dart:build`、`lib/screens/chat_screen.dart:_ChatScreenState.build`。
- 多角色指示：`lib/screens/character_list_screen.dart:_buildPageIndicator`，最多繪製五顆局部圓點並附目前／總數。
- 大字體：`CharacterListScreen.build` 增加卡片高度；`CharacterSignaturePanel._buildPanel` 先量測再決定高度。
- 模型入口：`lib/screens/chat_screen_app_bar.dart:_buildAppBar` 擴大中央模型入口熱區並提高次級文字辨識度。
- 這些 UI 狀態不注入 prompt。
- 人設卡頁以 dirty tracking + `PopScope` 攔截返回，提供儲存並離開／捨棄／取消；分享前先保存目前表單，編輯其他角色不偷換全域 active character。
- 世界書、人物與狀態列表預覽不攔截文字選取，整張卡可點；枚舉欄位使用具三語標籤的選擇器。鍵盤彈窗由自持 controller 的 state 管理，退場動畫完成後才 dispose。
- 圖片生成停止會取消本輪 token 並清除 `generating` 佔位，遲到圖片不再寫入訊息；記憶頁系統返回會攜帶摘要修改結果。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
無。

## 日常 / RP 差異
- 聊天工具、模型入口與輸入框操作共用。
- 角色輪盤共用；日常與 RP 下方資源內容不同，但頁面指示與卡片高度規則相同。

## 相關開關
- App 字體倍率與系統文字倍率共同影響可變高度。
- 系統「減少動態效果」會停止等待三點、軌道載入、TTS 循環與側邊欄手風琴位移；狀態本身仍可辨識。
- 角色頭像、時間線、自我註記等功能開關不改變本文件的操作規則。

## 量大時的風險
- 角色很多時頁面指示保持固定寬度；完整選擇仍交給「全部角色」搜尋入口。
- 44pt 氣泡工具熱區會增加短消息的最小工具列寬度，但不放大圖標。
- 字體極大時角色卡最多額外增加 72pt；仍需真機檢查最窄螢幕與最長三語文本。

## 相關測試檔
- `test/ui_operability_test.dart`
- `test/input_bar_test.dart`
- `test/chat_bubble_card_width_test.dart`
- `test/chat_model_picker_test.dart`
- `test/tts_play_button_test.dart`
- `test/rp_worldbook_service_test.dart`
- `test/chat_window_status_test.dart`

## ❓ 不確定的地方
- VoiceOver／TalkBack 的實際焦點順序、窄螢幕最大文字、任意自訂背景對比與左緣側邊欄手勢仍需真機驗收。
