# 工具與動作協議

## 它是做什麼的（一兩句話）
把模型想執行的功能動作統一成 Holt action，再交給本地工具執行器、記憶處理器或功能服務。可接受原生 tool call、JSON，並保留 XML 相容通道。

## 資料存在哪（資料表 / SharedPreferences key）
- 協議本身主要是請求／回覆記憶體物件：`ToolCall`、`HoltAction`、`ToolResult`。
- 實際結果寫入各功能自己的資料表，例如 `memories`、`pending_memory_actions`、`emotion_points`、`character_diaries`、`chat_diagnostics`。
- 功能開關由 `lib/services/tool_feature_settings.dart` 及其設定儲存處管理。

## 誰寫入（檔案：函式）
- 模型動作解碼：`lib/services/model_action_protocol.dart:ModelActionProtocol.decodeToolCalls`、`decodeJson`
- 舊格式正規化：`ModelActionProtocol.normalizeForLegacyProcessors`
- 執行與權限：`lib/services/tool_runner.dart:ToolRunner.run`
- 各功能 processor：`lib/services/memory_actions.dart:MemoryActions` 及日記、情緒、生物鐘、商店、婚姻、郵件等服務。
- 執行結果由各功能服務寫回自己的資料表或 SharedPreferences。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- 靜態工具說明：`lib/services/tool_prompts.dart:ToolPrompts`，由 `chat_screen_prompt_parts.dart:_buildCommonStaticParts` 分組加入 static prompt。
- RP 時間線／劇情狀態修正說明由 `lib/services/memory_actions.dart:MemoryActions.rpCorrectionRuntimeInstruction` 產生；只在 `isRpCorrectionIntent` 判定本輪確實為修正意圖時進 request-only 動態區，不常駐 static prompt。
- 動作結果與本輪證據由 `chat_screen_generation.dart:_sendMessageLocked` 組入 live state 或回覆處理流程。
- `ToolRunner` 從 `ToolRegistry` 讀取定義、權限與執行器；受保護操作先經 permission policy。
- 動作標籤與隱藏結構化內容在回覆呈現前由協議／處理器分離，正文只保留可見文字。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
協議層不做記憶檢索。模型可以透過 `memory.force_recall`、聊天搜尋／網路搜尋等 action 請求其他服務處理。

## 日常 / RP 差異
- 工具框架兩種模式共用。
- 可用功能、注入規則與資料 scope 由模式與功能開關決定；RP 額外使用故事、時間線、世界書相關動作。
- `ToolRunner` 的 permission requirement 可按模式覆寫。

## 相關開關
- `tool_feature_settings.dart` 的功能模組開關。
- 記憶、情緒、生物鐘、日記、畫圖、搜尋、郵件、社交、婚姻、貝殼等功能開關。
- API provider 是否支援原生 tool call／結構化輸出。
- 自訂 OpenAI-compatible 中轉站可在 API 設定展開「中轉站能力設定」，明示 developer role、中段 system、cache_control 與 tools。tools 此處表示運輸能力，實際是否送工具仍由功能與 adapter 路徑決定。

## 量大時的風險
- 多數工具 prompt 在 static 區；改動會使穩定前綴改變並可能影響 cache。RP 修正協議是按需加入的 request-only 例外，不改變後續一般回合的快取前綴。
- 動作過多或無效 JSON 會增加解析與重試成本；協議目前對無效 JSON 採失敗關閉。
- 本地 mutation、網路與外部副作用若權限政策放行，失控動作可能造成資料變更。

## 相關測試檔
- `test/model_action_protocol_test.dart`
- `test/tool_runner_test.dart`
- `test/memory_actions_test.dart`
- `test/tool_feature_settings_test.dart`
- `test/openai_compatible_capability_test.dart`

## ❓ 不確定的地方
- 某個 provider 是否真正支援原生 tool call，不能只由模型名稱推斷，應以 adapter 能力與實際回覆判定。
- 各功能 processor 的完整 action 清單會隨功能增加；這裡記錄協議層與主要入口，不代替工具 prompt 原文。
