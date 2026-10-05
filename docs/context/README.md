# 日常／RP Context 架構索引

狀態：日常／RP 的資料、cache 身分、專屬服務、注入路由、搜尋與 Flutter UI 已接通。

## 文件分工

- [窗口模式與注入契約](context_mode_and_injection_contract.md)：唯一模式來源、窗口不可變規則、cache 邊界與 RP 記憶／滾動摘要／時間線的注入位置。
- [日常模式契約](../daily/daily_context_contract.md)：現有日常能力與普通／蛛網記憶的關係。
- [RP 模式契約](../rp/rp_context_contract.md)：自由 RP、獨立記憶服務、摘要與時間線分流。
- [使用者多角色與綁定](../persona/user_persona_binding_contract.md)：使用者自身角色、夥伴綁定與窗口固定方式。
- [世界書預留](../worldbook/worldbook_contract.md)：世界書的獨立資料與注入邊界。
- [首次遷移契約](../migrations/context_mode_baseline_migration_contract.md)：既有資料一次性標記為日常，後續版本不得覆蓋。

## 固定術語

| 名稱 | 合法值 | 用途 |
|---|---|---|
| `ContextMode` | `daily`、`rp` | 決定窗口屬於日常或 RP；是記憶、摘要、時間線分流依據。 |
| `MemoryEngine` | `ordinary`、`spider` | 決定記憶演算法；不是窗口模式。RP 固定使用 `ordinary`。 |
| `continuity_id` | 預設 `main` | 區分同角色、同模式下互不相通的故事世界。 |
| `user_persona_id` | persona ID | 指定使用者在該窗口固定採用的自身角色，並參與 cache 身分。 |
| `worldbook_set_id` | 可空，未來使用 | 指定窗口採用的世界書集合。 |

既有 `MemorySettings.memory_mode` 與 `memories.mode` 目前承載舊記憶方案／桶位語義，後續不得把它們直接當成 `ContextMode`。資料層應另加 `context_mode`，避免 `daily/story/custom/romance` 等舊值與 `daily/rp` 混淆。

## 分批邊界

1. 第一批定義契約與驗收條件。（已完成）
2. 第二批實作 schema v48 migration、`ChatSessionIdentity` 與 cache／keep-alive 身分防呆。（已完成）
3. 第三批完成 RP 普通記憶、滾動摘要策略、時間線服務與實際注入路由。（已完成）
4. 第四批完成 Flutter UI、搜尋 scope／標籤與模式化 Debug 顯示。（已完成）

不得以空 service、空 repository、假 Prompt 或永遠不會執行的 feature flag 代替尚未開始的批次。
