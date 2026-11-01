# 側邊欄設定與手風琴

## 它是做什麼的（一兩句話）
提供首頁／我的頁的設定側邊欄，並以關聯群組協調各設定區塊的展開與收起。

## 資料存在哪（資料表 / SharedPreferences key）
- 手風琴目前展開群組只存在 `SidebarAccordionCoordinator` 記憶體狀態，不入庫。
- 各設定值由對應 service／SharedPreferences 保存，側邊欄本身不另建資料表。
- 自訂中轉站能力保存在 `oai_compat_capability_*` 四個 SharedPreferences key。
- 回覆通知開關保存在 SharedPreferences `reply_notifications_enabled`，預設開啟；首次權限請求另記 `reply_notifications_permission_attempted`。

## 誰寫入（檔案：函式）
- 群組狀態：`lib/widgets/sidebar/sidebar_accordion.dart:SidebarAccordionCoordinator.activate`
- 區塊展開／收起：`SidebarAccordionSection._expand`、`_collapse`
- 外部預設展開同步：`SidebarAccordionSection.didUpdateWidget`
- 成本設定載入／本地狀態：`lib/widgets/sidebar/sidebar_behavior_settings.dart:_SidebarBehaviorSettingsState._load`
- 數字設定失焦提交：`_CommittedCountFieldState._handleFocusChange`、`_commit`
- 中轉站能力設定：`lib/screens/api_settings_screen.dart:_loadSettings`、`_saveSettings`，UI 在 `lib/widgets/api_compatible_provider_settings_card.dart:ApiCompatibleProviderSettingsCard.build`。
- 聲音模型與全域 Voice ID：`lib/widgets/sidebar/sidebar_model_settings.dart:_buildVoiceModel`、`_addTtsVoiceId`、`_removeTtsVoiceId`、`_editVoiceIdLabel`；角色專屬綁定另見 `voice_tts.md`。
- 功能模組組合：`lib/screens/cost_context_screen.dart:_saveFeaturePreset`、`_activateFeaturePreset`、`_deleteFeaturePreset`；持久化由 `ToolFeatureSettings.savePreset`／`activatePreset` 負責。
- 回覆通知：`lib/widgets/sidebar/sidebar_feature_settings.dart:_SidebarFeatureSettingsState._setReplyNotifications`；平台權限與通知行為由 `ReplyNotificationService` 負責。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- 側邊欄容器：`lib/widgets/sidebar/holt_control_sidebar.dart:_HoltControlSidebarState.build`
- 各設定頁讀取對應 service；手風琴狀態不注入 prompt。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
無。

## 日常 / RP 差異
側邊欄外觀共用；各開關是否作用於日常／RP 由功能本身決定，見 `toggles.md`。

## 相關開關
- 「模型與連線」「系統行為」「功能模組開關」「用量」等大區塊。
- 「其他功能模型設定 → 聲音模型」可選來源／模型／預設聲音；ElevenLabs 可直接新增、命名、選擇與移除 Voice ID，列表固定保留 ID 供辨識。
- 「功能模組」右上角加號可把目前的畫圖、貝殼、日記、工具提示、首頁問候與郵件開關保存為具名組合；同一時間最多一組被標記為 RP 自動套用。
- 「回覆通知」預設開啟；關閉後不發 iOS／Android 本機完成通知，再次開啟會向系統重新請求通知權限。
- 無關聯群組展開時會收起上一組；同組是否互斥由 `exclusiveWithinGroup` 決定。
- 大分組標題（模型與連線／系統行為／功能模組開關）字級 12.5、下方留 12pt；第二組起上方有左右漸隱分隔線，作為分組層級。
- 標題列不再使用左側狀態光點；展開箭頭放在標題與問號之間，與右側 Switch 分離，避免狹窄區域誤觸。上下文限制、緩存命中與世界書仍可用 chevron 獨立收展。
- `SidebarAccordionSection.didUpdateWidget` 恢復持久設定的初始展開狀態時不啟動協調器；只有 user 手動展開才會收起不相關區塊，避免非同步載入時互擠。
- 上下文限制與緩存命中只在首次掛載時讀取持久設定；後續切換先更新本地狀態再保存，避免任意 `setState` 令開關短暫回到預設值。
- 數字欄位只在編輯結束時保存；收起手風琴、滑動關閉側邊欄或鍵盤 Done 造成的失焦都會提交，避免 `18` 被非同步拆成 `1`／`18` 競態。

## 量大時的風險
- 區塊很多時主要成本是 widget 建構；收起內容仍可能在反向動畫結束前短暫保持掛載。
- 外部更新 `initiallyExpanded` 必須在目前 build frame 結束後再通知協調器，否則 Debug 會拋出 `markNeedsBuild called during build`。
- 開啟側邊欄時 `HoltSidebarShell` 會關閉背景的 `TickerMode`；關閉後恢復，減少動畫背景與全高毛玻璃同時合成的成本。

## 相關測試檔
- `test/sidebar_accordion_test.dart`
- `test/sidebar_feature_settings_test.dart`
- `test/ui_operability_test.dart`

## ❓ 不確定的地方
- 真機快速連續展開多個包含鍵盤欄位的區塊仍需手勢驗收。
