# Holt 語音更新 v2

## 現行檔案樹補充

```text
lib/memory/
├── database.dart                ← 資料庫公開 facade 與各領域 CRUD
├── database_schema.dart         ← schema、migration、FTS5／FTS4 相容索引
└── database_memory_search.dart  ← BM25 記憶檢索、FTS4 matchinfo 排序、文字 fallback
```

API 設定的遠端模型清單分派集中在
`lib/services/provider_model_catalog.dart`。它把 OpenRouter、Gemini、xAI、
DeepSeek 與 OpenAI-compatible 的 Key、端點及解析器隔離，避免切換供應商後
沿用上一家的錯誤或憑證。

網路搜尋的角色回覆與 UI 分拆如下，避免繼續擴張已超過 2500 行的聊天室主檔：

```text
lib/services/web_search_follow_up.dart          ← OpenRouter 搜尋證據封裝與純文字安全收尾
lib/screens/chat_screen_web_search_follow_up.dart ← 搜尋後交給當前角色模型二次生成
lib/widgets/web_search_thinking_node.dart        ← Thinking > Web Search 狀態與不可點擊來源列
```

搜尋證據只存在於單次 request，不加入 prompt cache、聊天歷史或本地資料庫；
來源列只顯示標題與網域，不提供展開、預覽或開啟網站的操作。

本機郵件草稿同樣拆檔，避免繼續堆高聊天室主檔：

```text
lib/models/email_draft.dart                   ← 草稿資料、清理與序列化
lib/services/email_draft_tool.dart            ← 動態提示與模型標籤解析
lib/services/email_draft_repository.dart      ← 草稿隨訊息本機持久化
lib/services/email_draft_launcher.dart        ← mailto 交接系統郵件 App
lib/screens/chat_screen_email_drafts.dart      ← 編輯、刪除、打開與狀態同步
lib/widgets/email_draft_card.dart              ← 聊天氣泡下方的草稿卡與編輯器
```

郵件工具提示每輪放在動態區，不改既有靜態 prompt cache；草稿欄位是訊息 UI
metadata，`Message.toPromptHistoryEntry()` 明確不會把它帶回模型。App 不接觸
Gmail 帳號或 OAuth，也不會自行寄送；只有用戶點擊後才以 `mailto:` 打開郵件 App。

`database_memory_search.dart` 從超過 3000 行的 `database.dart` 拆出全文搜尋；
支援 FTS5 的平台使用 SQLite 原生 BM25，Android 系統缺少 FTS5 時改用 FTS4
統計計算 BM25，不需要更換主資料庫或複製業務 CRUD。

## 檔案清單

```
lib/
├── services/
│   └── tts_service.dart        ← 修復 + extractSpeechContent
├── widgets/
│   ├── chat_bubble.dart        ← 用新的 TtsPlayButton
│   ├── tts_play_button.dart    ← 🆕 三態動畫按鈕
│   └── voice_visualizer.dart   ← 🆕 通話中心波紋特效
└── screens/
    ├── chat_screen.dart        ← 已改好 messageId
    └── call_screen.dart        ← 重寫，完整語音通話
```

全部直接覆蓋就好。

---

## 1. 通話中心波紋 `voice_visualizer.dart`

`VoiceVisualizer` — 用 CustomPainter 畫的四態動畫：

| 狀態 | 視覺 |
|---|---|
| `idle` | 三層呼吸光環，緩慢脈動 |
| `listening` | 波紋向外擴散 + 8 段頻率跳動弧（模擬音量） |
| `speaking` | 柔光暈 + 多頻正弦波形環繞 |
| `thinking` | 三顆光點帶拖尾旋轉 |

所有顏色從 `YanciTheme.accent` 取，自動跟主題走。

## 2. TTS 小喇叭 `tts_play_button.dart`

`TtsPlayButton` — 獨立 widget，三態：

| 狀態 | 視覺 |
|---|---|
| idle | 靜態小喇叭 🔊（低透明度） |
| connecting | 喇叭 + 旋轉弧線（表示正在連接 TTS） |
| playing | 3 條音波 bars 跳動（各自頻率錯開） |

點擊後先進 connecting 狀態（視覺回饋），TTS 開始播放後自動切 playing。

## 3. 語音通話 `call_screen.dart`

完整流程，**不需要按播放鍵**：

```
點擊中心波紋 → STT 開始聽
  → 識別中文字即時顯示在波紋下方
  → 識別完成 → 送 LLM（thinking 狀態）
  → 回覆 → extractSpeechContent 剝動作
  → 自動 TTS 播放（speaking 狀態）
  → 播放完畢 → 回到 idle，等下一輪
```

下方有對話記錄滾動區（160px），顯示雙方文字。AI 回覆在記錄裡也是剝掉動作後的版本。

可打斷 AI 說話（點擊中心波紋）。

對話會寫入主 DB（回到聊天頁面可以看到通話記錄）。

---

## 你需要做的

### `pubspec.yaml`

```yaml
dependencies:
  speech_to_text: ^7.0.0
```

### Android `AndroidManifest.xml`

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
```

### iOS `Info.plist`

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>語音通話需要語音識別</string>
<key>NSMicrophoneUsageDescription</key>
<string>語音通話需要麥克風</string>
```
