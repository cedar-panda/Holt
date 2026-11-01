# Prompt 組裝

## 它是做什麼的（一兩句話）
把固定人設、用戶資料、窗口快照、控制規則與本輪動態事實組成 `StructuredPrompt`，再交給各 API adapter 轉成該來源需要的請求格式。

## 資料存在哪（資料表 / SharedPreferences key）
- 組裝中的提示主要是記憶體物件，不是一張單獨的 prompt 表。
- 窗口固定摘要、自我註記、貝殼快照等部分來源於 `conversations`。
- 角色／user 人設來自角色與 user persona 資料。
- provider、模型與設定由 API 設定服務及 SharedPreferences／安全儲存讀取。
- 窗口思考強度由 `reasoning_effort_v1` 與 `conversation_reasoning_efforts_v1` 讀取；思考鏈開關另由 `thinking_chain_enabled` 與 `conversation_thinking_enabled_v1` 讀取。兩者交給 adapter 的 request config，不寫進五層 Prompt；關閉開關不清除已選強度。

## 誰寫入（檔案：函式）
- 靜態與窗口區塊：`lib/screens/chat_screen_prompt_parts.dart:_buildCommonStaticParts`
- 首輪快照：`_firstRoundSnapshotParts`
- 本輪完整組裝：`lib/screens/chat_screen_generation.dart:_sendMessageLocked`
- 結構化容器：`lib/services/api_adapter.dart:StructuredPrompt`
- 固定 context contract：`SystemContextControl.compose`

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- `staticPart`：系統固定規則、角色設定、固定工具規則；只有 RP 以「模型是角色、user 是目前 user persona」的身分鎖作為第一段，日常模式不套用 RP 的全局身分鎖。
- 角色有 User 備注時，`staticPart` 會同時寫明角色本名與顯示備注，明確規定備注只是 User 稱呼、不可取代原身分；聊天 UI 優先顯示備注。
- `profilePart`：user profile／persona；有內容時放入穩定前綴。
- `windowPart`：開窗固定的摘要、自我註記、婚姻、貝殼、貼圖、習慣等窗口快照；RP 的 always 常駐世界書亦放在這個故事線綁定的穩定前綴，最多 3 條／500 字。
- `controlPart`：語言、輸出格式、功能開關與 context contract；穩定時可快取。
- `liveStatePart`：時間、記憶召回、動態摘要、RP 狀態／本輪命中的動態世界書／時間線、工具證據等本輪內容。
- 日常模式的新 user 消息與上一條可見消息間隔達 5 分鐘時，`ConversationTimeContext.buildGapPrompt` 把簡短經過時長加入 `liveStatePart`；同窗口優先，空新窗口才使用 `getPreviousConversationTurns` 的最後一條。這段不改 user 正文、不寫回歷史、不進 cacheable prefix，重試同一條消息時也不重算。
- RP 的 Story Reference 受 1800 字單輪上限與共享連續性預算約束，保底順序為「劇情狀態 → 人物／關係 → 動態世界書 → 一般記憶 → RP 時間線」；前項未用完的額度才交給後項。
- RP 一般記憶與時間線會在固定窗口摘要、截斷前情摘要、續接摘要確定後才組裝；若候選正文已被這三層摘要完整包含或高度覆蓋，本輪直接略過，且不提交記憶 mention／trigger 副作用。
- RP 未開啟「RP 中使用日常工具」時，不注入現實世界當前時間或貼圖清單；開啟後貼圖清單仍限制為最多 24 項／1600 字元。
- `rp.timeline.correct`／`rp.state.correct` 的修正說明不再常駐 `staticPart`；只有本輪 user 明確要求修正 RP 時間線／狀態時才加入 request-only 動態說明，避免日常回合佔用前綴。
- `requestOnlyPart` 只由 live state 組成，不進 cacheable parts、歷史或資料庫。
- provider adapter 讀 `StructuredPrompt.cacheableParts` 與 request-only 內容，轉成各 API 請求。
- Grok adapter 以首個保留歷史訊息的 hash 作 cache lineage；普通增量保持 append-only，摘要／裁切令歷史根改變時明確重錨，最多保留四個完整舊 lineage，不在活躍 lineage 內按條數硬刪。
- 本機 Gemma 與 Llama 都先分層分配 system 與歷史預算：system 保頭部身分規則，歷史由最新往前保留，單條超長時保留靠近當輪的尾端。
- 自訂 OpenAI-compatible 中轉站可顯式設定 developer role、中段 system、cache_control 與 tools 能力；只有 HTTP 400 明確指出欄位不支援時才降級重試一次。
- OpenRouter、Gemini、Thinking Machines 與 DeepInfra 共用自動／低／中／高語義；「自動」不傳強度欄位，顯式級別才由 adapter 轉成各來源的 effort、thinking level 或數值預算。這些設定不改 cacheable prompt bytes。
- `ToolFeatureSettings.loadForContext` 在組裝前解析功能模組組合；RP 有指定的自動組合時使用該快照，否則使用全域開關再套用既有 RP 日常工具隔離。
- 純圖片且沒有配文時，畫面／記錄仍可使用「發送圖片」佔位文字，但記憶、摘要、時間線、人物關係與世界書收到的召回 query 是空字串，不會用佔位文字製造假命中。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
Prompt 組裝本身不做檢索；它接收記憶、摘要、RP 故事、世界書與工具服務已經選出的結果。各來源的檢索方式見對應地圖文件。

## 日常 / RP 差異
- RP 使用最前方的角色／user 身分鎖；日常不加入這個 RP 全局鎖，也不加入故事線、人物關係、RP 狀態、RP 世界書與 RP 時間線。日常與 RP 的輸入框悄悄話則都會在 request-only 動態指令中帶入目前角色名與 user persona 名，只約束該句為 char → user，不改整輪對話風格。
- RP 會在 live state 加入對應故事線的劇情參考；現實時間、貼圖等日常內容受「RP 中使用日常工具」控制。
- 5 分鐘對話間隔提示只在日常模式生效；RP 不會因此額外注入現實時間間隔。
- 兩種模式共用 `StructuredPrompt` 五層結構，但內容來源不同。

## 相關開關
- 日常／RP 模式。
- 記憶、摘要、世界書、時間線、情緒、生物鐘、自我註記、工具功能開關。
- cache、上下文限制、keep-alive 與模型 provider 能力。
- `ModelCostPolicy.resolveEffectiveStrategy` 是請求端單一裁決：兩者同時為真時，支援 cache 的模型以 cache 為準；不支援 cache 才使用上下文限制。App 啟動與備份還原後另做一次持久設定正規化，底層 setter 不互相觸發。

## 量大時的風險
- `liveStatePart` 過大會增加每輪輸入 token 與注意力分散；摘要／召回服務負責先限額。
- 固定前綴內容變動會使 provider cache 失效；工具 prompt、控制規則和窗口快照要保持順序穩定。
- always 世界書放入穩定窗口前綴後可參與 Prompt Cache；user 編輯常駐世界書時，下一輪重建一次此前綴屬於預期行為。
- 多個功能同輪同時注入時，缺少總預算會造成動態 prompt 堆疊。

## 相關測試檔
- `test/structured_prompt_test.dart`
- `test/prompt_cache_channels_test.dart`
- `test/chat_prompt_parts_test.dart`
- `test/rp_identity_lock_prompt_test.dart`
- `test/grok_cache_service_test.dart`
- `test/local_model_prompt_budget_test.dart`
- `test/openai_compatible_capability_test.dart`
- `test/model_cost_policy_test.dart`
- `test/context_summary_recycling_test.dart`
- `test/context_mode_feature_test.dart`
- `test/conversation_time_context_test.dart`
- `test/whisper_service_test.dart`

## ❓ 不確定的地方
- 各 provider 對 system、developer、user 部分的最終排列由 adapter 決定；本圖只記 `StructuredPrompt` 的分層契約。
- 實際 cache 命中率與價格必須以 provider 回傳 usage 為準，單看本地組裝不能證明命中。
