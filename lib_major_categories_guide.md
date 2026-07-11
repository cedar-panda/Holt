# Yanci `lib/` 大類與細分目錄

校對日期：2026-07-03

本檔覆蓋舊版 `lib_major_categories_guide.md`，掃描範圍為所有 `lib/**/*.dart`。
結構分成兩層：先看每個檔案的大類定位，再按需求大類跳到檔案細分行段。
細分行段主要依明確分段註釋（例如 `// ═══ ... ═══`、`// ── ... ──`）與類別宣告切分；不追逐每個方法，避免普通 UI 調整就讓文件過期。

目前共收錄 `82` 個 Dart 檔，另列 `2` 個非編譯/備份檔。`lib/README.md` 與 `*.bak` 不屬正常編譯入口，但仍放入目錄方便辨識。

## 目錄一：檔案大類索引

### App 入口

| 檔案 | 大類定位 | 細分小類 |
|---|---|---|
| `lib/main.dart` | App 入口、初始化、根路由與全局包裝 | [查看](#file-lib-main-dart) |

### Screens 頁面級 UI

| 檔案 | 大類定位 | 細分小類 |
|---|---|---|
| `lib/screens/api_sub_settings_screen.dart` | 進階 API、思考鏈、摘要與畫圖模型設定頁 | [查看](#file-lib-screens-api-sub-settings-screen-dart) |
| `lib/screens/call_screen.dart` | 語音通話頁與 STT/LLM/TTS 流程 | [查看](#file-lib-screens-call-screen-dart) |
| `lib/screens/character_card_screen.dart` | 角色人設卡、頭像、token 門檻與畫圖錨點 | [查看](#file-lib-screens-character-card-screen-dart) |
| `lib/screens/character_list_screen.dart` | 角色列表、角色資源入口與能力開關 | [查看](#file-lib-screens-character-list-screen-dart) |
| `lib/screens/chat_screen.dart` | 聊天主流程、prompt 組裝、stream、工具與保活 | [查看](#file-lib-screens-chat-screen-dart) |
| `lib/screens/context_debug_screen.dart` | 窗口摘要與 keyword block 調試/修訂頁 | [查看](#file-lib-screens-context-debug-screen-dart) |
| `lib/screens/game_screen.dart` | 像素小屋頁與 Flame GameWidget 宿主 | [查看](#file-lib-screens-game-screen-dart) |
| `lib/screens/general_settings_screen.dart` | 通用設定、語言、字體與頭像顯示 | [查看](#file-lib-screens-general-settings-screen-dart) |
| `lib/screens/home_screen.dart` | 首頁、角色輪盤、正在聊入口與對話歷史 | [查看](#file-lib-screens-home-screen-dart) |
| `lib/screens/local_model_screen.dart` | 本地模型下載、管理、相容性與 GPU 狀態頁 | [查看](#file-lib-screens-local-model-screen-dart) |
| `lib/screens/memory_screen.dart` | 長期記憶列表、手動寫入、整理與回收站 | [查看](#file-lib-screens-memory-screen-dart) |
| `lib/screens/saved_messages_screen.dart` | 收藏訊息列表與回跳來源對話 | [查看](#file-lib-screens-saved-messages-screen-dart) |
| `lib/screens/settings_screen.dart` | 主設定頁、API provider、模型、cache、上下文與 TTS | [查看](#file-lib-screens-settings-screen-dart) |
| `lib/screens/splash_screen.dart` | 啟動畫面與星光動畫 | [查看](#file-lib-screens-splash-screen-dart) |
| `lib/screens/sticker_library_screen.dart` | 表情包庫、Vision 描述與手動標註 | [查看](#file-lib-screens-sticker-library-screen-dart) |
| `lib/screens/theme_workshop_screen.dart` | 主題工坊、色彩、氣泡與背景圖調整 | [查看](#file-lib-screens-theme-workshop-screen-dart) |
| `lib/screens/usage_dashboard_screen.dart` | Token 用量、cache hit、成本與圖表儀表盤 | [查看](#file-lib-screens-usage-dashboard-screen-dart) |
| `lib/screens/user_profile_screen.dart` | 用戶檔案、稱謂、自我介紹與頭像 | [查看](#file-lib-screens-user-profile-screen-dart) |
| `lib/screens/voice_library_screen.dart` | TTS 語音庫管理、播放與刪除 | [查看](#file-lib-screens-voice-library-screen-dart) |

### Widgets 共用 UI 元件

| 檔案 | 大類定位 | 細分小類 |
|---|---|---|
| `lib/widgets/atom_thinking.dart` | 思考狀態原子動畫 | [查看](#file-lib-widgets-atom-thinking-dart) |
| `lib/widgets/avatar_cropper.dart` | 頭像裁剪頁與裁剪遮罩 | [查看](#file-lib-widgets-avatar-cropper-dart) |
| `lib/widgets/character_timeline_panel.dart` | 角色時間線可視化面板 | [查看](#file-lib-widgets-character-timeline-panel-dart) |
| `lib/widgets/chat_bubble.dart` | 聊天氣泡、Markdown、貼圖、圖片、TTS 與 cache 標記 | [查看](#file-lib-widgets-chat-bubble-dart) |
| `lib/widgets/emotion_panel.dart` | 情緒座標測試面板與平面圖 | [查看](#file-lib-widgets-emotion-panel-dart) |
| `lib/widgets/gradient_background.dart` | 全局漸層/圖片背景與抖動 painter | [查看](#file-lib-widgets-gradient-background-dart) |
| `lib/widgets/input_bar.dart` | 聊天底部輸入框、附件與發送按鈕 | [查看](#file-lib-widgets-input-bar-dart) |
| `lib/widgets/neural_field.dart` | 神經網狀背景 painter | [查看](#file-lib-widgets-neural-field-dart) |
| `lib/widgets/starfield_painter.dart` | 星光粒子背景 painter | [查看](#file-lib-widgets-starfield-painter-dart) |
| `lib/widgets/tts_play_button.dart` | TTS 播放按鈕與軌道動畫 | [查看](#file-lib-widgets-tts-play-button-dart) |
| `lib/widgets/voice_visualizer.dart` | 語音通話呼吸 blob 視覺化 | [查看](#file-lib-widgets-voice-visualizer-dart) |
| `lib/widgets/x_post_panel.dart` | X/社群發文設定底部面板 | [查看](#file-lib-widgets-x-post-panel-dart) |
| `lib/widgets/yanci_sprite_overlay.dart` | 全局晏辭像素小人 overlay、拖拽與快捷入口 | [查看](#file-lib-widgets-yanci-sprite-overlay-dart) |

### Services 服務層

| 檔案 | 大類定位 | 細分小類 |
|---|---|---|
| `lib/services/api_adapter.dart` | API adapter 介面、StructuredPrompt 與 cache breakpoint | [查看](#file-lib-services-api-adapter-dart) |
| `lib/services/aws_bedrock_service.dart` | AWS Bedrock Claude 直連、SigV4 與 cache stats | [查看](#file-lib-services-aws-bedrock-service-dart) |
| `lib/services/backup_service.dart` | JSON/DB/SharedPreferences 全量備份 | [查看](#file-lib-services-backup-service-dart) |
| `lib/services/bio_clock_service.dart` | 生物鐘、習慣、時間窗口與 clock 工具標籤 | [查看](#file-lib-services-bio-clock-service-dart) |
| `lib/services/character_timeline_service.dart` | 角色時間線、狀態快照、事件與回憶觸發 | [查看](#file-lib-services-character-timeline-service-dart) |
| `lib/services/context_compressor.dart` | 窗口摘要、鏈式壓縮、關鍵詞與段落修訂 | [查看](#file-lib-services-context-compressor-dart) |
| `lib/services/deepseek_service.dart` | DeepSeek OpenAI-compatible API 與自動 cache 統計 | [查看](#file-lib-services-deepseek-service-dart) |
| `lib/services/gemini_service.dart` | Google Gemini API、cachedContents 與 streaming | [查看](#file-lib-services-gemini-service-dart) |
| `lib/services/image_gen_service.dart` | OpenRouter 圖像生成與角色畫圖錨點拼接 | [查看](#file-lib-services-image-gen-service-dart) |
| `lib/services/image_service.dart` | 圖片複製、壓縮與 base64 data URL | [查看](#file-lib-services-image-service-dart) |
| `lib/services/json_exporter.dart` | 對話、記憶與全資料 JSON 匯出 | [查看](#file-lib-services-json-exporter-dart) |
| `lib/services/keep_alive_service.dart` | 關窗保活、心跳與正在聊窗口持久化 | [查看](#file-lib-services-keep-alive-service-dart) |
| `lib/services/local_ai_service.dart` | 舊本地 AI 佔位 adapter | [查看](#file-lib-services-local-ai-service-dart) |
| `lib/services/local_model_service.dart` | 本地模型 catalog、下載、推理、相容性與 fallback | [查看](#file-lib-services-local-model-service-dart) |
| `lib/services/locale_strings.dart` | 簡易多語文案表 | [查看](#file-lib-services-locale-strings-dart) |
| `lib/services/memory_actions.dart` | 模型記憶工具標籤解析、落庫與剝離 | [查看](#file-lib-services-memory-actions-dart) |
| `lib/services/openai_compatible_service.dart` | OpenAI-compatible/自建端點與 Claude cache blocks | [查看](#file-lib-services-openai-compatible-service-dart) |
| `lib/services/openrouter_service.dart` | OpenRouter chat completions、Claude cache_control 與 usage | [查看](#file-lib-services-openrouter-service-dart) |
| `lib/services/qwen_service.dart` | DashScope/Qwen OpenAI-compatible chat | [查看](#file-lib-services-qwen-service-dart) |
| `lib/services/secure_store.dart` | API key 安全存儲封裝 | [查看](#file-lib-services-secure-store-dart) |
| `lib/services/sentence_buffer.dart` | TTS 短句緩衝與合併 | [查看](#file-lib-services-sentence-buffer-dart) |
| `lib/services/settings_manager.dart` | 設定 barrel export | [查看](#file-lib-services-settings-manager-dart) |
| `lib/services/sticker_service.dart` | 表情包 prompt、Vision 描述與貼圖語法解析 | [查看](#file-lib-services-sticker-service-dart) |
| `lib/services/streaming_tts_service.dart` | ElevenLabs WebSocket 串流 TTS | [查看](#file-lib-services-streaming-tts-service-dart) |
| `lib/services/token_estimator.dart` | Token 粗估、cache 門檻與保活資格判斷 | [查看](#file-lib-services-token-estimator-dart) |
| `lib/services/token_tracker.dart` | 真實 usage、cache hit/create 與成本記錄 | [查看](#file-lib-services-token-tracker-dart) |
| `lib/services/tts_service.dart` | OpenAI/ElevenLabs TTS、語音快取與正文抽取 | [查看](#file-lib-services-tts-service-dart) |
| `lib/services/x_post_settings.dart` | X/社群發文設定與每日計數 | [查看](#file-lib-services-x-post-settings-dart) |

### Services / Settings 設定讀寫層

| 檔案 | 大類定位 | 細分小類 |
|---|---|---|
| `lib/services/settings/api_settings.dart` | API provider、key、模型與 adapter 工廠設定 | [查看](#file-lib-services-settings-api-settings-dart) |
| `lib/services/settings/memory_settings.dart` | 記憶、摘要、prompt caching、上下文與能力設定 | [查看](#file-lib-services-settings-memory-settings-dart) |
| `lib/services/settings/theme_settings.dart` | 主題、背景圖、色彩覆蓋與字體設定 | [查看](#file-lib-services-settings-theme-settings-dart) |
| `lib/services/settings/tts_settings.dart` | TTS/STT provider、語音 ID 與語言設定 | [查看](#file-lib-services-settings-tts-settings-dart) |
| `lib/services/settings/user_settings.dart` | 用戶、角色與雜項偏好設定 | [查看](#file-lib-services-settings-user-settings-dart) |

### Memory 記憶與資料層

| 檔案 | 大類定位 | 細分小類 |
|---|---|---|
| `lib/memory/database.dart` | SQLite schema、migration 與資料 CRUD | [查看](#file-lib-memory-database-dart) |
| `lib/memory/emotion_coordinates.dart` | 情緒座標、衰減、安全感與負面情緒系統 | [查看](#file-lib-memory-emotion-coordinates-dart) |
| `lib/memory/retriever.dart` | 長期記憶檢索與 prompt 注入 | [查看](#file-lib-memory-retriever-dart) |
| `lib/memory/summarizer.dart` | 長期記憶摘要、寫入、整理與去重 | [查看](#file-lib-memory-summarizer-dart) |

### Models 資料模型

| 檔案 | 大類定位 | 細分小類 |
|---|---|---|
| `lib/models/memory.dart` | 長期記憶資料模型 | [查看](#file-lib-models-memory-dart) |
| `lib/models/message.dart` | 聊天訊息與對話資料模型 | [查看](#file-lib-models-message-dart) |

### Theme 主題資料

| 檔案 | 大類定位 | 細分小類 |
|---|---|---|
| `lib/theme/app_theme.dart` | 當前主題狀態、色彩 getter 與全域樣式 | [查看](#file-lib-theme-app-theme-dart) |
| `lib/theme/theme_presets.dart` | 預設主題色盤資料 | [查看](#file-lib-theme-theme-presets-dart) |

### Game 像素小屋與 NPC

| 檔案 | 大類定位 | 細分小類 |
|---|---|---|
| `lib/game/actors/actor_state.dart` | 遊戲 Actor 狀態資料 | [查看](#file-lib-game-actors-actor-state-dart) |
| `lib/game/bridge/emotion_bridge.dart` | 情緒座標到遊戲狀態的橋接 | [查看](#file-lib-game-bridge-emotion-bridge-dart) |
| `lib/game/bridge/schedule_bridge.dart` | 角色行程到遊戲位置的橋接 | [查看](#file-lib-game-bridge-schedule-bridge-dart) |
| `lib/game/config.dart` | 像素小屋尺寸、偏好 key 與常數 | [查看](#file-lib-game-config-dart) |
| `lib/game/holt_game.dart` | Flame 像素小屋主遊戲與 NPC 佔位行為 | [查看](#file-lib-game-holt-game-dart) |
| `lib/game/npc/game_npc_settings.dart` | 遊戲 NPC 模型選擇設定 | [查看](#file-lib-game-npc-game-npc-settings-dart) |
| `lib/game/npc/npc_brain.dart` | 遊戲 NPC 腦與模型調用策略 | [查看](#file-lib-game-npc-npc-brain-dart) |
| `lib/game/sprite/yanci_pixels.dart` | 晏辭像素幀資料與繪製 | [查看](#file-lib-game-sprite-yanci-pixels-dart) |

### 非編譯/備份檔

| 檔案 | 大類定位 | 細分小類 |
|---|---|---|
| `lib/README.md` | Holt 語音更新 v2 舊說明文，不是程式入口 | [查看](#file-lib-readme-md) |
| `lib/screens/home_screen.dart.bak` | 舊首頁備份檔，不屬正常編譯入口 | [查看](#file-lib-screens-home-screen-dart-bak) |

## 目錄二：按需求大類跳轉

這一段用「我要改什麼」來找檔案。點進去後看該檔的行段小類。

### 入口、導航、首頁
- [`lib/main.dart`](#file-lib-main-dart)：App 入口、初始化、根路由與全局包裝
- [`lib/screens/splash_screen.dart`](#file-lib-screens-splash-screen-dart)：啟動畫面與星光動畫
- [`lib/screens/home_screen.dart`](#file-lib-screens-home-screen-dart)：首頁、角色輪盤、正在聊入口與對話歷史
- [`lib/screens/character_list_screen.dart`](#file-lib-screens-character-list-screen-dart)：角色列表、角色資源入口與能力開關
- [`lib/widgets/yanci_sprite_overlay.dart`](#file-lib-widgets-yanci-sprite-overlay-dart)：全局晏辭像素小人 overlay、拖拽與快捷入口

### 聊天主流程、Prompt、Cache、保活
- [`lib/screens/chat_screen.dart`](#file-lib-screens-chat-screen-dart)：聊天主流程、prompt 組裝、stream、工具與保活
- [`lib/services/api_adapter.dart`](#file-lib-services-api-adapter-dart)：API adapter 介面、StructuredPrompt 與 cache breakpoint
- [`lib/services/openrouter_service.dart`](#file-lib-services-openrouter-service-dart)：OpenRouter chat completions、Claude cache_control 與 usage
- [`lib/services/openai_compatible_service.dart`](#file-lib-services-openai-compatible-service-dart)：OpenAI-compatible/自建端點與 Claude cache blocks
- [`lib/services/aws_bedrock_service.dart`](#file-lib-services-aws-bedrock-service-dart)：AWS Bedrock Claude 直連、SigV4 與 cache stats
- [`lib/services/gemini_service.dart`](#file-lib-services-gemini-service-dart)：Google Gemini API、cachedContents 與 streaming
- [`lib/services/deepseek_service.dart`](#file-lib-services-deepseek-service-dart)：DeepSeek OpenAI-compatible API 與自動 cache 統計
- [`lib/services/qwen_service.dart`](#file-lib-services-qwen-service-dart)：DashScope/Qwen OpenAI-compatible chat
- [`lib/services/token_estimator.dart`](#file-lib-services-token-estimator-dart)：Token 粗估、cache 門檻與保活資格判斷
- [`lib/services/token_tracker.dart`](#file-lib-services-token-tracker-dart)：真實 usage、cache hit/create 與成本記錄
- [`lib/services/keep_alive_service.dart`](#file-lib-services-keep-alive-service-dart)：關窗保活、心跳與正在聊窗口持久化

### API 設定、模型選擇、本地模型
- [`lib/screens/settings_screen.dart`](#file-lib-screens-settings-screen-dart)：主設定頁、API provider、模型、cache、上下文與 TTS
- [`lib/screens/api_sub_settings_screen.dart`](#file-lib-screens-api-sub-settings-screen-dart)：進階 API、思考鏈、摘要與畫圖模型設定頁
- [`lib/screens/local_model_screen.dart`](#file-lib-screens-local-model-screen-dart)：本地模型下載、管理、相容性與 GPU 狀態頁
- [`lib/services/settings/api_settings.dart`](#file-lib-services-settings-api-settings-dart)：API provider、key、模型與 adapter 工廠設定
- [`lib/services/settings_manager.dart`](#file-lib-services-settings-manager-dart)：設定 barrel export
- [`lib/services/local_model_service.dart`](#file-lib-services-local-model-service-dart)：本地模型 catalog、下載、推理、相容性與 fallback
- [`lib/services/local_ai_service.dart`](#file-lib-services-local-ai-service-dart)：舊本地 AI 佔位 adapter
- [`lib/services/secure_store.dart`](#file-lib-services-secure-store-dart)：API key 安全存儲封裝

### 記憶、窗口摘要、資料庫
- [`lib/screens/memory_screen.dart`](#file-lib-screens-memory-screen-dart)：長期記憶列表、手動寫入、整理與回收站
- [`lib/screens/context_debug_screen.dart`](#file-lib-screens-context-debug-screen-dart)：窗口摘要與 keyword block 調試/修訂頁
- [`lib/memory/database.dart`](#file-lib-memory-database-dart)：SQLite schema、migration 與資料 CRUD
- [`lib/memory/retriever.dart`](#file-lib-memory-retriever-dart)：長期記憶檢索與 prompt 注入
- [`lib/memory/summarizer.dart`](#file-lib-memory-summarizer-dart)：長期記憶摘要、寫入、整理與去重
- [`lib/services/memory_actions.dart`](#file-lib-services-memory-actions-dart)：模型記憶工具標籤解析、落庫與剝離
- [`lib/services/context_compressor.dart`](#file-lib-services-context-compressor-dart)：窗口摘要、鏈式壓縮、關鍵詞與段落修訂
- [`lib/services/settings/memory_settings.dart`](#file-lib-services-settings-memory-settings-dart)：記憶、摘要、prompt caching、上下文與能力設定
- [`lib/models/memory.dart`](#file-lib-models-memory-dart)：長期記憶資料模型
- [`lib/models/message.dart`](#file-lib-models-message-dart)：聊天訊息與對話資料模型

### 情緒、生物鐘、角色時間線
- [`lib/memory/emotion_coordinates.dart`](#file-lib-memory-emotion-coordinates-dart)：情緒座標、衰減、安全感與負面情緒系統
- [`lib/widgets/emotion_panel.dart`](#file-lib-widgets-emotion-panel-dart)：情緒座標測試面板與平面圖
- [`lib/services/bio_clock_service.dart`](#file-lib-services-bio-clock-service-dart)：生物鐘、習慣、時間窗口與 clock 工具標籤
- [`lib/services/character_timeline_service.dart`](#file-lib-services-character-timeline-service-dart)：角色時間線、狀態快照、事件與回憶觸發
- [`lib/widgets/character_timeline_panel.dart`](#file-lib-widgets-character-timeline-panel-dart)：角色時間線可視化面板
- [`lib/screens/character_card_screen.dart`](#file-lib-screens-character-card-screen-dart)：角色人設卡、頭像、token 門檻與畫圖錨點

### TTS、語音庫、通話
- [`lib/screens/call_screen.dart`](#file-lib-screens-call-screen-dart)：語音通話頁與 STT/LLM/TTS 流程
- [`lib/screens/voice_library_screen.dart`](#file-lib-screens-voice-library-screen-dart)：TTS 語音庫管理、播放與刪除
- [`lib/services/tts_service.dart`](#file-lib-services-tts-service-dart)：OpenAI/ElevenLabs TTS、語音快取與正文抽取
- [`lib/services/streaming_tts_service.dart`](#file-lib-services-streaming-tts-service-dart)：ElevenLabs WebSocket 串流 TTS
- [`lib/services/sentence_buffer.dart`](#file-lib-services-sentence-buffer-dart)：TTS 短句緩衝與合併
- [`lib/services/settings/tts_settings.dart`](#file-lib-services-settings-tts-settings-dart)：TTS/STT provider、語音 ID 與語言設定
- [`lib/widgets/tts_play_button.dart`](#file-lib-widgets-tts-play-button-dart)：TTS 播放按鈕與軌道動畫
- [`lib/widgets/voice_visualizer.dart`](#file-lib-widgets-voice-visualizer-dart)：語音通話呼吸 blob 視覺化

### 圖片、表情包、畫圖、匯出備份
- [`lib/screens/sticker_library_screen.dart`](#file-lib-screens-sticker-library-screen-dart)：表情包庫、Vision 描述與手動標註
- [`lib/services/sticker_service.dart`](#file-lib-services-sticker-service-dart)：表情包 prompt、Vision 描述與貼圖語法解析
- [`lib/services/image_service.dart`](#file-lib-services-image-service-dart)：圖片複製、壓縮與 base64 data URL
- [`lib/services/image_gen_service.dart`](#file-lib-services-image-gen-service-dart)：OpenRouter 圖像生成與角色畫圖錨點拼接
- [`lib/services/backup_service.dart`](#file-lib-services-backup-service-dart)：JSON/DB/SharedPreferences 全量備份
- [`lib/services/json_exporter.dart`](#file-lib-services-json-exporter-dart)：對話、記憶與全資料 JSON 匯出
- [`lib/widgets/avatar_cropper.dart`](#file-lib-widgets-avatar-cropper-dart)：頭像裁剪頁與裁剪遮罩
- [`lib/widgets/chat_bubble.dart`](#file-lib-widgets-chat-bubble-dart)：聊天氣泡、Markdown、貼圖、圖片、TTS 與 cache 標記

### 主題、背景、共用 UI
- [`lib/screens/theme_workshop_screen.dart`](#file-lib-screens-theme-workshop-screen-dart)：主題工坊、色彩、氣泡與背景圖調整
- [`lib/screens/general_settings_screen.dart`](#file-lib-screens-general-settings-screen-dart)：通用設定、語言、字體與頭像顯示
- [`lib/screens/user_profile_screen.dart`](#file-lib-screens-user-profile-screen-dart)：用戶檔案、稱謂、自我介紹與頭像
- [`lib/screens/saved_messages_screen.dart`](#file-lib-screens-saved-messages-screen-dart)：收藏訊息列表與回跳來源對話
- [`lib/screens/usage_dashboard_screen.dart`](#file-lib-screens-usage-dashboard-screen-dart)：Token 用量、cache hit、成本與圖表儀表盤
- [`lib/theme/app_theme.dart`](#file-lib-theme-app-theme-dart)：當前主題狀態、色彩 getter 與全域樣式
- [`lib/theme/theme_presets.dart`](#file-lib-theme-theme-presets-dart)：預設主題色盤資料
- [`lib/services/settings/theme_settings.dart`](#file-lib-services-settings-theme-settings-dart)：主題、背景圖、色彩覆蓋與字體設定
- [`lib/services/settings/user_settings.dart`](#file-lib-services-settings-user-settings-dart)：用戶、角色與雜項偏好設定
- [`lib/widgets/gradient_background.dart`](#file-lib-widgets-gradient-background-dart)：全局漸層/圖片背景與抖動 painter
- [`lib/widgets/starfield_painter.dart`](#file-lib-widgets-starfield-painter-dart)：星光粒子背景 painter
- [`lib/widgets/neural_field.dart`](#file-lib-widgets-neural-field-dart)：神經網狀背景 painter
- [`lib/widgets/input_bar.dart`](#file-lib-widgets-input-bar-dart)：聊天底部輸入框、附件與發送按鈕
- [`lib/widgets/atom_thinking.dart`](#file-lib-widgets-atom-thinking-dart)：思考狀態原子動畫
- [`lib/widgets/x_post_panel.dart`](#file-lib-widgets-x-post-panel-dart)：X/社群發文設定底部面板

### 像素小屋、Game、NPC
- [`lib/screens/game_screen.dart`](#file-lib-screens-game-screen-dart)：像素小屋頁與 Flame GameWidget 宿主
- [`lib/game/config.dart`](#file-lib-game-config-dart)：像素小屋尺寸、偏好 key 與常數
- [`lib/game/holt_game.dart`](#file-lib-game-holt-game-dart)：Flame 像素小屋主遊戲與 NPC 佔位行為
- [`lib/game/actors/actor_state.dart`](#file-lib-game-actors-actor-state-dart)：遊戲 Actor 狀態資料
- [`lib/game/bridge/emotion_bridge.dart`](#file-lib-game-bridge-emotion-bridge-dart)：情緒座標到遊戲狀態的橋接
- [`lib/game/bridge/schedule_bridge.dart`](#file-lib-game-bridge-schedule-bridge-dart)：角色行程到遊戲位置的橋接
- [`lib/game/npc/game_npc_settings.dart`](#file-lib-game-npc-game-npc-settings-dart)：遊戲 NPC 模型選擇設定
- [`lib/game/npc/npc_brain.dart`](#file-lib-game-npc-npc-brain-dart)：遊戲 NPC 腦與模型調用策略
- [`lib/game/sprite/yanci_pixels.dart`](#file-lib-game-sprite-yanci-pixels-dart)：晏辭像素幀資料與繪製

### 語系、實驗功能、社群發文
- [`lib/services/locale_strings.dart`](#file-lib-services-locale-strings-dart)：簡易多語文案表
- [`lib/services/x_post_settings.dart`](#file-lib-services-x-post-settings-dart)：X/社群發文設定與每日計數
- [`lib/widgets/x_post_panel.dart`](#file-lib-widgets-x-post-panel-dart)：X/社群發文設定底部面板

## 細分小類：逐檔行段

### Game 像素小屋與 NPC

<a id="file-lib-game-actors-actor-state-dart"></a>
#### `lib/game/actors/actor_state.dart` - 遊戲 Actor 狀態資料（3 行）
- 第 3-3 行：YanciActorState enum 狀態/選項：NPC 基礎動作狀態（規劃表 表四）。 M1 只用 idle / walk；sit / sleep / wave 等 M2 接 bio_clock 後啟用。。

<a id="file-lib-game-bridge-emotion-bridge-dart"></a>
#### `lib/game/bridge/emotion_bridge.dart` - 情緒座標到遊戲狀態的橋接（12 行）
- 第 3-4 行：YanciMood enum 狀態/選項：情緒修飾層：emotion_coordinates → 小人的表情/氣泡修飾。 規劃表 表五：閾值全在這裡，遊戲層只認枚舉。。
- 第 5-12 行：EmotionBridge 類別/狀態定義。

<a id="file-lib-game-bridge-schedule-bridge-dart"></a>
#### `lib/game/bridge/schedule_bridge.dart` - 角色行程到遊戲位置的橋接（21 行）
- 第 5-11 行：ScheduleSnapshot 類別/狀態定義：日程快照：bio_clock → 「現在他在哪個房間、做什麼」 規劃表 表五：bridge 只讀 service，遊戲不做決策、不碰 DB。。
- 第 12-21 行：ScheduleBridge 類別/狀態定義。

<a id="file-lib-game-config-dart"></a>
#### `lib/game/config.dart` - 像素小屋尺寸、偏好 key 與常數（24 行）
- 第 2-2 行：GameConfig 類別/狀態定義：遊戲層全部常數 —— 魔法數字禁止散落在別處（審核表 A-3）。
- 第 3-10 行：像素規格（跟《像素遊戲內嵌規劃表》一致）。
- 第 11-14 行：佔位地圖（M1：Tiled 地圖就位前的代碼房間）。
- 第 15-24 行：全局小人 overlay。

<a id="file-lib-game-holt-game-dart"></a>
#### `lib/game/holt_game.dart` - Flame 像素小屋主遊戲與 NPC 佔位行為（177 行）
- 第 17-61 行：HoltGame 類別/狀態定義：Holt 像素小屋 —— M1 骨架。 現在：代碼畫的佔位房間（米白地板 + 格線）+ 佔位晏辭在裡面溜達。 M2：flame_tiled 換真地圖，ScheduleB…。
- 第 62-90 行：_PlaceholderRoom 類別/狀態定義：佔位房間：地板 + 格線 + 一圈牆。Tiled 地圖就位後整個刪掉。。
- 第 91-177 行：YanciNpc 類別/狀態定義：佔位晏辭 NPC：待機眨眼 + 隨機溜達 + 點地板走過去。 素材就位後：渲染換 SpriteAnimationGroupComponent，狀態機不變。。

<a id="file-lib-game-npc-game-npc-settings-dart"></a>
#### `lib/game/npc/game_npc_settings.dart` - 遊戲 NPC 模型選擇設定（21 行）
- 第 6-21 行：GameNpcSettings 類別/狀態定義：遊戲 NPC 的 AI 設定（遊戲頁右上角齒輪調）。 取值：'' = 不啟用；[followChat] = 跟隨聊天當前模型（API/本地都行， 永遠與 API 設定同…。

<a id="file-lib-game-npc-npc-brain-dart"></a>
#### `lib/game/npc/npc_brain.dart` - 遊戲 NPC 腦與模型調用策略（29 行）
- 第 14-29 行：NpcBrain 類別/狀態定義：NPC 的腦子 —— 按齒輪設定拿到能推理的本地模型 adapter。 M2+ TODO：NPC 對話迴路（人設 prompt、短上下文、氣泡輸出）。 本輪只鋪通「設定…。

<a id="file-lib-game-sprite-yanci-pixels-dart"></a>
#### `lib/game/sprite/yanci_pixels.dart` - 晏辭像素幀資料與繪製（128 行）
- 第 12-128 行：YanciPixels 類別/狀態定義：佔位像素小人 —— YANCI-32 配色，16×24。 全局 overlay 和 Flame 遊戲共用同一份數據。 昭昭的 Aseprite sprite sheet…。

### App 入口

<a id="file-lib-main-dart"></a>
#### `lib/main.dart` - App 入口、初始化、根路由與全局包裝（236 行）
- 第 38-48 行：callbackDispatcher() 檔案級函式。
- 第 49-104 行：main() 檔案級函式。
- 第 105-119 行：_applySystemOverlay() 檔案級函式。
- 第 120-128 行：toggleTheme() 檔案級函式：切換主題（兼容舊代碼，新代碼用主題工坊）。
- 第 129-137 行：changeFont() 檔案級函式：切換字體（任何地方都能呼叫）。
- 第 138-143 行：changeFontScale() 檔案級函式：切換字體大小（任何地方都能呼叫）。
- 第 144-150 行：YanciApp 類別/狀態定義。
- 第 151-236 行：_YanciAppState 類別/狀態定義。

### Memory 記憶與資料層

<a id="file-lib-memory-database-dart"></a>
#### `lib/memory/database.dart` - SQLite schema、migration 與資料 CRUD（1684 行）
- 第 10-376 行：DatabaseHelper 類別/狀態定義：本地數據庫 v3 — 角色綁定 + 表情包。
- 第 377-665 行：上下文壓縮表。
- 第 666-837 行：級聯清理：對話（含其語音/收藏）、記憶、貼圖（含文件）。
- 第 838-1684 行：級聯清理：語音（含文件）、收藏。

<a id="file-lib-memory-emotion-coordinates-dart"></a>
#### `lib/memory/emotion_coordinates.dart` - 情緒座標、衰減、安全感與負面情緒系統（1524 行）
- 第 51-128 行：EmotionPoint 類別/狀態定義：單個情緒點（同 V1 結構，保持向後相容）。
- 第 129-158 行：EmotionCoordinates 類別/狀態定義。
- 第 159-175 行：交互衰減。
- 第 176-199 行：安全感閒置衰減。
- 第 200-220 行：翻舊帳。
- 第 221-307 行：維度上限。
- 第 308-333 行：交叉影響常數。
- 第 334-513 行：交叉影響：動態調整 cap 和濃度。
- 第 514-541 行：預計算交互衰減參數。
- 第 542-562 行：慾望專屬衰減：90min 線性歸零。
- 第 563-568 行：安全感：不走標準衰減。
- 第 569-602 行：閒置衰減（≥85 不豁免：一直不來，本身就是事件）。
- 第 603-634 行：活躍期：負面侵蝕 / 回暖，每點最多一小時一次。
- 第 635-639 行：≥85：不自然衰減，只能事件消解。
- 第 640-651 行：<10：自然消散。
- 第 652-682 行：10~84：標準衰減（安全感已在上面獨立分支處理）。
- 第 683-1084 行：交叉影響：戲謔高 → 愜意 tick +1，cap 45。
- 第 1085-1433 行：V2 grudge_sealed：同輪有負面情緒 ≥70 且有具體事件記憶 → 掛標記。
- 第 1434-1446 行：底色：五維進度條。
- 第 1447-1457 行：近期波動。
- 第 1458-1466 行：共振 / 拉扯。
- 第 1467-1509 行：翻舊帳（概率 roll，有副作用）。
- 第 1510-1524 行：_ParsedEmotionPoint 類別/狀態定義。

<a id="file-lib-memory-retriever-dart"></a>
#### `lib/memory/retriever.dart` - 長期記憶檢索與 prompt 注入（161 行）
- 第 7-37 行：Retriever 類別/狀態定義：記憶檢索器（V2：扁平注入 + 單一預算 + 觸發詞優先）。
- 第 38-68 行：維護模式：全量注入。
- 第 69-96 行：正常模式：單一預算，扁平注入。
- 第 97-161 行：輔助：嘗試注入一條。

<a id="file-lib-memory-summarizer-dart"></a>
#### `lib/memory/summarizer.dart` - 長期記憶摘要、寫入、整理與去重（536 行）
- 第 11-15 行：Summarizer 類別/狀態定義：記憶摘要器 — 單層記憶 + 角色綁定。
- 第 16-63 行：日常模式 prompt（~800 tokens）。
- 第 64-120 行：劇情模式 prompt（~1800 tokens）。
- 第 121-163 行：English romance prompt。
- 第 164-251 行：English story prompt。
- 第 252-322 行：注入現有記憶，讓模型去重。
- 第 323-536 行：代碼級去重：與既有記憶高度相似的不入庫。

### Models 資料模型

<a id="file-lib-models-memory-dart"></a>
#### `lib/models/memory.dart` - 長期記憶資料模型（79 行）
- 第 2-79 行：Memory 類別/狀態定義：記憶資料模型（帶角色綁定 + 送審計數）。

<a id="file-lib-models-message-dart"></a>
#### `lib/models/message.dart` - 聊天訊息與對話資料模型（100 行）
- 第 2-60 行：Message 類別/狀態定義：訊息資料模型（帶角色綁定）。
- 第 61-100 行：Conversation 類別/狀態定義：對話資料模型（帶角色綁定）。

### Screens 頁面級 UI

<a id="file-lib-screens-api-sub-settings-screen-dart"></a>
#### `lib/screens/api_sub_settings_screen.dart` - 進階 API、思考鏈、摘要與畫圖模型設定頁（601 行）
- 第 9-15 行：ApiSubSettingsScreen 類別/狀態定義：API 子設定 — 思考鏈 / 拆分回覆 / 摘要。
- 第 16-79 行：_ApiSubSettingsScreenState 類別/狀態定義。
- 第 80-128 行：思考鏈。
- 第 129-177 行：拆分回覆。
- 第 178-180 行：節省 Token。
- 第 181-236 行：精簡對話。
- 第 237-360 行：自由發揮。
- 第 361-422 行：窗口摘要。
- 第 423-462 行：Debug 入口。
- 第 463-531 行：畫圖模型（OpenRouter 圖像輸出）。
- 第 532-538 行：_ImageModelField 類別/狀態定義：畫圖模型輸入欄（自包含：自行讀寫設定，不依賴頁面狀態）。
- 第 539-601 行：_ImageModelFieldState 類別/狀態定義。

<a id="file-lib-screens-call-screen-dart"></a>
#### `lib/screens/call_screen.dart` - 語音通話頁與 STT/LLM/TTS 流程（633 行）
- 第 19-32 行：CallScreen 類別/狀態定義：語音通話介面 佈局：上方水紋視覺 → 中間文字區 → 下方按鈕列（麥克風 + 掛斷） 流程：按住麥克風 → STT → 送 LLM → 自動 TTS → 循環。
- 第 33-139 行：_CallScreenState 類別/狀態定義。
- 第 140-180 行：按住錄音。
- 第 181-238 行：送 AI + 自動 TTS。
- 第 239-358 行：OpenAI TTS 串行路徑。
- 第 359-373 行：角色名 + 狀態。
- 第 374-400 行：語言切換。
- 第 401-408 行：水紋視覺化（主體）。
- 第 409-427 行：即時識別文字。
- 第 428-489 行：對話記錄（可收起）。
- 第 490-495 行：底部按鈕列：麥克風（按住）+ 掛斷。
- 第 496-532 行：麥克風（按住錄音）。
- 第 533-623 行：掛斷。
- 第 624-633 行：_CallMessage 類別/狀態定義。

<a id="file-lib-screens-character-card-screen-dart"></a>
#### `lib/screens/character_card_screen.dart` - 角色人設卡、頭像、token 門檻與畫圖錨點（1186 行）
- 第 21-29 行：CharacterCardScreen 類別/狀態定義：人設卡 — 創建/編輯（存 DB，無行數限制）。
- 第 30-42 行：_CharacterCardScreenState 類別/狀態定義。
- 第 43-251 行：Token 計數（緩存門檻提示）。
- 第 252-261 行：頂部：圖片（左）+ 基本資訊（右）。
- 第 262-362 行：2:3 人設圖片（帶模糊邊緣）。
- 第 363-417 行：右側：姓名 / 性別 / 關係（透明氣泡框）。
- 第 418-420 行：Token 計數（緩存門檻提示）。
- 第 421-479 行：角色設定（透明氣泡圓角框）。
- 第 480-540 行：情緒座標測試面板（kVisible 控制顯隱）。
- 第 541-1186 行：畫畫角色錨點。

<a id="file-lib-screens-character-list-screen-dart"></a>
#### `lib/screens/character_list_screen.dart` - 角色列表、角色資源入口與能力開關（856 行）
- 第 20-26 行：CharacterListScreen 類別/狀態定義：角色管理 — 橫向卡片輪盤 + 關聯資源入口。
- 第 27-82 行：_CharacterListScreenState 類別/狀態定義。
- 第 83-140 行：頂部欄。
- 第 141-184 行：橫向卡片輪盤。
- 第 185-210 行：頁面指示器。
- 第 211-216 行：時間線。
- 第 217-277 行：關聯資源入口（語音 / 表情庫 / 記憶 / 收藏）。
- 第 278-372 行：圓形頭像。
- 第 373-835 行：底部操作。
- 第 836-842 行：_ResourceTab 類別/狀態定義。
- 第 843-856 行：_AbilityModule 類別/狀態定義。

<a id="file-lib-screens-chat-screen-dart"></a>
#### `lib/screens/chat_screen.dart` - 聊天主流程、prompt 組裝、stream、工具與保活（2880 行）
- 第 37-45 行：ChatScreen 類別/狀態定義：聊天頁面 — 完整版（2.0：adapter 工廠 + 角色綁定）。
- 第 46-78 行：_ChatScreenState 類別/狀態定義。
- 第 79-81 行：本地模型預加載。
- 第 82-86 行：歷史搜尋卡片狀態。
- 第 87-193 行：流式標籤實時剝離。
- 第 194-277 行：本地模型預加載：進聊天頁就開始，不等發送。
- 第 278-281 行：B1：記憶桶名唯一事實源（daily/story 兩個世界互不可見）。
- 第 282-284 行：B4：滯後截斷錨點（歷史只在尾部增長，絕對索引跨輪穩定）。
- 第 285-288 行：習慣快照（增量方案）：開窗時凍結，窗內新增走動態。
- 第 289-588 行：自我註記快照（同款增量方案）。
- 第 589-652 行：並行化：一次發射所有獨立的異步調用，大幅減少等待。
- 第 653-661 行：習慣快照（昭昭的增量方案）。
- 第 662-667 行：自我註記快照：開窗凍結，窗內 persona_note 新增走動態。
- 第 668-674 行：拆分 prompt：靜態（可緩存）+ 動態（每次變）。
- 第 675-702 行：可用工具（統一 header + 各模塊 section）。
- 第 703-705 行：習慣清單（靜態：模型看得到全貌才不會重複記）。
- 第 706-856 行：節省 Token 指引（開關控制，關閉時零開銷）。
- 第 857-884 行：B4 滯後截斷（保護前綴緩存）。
- 第 885-895 行：記錄真實 API 用量（不再用估算，避免雙重計算）。
- 第 896-903 行：模型自主記憶：開啟時才執行 <memo>/<persona_note> 落庫。
- 第 904-911 行：情緒座標：<emo> 打點入庫並剝離。
- 第 912-916 行：生物鐘：<clock> 標籤入庫並剝離。
- 第 917-928 行：角色生活化：<life_fix> 處理 + 關鍵詞掃描。
- 第 929-940 行：便箋：<home> 標籤處理（存入 sticky_notes）。
- 第 941-951 行：模型畫畫：先出字後出圖（圖在後台生成，好了自己掛上）。
- 第 952-1044 行：歷史搜尋：<search_chat> 觸發可視化搜索 + 自動追加回覆。
- 第 1045-1098 行：記憶過程日誌：只記寫入本地的操作。
- 第 1099-1119 行：回覆完成震動 + Cache 命中震動。
- 第 1120-1201 行：AI 自動命名。
- 第 1202-1348 行：構建 API 消息。
- 第 1349-1376 行：歷史圖片降級：只有最新一張真實上傳。
- 第 1377-1423 行：B4 滯後截斷（保護前綴緩存）。
- 第 1424-1433 行：記錄真實 API 用量。
- 第 1434-1441 行：模型自主記憶：開啟時才執行 <memo>/<persona_note> 落庫。
- 第 1442-1449 行：情緒座標：<emo> 打點入庫並剝離。
- 第 1450-1454 行：生物鐘：<clock> 標籤入庫並剝離。
- 第 1455-1466 行：角色生活化：<life_fix> 處理 + 關鍵詞掃描。
- 第 1467-1478 行：便箋：<home> 標籤處理（存入 sticky_notes）。
- 第 1479-1489 行：模型畫畫：先出字後出圖（圖在後台生成，好了自己掛上）。
- 第 1490-1765 行：記憶過程日誌：只記寫入本地的操作。
- 第 1766-1815 行：待發圖片預覽。
- 第 1816-1869 行：待發表情包預覽。
- 第 1870-2149 行：圖片生成中 banner。
- 第 2150-2158 行：搜索卡片（streaming 後、最末尾）。
- 第 2159-2304 行：流式氣泡（拆分回覆時按段落拆）。
- 第 2305-2318 行：角色名（加粗）。
- 第 2319-2379 行：模型 + token。
- 第 2380-2770 行：開新窗口。
- 第 2771-2795 行：_DisplayItem 類別/狀態定義：顯示用消息項（支持拆分回覆）。
- 第 2796-2805 行：_MarqueeText 類別/狀態定義：文字過長時慢速水平滾動，短文字靜態顯示。
- 第 2806-2880 行：_MarqueeTextState 類別/狀態定義。

<a id="file-lib-screens-context-debug-screen-dart"></a>
#### `lib/screens/context_debug_screen.dart` - 窗口摘要與 keyword block 調試/修訂頁（607 行）
- 第 7-14 行：ContextDebugScreen 類別/狀態定義：上下文壓縮 debug 頁（開發用，user 不可見）。
- 第 15-42 行：_ContextDebugScreenState 類別/狀態定義。
- 第 43-79 行：頂欄。
- 第 80-105 行：內容。
- 第 106-127 行：總覽。
- 第 128-183 行：摘要塊。
- 第 184-506 行：關鍵詞塊。
- 第 507-520 行：_EditableSummarySegment 類別/狀態定義。
- 第 521-529 行：_SummaryRevisionDialog 類別/狀態定義。
- 第 530-607 行：_SummaryRevisionDialogState 類別/狀態定義。

<a id="file-lib-screens-game-screen-dart"></a>
#### `lib/screens/game_screen.dart` - 像素小屋頁與 Flame GameWidget 宿主（224 行）
- 第 13-19 行：GameScreen 類別/狀態定義：像素小屋頁 —— GameWidget 宿主。 生命週期紅線（審核表 A-6）：離開頁面 / app 進後台必須 pauseEngine， 遊戲不跟聊天流式輸出搶幀。。
- 第 20-78 行：_GameScreenState 類別/狀態定義。
- 第 79-224 行：右上角齒輪：NPC AI 設定。

<a id="file-lib-screens-general-settings-screen-dart"></a>
#### `lib/screens/general_settings_screen.dart` - 通用設定、語言、字體與頭像顯示（341 行）
- 第 9-15 行：GeneralSettingsScreen 類別/狀態定義：一般設定 — 震動、語言、字體。
- 第 16-57 行：_GeneralSettingsScreenState 類別/狀態定義。
- 第 58-89 行：震動開關。
- 第 90-121 行：對話框頭像。
- 第 122-148 行：像素小人。
- 第 149-185 行：語言。
- 第 186-225 行：字體。
- 第 226-341 行：User 表情庫。

<a id="file-lib-screens-home-screen-dart"></a>
#### `lib/screens/home_screen.dart` - 首頁、角色輪盤、正在聊入口與對話歷史（2184 行）
- 第 23-29 行：HomeScreen 類別/狀態定義：主頁 — 角色輪盤 + 水晶球 + 底部導航。
- 第 30-315 行：_HomeScreenState 類別/狀態定義。
- 第 316-318 行：問候文本。
- 第 319-320 行：角色輪盤。
- 第 321-323 行：心跳數值。
- 第 324-333 行：心電圖波動（點擊開始新對話）。
- 第 334-338 行：正在聊的窗口入口。
- 第 339-1003 行：歷史對話按鈕（右上角）。
- 第 1004-1062 行：搜索框。
- 第 1063-1311 行：對話列表。
- 第 1312-1324 行：「我的」佈局參數（手動調整用）。
- 第 1325-1424 行：頭像卡片區（點擊進入用戶檔案）。
- 第 1425-1434 行：設置入口。
- 第 1435-1446 行：本地模型入口。
- 第 1447-1460 行：主題工坊入口。
- 第 1461-1544 行：像素小屋大入口。
- 第 1545-2017 行：備份操作。
- 第 2018-2175 行：_EcgPainter 類別/狀態定義：發光心電線 — Light Line 風格，從左往右掃描。
- 第 2176-2184 行：_MiniYanciPainter 類別/狀態定義：像素小屋入口的迷你晏辭（16×24 @1.5x = 24×36）。

<a id="file-lib-screens-local-model-screen-dart"></a>
#### `lib/screens/local_model_screen.dart` - 本地模型下載、管理、相容性與 GPU 狀態頁（1220 行）
- 第 11-17 行：LocalModelScreen 類別/狀態定義：本地模型管理頁面。
- 第 18-485 行：_LocalModelScreenState 類別/狀態定義。
- 第 486-515 行：頂部標題列。
- 第 516-1220 行：內容。

<a id="file-lib-screens-memory-screen-dart"></a>
#### `lib/screens/memory_screen.dart` - 長期記憶列表、手動寫入、整理與回收站（1363 行）
- 第 16-24 行：MemoryScreen 類別/狀態定義：記憶庫頁面 — V2：扁平列表 + 浮動回收站。
- 第 25-1363 行：_MemoryScreenState 類別/狀態定義。

<a id="file-lib-screens-saved-messages-screen-dart"></a>
#### `lib/screens/saved_messages_screen.dart` - 收藏訊息列表與回跳來源對話（301 行）
- 第 9-22 行：SavedMessagesScreen 類別/狀態定義：收藏消息頁面 — 按角色顯示收藏的消息。
- 第 23-301 行：_SavedMessagesScreenState 類別/狀態定義。

<a id="file-lib-screens-settings-screen-dart"></a>
#### `lib/screens/settings_screen.dart` - 主設定頁、API provider、模型、cache、上下文與 TTS（1445 行）
- 第 10-16 行：SettingsScreen 類別/狀態定義：設定頁 — API key + 自動拉取模型列表 + System Prompt。
- 第 17-238 行：_SettingsScreenState 類別/狀態定義。
- 第 239-256 行：進階設定（思考鏈/拆分/摘要）。
- 第 257-506 行：API 來源。
- 第 507-677 行：Model 選擇（可收起）。
- 第 678-742 行：緩存命中（默認展開，開關默認關）。
- 第 743-859 行：上下文限制（默認收起）。
- 第 860-890 行：表情包分析（可收起）。
- 第 891-1007 行：語音 TTS（默認展開）。
- 第 1008-1254 行：Voice ID 列表。
- 第 1255-1445 行：儲存按鈕。

<a id="file-lib-screens-splash-screen-dart"></a>
#### `lib/screens/splash_screen.dart` - 啟動畫面與星光動畫（305 行）
- 第 7-13 行：SplashScreen 類別/狀態定義：開屏動畫 海獺落下 → Holt 逐字淡入 → 星光散開 → 推進主頁。
- 第 14-44 行：_SplashScreenState 類別/狀態定義。
- 第 45-64 行：1. Logo：從上方滑落 + 縮放 + 淡入。
- 第 65-70 行：2. 文字「Holt」逐字淡入。
- 第 71-76 行：3. 星光散開。
- 第 77-173 行：4. 退場。
- 第 174-238 行：Logo + 星光。
- 第 239-292 行：「Holt」逐字淡入。
- 第 293-305 行：_StarParticle 類別/狀態定義。

<a id="file-lib-screens-sticker-library-screen-dart"></a>
#### `lib/screens/sticker_library_screen.dart` - 表情包庫、Vision 描述與手動標註（776 行）
- 第 11-19 行：StickerLibraryScreen 類別/狀態定義：表情包庫管理頁 — 上傳 + 三種描述方式 + Vision API。
- 第 20-170 行：_StickerLibraryScreenState 類別/狀態定義。
- 第 171-197 行：Tab 切換。
- 第 198-243 行：Tab 0：選標籤。
- 第 244-437 行：Tab 1：Vision API。
- 第 438-460 行：Tab 2：手動輸入。
- 第 461-776 行：儲存按鈕。

<a id="file-lib-screens-theme-workshop-screen-dart"></a>
#### `lib/screens/theme_workshop_screen.dart` - 主題工坊、色彩、氣泡與背景圖調整（1311 行）
- 第 13-19 行：ThemeWorkshopScreen 類別/狀態定義：主題工坊 — 選預設 + 微調氣泡/星光。
- 第 20-387 行：_ThemeWorkshopScreenState 類別/狀態定義。
- 第 388-403 行：進階設定。
- 第 404-414 行：預設主題。
- 第 415-469 行：氣泡微調。
- 第 470-524 行：星光。
- 第 525-623 行：預設主題網格。
- 第 624-671 行：氣泡預覽。
- 第 672-994 行：通用拉條。
- 第 995-1019 行：色相。
- 第 1020-1032 行：飽和。
- 第 1033-1047 行：亮度。
- 第 1048-1303 行：歷史選色。
- 第 1304-1311 行：_ColorEntry 類別/狀態定義。

<a id="file-lib-screens-usage-dashboard-screen-dart"></a>
#### `lib/screens/usage_dashboard_screen.dart` - Token 用量、cache hit、成本與圖表儀表盤（460 行）
- 第 9-15 行：UsageDashboardScreen 類別/狀態定義：用量監控面板。
- 第 16-173 行：_UsageDashboardScreenState 類別/狀態定義。
- 第 174-258 行：摘要卡片。
- 第 259-279 行：折線圖。
- 第 280-360 行：模型分佈。
- 第 361-460 行：_UsageChartPainter 類別/狀態定義：簡易折線圖。

<a id="file-lib-screens-user-profile-screen-dart"></a>
#### `lib/screens/user_profile_screen.dart` - 用戶檔案、稱謂、自我介紹與頭像（447 行）
- 第 16-22 行：UserProfileScreen 類別/狀態定義：用戶檔案 — 頭像、暱稱、偏好、自訂資訊。
- 第 23-29 行：_UserProfileScreenState 類別/狀態定義。
- 第 30-232 行：Token 計數（緩存門檻提示）。
- 第 233-436 行：頭像。
- 第 437-447 行：SharedPreferencesHelper 類別/狀態定義：SharedPreferences 簡易輔助。

<a id="file-lib-screens-voice-library-screen-dart"></a>
#### `lib/screens/voice_library_screen.dart` - TTS 語音庫管理、播放與刪除（380 行）
- 第 10-16 行：VoiceLibraryScreen 類別/狀態定義：語音庫 — 管理已保存的 TTS 語音。
- 第 17-228 行：_VoiceLibraryScreenState 類別/狀態定義。
- 第 229-266 行：頂部欄。
- 第 267-380 行：內容。

### Services 服務層

<a id="file-lib-services-api-adapter-dart"></a>
#### `lib/services/api_adapter.dart` - API adapter 介面、StructuredPrompt 與 cache breakpoint（82 行）
- 第 4-17 行：StructuredPrompt 類別/狀態定義：結構化 System Prompt（支持 prompt caching） static → 人設卡內容（不變，可緩存） dynamic → 記憶注入 + 時間 + 表情…。
- 第 18-36 行：ApiAdapter 類別/狀態定義：API 統一接口。
- 第 37-79 行：CacheBreakpoint 類別/狀態定義：共用：Anthropic 風格滾動緩存斷點（1 小時 TTL） 掛在「最新 user 之前的最後一條消息」的最後一個 block 上， 緩存邊界停在純歷史上，含 dyn…。
- 第 80-82 行：CacheSession 類別/狀態定義：緩存會話錨點：以對話為單位 換新對話 = 新 session（前綴本就不同，乾淨切開）； 進出同一對話 = 同 session（命中中的緩存不被打斷）。 chat_sc…。

<a id="file-lib-services-aws-bedrock-service-dart"></a>
#### `lib/services/aws_bedrock_service.dart` - AWS Bedrock Claude 直連、SigV4 與 cache stats（316 行）
- 第 11-157 行：BedrockService 類別/狀態定義：AWS Bedrock 直連 Claude — 帶 Signature V4 簽名。
- 第 158-169 行：歷史統一 blocks 格式（滾動斷點需要）。
- 第 170-179 行：滾動 breakpoint（按模型能力決定 TTL）— 僅啟用 caching 時。
- 第 180-316 行：dynamic 注入最新 user。

<a id="file-lib-services-backup-service-dart"></a>
#### `lib/services/backup_service.dart` - JSON/DB/SharedPreferences 全量備份（421 行）
- 第 13-39 行：BackupService 類別/狀態定義：備份服務 — JSON 導出 + 本地全量備份。
- 第 40-42 行：角色卡。
- 第 43-68 行：對話 + 訊息。
- 第 69-73 行：記憶。
- 第 74-76 行：便箋。
- 第 77-82 行：表情包。
- 第 83-88 行：用量記錄。
- 第 89-94 行：情緒座標歷史。
- 第 95-103 行：角色生活化 timeline。
- 第 104-109 行：語音。
- 第 110-113 行：SharedPreferences（用戶設定）。
- 第 114-141 行：組裝。
- 第 142-168 行：寫入。
- 第 169-179 行：角色卡。
- 第 180-216 行：對話 + 訊息。
- 第 217-230 行：記憶。
- 第 231-243 行：封存記憶。
- 第 244-256 行：便箋。
- 第 257-288 行：表情包 / 情緒座標 / 時間線 / 用量。
- 第 289-321 行：SharedPreferences。
- 第 322-347 行：備份 SQLite。
- 第 348-355 行：備份 SharedPreferences。
- 第 356-421 行：寫入時間戳。

<a id="file-lib-services-bio-clock-service-dart"></a>
#### `lib/services/bio_clock_service.dart` - 生物鐘、習慣、時間窗口與 clock 工具標籤（1044 行）
- 第 37-84 行：ClockHabit 類別/狀態定義：單條習慣。
- 第 85-102 行：PendingDedup 類別/狀態定義：待去重項。
- 第 103-158 行：BioClockData 類別/狀態定義：完整生物鐘數據。
- 第 159-1031 行：BioClockService 類別/狀態定義。
- 第 1032-1044 行：_ClockParsed 類別/狀態定義：內部解析結果。

<a id="file-lib-services-character-timeline-service-dart"></a>
#### `lib/services/character_timeline_service.dart` - 角色時間線、狀態快照、事件與回憶觸發（494 行）
- 第 17-494 行：CharacterTimelineService 類別/狀態定義：═══════════════════════════════════════════════ 角色生活化 Timeline 服務 ══════════════════…。

<a id="file-lib-services-context-compressor-dart"></a>
#### `lib/services/context_compressor.dart` - 窗口摘要、鏈式壓縮、關鍵詞與段落修訂（630 行）
- 第 20-24 行：ContextCompressor 類別/狀態定義：窗口摘要器 — 鏈式摘要 + 關鍵詞提取 三層結構： - 關鍵詞層 ≤ 900 tokens（最舊摘要壓縮而來，觸發召回用） - 摘要層 ≤ 1200 tokens（滾…。
- 第 25-63 行：壓縮 prompt。
- 第 64-362 行：關鍵詞提取 prompt。
- 第 363-630 行：內部方法。

<a id="file-lib-services-deepseek-service-dart"></a>
#### `lib/services/deepseek_service.dart` - DeepSeek OpenAI-compatible API 與自動 cache 統計（171 行）
- 第 9-171 行：DeepSeekService 類別/狀態定義：DeepSeek API（OpenAI 兼容格式，自動 prompt caching） 不需要手動標記 cache_control，DeepSeek 自動緩存重複前綴…。

<a id="file-lib-services-gemini-service-dart"></a>
#### `lib/services/gemini_service.dart` - Google Gemini API、cachedContents 與 streaming（326 行）
- 第 12-320 行：GeminiService 類別/狀態定義：Google Gemini API 直連 Context caching 依模型有不同最低 token 門檻 達不到門檻時降級為普通請求。
- 第 321-326 行：_GeminiCacheEntry 類別/狀態定義。

<a id="file-lib-services-image-gen-service-dart"></a>
#### `lib/services/image_gen_service.dart` - OpenRouter 圖像生成與角色畫圖錨點拼接（101 行）
- 第 14-33 行：ImageGenService 類別/狀態定義：模型畫畫：`<draw>prompt</draw>` 標籤 → OpenRouter 圖像輸出模型 僅 OpenRouter 路線可用（chat_screen 注入能力…。
- 第 34-101 行：拼接角色錨點 + 畫風。

<a id="file-lib-services-image-service-dart"></a>
#### `lib/services/image_service.dart` - 圖片複製、壓縮與 base64 data URL（106 行）
- 第 11-79 行：ImageService 類別/狀態定義：圖片壓縮 & 編碼服務 壓縮交給 image_picker（選圖時 maxWidth/imageQuality）， 這裡只負責：複製到 app 目錄 + base64…。
- 第 80-80 行：壓縮：原圖整張 base64 會概率性撞 provider 體積上限。
- 第 81-106 行：（手機原相機照片動輒 4~12MB，base64 再膨脹 1.33x）。

<a id="file-lib-services-json-exporter-dart"></a>
#### `lib/services/json_exporter.dart` - 對話、記憶與全資料 JSON 匯出（183 行）
- 第 8-183 行：JsonExporter 類別/狀態定義：JSON 導出 — 對話記錄 + 記憶。

<a id="file-lib-services-keep-alive-service-dart"></a>
#### `lib/services/keep_alive_service.dart` - 關窗保活、心跳與正在聊窗口持久化（741 行）
- 第 18-28 行：KeepAliveHeartbeat 類別/狀態定義：角色心跳事件。。
- 第 29-741 行：KeepAliveService 類別/狀態定義：關窗保活服務。 只有已確認支持 1 小時 cache TTL 的模型會啟動。無此能力的模型不做 關窗 ping，避免把隱藏心跳變成額外燒錢請求。。

<a id="file-lib-services-local-ai-service-dart"></a>
#### `lib/services/local_ai_service.dart` - 舊本地 AI 佔位 adapter（30 行）
- 第 4-30 行：LocalAiService 類別/狀態定義：本地 AI — 暫時佔位，等確認 flutter_gemma API 再接。

<a id="file-lib-services-local-model-service-dart"></a>
#### `lib/services/local_model_service.dart` - 本地模型 catalog、下載、推理、相容性與 fallback（2028 行）
- 第 31-38 行：LocalModelService 類別/狀態定義：═══════════════════════════════════════════════ 本地模型服務 ═════════════════════════════…。
- 第 39-71 行：Qwen3 系列（mlabonne abliteration → Mungert GGUF）。
- 第 72-87 行：Llama 3.2 系列（QuantFactory abliterated GGUF）。
- 第 88-103 行：Phi 4 系列（mradermacher imatrix abliterated GGUF）。
- 第 104-120 行：Gemma 2 系列（Nidum uncensored GGUF）。
- 第 121-272 行：Gemma 4 系列（HauhauCS aggressive abliteration + imatrix）。
- 第 273-1169 行：enqueue 後台下載的回調管理。
- 第 1170-1219 行：RAM 預檢：用 MemAvailable 判斷，不看 MemTotal。
- 第 1220-1222 行：自適應 maxTokens（只影響本地，不影響 API）。
- 第 1223-1352 行：GPU → CPU fallback（跟 llamadart Vulkan 策略同理）。
- 第 1353-1368 行：Crash canary 偵測。
- 第 1369-1393 行：第一級：Vulkan 全層 offload。
- 第 1394-1424 行：第二級：Vulkan 部分 offload（~40% 層）。
- 第 1425-1529 行：最終：CPU（Android）或 auto（桌面）。
- 第 1530-1534 行：加速開關。
- 第 1535-1539 行：線程調優（0 auto，Android 上明確設定物理核心數效果更好）。
- 第 1540-1654 行：Batch 調優（prompt 處理吞吐）。
- 第 1655-1950 行：Crash canary：第一個 token 成功 → GPU 推理沒問題 → 清除金絲雀。
- 第 1951-2022 行：LocalModelInfo 類別/狀態定義。
- 第 2023-2028 行：ModelCompatibility enum 狀態/選項。

<a id="file-lib-services-locale-strings-dart"></a>
#### `lib/services/locale_strings.dart` - 簡易多語文案表（1005 行）
- 第 3-619 行：L 類別/狀態定義。
- 第 620-622 行：input bar。
- 第 623-701 行：settings: API / model。
- 第 702-706 行：call screen pronouns。
- 第 707-713 行：usage。
- 第 714-780 行：character card。
- 第 781-812 行：theme workshop。
- 第 813-899 行：memory screen。
- 第 900-921 行：sticker tags。
- 第 922-957 行：sticker。
- 第 958-991 行：theme presets。
- 第 992-1005 行：home。

<a id="file-lib-services-memory-actions-dart"></a>
#### `lib/services/memory_actions.dart` - 模型記憶工具標籤解析、落庫與剝離（320 行）
- 第 13-320 行：MemoryActions 類別/狀態定義：模型自主記憶動作 模型在回覆中用標籤聲明記憶動作，落庫前剝離執行： - `<memo>[類別] 內容 @觸發詞</memo>` → 主動寫入記憶（高置信度） - `<p…。

<a id="file-lib-services-openai-compatible-service-dart"></a>
#### `lib/services/openai_compatible_service.dart` - OpenAI-compatible/自建端點與 Claude cache blocks（266 行）
- 第 11-180 行：OpenAICompatibleService 類別/狀態定義：OpenAI 兼容 API（支持任何中轉站 / 自建端點） 只要遵循 /v1/chat/completions 格式就能用。
- 第 181-232 行：system 只放靜態部分，動態移到最新 user。
- 第 233-241 行：滾動 breakpoint（僅 Claude 路線 + 啟用 caching）。
- 第 242-266 行：dynamic 注入最新 user（保持前綴穩定）。

<a id="file-lib-services-openrouter-service-dart"></a>
#### `lib/services/openrouter_service.dart` - OpenRouter chat completions、Claude cache_control 與 usage（327 行）
- 第 9-173 行：OpenRouterService 類別/狀態定義：OpenRouter API 實現（含 Anthropic prompt caching）。
- 第 174-193 行：核心：system prompt 構建。
- 第 194-241 行：關鍵：dynamic 不放 system，改注入最新 user 消息。
- 第 242-251 行：滾動 breakpoint（共用助手，1h TTL）。
- 第 252-281 行：dynamic 注入最新 user 消息（保持前綴不變）。
- 第 282-321 行：緩存優化。
- 第 322-327 行：ModelInfo 類別/狀態定義。

<a id="file-lib-services-qwen-service-dart"></a>
#### `lib/services/qwen_service.dart` - DashScope/Qwen OpenAI-compatible chat（145 行）
- 第 8-145 行：QwenService 類別/狀態定義：通義千問 API（阿里雲 DashScope，OpenAI 兼容格式） endpoint: compatible-mode/v1。

<a id="file-lib-services-secure-store-dart"></a>
#### `lib/services/secure_store.dart` - API key 安全存儲封裝（53 行）
- 第 15-53 行：SecureStore 類別/狀態定義：密鑰安全存儲（Android Keystore / iOS Keychain） 取代 SharedPreferences 明文存 API Key： 明文存儲會隨系統雲備…。

<a id="file-lib-services-sentence-buffer-dart"></a>
#### `lib/services/sentence_buffer.dart` - TTS 短句緩衝與合併（80 行）
- 第 5-80 行：SentenceBuffer 類別/狀態定義：句子緩衝器 — LLM stream tokens → 完整句子 收集 token，在斷句點（句號、問號、感嘆號、換行）切割。 太短的碎片會合併到下一句，避免 TTS…。

### Services / Settings 設定讀寫層

<a id="file-lib-services-settings-api-settings-dart"></a>
#### `lib/services/settings/api_settings.dart` - API provider、key、模型與 adapter 工廠設定（582 行）
- 第 13-13 行：ApiSettings 類別/狀態定義：API 供應商配置（OpenRouter / Bedrock / Gemini / DeepSeek / Qwen / OpenAI Compatible / Loca…。
- 第 14-170 行：通用。
- 第 171-213 行：AWS Bedrock。
- 第 214-235 行：Gemini。
- 第 236-257 行：DeepSeek。
- 第 258-279 行：Qwen。
- 第 280-312 行：OpenAI Compatible（中轉站）。
- 第 313-359 行：Local API（電腦 / 局域網 OpenAI compatible 端點）。
- 第 360-382 行：星標模型。
- 第 383-496 行：工廠方法。
- 第 497-509 行：思考鏈。
- 第 510-582 行：節省 Token。

<a id="file-lib-services-settings-memory-settings-dart"></a>
#### `lib/services/settings/memory_settings.dart` - 記憶、摘要、prompt caching、上下文與能力設定（215 行）
- 第 4-4 行：MemorySettings 類別/狀態定義：記憶系統設定（窗口摘要、模型寫入記憶、Token 預算、Prompt Caching）。
- 第 5-52 行：摘要。
- 第 53-65 行：Prompt Caching。
- 第 66-89 行：上下文 Token 限制。
- 第 90-120 行：Token 預算（V2：統一預算）。
- 第 121-150 行：舊方法保留（向後相容，新代碼不再調用）。
- 第 151-153 行：AI 拆分回覆。
- 第 154-196 行：窗口摘要總開關（舊 key 保留，避免升級後設定丟失）。
- 第 197-215 行：Ability 模組開關。

<a id="file-lib-services-settings-theme-settings-dart"></a>
#### `lib/services/settings/theme_settings.dart` - 主題、背景圖、色彩覆蓋與字體設定（181 行）
- 第 4-4 行：ThemeSettings 類別/狀態定義：主題與外觀設定（配色、氣泡、星光、字體）。
- 第 5-82 行：主題。
- 第 83-113 行：自定義圖片背景（首頁 / 對話分開）。
- 第 114-133 行：自定義色覆蓋。
- 第 134-168 行：字體。
- 第 169-181 行：歷史選色。

<a id="file-lib-services-settings-tts-settings-dart"></a>
#### `lib/services/settings/tts_settings.dart` - TTS/STT provider、語音 ID 與語言設定（162 行）
- 第 5-15 行：TtsSettings 類別/狀態定義：TTS 語音設定（OpenAI / ElevenLabs）。
- 第 16-96 行：STT 語音辨識語言。
- 第 97-162 行：多個聲音 ID 管理。

<a id="file-lib-services-settings-user-settings-dart"></a>
#### `lib/services/settings/user_settings.dart` - 用戶、角色與雜項偏好設定（143 行）
- 第 4-4 行：UserSettings 類別/狀態定義：用戶檔案、角色設定、雜項偏好。
- 第 5-50 行：用戶檔案。
- 第 51-85 行：角色設定。
- 第 86-143 行：雜項。

### Services 服務層

<a id="file-lib-services-settings-manager-dart"></a>
#### `lib/services/settings_manager.dart` - 設定 barrel export（27 行）
- 第 1-27 行：整檔職責集中，負責 設定 barrel export。

<a id="file-lib-services-sticker-service-dart"></a>
#### `lib/services/sticker_service.dart` - 表情包 prompt、Vision 描述與貼圖語法解析（292 行）
- 第 9-245 行：StickerService 類別/狀態定義：表情包管理服務 上傳 → 三種描述 → AI 挑選 → 台詞注入 prompt。
- 第 246-281 行：StickerInfo 類別/狀態定義：表情包資訊。
- 第 282-283 行：ChatSegment 類別/狀態定義：聊天內容片段。
- 第 284-288 行：TextSegment 類別/狀態定義。
- 第 289-292 行：StickerSegment 類別/狀態定義。

<a id="file-lib-services-streaming-tts-service-dart"></a>
#### `lib/services/streaming_tts_service.dart` - ElevenLabs WebSocket 串流 TTS（232 行）
- 第 14-232 行：StreamingTtsService 類別/狀態定義：ElevenLabs WebSocket 流式 TTS LLM stream → 句子 → WebSocket → 音頻 chunks → 邊收邊播 核心：三管線並行…。

<a id="file-lib-services-token-estimator-dart"></a>
#### `lib/services/token_estimator.dart` - Token 粗估、cache 門檻與保活資格判斷（239 行）
- 第 8-18 行：TokenEstimator 類別/狀態定義：Token 估算（保守方向：寧可估低，避免「以為夠門檻其實沒緩存」） CJK ≈ 1 token/字（Anthropic 實際多在 1.2~1.8），其他 ≈ 4 字符…。
- 第 19-21 行：Anthropic。
- 第 22-23 行：Gemini。
- 第 24-25 行：DeepSeek。
- 第 26-62 行：其他。
- 第 63-65 行：DeepSeek（官方 or OpenRouter 都是 64t 分塊）。
- 第 66-76 行：Gemini。
- 第 77-97 行：Anthropic / Claude（官方、OpenRouter、Bedrock）。
- 第 98-239 行：其他模型。

<a id="file-lib-services-token-tracker-dart"></a>
#### `lib/services/token_tracker.dart` - 真實 usage、cache hit/create 與成本記錄（154 行）
- 第 9-154 行：TokenTracker 類別/狀態定義：Token 用量追蹤器（真實 API 用量 + 持久化）。

<a id="file-lib-services-tts-service-dart"></a>
#### `lib/services/tts_service.dart` - OpenAI/ElevenLabs TTS、語音快取與正文抽取（486 行）
- 第 11-13 行：TtsState enum 狀態/選項：TTS 播放狀態。
- 第 14-63 行：TtsService 類別/狀態定義：TTS 統一服務 — OpenAI + ElevenLabs。
- 第 64-321 行：緩存命中 → 直接播本地文件。
- 第 322-323 行：A. 明確動作模式。
- 第 324-332 行：第二人稱感官敘事。
- 第 333-345 行：純動作起始（放寬：不要求特定結尾）。
- 第 346-360 行：副詞開頭的動作描寫。
- 第 361-370 行：身體部位起始的動作描寫。
- 第 371-378 行：環境/氛圍描寫。
- 第 379-380 行：B. 敘事風格判斷。
- 第 381-383 行：以「——」破折號結尾的敘事句（常見動作描寫斷句）。
- 第 384-385 行：整行是 斜體 （已在上面處理）。
- 第 386-396 行：「沒有說話」「沒有回答」等描寫沉默的行。
- 第 397-422 行：OpenAI TTS。
- 第 423-478 行：ElevenLabs TTS。
- 第 479-486 行：_PlayingProxy 類別/狀態定義：向下相容：讓 `playingNotifier.value` 回傳 bool call_screen 用 `TtsService.playingNotifier.add…。

<a id="file-lib-services-x-post-settings-dart"></a>
#### `lib/services/x_post_settings.dart` - X/社群發文設定與每日計數（110 行）
- 第 11-23 行：XPostSettings 類別/狀態定義：X（推文）發文設定 —— 每個角色獨立 三個旋鈕： enabled 總開關，關 = 這個角色完全不發 unlimited 起念不限制，開 = 解除每日上限（但確認卡仍在…。
- 第 24-34 行：總開關。
- 第 35-45 行：起念不限制。
- 第 46-56 行：每日上限。
- 第 57-67 行：綁定 handle（正式 OAuth 為下一步，這裡先存 @handle）。
- 第 68-110 行：今日計數。

### Theme 主題資料

<a id="file-lib-theme-app-theme-dart"></a>
#### `lib/theme/app_theme.dart` - 當前主題狀態、色彩 getter 與全域樣式（249 行）
- 第 5-26 行：YanciTheme 類別/狀態定義：Project Yanci 設計系統 — 主題預設驅動。
- 第 27-34 行：Getters。
- 第 35-249 行：Setters。

<a id="file-lib-theme-theme-presets-dart"></a>
#### `lib/theme/theme_presets.dart` - 預設主題色盤資料（520 行）
- 第 4-75 行：ThemePreset 類別/狀態定義：主題預設 — 每套定義完整的色彩系統。
- 第 76-83 行：亮色組。
- 第 84-93 行：暗色組。
- 第 94-123 行：1. 晨光（亮色默認）。
- 第 124-155 行：2. 深夜書房（暗色默認）。
- 第 156-185 行：3. 墨竹。
- 第 186-215 行：4. 象牙白。
- 第 216-251 行：6. 霧紫。
- 第 252-282 行：8. 花信。
- 第 283-312 行：9. 冬夜。
- 第 313-342 行：11. 夜燈。
- 第 343-372 行：12. 微醺。
- 第 373-402 行：13. 初雪。
- 第 403-432 行：14. 奶咖。
- 第 433-461 行：10. 淡粉（追加）。
- 第 462-491 行：青梅蘇打。
- 第 492-520 行：霓虹雨。

### Widgets 共用 UI 元件

<a id="file-lib-widgets-atom-thinking-dart"></a>
#### `lib/widgets/atom_thinking.dart` - 思考狀態原子動畫（166 行）
- 第 6-19 行：AtomThinkingWidget 類別/狀態定義：原子軌道等待動畫 展開 → 旋轉 → 脈動 → 旋轉 → 收回 → 循環。
- 第 20-76 行：_AtomThinkingWidgetState 類別/狀態定義。
- 第 77-92 行：_AtomPainter 類別/狀態定義。
- 第 93-127 行：階段計算。
- 第 128-166 行：畫軌道。

<a id="file-lib-widgets-avatar-cropper-dart"></a>
#### `lib/widgets/avatar_cropper.dart` - 頭像裁剪頁與裁剪遮罩（294 行）
- 第 11-38 行：AvatarCropperScreen 類別/狀態定義：簡易圓形頭像裁剪器 用戶可雙指縮放、拖曳移動圖片，圓形遮罩顯示最終裁切區域。 返回裁切後的正方形圖片路徑，或 null（取消）。。
- 第 39-258 行：_AvatarCropperScreenState 類別/狀態定義。
- 第 259-294 行：_CropOverlayPainter 類別/狀態定義：圓形裁切遮罩 — 圓圈外半透明黑色，圓圈內透明。

<a id="file-lib-widgets-character-timeline-panel-dart"></a>
#### `lib/widgets/character_timeline_panel.dart` - 角色時間線可視化面板（530 行）
- 第 10-18 行：CharacterTimelinePanel 類別/狀態定義：角色時間線 — 橫軸 + 上下交錯 一條橫線貫穿，節點圓點在線上，內容交替顯示在線的上方/下方 左舊右新，可左右滑動。
- 第 19-222 行：_CharacterTimelinePanelState 類別/狀態定義。
- 第 223-273 行：標題行。
- 第 274-408 行：橫軸時間線。
- 第 409-515 行：_TimelineAxisPainter 類別/狀態定義。
- 第 516-517 行：_NodeType enum 狀態/選項。
- 第 518-530 行：_TimelineNode 類別/狀態定義。

<a id="file-lib-widgets-chat-bubble-dart"></a>
#### `lib/widgets/chat_bubble.dart` - 聊天氣泡、Markdown、貼圖、圖片、TTS 與 cache 標記（1427 行）
- 第 15-56 行：ChatBubble 類別/狀態定義：聊天氣泡 — 思考鏈 + markdown + 表情包圖片 + 長按菜單。
- 第 57-64 行：_ChatBubbleState 類別/狀態定義。
- 第 65-537 行：四階段氣泡動畫。
- 第 538-678 行：分離記憶日誌、畫圖狀態、情緒座標。
- 第 679-727 行：圖片（用戶發送 / AI 生成）。
- 第 728-776 行：文字內容。
- 第 777-840 行：AI 消息操作按鈕（只在非拆分模式顯示）。
- 第 841-1174 行：緩存命中閃電。
- 第 1175-1212 行：_MixedContent 類別/狀態定義：混合渲染：markdown 文字 + [sticker:ID] 本地圖片。
- 第 1213-1273 行：_StickerImage 類別/狀態定義：表情包圖片（從本地加載）。
- 第 1274-1346 行：_MarkdownBlock 類別/狀態定義：Markdown 渲染塊。
- 第 1347-1351 行：_TypingIndicator 類別/狀態定義。
- 第 1352-1383 行：_TypingIndicatorState 類別/狀態定義。
- 第 1384-1427 行：_SquareCopyPainter 類別/狀態定義：方形複製圖標繪製器：兩個重疊的正方形線框。

<a id="file-lib-widgets-emotion-panel-dart"></a>
#### `lib/widgets/emotion_panel.dart` - 情緒座標測試面板與平面圖（459 行）
- 第 14-23 行：EmotionPanel 類別/狀態定義：═══════════════════════════════════════════════ 情緒座標測試面板 V2 ════════════════════════…。
- 第 24-80 行：_EmotionPanelState 類別/狀態定義。
- 第 81-229 行：標題行。
- 第 230-263 行：座標平面。
- 第 264-298 行：圖例。
- 第 299-392 行：五維進度條。
- 第 393-459 行：_PlanePainter 類別/狀態定義：座標平面畫筆（同 V1，配色改用 V2）。

<a id="file-lib-widgets-gradient-background-dart"></a>
#### `lib/widgets/gradient_background.dart` - 全局漸層/圖片背景與抖動 painter（107 行）
- 第 6-8 行：YanciBackgroundScope enum 狀態/選項。
- 第 9-85 行：GradientBackground 類別/狀態定義：全 app 共用的漸變背景（帶 dithering 消除色帶）。
- 第 86-107 行：_DitherPainter 類別/狀態定義：極輕的噪點層 — 打破色帶的視覺邊界。

<a id="file-lib-widgets-input-bar-dart"></a>
#### `lib/widgets/input_bar.dart` - 聊天底部輸入框、附件與發送按鈕（463 行）
- 第 8-10 行：SendButtonStyle enum 狀態/選項：發送按鈕樣式。
- 第 11-38 行：InputBar 類別/狀態定義：輸入欄組件 — ＋按鈕 + 毛玻璃輸入框 + 發送鍵。
- 第 39-46 行：_InputBarState 類別/狀態定義。
- 第 47-194 行：葉子動效。
- 第 195-243 行：展開選單（圖片 + 表情包 + 通話）。
- 第 244-463 行：統一輸入容器（＋ + 輸入框 + 發送鍵）。

<a id="file-lib-widgets-neural-field-dart"></a>
#### `lib/widgets/neural_field.dart` - 神經網狀背景 painter（193 行）
- 第 11-19 行：NeuralFieldWidget 類別/狀態定義：神經網路碎片漂浮背景 半透明節點緩慢漂移，距離近的節點間畫淡連線， 節點大小不一帶呼吸閃爍，像冰水裡的氣泡+突觸碎片。 自動根據主題明暗調整可見度。。
- 第 20-77 行：_NeuralFieldWidgetState 類別/狀態定義。
- 第 78-91 行：_Node 類別/狀態定義。
- 第 92-193 行：_NeuralPainter 類別/狀態定義。

<a id="file-lib-widgets-starfield-painter-dart"></a>
#### `lib/widgets/starfield_painter.dart` - 星光粒子背景 painter（137 行）
- 第 6-24 行：_Star 類別/狀態定義：星光粒子資料。
- 第 25-33 行：StarfieldWidget 類別/狀態定義：星光粒子動畫 Widget。
- 第 34-88 行：_StarfieldWidgetState 類別/狀態定義。
- 第 89-137 行：_StarfieldPainter 類別/狀態定義。

<a id="file-lib-widgets-tts-play-button-dart"></a>
#### `lib/widgets/tts_play_button.dart` - TTS 播放按鈕與軌道動畫（247 行）
- 第 12-13 行：TtsButtonState enum 狀態/選項：氣泡下方 TTS 播放按鈕 三態： - 靜態（未播放）：小喇叭圖標 - 連接中：喇叭 + 旋轉小點提示 - 播放中：3 條音波跳動 bars。
- 第 14-29 行：TtsPlayButton 類別/狀態定義。
- 第 30-200 行：_TtsPlayButtonState 類別/狀態定義。
- 第 201-247 行：_OrbitPainter 類別/狀態定義：單珠繞正圓 + 長尾跡。

<a id="file-lib-widgets-voice-visualizer-dart"></a>
#### `lib/widgets/voice_visualizer.dart` - 語音通話呼吸 blob 視覺化（319 行）
- 第 12-13 行：VoiceState enum 狀態/選項：語音通話中心視覺化 — 單體呼吸 畫面中央一團柔軟的不規則形體，邊緣持續微微流動變形。 - [VoiceState.idle] 緩慢呼吸，形狀安靜地變化 - [Voic…。
- 第 14-23 行：VoiceVisualizer 類別/狀態定義。
- 第 24-68 行：_VoiceVisualizerState 類別/狀態定義。
- 第 69-106 行：_BlobPainter 類別/狀態定義。
- 第 107-123 行：最外層：背景色融合光暈（跟頁面底色呼應）。
- 第 124-139 行：主色光暈。
- 第 140-158 行：內層 blob（更小、更柔、偏移相位，製造層次感）。
- 第 159-288 行：主 blob 路徑。
- 第 289-319 行：_BlobParams 類別/狀態定義。

<a id="file-lib-widgets-x-post-panel-dart"></a>
#### `lib/widgets/x_post_panel.dart` - X/社群發文設定底部面板（233 行）
- 第 9-190 行：showXPostPanel() 檔案級函式：X / 社群發文設定面板（共用）。 原本是 character_card_screen 的私有方法， 入口移到角色列表卡片後抽成共用，兩邊都能開。。
- 第 191-233 行：_switchRow() 檔案級函式。

<a id="file-lib-widgets-yanci-sprite-overlay-dart"></a>
#### `lib/widgets/yanci_sprite_overlay.dart` - 全局晏辭像素小人 overlay、拖拽與快捷入口（403 行）
- 第 17-32 行：SpriteOverlaySettings 類別/狀態定義：小人顯示開關（設定頁控制，全局即時生效）。
- 第 33-55 行：YanciSpriteLayer 類別/狀態定義：包在 MaterialApp.builder 外面的最頂層 —— 不管路由走到哪，小人都在。。
- 第 56-57 行：_Frame enum 狀態/選項。
- 第 58-64 行：_YanciSprite 類別/狀態定義。
- 第 65-129 行：_YanciSpriteState 類別/狀態定義。
- 第 130-179 行：日常：眨眼、伸懶腰、偶爾散步。
- 第 180-240 行：互動。
- 第 241-299 行：拖拽：長按揪起 → 移動 → 鬆手放下。
- 第 300-308 行：頭頂區：氣泡或快捷菜單。
- 第 309-390 行：小人本體。
- 第 391-403 行：_SpritePainter 類別/狀態定義。

### 非編譯/備份檔

<a id="file-lib-readme-md"></a>
#### `lib/README.md` - Holt 語音更新 v2 舊說明文（90 行）
- 第 1-90 行：記錄語音更新 v2 的舊交付說明、涉及檔案、pubspec 與平台權限提示；不屬正常 Dart 編譯入口。

<a id="file-lib-screens-home-screen-dart-bak"></a>
#### `lib/screens/home_screen.dart.bak` - 舊首頁備份檔（868 行）
- 第 1-868 行：舊版首頁實作備份，用於歷史參考；正常功能修改不要依賴或同步到此檔，除非明確要恢復舊版。

## 使用邊界

- 行號用於快速定位，不是穩定 API；精確修改前仍以 `rg -n "關鍵詞" lib/...` 查最新位置。
- 本目錄偏向「找入口」：大段 UI、業務流程、provider、資料層會標出；小 getter/setter 和純樣式行不逐一列。
- `screens/` 通常是頁面工作流，`services/` 才是可重用業務能力；不要把 provider、DB、cache 邏輯塞回 UI。
- `ContextCompressor` 是窗口摘要；`Summarizer` 是長期記憶；`MemoryActions` 是聊天回覆工具標籤解析；`Retriever` 是既有記憶注入。
- OpenRouter/Claude cache 的路徑集中在 `api_adapter.dart`、`openrouter_service.dart`、`token_estimator.dart`、`keep_alive_service.dart` 與 `chat_screen.dart`。
- `lib/game/` 是像素小屋/Flame/NPC 線，和聊天 UI 並行；遊戲層不要直接碰 DB 或網絡。
