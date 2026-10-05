# 使用者多角色與綁定契約

狀態：schema v50、資料服務、新窗口解析、窗口快照、Prompt、cache 身分與備份已實作；管理 UI 待設計。

## 目標

未來使用者可建立多個「自身角色」，並將某個自身角色綁定到特定夥伴、日常／RP 模式與故事 continuity。切換夥伴或模式時，App 自動選取對應身分。

## 概念模型

```text
user_personas
├─ id
├─ display_name
├─ pronouns / bio / avatar
└─ prompt_content

character_persona_bindings
├─ character_id
├─ context_mode
├─ continuity_id
└─ user_persona_id
```

綁定唯一鍵是：

```text
character_id + context_mode + continuity_id
```

## 窗口固定規則

- 建立新窗口時，解析綁定並把 `user_persona_id` 寫入窗口。
- 舊窗口固定使用出生時的 persona；之後修改綁定只影響新窗口。
- persona 採軟封存。封存時只解除未來窗口綁定；舊窗口仍以安全快照還原出生時的文字身分。
- 角色名稱、稱謂、自介與額外人設文字固定於窗口快照；頭像使用 persona 資料列上的單一媒體路徑，避免可攜式備份複製同一檔案。
- persona 內容進既有 `profilePart`，不新增 Prompt 注入層。

## 與目前 Profile 的關係

- communication profile 是「角色／App 如何互動」的 system 規則，可分日常與 RP。
- user persona 是「使用者在故事中是誰」的資料。
- 兩者不得合併成同一資料表或同一設定開關。
- 現有使用者 Profile 在首次讀取時成為穩定 ID 為 `default` 的預設 persona；RP 沿用該 persona，直到使用者另設綁定。

## 實作入口

- `lib/services/user_persona_service.dart`：唯一公開的 persona／binding 讀寫與解析邊界。
- `user_personas`：自身角色資料與軟封存狀態。
- `character_persona_bindings`：夥伴 × 日常/RP × continuity 的未來窗口綁定。
- `conversations.user_persona_id`：窗口 cache 身分。
- `conversations.user_persona_snapshot`：窗口出生時的 Prompt 文字快照。

新窗口必須先呼叫 `resolveForNewWindow`，再把回傳的 ID 與 snapshot 一起寫入 `Conversation`。舊資料或不完整資料只可透過 `ensureConversationPersona` 補齊；它固定回退到預設 persona，不採用今天的綁定。

## 安全與驗收

- 任何 persona 查詢必須同時驗證窗口 `character_id/context_mode/continuity_id`。
- cache namespace 包含 `user_persona_id`；不相符的 snapshot 不得續用。
- 全域 RP 或單角色模式切換不得修改舊窗口的 persona。
- v50 備份與還原保存 persona、binding、窗口 persona ID 與文字快照；錯誤引用、重複 scope 或快照 ID 不一致時拒絕還原。
- 管理 UI 的待決項目見 [UI 交接清單](user_persona_ui_handoff.md)。
