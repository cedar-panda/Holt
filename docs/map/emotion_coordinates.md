# 情緒座標

## 它是做什麼的（一兩句話）

保存角色由模型記下的情緒點，計算五個主要維度的當前底色、近期波動、內在拉扯與衰減。RP 模式把每條故事線視為獨立平行時空，不與日常情緒共用 scope。

## 資料存在哪（資料表 / SharedPreferences key）

- `emotion_points`：scope id、維度、x/y、濃度、關聯記憶、備註、狀態與時間。
- `grudge_seals`：達門檻的負面情緒與具體記憶之綁定、濃度、事件摘要及最近浮現時間。
- scope 編碼不另開表：日常用角色 id；RP 使用 `<character_id>#rp:<continuity_id>` 寫入上述兩表的 `character_id`。
- SharedPreferences：`ability_emotion_enabled`。

## 誰寫入（檔案：函式）

- `lib/memory/emotion_coordinates.dart`：`EmotionCoordinates.processReply` 解析情緒 record／resolve 動作並剝離私有協議。
- `lib/memory/emotion_coordinates.dart`：`EmotionCoordinates.addPoint` 對六小時內同維度 active 點合併，並套用維度上限與交叉影響。
- `lib/memory/emotion_coordinates.dart`：`EmotionCoordinates.tickDecay` 在發訊息前處理自然衰減、閒置衰減與維度互動。
- `lib/memory/emotion_coordinates.dart`：`EmotionCoordinates.onNewWindow` 將該 scope 的 active 慾望點減半。
- `lib/memory/emotion_coordinates.dart`：`EmotionCoordinates.resetAll` 將指定 scope 的 active 點標記為 dissipated。
- `lib/screens/chat_screen_generation.dart`：`_ChatScreenState._sendMessageLocked`（文字／圖片共用同一路徑） 以 `_emotionScopeId` 呼叫寫入與衰減。
- `lib/screens/call_screen.dart`：`_CallScreenState._generateTurn` 以角色 id 寫入日常通話情緒。
- `lib/services/mood_glow_service.dart`：`MoodGlowService.processReply` 以窗口為單位累計已處理回覆；一般換色須距上次換色滿 10 輪，判定包含當前這一輪，固定色／解鎖另走立即規則。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）

- `lib/memory/emotion_coordinates.dart`：`EmotionCoordinates.statePrompt` 讀 active 點、五維 bars、24 小時波動與 grudge，輸出行為參照。
- `lib/screens/chat_screen_generation.dart`：`_ChatScreenState._sendMessageLocked`（文字／圖片共用同一路徑） 把狀態 prompt 放進 `dynamicParts`。
- Prompt 層：當前情緒狀態在 `liveStatePart`；`EmotionCoordinates.abilityPrompt` 的固定動作規則在 `staticPart`。
- `lib/widgets/emotion_panel.dart`：`_EmotionPanelState._load` 讀 `EmotionCoordinates.bars` 顯示 UI。
- `lib/memory/retriever.dart`：`Retriever.buildMemoryPrompt` 在日常蛛網模式讀 active 點，作記憶情緒共振排序。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）

- 無文字檢索、BM25 或向量檢索；以精確 scope id 與狀態查 SQLite。
- `statePrompt` 讀全部 active 點，再按時間與維度計算 bars／近期波動。
- grudge 浮現先看負面情緒 bar、概率與六小時冷卻，再讀該 scope 的 `grudge_seals` 與綁定記憶正文。

## 日常 / RP 差異

- 日常：scope 就是角色 id，跨該角色所有日常窗口共用。
- RP：`EmotionCoordinates.scopeId` 產生 `角色#rp:故事線`；不同故事線、日常互不讀寫。
- 記憶動作若同輪產生情緒快照，也使用相同 context mode／continuity scope。
- 刪角色會清日常與所有 RP scope；硬刪記憶按全域 memory id 清關聯情緒點與 grudge。
- 通話頁目前直接使用角色 id，因此靜態可確認的是日常 scope；未看到通話以 RP continuity 建 scope。

## 相關開關

- `ability_emotion_enabled`：由 `MemorySettings.isAbilityEnabled('emotion')` 讀取。
- 工具提示詞總開關關閉時，不注入情緒能力說明；情緒模組本身關閉時，回覆中的情緒協議只剝離、不落庫。
- 蛛網記憶開啟時，情緒開關同時決定是否參與記憶共振排序。
- 聊天角色頭像讀 `MoodGlowService.activeColor`；未啟用或沒有顏色時直接使用靜態無光圈狀態，不建立空終點的顏色 tween。

## 量大時的風險

- `activePoints` 沒有數量上限；每次發訊息的 `tickDecay` 與 `statePrompt` 都會讀該 scope 全部 active 點。
- 長期 bars 對安全感、負面情緒各做七天範圍查詢；索引含 `character_id/type/created_at`，但 scope 內點數仍會影響聚合成本。
- `startupMaintenance` 只刪 90 天以前且非 active 的點；高濃度持久點或大量未消解 active 點會一直保留。
- grudge 每次浮現會逐筆讀綁定記憶並更新 `surfaced_at`；目前最多取 3 筆。

## 相關測試檔

- `test/database_schema_v33_test.dart`
- `test/prompt_locale_test.dart`
- `test/model_action_protocol_test.dart`
- `test/context_mode_migration_test.dart`
- `test/chat_bubble_thinking_test.dart`
- `test/chat_bubble_card_width_test.dart`
- `test/mood_glow_service_test.dart`

## ❓ 不確定的地方

- 未找到專門覆蓋五維衰減、grudge 概率與 RP 故事線隔離的完整行為測試；現有測試主要覆蓋 schema、prompt 與動作協議。
- `statePrompt` 會在組 prompt 時嘗試 grudge 概率並更新 `surfaced_at`；它不像 `DeferredPrompt` 那樣等請求成功才 commit，請求失敗時是否應視為已浮現，代碼沒有額外補償。
