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
- 角色星標：`lib/widgets/character_quick_picker.dart:_toggleStar` 只更新持久星標；`lib/screens/home_screen.dart:_loadCharacters` 僅在重新載入首頁輪盤時把星標角色穩定排在前方，不重排「全部角色」卡片或當場跳頁。
- 角色備注：`lib/screens/character_list_screen.dart:_editCharacterRemark` 原地更新目前卡片；角色頁大卡第一行保留本名、編輯 icon 緊鄰名字，第二行以可換行的 `（備注）` 顯示。`lib/utils/character_display_name.dart:characterCardDisplayName` 讓首頁緊湊輪盤使用同行的 `名字（備注）`。聊天 AppBar 仍只顯示備注，本名保留於角色資料與 Prompt 身分說明。
- 便箋顯示時間：`lib/screens/home_screen_sheets.dart:_formatNoteTimestamp` 將資料庫 ISO 時間轉為本地 `MM/dd HH:mm`，不再露出 `T`。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- 氣泡工具熱區：`lib/widgets/chat_bubble.dart:_buildToolbarTapTarget`。
- 待發內容取消與滾底：`lib/widgets/input_bar.dart:build`、`lib/screens/chat_screen.dart:_ChatScreenState.build`。
- 多角色指示：`lib/screens/character_list_screen.dart:_buildPageIndicator`，最多繪製五顆局部圓點並附目前／總數。
- 大字體：`CharacterListScreen.build` 增加卡片高度；`CharacterSignaturePanel._buildPanel` 先量測再決定高度。
- 角色輪盤高度：`CharacterListScreen.build` 依可用螢幕高度取約 40%，並限制在 320～380pt，再疊加既有文字放大補償；iOS／Android 不再使用 310／400 兩套斷裂的固定高度。
- 彈窗與選單表面：初次命名、便箋、歷史編輯／刪除、圖片／文字選單、刮刮卡與轉帳面板共用 `YanciTheme.surfacePanel`／`glassBorder`，沒有新增即時 `BackdropFilter`。
- 首頁手動摘要 BottomSheet 直接指定 `YanciTheme.themedOverlaySurface` 與主題邊界；不向 `showModalBottomSheet` 傳入版本不支援的 `surfaceTintColor`，避免建置失敗。
- 次級表單：`lib/theme/app_theme.dart:YanciTheme.themedInputDecoration` 提供 14pt 圓角、主題填色、0.7px 邊界與 accent 聚焦線；便箋、歷史標題、RP 人物／關係／狀態與世界書編輯共用，僅使用主題色表面，不新增即時模糊。
- RP 資料閱讀：`RpStoryRelationshipScreen` 的人物、關係與狀態使用低對比 0.5px 卡片邊界；狀態類型、敘事層級與進度使用小型主題徽章，世界書既有卡片層級不重複加框。
- 模型入口：`lib/screens/chat_screen_app_bar.dart:_buildAppBar` 擴大中央模型入口熱區並提高次級文字辨識度。
- 窗口狀態面板：`lib/widgets/chat_window_status.dart:ChatWindowStatusSheet.build` 點「當前模型」會在原 BottomSheet 內以 220ms 尺寸／淡入過渡展開模型與「自動／低／中／高」強度；面板限制為螢幕 90% 高並可滾動，短螢幕不溢出。模型清單打開時定位目前選項，頂部模型名稱入口與既有自動隱藏規則不變。
- 這些 UI 狀態不注入 prompt。
- 人設卡頁以 dirty tracking + `PopScope` 攔截返回，提供儲存並離開／捨棄／取消；分享前先保存目前表單，編輯其他角色不偷換全域 active character。
- 世界書、人物與狀態列表預覽不攔截文字選取，整張卡可點；枚舉欄位使用具三語標籤的選擇器。鍵盤彈窗由自持 controller 的 state 管理，退場動畫完成後才 dispose。
- 圖片生成停止會取消本輪 token 並清除 `generating` 佔位，遲到圖片不再寫入訊息；記憶頁系統返回會攜帶摘要修改結果。
- AI 串流氣泡轉成正式訊息時不重播入場動畫；剛解析出的 Thinking／Memory／Mood 使用 220ms 的淡入與尺寸過渡，平鋪模式維持在 40pt 頭像列內，一般氣泡模式平滑展開。歷史消息、截圖模式與「減少動態效果」不等待這段動畫。
- 「我的」雙頭像紅線仍沿用原六個錨點與手繪走勢，`lib/widgets/user_persona_avatar_pair.dart:_RedThreadPainter._threadPath` 只讓兩個交叉點的進出貝茲切線共線，消除死折角；動畫路徑與播放方向不變。
- 主題工坊主頁在色卡輪盤後依序顯示「自訂背景／對話與氣泡／粒子特效」三張主題化分組卡，卡距 14pt，0.8px 邊界取當前 accent 的 15% 透明度；粒子內容預設收起，標題仍顯示目前樣式。氣泡三色票同列，透明度、圓角與亮度直接展示；自訂發送鍵格式提示只在選中自訂樣式時出現。38pt 發送樣式方塊仍保留 44pt 觸控範圍，沒有新增 `BackdropFilter`。
- 首頁角色名稱右側以單顆膠囊同時表示 `RP` 與「在線」，不再將小字懸在卡片外；「我的」三個主入口保留透明表面，只增加低對比 InkWell 壓感，不把頁面變成滿版玻璃框。
- 日記詳情 BottomSheet 使用非全屏擴展的 `DraggableScrollableSheet`；上方視覺空白屬於可關閉遮罩，點擊即可返回日記列表，正文捲動與下拉關閉仍保留。
- 首次設定四步共用主題粒子、柔光主按鈕與一致輸入語法；模式卡在 360×720／放大字體下以整列 56pt 熱區控制縮小後的 Switch，避免文字與開關互相擠壓。主題預覽的單行氣泡為膠囊，多行改用 22pt 大圓角，保留特殊 AI 漸層而不把多行文字壓成橢圓。
- 首次語言按鈕使用穩定寬度的膠囊，只有送出中的選項顯示進度，移除箭頭後文字不會左右跳；嚮導推薦問題提供至少 44pt 點擊高度，長文自動改用圓角矩形而非多行膠囊。
- 首頁中心角色卡在有自訂背景且輪盤靜止時顯示螢幕座標對齊的預烘焙模糊切片；滑動時切片淡出，不使用 `BackdropFilter`／`ImageFiltered` 即時模糊。
- 歷史面板標題縮為置中「歷史」，模式膠囊與關閉鈕分置左右；有首頁背景時使用預烘焙區域切片與主題覆色，不使用即時 `BackdropFilter`。
- 「我的」姓名與三個主入口改用正常字重、文字水平置中；主題工坊與 RP 劇情／時間線分組容器保留邊界但移除填色，降低資訊量大時的框層堆疊。

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
- 角色超過十個且尚未星標時只提示一次；星標集合用 SharedPreferences 字串列表保存，首頁採穩定排序，不改角色資料本身。
- 44pt 氣泡工具熱區會增加短消息的最小工具列寬度，但不放大圖標。
- 字體極大時角色卡最多額外增加 72pt；仍需真機檢查最窄螢幕與最長三語文本。

## 相關測試檔
- `test/ui_operability_test.dart`
- `test/input_bar_test.dart`
- `test/chat_bubble_card_width_test.dart`
- `test/chat_bubble_thinking_test.dart`
- `test/chat_model_picker_test.dart`
- `test/tts_play_button_test.dart`
- `test/rp_worldbook_service_test.dart`
- `test/chat_window_status_test.dart`
- `test/theme_workshop_bubble_customization_test.dart`
- `test/ambient_particles_test.dart`
- `test/initial_setup_test.dart`
- `test/first_launch_language_test.dart`
- `test/gradient_background_transition_test.dart`
- `test/character_display_name_test.dart`
- `test/character_diary_service_test.dart`

## ❓ 不確定的地方
- VoiceOver／TalkBack 的實際焦點順序、窄螢幕最大文字、任意自訂背景對比與左緣側邊欄手勢仍需真機驗收。
