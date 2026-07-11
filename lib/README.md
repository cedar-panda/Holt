# Holt 語音更新 v2

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
