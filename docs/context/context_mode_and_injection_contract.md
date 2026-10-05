# 窗口模式與注入契約

狀態：已實作。窗口身分、schema、備份、cache／keep-alive、模式專屬服務與 UI 均依本契約接線。

## 1. 唯一真相來源

每個聊天窗口建立時必須保存不可變的 `context_mode`：

- `daily`：日常窗口。
- `rp`：RP 窗口。

窗口建立後，任何全域開關、單角色切換、Profile 切換或歷史篩選都不得修改它。打開既有窗口時，所有模式敏感功能必須從該窗口的 `ConversationContext` 讀取模式，不得從目前 UI 開關重新推導。

建議的不可變窗口身分：

```text
ConversationContext
├─ conversation_id       必填
├─ character_id          必填
├─ context_mode          必填：daily | rp
├─ continuity_id         必填，初始為 main
├─ user_persona_id       可空，未來使用
└─ worldbook_set_id      可空，未來使用
```

`ChatSessionIdentity` 已承載以上資料。文字、圖片、通話、重試、分支、keep-alive、搜尋 follow-up、摘要與記憶提案都由窗口解析出的身分分流，不得各自猜測。

## 2. 新窗口模式

模式開關只影響「下一個新窗口」：

```text
effective_mode = global_rp_enabled ? rp : character_preferred_mode
new_conversation.context_mode = effective_mode
```

- 全域 RP 開啟時，所有角色的有效模式是 RP，但保留各角色原偏好。
- 全域 RP 關閉時，恢復各角色原偏好。
- 單角色切換不反向改動全域開關。
- 分支窗口不是一般新窗口；它必須繼承來源窗口的 `context_mode`、`continuity_id`、`user_persona_id` 與 `worldbook_set_id`。

若目前最新窗口與剛切換後的有效模式不同，顯示一次非阻斷提示，引導另開窗口；不得在舊窗口內熱切換模式。

以下三種 UI 狀態彼此獨立，禁止共用同一設定 key：

| 狀態 | 作用 | 持久化規則 |
|---|---|---|
| 全域 RP 開關 | 強制所有角色的新窗口採用 RP | 關閉後恢復角色原偏好，不覆寫偏好。 |
| 單角色模式偏好 | 決定全域 RP 關閉時該角色的新窗口模式 | 全域 RP 開啟時保留原值，UI 顯示有效 RP 狀態。 |
| 歷史篩選 `all/daily/rp` | 只控制歷史列表顯示 | 每角色保存；只有使用者手動切換篩選時才更新，預設 `all`。 |

所有切換、標籤與非阻斷提示文案都必須提供 `zh_TW`、`zh_CN`、`en`，但語言切換不得影響窗口模式。

## 3. StructuredPrompt 注入位置

RP 不增加新的 Prompt 階層，也不搬動現有注入位置。保留既有順序：

```text
cacheable prefix
staticPart → profilePart → windowPart → resolvedControlPart

request only
liveStatePart → ephemeralEvidencePart
```

模式只決定每個既有槽位要取哪一組內容：

| 內容 | 注入位置 | Cache 規則 | 模式規則 |
|---|---|---|---|
| 日常／RP communication profile、角色卡固定資料 | `staticPart` | 可快取 | 依窗口模式選取；RP 不提供 App 內建生成 Prompt。 |
| 使用者自身角色資料 | `profilePart` | 可快取 | 依窗口保存的 `user_persona_id`；功能完成前沿用現有使用者資料。 |
| 開窗時凍結的摘要、自我註記等快照 | `windowPart` | 可快取 | 來源必須與窗口模式、continuity 一致。 |
| 固定輸出／能力控制 | `resolvedControlPart` | 可快取 | RP 專屬注入規則保留擴充點，現階段不寫規則或假 Prompt。 |
| 本輪召回記憶 | `liveStatePart` | request-only | 只查同角色、同窗口模式、同 continuity。 |
| 本輪滾動摘要與關鍵詞召回 | `liveStatePart` | request-only | 只查同角色、同窗口模式、同 continuity。 |
| 本輪時間線狀態／事件召回 | `liveStatePart` | request-only | 日常與 RP 使用各自服務與去重域。 |
| 搜尋或工具證據 | `ephemeralEvidencePart` | request-only | 可跨模式，但必須由明確 scope 授權並保留模式標籤。 |

RP 記憶、滾動摘要與時間線的「注入邏輯預留」就是上述三個 `liveStatePart` 子來源。後續可以替換其檢索、排序、預算與格式，但不得改變 StructuredPrompt 的槽位或順序。

若啟用「專用窗口摘要」，其出生快照可進 `windowPart`；後續新增或變動的摘要只能進 `liveStatePart`，不得為每輪摘要刷新固定前綴。

## 4. Cache 身分與防呆

日常與 RP 不是新的 transport channel。`text`／`call` 等既有 `cacheChannel` 保留；模式屬於 cache namespace 身分。

後續 cache snapshot 至少要核對：

```text
conversation_id + character_id + context_mode + continuity_id
+ user_persona_id + worldbook_set_id + provider + model + cache_channel
```

- 任一已保存值與當前窗口不符：不得續用，必須丟棄該 snapshot 並以正確 context 重建。
- 不得因 UI 模式切換清空或重寫舊窗口 cache。
- 模式相關固定內容真的不同時，允許該窗口固定前綴自然重建一次。
- 記憶、動態摘要、時間線召回與搜尋結果只在 request-only 變化，不得旋轉 cacheable prefix。
- 所謂「RP cache debug」是帶 `context_mode` 的診斷資訊，不是新增 `rp` cache channel。

## 5. 明確允許的跨模式例外

一般聊天注入一律禁止跨模式。唯一例外是使用者明確使用全域聊天內容搜尋：

- `current`：只查當前窗口模式。
- `daily`：只查日常窗口。
- `rp`：只查 RP 窗口。
- `all`：查兩者，當前模式可提高排序優先度。

所有結果必須攜帶可見的日常／RP 標籤。搜尋結果只能作本輪證據，不能寫入固定 cache；若之後由使用者確認轉成記憶，必須明確選擇目標模式。

## 6. Fail-closed 規則

- 找不到窗口：停止請求，不得回退到目前選中的角色或模式。
- `context_mode` 缺失或非法：已完成 migration 的資料庫視為資料錯誤，不得依全域開關猜測。
- 查詢 mode-sensitive 資料時缺少 `ConversationContext`：拒絕執行，不提供 `daily`、`rp` 或舊 `romance` 預設值。
- 日誌不得保存聊天正文、完整 Prompt、記憶全文、API key 或搜尋原文。

## 7. 驗收

- 舊 RP 窗口在 UI 切回日常後，仍只使用 RP 的記憶、摘要、時間線與 Profile。
- 同一角色可同時擁有日常與 RP 窗口，彼此召回結果為零交叉。
- 文字、圖片、通話、重試與 keep-alive 的 context fingerprint 一致。
- 分支窗口完整繼承來源 context。
- 切換歷史篩選、全域／單角色模式不修改任何舊窗口 Prompt 或 cache snapshot。
