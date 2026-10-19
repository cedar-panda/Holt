# 晏辭施工報告 — 2026-10-19

> ⚠️ 全部**未編譯、未真機驗證**（雲端沒有 Flutter）。請先跑：
> ```
> flutter analyze
> flutter test
> ```
> 原檔備份：`backups/yanci-20261019/`（備份時間早於 Codex 這輪對 chat_screen_generation.dart 的改動；**不要整檔還原**，會把 Codex 的也一起倒退，用 diff 對著回退）。
> 沒有 commit。Codex 同一時間也在改 `chat_screen_generation.dart`（RP 連續性第 4、5 步），兩邊改的區段不重疊，目前檔案裡兩邊的改動都在。

## 改了什麼

### 1. Prompt bug（`lib/screens/chat_screen_generation.dart`）
- **A1**：角色描述為空時，persona 的 promptContent 不再重複注入兩次（刪掉 else-if 分支）。
- **A2**：新增 `_firstRoundSnapshotParts`，文字／圖片路徑共用。用圖片開窗也會拿到首輪背包與角色狀態快照。
- **A3**：圖片路徑的「當前時間」移到動態區後段（和文字路徑一致）；圖片路徑補上蛛網記憶串聯提示。
- **C3**：蛛網提示改成本地化的 `### 記憶串聯` 段落（新增 `_memoLinkNotice`，兩路徑共用）。

### 2. RP 日常工具預設關（B1）
- `lib/services/tool_feature_settings.dart`：`ToolFeatureState` 新增 `rpDailyLifeToolsEnabled`（預設 **false**，pref key `ability_rp_daily_life_tools_enabled`）、`forContext(mode)`、`dailyLifeToolsAllowed(mode)`。
- RP 且開關關閉時，不注入：貝殼經濟（商店／背包／轉帳／刮刮卡／餘額）、首頁便箋、郵件草稿、X 發文、婚姻（已婚狀態＋主動遞提示）。
- 套用於文字路徑、圖片路徑、`static_token_estimator.dart`（估算與實際一致）。
- `lib/screens/cost_context_screen.dart`：功能開關頁最後新增「RP 中使用日常工具」。
- 保留在 RP 的：悄悄話、表情包、生圖、網路搜尋、日記（日記本來就按模式處理）。
- 注意：RP 窗口的轉帳／刮刮卡**按鈕**仍會顯示（UI 沒動）；開關關閉時，模型回覆裡的這類標籤不會被執行。

### 3. 世界書簡中（C5）
- `lib/services/rp_worldbook_prompt.dart`：`_zhCn` 改成完整簡中文本（OpenCC 轉換＋術語：數組、對象、字符串），不再逐字替換。

### 4. 情緒座標平行時空（B2）
- `lib/memory/emotion_coordinates.dart`：新增 `scopeId()`／`baseCharacterId()`／`rpScopeMark`。RP 存成 `角色id#rp:故事線`，日常不變。
  - `tickDecay` 查最後聊天時間時改用真角色 id。
  - `startupMaintenance` 同時清理該角色所有 RP 範圍的過期點。
- `chat_screen_generation.dart`：新增 `_emotionScopeId`；`tickDecay`／`statePrompt`×2／`processReply`×4 改傳範圍 ID。
- `lib/services/memory_actions.dart`：記憶寫入時讀的情緒點改按範圍讀。
- 舊資料全部歸日常；RP 從零開始。
- **已補做（Codex 完成後，晏辭改）**：
  - 刪角色時連 `#rp:` 範圍一起刪（`database.dart` 約 1588、1595 行，`WHERE (character_id = ? OR character_id LIKE ?)`）
  - 硬刪記憶時情緒點改成只按 `memory_id` 刪（約 4535、4540 行）

### 5. 夜間文字降亮度（D3，`lib/theme/theme_presets.dart`）
| preset | textOnBubble | textPrimary |
|---|---|---|
| nightlamp 夜燈 | EFEAF2 → D9D4DE | EFEAF2 → D9D4DE |
| tidal 潮汐 | DCE2E8 → C8CFD5 | DEE4EA → C8CED5 |
| iced 冬夜 | D6DAE4 → C5C9D3 | D8DCE6 → C5C9D3 |
| neon 街角 | EDEBF8 → E9E7F5 | 不變 |
| blaze 燎 | E6E0DA → CBC5BF | E8E2DC → CBC5BF |
| neonpink 夜櫻 | EEE4E8 → CBC0C5 | F0E6EA → CBC1C5 |
- 未洗硯（yanci）**保持原樣**：它本來就接近目標（11:1），測試也釘住了它的配色。迷霧本來就偏低，不動。
- 用戶自訂的氣泡字色不受影響。

### 6. 背景模糊預烘焙（`lib/widgets/gradient_background.dart`）
- 新增 `_BakedBlurBackground`：背景／模糊／縮放／位移／尺寸改變時，把模糊結果畫成一張圖，之後每幀只貼圖。
- sigma ≥ 3 用半解析度烘焙；最多快取 3 張（LRU）；參數停止變動 250ms 後才烘焙（拖滑桿時是即時模糊）；烘焙完成前顯示即時模糊，不閃白；烘焙失敗就維持即時模糊。
- 滑動切換角色、底色淡入淡出的**過場**模糊不變（那是動畫）。
- 已知差異：畫面最外緣約幾個像素內，模糊取樣方式和即時版略有不同（邊緣用 clamp），縮放 < 1 時最明顯。請真機對比一下。

### 7. 關鍵詞召回兩段式（召回方案第一節・階段 1）
- `database.dart`：新增 `getRecallIndexRows`（只撈 id／關鍵詞／窗口／時間，不撈全文）與 `fillRecallContents`（只替候選補全文）。
- `context_compressor.dart`：`loadSummaryPack` 改為「先用關鍵詞挑候選（最多 max(8, 段數×4) 個）→ 只撈候選全文 → 交給原本的 `_recallKeywordSummarySegment`」。排序、去重、字數預算邏輯一行沒改；移除已無用的 `_rpRecallRows`。
- RP 標籤自修復（`restoreArchivedSummaryKeywords`）在召回熱路徑上改成「每個角色＋故事線，每次 App 啟動只跑一次」；摘要歸檔、手動摘要、訊息失效時原本就會主動呼叫，不受影響。`getContextKeywords`（摘要頁、Debug 用）行為不變。
- 沒做：階段 2 詞索引表、摘要頁分頁（摘要頁打開時仍會全量載入，那是 UI，頻率低）。
- 驗收：RP 長故事線裡，用一個舊事件的關鍵詞發問 → 召回內容與改之前一致；Xcode / Android Studio 看記憶體，每輪發訊息不再出現大幅尖峰。

## 驗收（真機）
1. `flutter analyze`、`flutter test` 無新增錯誤。
2. 開粒子＋背景模糊，聊天頁停 30 秒 → 背景與改之前看起來一樣；主題工坊拖模糊滑桿 → 拖的時候即時變化，放手後不閃。
3. 夜燈主題：正文不再刺眼。
4. RP 窗口：Debug 頁看 system context，沒有貝殼／商店／X／便箋／郵件／婚姻；打開「RP 中使用日常工具」後出現。
5. 角色描述留空的角色：Debug 頁看 static，persona 內容只出現一次。
6. 用圖片開一個新窗口：Debug 頁看動態區有背包／狀態快照，時間在後段。
7. RP 吵架 → 回日常，情緒面板與語氣不受影響；換另一條故事線也是乾淨的。

## 順手發現、沒改
- `lib/screens/call_screen.dart` 約 958–968 行：`widget.cacheStaticSnapshot` 同時加進 `staticPrompt` 和 `windowPrompt`，看起來注入了兩次。語音通話的快取設計我沒讀完，先不動，請確認是不是刻意的。
