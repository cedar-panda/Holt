# 聲音模型、角色 Voice ID、播放與語音通話

## 它是做什麼的（一兩句話）
管理 OpenAI／ElevenLabs 的 TTS 來源、模型與全域預設聲音，並允許每個角色以 `tts_voice_id` 覆蓋全域聲音；聊天朗讀與語音通話共用同一套解析順序。

## 資料存在哪（資料表 / SharedPreferences key）
- 角色綁定：`characters.tts_voice_ids_json`（schema v86，按供應商各存一個）；舊 `characters.tts_voice_id` 保留並鏡像當前來源的值，新欄位空時由 `CharacterVoiceBindings.bindingsOf` 依格式歸屬。
- 全域來源／聲音：`tts_provider`、`tts_voice`、`tts_elevenlabs_voice_id`、`tts_elevenlabs_voice_id_list`、`tts_elevenlabs_voice_id_labels_v1`、`tts_elevenlabs_model`。
- STT 語言：`stt_locale`；有效值為 `zh_HK`、`zh_TW`、`zh_CN`、`en_US`。
- 通話背景沿用 `BackgroundPreset.callBackgroundScope`，值為 `none`／`home`／`chat`。
- API Key：`tts_openai_key`、`tts_elevenlabs_key`，由 `SecureStore` 保存。

## 誰寫入（檔案：函式）
- 全域聲音模型與 Voice ID：`lib/widgets/sidebar/sidebar_model_settings.dart:_buildVoiceModel`、`_addTtsVoiceId`、`_removeTtsVoiceId`。
- Voice ID 清理、增刪、別名與預設選擇：`lib/services/settings/tts_settings.dart:normalizeVoiceIdOptions`、`addAndSelectVoiceId`、`saveVoiceIdLabel`、`removeVoiceId`。
- 角色專屬綁定：`lib/screens/character_card_screen.dart:_buildVoiceIdField`、`_addCharacterVoiceId`、`_saveCharacter`。
- 舊版完整語音設定頁仍由 `lib/screens/voice_call_screen.dart` 寫入相同設定 key。

- TTS 合成統一入口：`lib/services/tts_synthesizer.dart:TtsSynthesizer.resolve`（角色卡 `tts_voice_id` 優先 → 全域預設）與 `synthesize`（OpenAI／ElevenLabs 請求、30s 逾時、設定錯誤拋 `CallTtsConfigurationException`）。聊天朗讀 `TtsService._synthesizeAndPlay` 與通話 `SentenceTtsPipeline._generate` 共用；新增供應商（例如 MiniMax）只需在 `TtsProviders`／`TtsVoiceConfig`／`synthesize` 加分支並補設定 UI。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- 聊天朗讀：`lib/widgets/chat_bubble.dart:_speakText` 把 `characterId` 傳給 `TtsService.speak`。
- TTS 解析：`lib/services/tts_synthesizer.dart:TtsSynthesizer.resolve`；先讀角色 `tts_voice_id`，空值才回退當前供應商的全域預設。只取當前供應商的綁定，切換來源不會把別家的 ID 送出。
- 語音通話：`lib/screens/call_screen.dart` 建立帶 `characterId` 的 `SentenceTtsPipeline`；`lib/services/call_audio_pipeline.dart:start` 使用相同角色優先規則。
- 通話與文字聊天銜接：同一個窗口（conversation），通話每輪寫入同一張 messages 表。開通話時 `chat_screen_actions.dart:_openCall` 用 `_buildCommonStaticParts` 建與文字聊天相同的 static／profile／window 前綴傳入；歷史由 `_callInitialHistory` 從當前窗口錨點 `_contextKeepFrom` 起（第一則 user 開始），通話內最多保留 500 條。通話用 `PromptCacheChannel.call`、control 層換成通話規則（含語言指示），文字聊天用 `text` 頻道；兩條 cache 共用同一條 append-only 歷史。掛斷後聊天頁 `_loadMessages` 重讀，通話內容與 `[call_event:…]` 隱藏事件接在原歷史後面，不會開新窗口或重拍靜態。
- 通話提示詞：`lib/services/call_prompt_composer.dart:CallPromptComposer.compose` 以目前介面語言組裝正向口語通話規則，並明確鎖定「目前角色直接對目前 user persona 說話」；供應商不支援音訊標籤時不注入標籤說明，角色明確決定結束通話時才使用 `<hangup/>`。
- 通話時長：`lib/screens/call_screen.dart:_generateTurn` 把現有 `_elapsed` 交給 `CallPromptComposer.compose`；每次真正發出模型請求時，把當下準確到秒的經過時長（例如 `00:47`）放入 `liveStatePart`。不會為了更新秒數額外呼叫 API，不改用戶通話正文或 cacheable prefix，且提醒模型只感知節奏、無需刻意報時。
- 空回覆保護：`lib/screens/call_screen.dart:_generateTurn` 若供應商只回 Thinking／工具標籤而沒有可朗讀正文，會用 `CallPromptComposer.emptyReplyRecoveryInstruction` 在 `liveStatePart` 追加一次 request-only 補句要求；只重試一次、不改 stable cache 前綴、不把空 assistant 回合寫入歷史，第二次仍空則在通話頁明示重試。
- 通話漸進朗讀：`lib/services/call_audio_pipeline.dart:SentenceTtsPipeline._trySplit` 依實際可朗讀文字採 12／26 字漸進門檻，第一句較快出聲、後續句保留自然節奏；工具／音訊標籤不計入門檻。ElevenLabs 支援的模型會把上一段 request id 傳入下一段以改善銜接；供應商拒絕 stitching 時，本輪立即清除鏈並回退獨立合成，不阻斷後續句播放。
- 通話呈現：`lib/screens/call_screen.dart:_buildInCallMiddle` 常駐一行字幕；出聲後由 `SentenceTtsPipeline.onSentencePlaying` 驅動，按子句切短行並依音頻長度逐行淡出淡入（開播前／TTS 失敗退回生成進度最新一句），點擊後開完整逐字稿；麥克風音量與角色播放振幅分離。左上角顯示將要切換到的「自動聆聽／按鍵說話」，右上角顯示「簡中／繁中／EN／粵語」語言選單；兩者無底色無邊框、淡字低存在感，選單用主題面板樣式。`lib/widgets/call_visual.dart:CallCenterVisual` 以既有 ticker 呈現響鈴、思考呼吸與振幅柔光，閒置／思考 30fps、實際音訊或響鈴 60fps，Reduced Motion 取消擺動與呼吸。
- 通話收音：`lib/screens/call_screen.dart:_startListening`、`_handleSoundLevel`、`_onSpeechResult` 只以 STT 辨識出的非空文字確認人聲；環境音量不會單獨觸發送出，長時間沒有辨識文字會退出本輪並提示重試。
- 藍牙麥克風：iOS 的 `speech_to_text` 原生層以 `playAndRecord + allowBluetooth` 管理輸入路由；Android 12+ 由 `lib/services/call_audio_route_service.dart:CallAudioRouteService.ensureBluetoothPermission` 在 STT 初始化前補申請 `BLUETOOTH_CONNECT`，避開套件在「麥克風早已允許」時漏申請 Nearby Devices 的缺口。只有系統目前存在 SCO／BLE headset 輸入時才彈權限，不讓單用手機麥克風的人多看一次提示。Android 按鍵說話走本機 ASR 時，`activateBluetoothMicrophone` 暫時選擇該 communication input，結束收音或離開通話即 `releaseBluetoothMicrophone` 還原系統路由。
- 通話背景：`lib/screens/call_screen.dart:_loadVisualSettings` 依目前角色綁定／啟用的背景 preset 讀取 `callBackgroundScope`；主題工坊在雙預覽下方以獨立的「語音通話使用當前背景」圓形勾選列寫入首頁或對話框 scope，不再把無文字勾選疊在圖片右上角。字幕後方使用預烘焙羽化區域，不新增逐幀背景模糊。
- 通話粒子：`lib/screens/call_screen.dart:build` 使用與主題相同的粒子樣式、密度與預設粒子基數，通話視為 busy 而以低頻檔刷新；`AmbientParticleField` 的路由可見性守衛會停止被通話頁蓋住的首頁／角色／聊天粒子，避免雙重動畫。
- TTS 設定與 Voice ID 不注入聊天 Prompt，只影響本機送往語音供應商的請求。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
無；依明確 `characterId` 查詢角色資料列。

## 日常 / RP 差異
播放解析本身不區分日常／RP；只要訊息或通話帶有同一角色 ID，就使用該角色綁定的聲音。模式只影響語音通話入口是否可用，不改角色聲音優先級。

## 相關開關
- 「其他功能模型設定 → 聲音模型」：選 TTS 來源、模型、全域聲音，並管理 ElevenLabs Voice ID。
- 「角色人設卡 → 更多屬性 → TTS 聲音」：選擇或新增角色專屬 Voice ID；留空時跟隨全域預設。別名只改善顯示，不改實際 Voice ID。
- 「主題工坊 → 自訂背景」：先選目前要編輯的首頁／對話框背景，再以預覽下方獨立勾選列決定語音通話是否使用它。

## 量大時的風險
- Voice ID 清單目前是 SharedPreferences 字串列表；一般數量下成本很低，但若累積數百筆，設定頁的 Dropdown／Chip 會變得難操作。
- 移除全域清單項目不會清除既有角色綁定，避免角色突然失聲；重新打開該角色時仍會顯示其舊 ID。
- 通話背景使用與其他頁面相同的主題粒子密度，但忙碌時降頻；通話成為目前路由後，其他被蓋住頁面的粒子時鐘停止。靜態頭像模糊層包在 `RepaintBoundary`，沒有新增逐幀 `BackdropFilter`。

## 相關測試檔
- `test/tts_settings_voice_id_test.dart`
- `test/call_prompt_composer_test.dart`
- `test/call_audio_pipeline_threshold_test.dart`
- `test/call_audio_route_service_test.dart`

## ❓ 不確定的地方
- 各語音供應商是否仍接受某個已保存 Voice ID，只能由實際 API 回應確認；本地不會預先連線驗證 ID 存在。
- 本輪沒有宣稱通話可在 App 退到背景後持續收音。Android 需要獨立的 microphone foreground-service type／權限與通話專用生命週期租約；現有 dataSync guard 不能安全替代，需另案實作並做真機驗收。
- Android 藍牙權限、HFP/SCO 與 BLE headset 路由仍需在不同廠牌真機驗證；單元測試與 APK 編譯只能證明通道、權限宣告與回退路徑成立，不能證明特定耳機韌體實際送入語音。
