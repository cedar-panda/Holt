# 時間線

## 它是做什麼的（一兩句話）

記錄角色日常的持續狀態與離散生活事件；RP 使用獨立的劇情事件時間線，不把持續狀態混進事件表。

## 資料存在哪（資料表 / SharedPreferences key）

- 日常：`character_timeline`。
- RP：`rp_character_timeline`，以 `character_id + continuity_id` 分線。
- 開關由 `MemorySettings.getTimelineEnabled` 讀取。

## 誰寫入（檔案：函式）

- `lib/services/context_compressor.dart:ContextCompressor._compressQueued` 在摘要成功後寫入日常或 RP 候選。
- `lib/services/manual_summary_service.dart:ManualSummaryService.summarizeMessages` 與 `summarizeExcerpt` 的手動摘要流程也寫入候選。
- `lib/screens/chat_screen_loading.dart:_loadMessages` 直接處理可驗證的日常生理期訊息。
- 日常 `<life_fix>` 由 `lib/services/character_timeline_service.dart:CharacterTimelineService.processLifeFix` 寫入。
- RP 修正由 `lib/services/rp_story_correction_service.dart:RpStoryCorrectionService.applyReplyActions` 寫入既有事件。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）

- `lib/screens/chat_screen_generation.dart:_sendMessageLocked` 呼叫日常或 RP 的 `recallPrompt`，結果進入 dynamic/live 區。
- `lib/screens/chat_screen_prompt_parts.dart:_buildCommonStaticParts` 在日常第一輪加入 `stateSnapshotPrompt`，屬於 window/static snapshot。
- `lib/services/character_timeline_service.dart:CharacterTimelineService.recallPrompt` 只在日常訊息含回憶觸發詞時回傳事件。
- `lib/services/rp_character_timeline_service.dart:RpCharacterTimelineService.recallPrompt` 以事件與劇情時間匹配；在取最多 6 條之前，先略過已被固定窗口摘要、截斷前情摘要或續接摘要覆蓋的事件，再回傳 RP 時間線參考。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）

- 日常回憶：固定回憶詞、事件全文或連續雙字片段；沒有 BM25／向量。
- RP：`RecallTextMatcher.relevanceTerms` 對事件值與劇情時間做字面匹配和分數排序。
- 狀態快照不做檢索，直接讀取目前狀態。

## 日常 / RP 差異

- 日常狀態用穩定 `key` 覆蓋；事件按週分組並有去重。
- RP 只落庫離散事件；scene、body、promise、identity 等持續狀態由 `RpStoryStateService` 管理。
- RP 支援 narrative layer、event key 與 user 原文修正；日常另有生活狀態修正標籤。
- RP 生成的共享 Story Reference 中，時間線排在劇情狀態、人物／關係、動態世界書與一般記憶之後，作為離散歷史補充；日常順序不受影響。

## 相關開關

- `MemorySettings.getTimelineEnabled`。
- RP 的實際注入仍受該開關控制；日常第一輪狀態快照也檢查 timeline 開關。

## 量大時的風險

- 日常事件查詢可限制筆數，但長期事件與狀態仍會增加資料庫索引與 UI 載入量。
- RP 召回最多取有限事件並有 token budget；大量事件主要增加查詢與排序成本。
- 只有 RP 已完成事件進入 recall-only 路徑，舊事件不應自動變成當前行動。

## 相關測試檔

- `test/character_timeline_service_test.dart`
- `test/rp_story_state_service_test.dart`
- `test/context_compressor_timeline_test.dart`
- `test/context_mode_feature_test.dart`

## ❓ 不確定的地方

- 角色頁面時間線 UI 的完整載入與分頁行為不在本服務檔案內，未在此推定。
