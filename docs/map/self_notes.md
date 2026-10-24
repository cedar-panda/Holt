# 自我註記

## 它是做什麼的（一兩句話）

保存日常模式下角色在互動中形成的自我註記，並可將部分註記標為長期保存或手動鎖定。

## 資料存在哪（資料表 / SharedPreferences key）

- `characters.self_notes` 保存相容的換行文字。
- `character_self_notes` 保存逐條記錄、來源模型、來源窗口、來源消息、鎖定與長期欄位。
- `conversations.pinned_static_self_notes` 保存窗口首次建立時的靜態快照。
- 設定 key 由 `MemorySettings.getSelfNotesEnabled`、`getSelfNotesLongTermEnabled`、`getSelfNotesInjectionLimit` 讀取。

## 誰寫入（檔案：函式）

- `lib/memory/database_self_notes.dart:_SelfNoteStore.appendSelfNoteDetailed` 合併、去重並寫入兩層資料。
- 同一服務的 `_mergeSelfNotesDetailed` 以相似度與資訊長度決定忽略或替換。
- `lib/widgets/character_self_notes_panel.dart:_CharacterSelfNotesPanelState._toggleLock` 切換鎖定。
- `lib/widgets/character_self_notes_panel.dart:_CharacterSelfNotesPanelState._deleteNote` 經二次確認後刪除。
- `lib/memory/database_self_notes.dart:_SelfNoteStore.bindSelfNotesToMessage` 補來源消息 ID。

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）

- `lib/screens/chat_screen_generation.dart:_sendMessageLocked` 讀取日常註記並傳入共同 prompt 組裝。
- `lib/screens/chat_screen_prompt_parts.dart:_buildCommonStaticParts` 將窗口首次看到的註記固定到 window/static 區；新增註記差異可進 dynamic 區。
- `lib/services/static_token_estimator.dart:StaticTokenEstimator.estimate` 也讀取它計算靜態 token。
- `lib/memory/database_self_notes.dart:_SelfNoteStore.getSelfNotesForPrompt` 按設定上限取最新註記，最多 12 條。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）

無獨立檢索。按角色 ID 讀取，按設定數量取最新內容；去重使用本地文字正規化、衝突詞檢查與相似度。

## 日常 / RP 差異

- `lib/screens/chat_screen_generation.dart` 明確只在 `ContextMode.daily` 讀取與注入。
- RP 模式把自我註記讀取關閉；角色卡本身仍是跨模式資料，但不是本子系統的自我註記注入。

## 相關開關

- 偷偷記住你／自我註記總開關。
- 長期保存自我註記。
- 自我註記注入條數。
- 角色卡面板另有鎖定、刪除操作。

## 量大時的風險

- 普通未鎖定、非長期記錄會按角色保留最新 12 條；鎖定或長期記錄不受這個滾動清理影響。
- 注入量另受設定上限控制，保存量與注入量不是同一件事。
- `characters.self_notes` 與逐條表需維持相容同步，資料不一致時會增加回填與去重成本。

## 相關測試檔

- `test/character_self_notes_data_test.dart`
- `test/character_self_notes_panel_test.dart`

## ❓ 不確定的地方

- 模型產生自我註記的具體解析入口不在本批已定位的資料服務中；代碼可確認寫入與注入，但不能僅據此斷言每次回覆都會產生註記。
