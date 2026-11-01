# 聊天輸入與等待狀態

## 它是做什麼的（一兩句話）
處理對話頁輸入、發送鍵外觀與回覆開始前的等待提示。發送鍵樣式只改 UI，不改消息提交或 420ms 飛出動畫。

## 資料存在哪（資料表 / SharedPreferences key）
- `send_button_style`：`leaf`／`paw`／`shell`／`custom`，未知值讀取時回退 `leaf`。
- `send_button_custom_path`：App Documents 內 `send_button_images/` 的自訂 PNG 路徑。
- 等待秒數不入庫；`_TypingIndicator` 的 `Stopwatch`、`Timer` 與 `ValueNotifier` 只存在於當前 widget 生命週期。

## 誰寫入（檔案：函式）
- 樣式與路徑：`lib/services/settings/theme_settings.dart:ThemeSettings.saveSendButtonStyle`、`saveSendButtonCustomPath`
- 主題工坊選擇：`lib/screens/theme_workshop_bubbles.dart:_selectSendButtonStyle`、`_pickCustomSendButton`
- 自訂 PNG 驗證／複製／刪除：`lib/services/image_service.dart:ImageService.validateSendButtonPng`、`copySendButtonToAppDir`、`deleteSendButtonFile`
- 消息發送：`lib/widgets/input_bar.dart:_handleSend`

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- 啟動讀取：`lib/main.dart:main`
- 聊天頁傳入輸入框：`lib/screens/chat_screen.dart:_ChatScreenState.build`
- 發送鍵渲染：`lib/widgets/input_bar.dart:_buildSendImage`
- 楓葉（`leaf` 相容 key，現行 `send_maple_leaf.png` 使用 2026-10-26 提供的新白色透明線稿）／爪印／紙船／自訂發送鍵：全部使用同一套白色線稿染色規則；無輸入時沿用主題 accent，有文字或待發內容而亮起時按 accent 亮度選深／白色線條，維持與亮起圓底的對比。舊 `send_leaf.png` 與 `shell_coin.png` 資產仍保留；設定值仍沿用 `leaf`／`shell` 以相容舊資料。
- 等待提示：`lib/widgets/chat_bubble.dart:_TypingIndicatorState`
- 氣泡複製／書籤／朗讀的透明操作熱區：`lib/widgets/chat_bubble.dart:_buildToolbarTapTarget`
- 聊天氣泡形狀：`lib/widgets/chat_bubble.dart:_usesSingleLinePill` 先以實際字級與可用寬度排版；真正只有一行的自然語言使用膠囊，換行或區塊內容使用主題工坊設定的大圓角。AI／User 共用同一個圓角設定來源。
- 連續氣泡：`lib/widgets/chat_bubble.dart:_bubbleBorderRadius` 只把同一說話者相接側收至多行主圓角的 70%；單行膠囊的相接角為 14pt，外側仍保持完整膠囊，不回到尖尾巴。
- 多氣泡回覆：`lib/utils/split_reply_parser.dart:splitReplyParagraphs` 先保留完整 Thinking 前綴，再依空行拆分；只有 2～6 行短純文字才接受單換行後備，列表、引用、表格與程式碼不拆。聊天列表、串流預覽與長截圖共用此解析器。
- 多氣泡群組：`lib/screens/chat_screen_message_list.dart:_buildMessageList` 只把同一資料庫回覆拆出的相鄰段落標為緊密群組；`lib/widgets/chat_bubble.dart:_bubbleBorderRadius` 將其貼合側收至約 5.5～7.5pt，並減弱上一顆底影。一般連發仍沿用較柔和的 70% 圓角。
- 多氣泡工具列：只有最後一顆顯示工具列，但複製、收藏與朗讀作用於 `VisibleModelOutput.finalOnly` 清理後的完整回覆；不會只處理最後一段，也不會帶出 Thinking／工具標籤。
- 氣泡明度與透明度：`lib/theme/app_theme.dart:applyBubbleBrightness`、`chatBackgroundAiBubbleColor`、`chatBackgroundUserBubbleColor`；主題覆蓋色與自訂背景配色都走同一套微調，主題工坊預覽與聊天室一致。
- 氣泡表面：`lib/theme/app_theme.dart:bubbleGlazeGradient`、`bubbleGlazeBorderColor`、`bubbleGlazeShadows` 在原實色與透明度上增加極輕頂光、底部陰影與單層柔影；不使用 `BackdropFilter`，既有特殊 AI 漸層優先保留。主題工坊兩種預覽與聊天室共用規則。
- 串流轉正式訊息：`lib/screens/chat_screen_message_list.dart:_buildMessageList` 讓串流中的 AI 氣泡只播放一次入場；同一回覆寫入資料庫後以 `animateEntry: false` 接替，不再把已顯示正文短暫降成透明。`lib/screens/chat_screen_stream.dart:_markFreshAssistantContext` 只標記剛完成的回覆，讓其 Thinking／Memory／Mood 以 220ms 高度＋透明度過渡顯示；歷史訊息直接顯示。
- Context 標題列：`lib/widgets/chat_bubble.dart:_buildThinkingTree`、`_buildStandaloneContextRoot` 與 `lib/widgets/thinking_context_widgets.dart:ThinkingSheetLauncher.build` 收合高度不超過 40pt。平鋪模式的標題留在 40pt 頭像橫列內；一般氣泡模式則在氣泡上方平滑展開，避免串流結束時硬把正文向下頂。
- 加號工具盒：`lib/widgets/input_bar.dart:_buildActionPanel`；每個工具動作維持透明表面，只顯示自適應文字與 accent 圖標，並保留 44pt 以上熱區與低透明水波／按壓回饋。自訂對話背景存在時，文字與圖標仍沿用輸入框的自適應配色。
- 兩者都是本地 UI，不注入任何 prompt，也不新增 API 請求。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
無。樣式按 SharedPreferences key 直接讀取；自訂圖按安全的 App-owned 本地路徑載入。

## 日常 / RP 差異
無；兩種模式共用同一個輸入框外觀與等待提示。

## 相關開關
- 主題工坊「發送鍵」四種樣式。
- 主題工坊「氣泡圓角／明度／透明度」直接影響實際聊天氣泡；單行膠囊只改幾何外形，不覆寫使用者保存的多行圓角值。
- 「多氣泡回覆」與 AI 平鋪模式互斥：開啟多氣泡會自動切回氣泡模式；手動開啟平鋪會關閉多氣泡；聊天載入時也會修復舊資料形成的衝突組合。多氣泡控制提示詞使用三語正向即時通訊描述，不加入否定式格式提醒。
- AI 平鋪模式使用左窄右寬的閱讀版心：左側至少 20pt、約螢幕 5.5%，右側至少 40pt、約螢幕 11.5%；內側另保留 4pt，不影響氣泡模式。
- 自訂圖必須是 1:1、白色線條、透明底 PNG；匯入時會檢查檔案格式、尺寸、透明像素與可見像素是否以近白線稿為主。檔案遺失或讀取失敗時回退預設楓葉。
- 等待前 5 秒只顯示三點；第 5 秒起在右側顯示秒數，第一個正文字符出現後整體消失。
- 系統「減少動態效果」開啟時，等待三點、TTS 連接軌道與播放音條保留狀態提示但停止循環位移。
- 系統「減少動態效果」或截圖模式下，氣泡入場與 Context 顯示不等待動畫，直接呈現完整內容。
- 氣泡工具圖標使用 `lib/widgets/chat_bubble.dart:_toolbarGlyphScale` 跟隨系統文字縮放，視覺倍率為基準圖形的 0.8：預設複製約 12px、書籤／朗讀約 16.8px、緩存閃電約 12.8px，較上一版 1.2 倍視覺尺寸縮小三分之一。複製／書籤／朗讀的橫向槽寬維持 38、緩存槽寬 28；縱向仍保留 44pt、語意標籤與整槽點擊。掛起禮物／結婚證與待發表情、轉帳、刮刮卡仍提供較大的取消熱區。

## 量大時的風險
- 自訂圖只有一份當前檔案，替換或改回內建樣式會刪除舊 App-owned 檔案，不會隨使用時間累積。
- 等待計時每秒只更新一次；不進逐幀動畫路徑。被列表回收後重建會從 0 重新計時，這是已知且接受的顯示限制。

## 相關測試檔
- `test/input_bar_test.dart`
- `test/theme_workshop_bubble_customization_test.dart`
- `test/user_persona_widgets_test.dart`
- `test/portable_backup_bundle_test.dart`
- `test/chat_bubble_thinking_test.dart`
- `test/split_reply_parser_test.dart`
- `test/tts_play_button_test.dart`
- `test/ui_operability_test.dart`

## ❓ 不確定的地方
- 不同真機主題下楓葉／紙船線稿在 32px 的清晰度、自訂線稿閾值，以及等待秒數的實際視覺節奏仍需實機驗收。
