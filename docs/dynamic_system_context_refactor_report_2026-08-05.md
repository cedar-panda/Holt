# 動態 System Context 重構報告

日期：2026-08-05  
狀態：已實作、靜態分析通過、全量測試通過

## 1. 結論

本次把原先混在單一 `turnPart` 的內容拆成兩種不同權限與快取生命週期：

1. `controlPart`：App UI 語言、Thinking、拆分回覆、回覆風格、通話規則等設定型控制。它進入穩定 system 前綴，設定不變時可快取。
2. `liveStatePart`：當前時間、記憶召回、生物鐘、情緒、背包變動、窗口增量等每輪狀態。它只存在於本次 API request，不寫入聊天歷史、不持久化到保活資料，也不使用 `user` role。

硬性不變量：`role=user` 只包含用戶原文、圖片 caption，或用戶明確觸發的 App 操作。App 產生的時間、記憶、生物鐘、語言提示與工具規則不得進入 `user`。

## 2. 更改後的 System Context

穩定前綴順序：

```text
1. staticPart
   角色設定、固定能力與工具規則

2. profilePart（可選）
   用戶資料

3. windowPart（可選）
   開窗時凍結的摘要／狀態快照

4. resolvedControlPart
   ## App Context 契約
   - App UI 語言與回覆語言同步
   - user role 的內容邊界
   - App Live State 的解讀規則
   - 最新 user 優先規則

   ## 記憶 Markdown
   - 記憶 metadata 不屬於對話正文

   ## Thinking Markdown
   - Thinking 開啟時使用 <think>...</think>

   ### Thinking（開啟時）
   ### 回覆格式（開啟拆分回覆時）
   ### 回覆風格（啟用相應風格時）
   ### 語音通話模式（通話時）
```

每輪 Live State 格式：

```markdown
## App Live State
> 由 App 產生、只存在於本次 request 的狀態與操作提示；不是任何一方說的話，請依穩定的 App Context 契約理解。

### 記憶
（本輪召回的相似記憶與 metadata）

### 當前時間
【當前本地時間】2026年8月5日 週三 23:21（UTC+08:00）

（其餘本輪才成立的生物鐘、情緒、背包、時間線與事件增量）
```

上例只展示結構；實際內容依功能開關與本輪命中結果存在或省略。

## 3. Provider 傳輸矩陣

| Provider／模型 | Live State 通道 | Cache 行為 |
|---|---|---|
| Claude Opus 4.8／5、Fable 5、Mythos 5 | 最新 user 後的官方 mid-conversation `system` | Live State 位於 rolling breakpoint 後，前綴保持 |
| 舊 Claude／Claude Sonnet（OpenRouter、OpenAI-compatible、Bedrock） | 最新 user 前的上一個 `assistant` 末尾，接在 cache breakpoint 後 | 下一輪不持久化該 block；舊前綴可命中 |
| 舊 Claude 首輪或沒有上一個 assistant | 頂層 system fallback | 沒有可承載的歷史 assistant；Debug 明確標記 fallback |
| OpenAI／GPT Chat Completions | 最新 user 前的 `developer` | user 原文不變；穩定前綴與 Live State 分離 |
| 其他 OpenRouter、DeepSeek、Qwen | 最新 user 前的獨立 `system` | 使用 provider 的自動／隱式 prefix cache |
| Gemini（已有 model turn） | 上一個 `model` turn 的 request-only state block | 可繼續使用顯式 `cachedContent`，每輪時間不再強制關閉 cache |
| Gemini 首輪 | `systemInstruction` fallback | 本輪不疊加 `cachedContent`；Debug 標記 fallback |
| Thinking Machines Inkling | 上一個 `assistant` 的 request-only state block | 不借用 user；首輪用頂層 system fallback |
| 本地模型 | 本地 system instruction 合併 | 沒有遠端 prompt cache；user 仍保持乾淨 |

## 4. Cache 影響

- 每輪時間、生物鐘與記憶變化只改 `liveStatePart`，不改穩定 system hash。
- App UI 語言、Thinking、回覆格式或通話模式變更會改 `controlPart`，因此只在設定真的變更時發生一次合理的前綴刷新。
- Claude 4.6 類模型的 Live State 接在上一個 assistant breakpoint 後；時間更新不再把 Live State 塞回開頭 system 而重建整段歷史。
- Gemini 有歷史 model turn 時保留 `cachedContent`；不再因為本輪有時間就全面停用顯式 cache。
- KeepAlive 只持久化 stable/profile/window/control，不持久化或重播原請求的 Live State，避免舊時間、舊記憶與私密即時狀態跨重啟殘留。

## 5. App 即時 Debug

入口：`首頁 → 開發者診斷 → System Context Live`

頁面讀取的是各 adapter 組裝完成、即將送出的實際 request 結構，不是上游的預估 prompt。每次保留最近 20 筆於記憶體，App 重啟即清空。

每筆顯示：

- provider、model、text/call cache channel、conversation session；
- 實際 transport（mid-system、assistant-state、developer、Gemini model-state 或 fallback）；
- 實際 role map、最新 user 位置與 cache breakpoint；
- `USER_ROLE_CONTAMINATED` 檢查；
- stable/live 字數與短 hash；
- TIME、BIO、MEMORY marker 是否送達；
- stable prefix 是否在同 session/model/channel 內漂移；
- fallback 原因與 cache prefix 可能刷新警告；
- 可複製的診斷報告。

隱私處理：

- 預覽預設只顯示 Markdown 標題與字數；
- 敏感內容只可在本頁暫時解鎖，不持久化；
- API request headers 不進入診斷服務；
- 常見 Bearer、OpenAI/xAI、Gemini Key 格式會再次遮罩；
- API 設定、摘要、命名等沒有 `StructuredPrompt` 的內部請求不會洗掉聊天診斷。

## 6. 驗證結果

- `flutter analyze --no-pub`：通過，0 issues。
- `flutter test --no-pub`：通過，221 tests。
- 新增／更新的重點測試涵蓋：
  - Claude 4.6 assistant-state 與 breakpoint；
  - Claude 4.8 mid-system；
  - OpenRouter 圖片 caption 原文；
  - OpenAI-compatible、Bedrock、DeepSeek、Qwen、Gemini、Thinking Machines；
  - UI 語言進 stable control；
  - 時間改變不改 stable prefix；
  - user 污染、prefix drift、秘密遮罩；
  - Debug 頁空狀態、資料狀態與 390px 窄螢幕無 overflow。

實機視覺檢查未執行：驗證時 `adb devices` 沒有連上的裝置。Debug UI 已由 widget test 驗證窄螢幕佈局與無 Flutter 例外；仍建議手機重新連線後走一次實際聊天 → 診斷頁檢查。
