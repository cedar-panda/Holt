# 生物鐘

## 它是做什麼的（一兩句話）

替角色保存少量日常作息，按本地時間注入當前時段提醒、去重、校準或前七天構建提示；另以最近聊天時間與睡眠習慣估算疲勞。

## 資料存在哪（資料表 / SharedPreferences key）

- `characters.bio_clock`：一個 JSON 字串，含最多 10 條習慣、next id、首次記錄時間、校準／注入時間、待去重與已送達構建提示 key。
- SharedPreferences：`fatigue_log_<character_id>`，保存最近 14 天每天最後一次聊天時間。
- SharedPreferences：`ability_bioclock_enabled`。

## 誰寫入（檔案：函式）

- `lib/services/bio_clock_service.dart`：`BioClockService.processReply` 解析 record／keep／update／delete 動作並剝離協議。
- `lib/services/bio_clock_service.dart`：`BioClockService.addHabit` 寫入習慣；關鍵詞重疊時保留兩條並加入 pending dedup。
- `lib/services/bio_clock_service.dart`：`BioClockService.resolveDedup`、`fallbackDedup` 處理重複習慣。
- `lib/services/bio_clock_service.dart`：`BioClockService.recordLastChatTime` 更新最近 14 天 fatigue log。
- `lib/screens/chat_screen_generation.dart`：`_ChatScreenState._sendMessageLocked`、`_sendImageLocked` 只在日常模式處理生物鐘回覆與最後聊天時間。
- `lib/services/deferred_prompt.dart`：`DeferredPrompt.commit` 在請求成功後才提交提醒／校準／構建提示的 last-delivered 狀態。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）

- `lib/services/bio_clock_service.dart`：`BioClockService.habitListPrompt` 讀完整習慣清單。
- `lib/screens/chat_screen_prompt_parts.dart`：`_ChatScreenState._buildCommonStaticParts` 將清單快照放進 `windowPart`，能力規則放進 `staticPart`。
- `lib/services/bio_clock_service.dart`：`BioClockService.turnPrompt` 依序嘗試時段提醒、去重、校準、前七天構建提示。
- `lib/services/bio_clock_service.dart`：`BioClockService.habitDeltaPrompt` 只注入本窗口快照後新增的習慣。
- `lib/services/bio_clock_service.dart`：`BioClockService.fatiguePrompt` 依最近七天偏離睡眠時間的天數，以機率回傳一條身體提示。
- `lib/screens/chat_screen_generation.dart`：`_ChatScreenState._sendMessageLocked`、`_sendImageLocked` 將 turn prompt、delta 與疲勞提示放進 `liveStatePart`。
- `lib/screens/call_screen.dart`：`_CallScreenState._generateTurn` 在日常通話 prompt 中加入生物鐘能力與本輪提示。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）

- 無全文／BM25／向量檢索。
- 時段提醒按本地分鐘與習慣時間的環形距離比對，窗口為前後 2 小時；選最接近的一條。
- 全域注入冷卻 3 小時；單一習慣冷卻 16 小時，白名單習慣最短 6 小時。
- 疲勞以睡眠關鍵詞找到第一條睡眠習慣，再檢查最近七天最後聊天時間是否晚於習慣兩小時以上。

## 日常 / RP 差異

- 對話生成只在 `ContextMode.daily` 啟用生物鐘；RP 的 `bioclockEnabledF` 直接為 false。
- 生物鐘資料按角色保存，不按故事線分 scope。
- RP 即使保留角色原有 `bio_clock` JSON，也不注入、不處理 clock 動作、不更新 fatigue log。
- 通話頁以角色 id 使用同一份日常生物鐘。

## 相關開關

- `ability_bioclock_enabled`：生物鐘總開關。
- 工具提示詞總開關決定是否提供模型寫入能力；對話生成另外以日常模式作硬條件。
- 沒有獨立的疲勞開關；疲勞跟隨生物鐘總開關。

## 量大時的風險

- 每角色習慣硬上限 10，`bio_clock` JSON 與每輪排序不會隨聊天量無限增長。
- fatigue log 每次寫入會清到最近 14 天，資料量有界。
- 角色數達數萬時，資料分散在 `characters.bio_clock`；單角色讀取是主鍵查詢，但全量角色備份／遷移會攜帶所有 JSON。
- 每輪可能多次載入同一角色 `bio_clock` 以組 turn、delta、fatigue；單筆小，但大量並發窗口會放大 SQLite 讀取次數。

## 相關測試檔

- `test/bio_clock_action_log_test.dart`
- `test/turn_context_commit_test.dart`
- `test/database_schema_v33_test.dart`
- `test/prompt_locale_test.dart`
- `test/widget_test.dart`

## ❓ 不確定的地方

- `BioClockService.fallbackDedup` 的註解寫「app 啟動時調用」，但以 `rg` 只找到函式宣告，未找到 production 呼叫點。
- 疲勞提示用 `DateTime.now().microsecond` 形成機率值；沒有找到固定 seed 或專門行為測試，無法從靜態代碼保證實際分布。
