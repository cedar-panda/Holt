# Context Mode 首次基線遷移契約

狀態：已於 schema v48 實作並由 migration／backup 測試覆蓋。

## 目的

RP 功能出現前，所有既有資料都屬於日常。第一次加入 `context_mode` 時，必須一次性把未標記的舊資料建立為日常基線；之後任何版本都不得再次覆蓋使用者已建立的日常／RP 分類。

這個行為由 SQLite schema version migration 控制，而不是每次啟動執行 `UPDATE`，也不依賴可變的 App semantic version 字串。實作以 v1.4.2、schema v47 為基線，首次模式 schema 為 v48。

## 一次性規則

首次加入模式欄位的 migration：

1. `conversations.context_mode`：所有既有窗口寫為 `daily`。
2. `conversations.continuity_id`：所有既有窗口寫為 `main`。
3. 既有 memories 新增獨立 `context_mode` 後，所有舊記憶寫為 `daily`；不得改寫原有 `memories.mode`。
4. `context_summaries`、`context_keywords` 新增模式／continuity 後，所有舊資料寫為 `daily/main`。
5. 現有 `character_timeline` 整體定義為日常；新增的 `rp_character_timeline` 初始為空。
6. 現有 communication profile 成為日常 profile；RP profile 預設空白。
7. 全域 RP 預設關閉、角色偏好預設日常、歷史篩選預設全部。

資料表在 fresh install 時直接以 `NOT NULL`、合法預設值與必要 CHECK／index 建立；upgrade 則先補欄、回填、驗證，再建立索引。

## 後續版本不得做的事

- 不得再次執行「所有窗口設為 daily」。
- 不得用當前全域／角色開關回填舊窗口。
- 不得把缺失值一律修成目前 effective mode。
- 不得改寫已存在的 `rp`、persona、continuity 或 worldbook 綁定。
- `_ensureRuntimeSchema` 只能補 schema object；不得承擔重複資料覆蓋。

## 備份與降級資料

- 舊格式備份確定沒有 `context_mode` 欄位時，匯入資料視為 legacy，標記 `daily/main`。
- 新格式備份宣告支持模式卻帶非法／缺失值時，停止匯入並回報錯誤；不得靜默猜測成日常或 RP。
- 新欄位、RP 時間線與未來 persona／世界書表必須加入 portable/encrypted backup allowlist 與正規化流程。
- 還原後要重新建立衍生索引，但不得重新分類資料。

## 必要測試

- schema v47（或實作時的上一版）升級後，所有既有窗口、記憶、摘要均為 `daily/main`。
- migration 重開資料庫第二次不再改動任何模式。
- 已包含 daily/RP 的新 schema 升級到下一版後，分類保持不變。
- fresh install constraint、upgrade schema 與 backup restore schema 一致。
- legacy backup 匯入為日常；新格式非法 mode 明確失敗。
- 分支窗口繼承來源模式，不受 migration 或當前 UI 開關影響。
