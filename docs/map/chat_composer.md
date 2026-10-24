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
- 貓爪發送鍵：無輸入時沿用主題 accent 染色；有文字或待發內容而亮起時，按 accent 亮度選深／白色線條，維持與亮起圓底的對比。只影響貓爪的亮起狀態，PNG 透明度與發送動畫不變。
- 等待提示：`lib/widgets/chat_bubble.dart:_TypingIndicatorState`
- 氣泡複製／書籤／朗讀的透明操作熱區：`lib/widgets/chat_bubble.dart:_buildToolbarTapTarget`
- 聊天氣泡形狀：`lib/widgets/chat_bubble.dart:_usesSingleLinePill` 先以實際字級與可用寬度排版；真正只有一行的自然語言使用膠囊，換行或區塊內容使用主題工坊設定的大圓角。AI／User 共用同一個圓角設定來源。
- 氣泡明度與透明度：`lib/theme/app_theme.dart:applyBubbleBrightness`、`chatBackgroundAiBubbleColor`、`chatBackgroundUserBubbleColor`；主題覆蓋色與自訂背景配色都走同一套微調，主題工坊預覽與聊天室一致。
- 加號工具盒：`lib/widgets/input_bar.dart:_buildActionPanel`；自訂對話背景存在時，文字、圖標、襯底與 0.5px 邊框沿用輸入框的自適應配色，沒有背景時維持主題預設。
- 兩者都是本地 UI，不注入任何 prompt，也不新增 API 請求。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
無。樣式按 SharedPreferences key 直接讀取；自訂圖按安全的 App-owned 本地路徑載入。

## 日常 / RP 差異
無；兩種模式共用同一個輸入框外觀與等待提示。

## 相關開關
- 主題工坊「發送鍵」四種樣式。
- 主題工坊「氣泡圓角／明度／透明度」直接影響實際聊天氣泡；單行膠囊只改幾何外形，不覆寫使用者保存的多行圓角值。
- 自訂圖必須為 1:1 PNG；檔案遺失或讀取失敗時回退葉子。
- 等待前 5 秒只顯示三點；第 5 秒起在右側顯示秒數，第一個正文字符出現後整體消失。
- 系統「減少動態效果」開啟時，等待三點、TTS 連接軌道與播放音條保留狀態提示但停止循環位移。
- 氣泡工具圖標維持原尺寸，外層提供 44pt 透明操作區與語意標籤；掛起禮物／結婚證與待發表情、轉帳、刮刮卡提供較大的取消熱區。

## 量大時的風險
- 自訂圖只有一份當前檔案，替換或改回內建樣式會刪除舊 App-owned 檔案，不會隨使用時間累積。
- 等待計時每秒只更新一次；不進逐幀動畫路徑。被列表回收後重建會從 0 重新計時，這是已知且接受的顯示限制。

## 相關測試檔
- `test/input_bar_test.dart`
- `test/theme_workshop_bubble_customization_test.dart`
- `test/portable_backup_bundle_test.dart`
- `test/chat_bubble_thinking_test.dart`
- `test/tts_play_button_test.dart`
- `test/ui_operability_test.dart`

## ❓ 不確定的地方
- 不同真機主題下貝殼色相與像素邊、貓爪縮放清晰度，以及等待秒數的實際視覺節奏仍需實機驗收。
