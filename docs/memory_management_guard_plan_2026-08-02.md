# 記憶管理防護方案

日期：2026-08-02

## 目標

在不改變角色自然記憶能力、也不污染 prompt cache 的前提下，防止三類事故：

1. 同一件事因措辭不同被重複寫入。
2. 模型或使用者誤刪仍有效的記憶。
3. 合併時漏掉原記憶的重要內容、觸發詞或蛛網連線。

## 一、統一變更管線

所有新增、刪除、合併，不再各自直接操作資料庫，而是走同一條管線：

```text
模型標籤／記憶管理 UI
        ↓
建立變更提案（proposal）
        ↓
角色範圍、短號、狀態與永久記憶檢查
        ↓
重複／衝突偵測
        ↓
自動安全處理，或顯示確認卡
        ↓
單一 transaction 執行
        ↓
審計紀錄 + 可恢復封存
```

建議新增 `pending_memory_actions`，保存 action、角色、來源、候選內容、涉及的真實記憶 ID、比對理由、建立時間與狀態。模型只能提出 proposal，不能繞過確認層直接執行高風險操作。

## 二、新增記憶的去重防護

### 比對範圍

只和同角色、同模式、active／permanent 記憶比較；不跨角色，也不拿回收區內容阻止正常新增。

### 比對訊號

- 內容正規化：大小寫、全半形、標點、日期前綴、第三人稱名稱差異。
- 觸發詞與別名重疊。
- 類別是否相同或可兼容。
- 內容包含度、字詞／中文雙字組相似度。
- 相同來源對話與短時間內連續生成提高重複置信度。

### 三段處理

- 明確重複：不新增；操作紀錄顯示「已略過重複記憶」，並連到既有條目。
- 疑似重複：建立確認卡，提供「保留舊條／使用新條／合併」三種選擇。
- 明確新內容：直接新增，維持目前自然記憶體驗。

第一版建議以保守門檻上線：只有內容相等、近似包含或高相似且觸發詞重疊時才自動略過；其餘一律提示，不自動吞掉。

## 三、刪除確認

### 模型提出刪除

`<memo_del>` 改成建立待確認 proposal，不立即 archive。聊天內顯示非打斷式提示卡：

- 要刪除的類別與完整內容。
- 模型提供的理由。
- 是否為永久記憶、最近是否被召回。
- 「取消」與「確認移至回收區」。

永久記憶禁止模型直接刪除，必須由使用者明確確認。

### UI 主動刪除

單條刪除使用確認 sheet；批量刪除列出數量與永久記憶數。執行後仍進既有 archive，可復原，不做物理刪除。

## 四、合併確認

`<memo_merge>` 與 UI 合併都先顯示 preview：

- 左側列出所有原記憶。
- 右側顯示合併後的類別、內容與觸發詞。
- 標出新內容沒有覆蓋到的原始專有名詞、日期、承諾與觸發詞。
- 允許確認前手動編輯合併結果。

確認後在同一 transaction 內：

1. 再驗證所有原記憶仍 active 且屬於同角色。
2. 插入合併記憶。
3. 遷移蛛網連線並去重。
4. 原記憶移入 archive。
5. proposal 標記 completed，寫入審計結果。

任一步失敗整筆 rollback，不允許出現「新條已建、舊條只刪一半」。

## 五、競態與防重送

- proposal 使用內容 fingerprint，串流重播或重試不重複建立確認卡。
- 確認按鈕冪等；completed／cancelled proposal 再點不重做。
- 執行時檢查記憶 `updated_at/status`，資料已變時要求重新預覽。
- 所有 ID 在執行前重新做 character scope 驗證；窗口短號只負責定位，不能成為授權依據。

## 六、UI 建議

- 聊天：小型「記憶變更待確認」卡，不塞進角色正文氣泡。
- 記憶頁：新增「待確認」入口與數量徽標。
- 去重提示：並排顯示舊／新內容，差異部分高亮。
- 刪除：預設焦點在取消；永久記憶增加第二層確認。
- 合併：確認前可修改合併正文與觸發詞。
- 完成後提供「復原」；實際使用既有 archive 還原能力。

## 七、Cache 影響

proposal、比對分數、確認 UI 與審計資料全部是本地狀態，不進 `staticPart/profilePart/windowPart`。

模型提出的變更只剝離標籤並建立本地 proposal；不需要修改 system prompt。確認後，真正的記憶變化按現有規則在後續 `turnPart` 召回，因此不刷新窗口 cache。若需要告訴模型「某項變更尚待確認」，也只能放在本輪 request-only sidecar，不能放入可快取前綴。

## 八、實作順序

1. Proposal schema、資料模型、fingerprint 與 transaction executor。
2. 新增記憶重複偵測與「明確重複自動略過」。
3. 將模型刪除／合併從立即執行改成 proposal。
4. 聊天確認卡、記憶頁待確認列表、刪除／合併 preview。
5. 永久記憶二次確認、批量操作與復原。
6. 回歸與 migration 測試，再開正式功能旗標。

## 九、驗收條件

- 同輪重送、串流重連與 App 重啟都不產生雙份 proposal。
- 明確重複記憶不入庫；疑似重複不被靜默吞掉。
- 未確認的模型刪除／合併不改任何 memory、archive 或 spider link。
- 合併失敗可以完整 rollback。
- 永久記憶不能由模型單方面刪除。
- 所有刪除可在 archive 復原。
- 只改動 proposal 或確認狀態時，cacheable prompt fingerprint 完全不變。

## 十、關鍵產品決策

### 哪些動作可以自動完成

| 動作 | 明確安全 | 有疑義 | 高風險 |
|---|---|---|---|
| 新增 | 直接新增 | 顯示去重確認 | 明確重複直接略過，不新增第二條 |
| 刪除 | 無 | 一律確認 | 永久記憶二次確認 |
| 合併 | 無 | 一律預覽並確認 | 涉及永久記憶時二次確認 |
| 還原 | 單條可直接還原 | ID／內容衝突時預覽 | 不覆蓋現有記憶 |

刪除與合併不設「模型很確定就自動做」的例外。模型置信度不是授權，最多只能影響 proposal 中顯示的理由。

### 什麼算「重複」

重複不等於「談到同一個人或同一件物品」。以下應視為不同記憶：

- 「昭昭喜歡咖啡」與「昭昭不再喝咖啡」：有否定／狀態反轉。
- 「8 月 1 日約好看電影」與「8 月 8 日約好看電影」：日期不同。
- 「喜歡橘貓」與「收養了一隻橘貓」：偏好與事件不同。
- 「答應陪他」與「取消了陪伴約定」：承諾狀態不同。

只有核心事實相同、差異主要來自標點、稱謂、日期前綴或贅詞時，才允許自動略過。

## 十一、資料結構草案

資料庫升級建議使用下一個 schema version，新增：

```sql
CREATE TABLE pending_memory_actions (
  id TEXT PRIMARY KEY,
  character_id TEXT NOT NULL,
  mode TEXT NOT NULL,
  action TEXT NOT NULL,
  source TEXT NOT NULL,
  source_conversation_id TEXT,
  source_message_id INTEGER,
  target_ids_json TEXT NOT NULL DEFAULT '[]',
  payload_json TEXT NOT NULL,
  base_versions_json TEXT NOT NULL DEFAULT '{}',
  fingerprint TEXT NOT NULL,
  duplicate_score REAL,
  reasons_json TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TEXT NOT NULL,
  resolved_at TEXT,
  error TEXT
);
```

欄位語義：

- `action`：`create / delete / merge / replace / restore`。
- `source`：`model / memory_ui / duplicate_guard`。
- `payload_json`：候選類別、正文、觸發詞，以及合併後 preview。
- `base_versions_json`：每個 target 的 `updated_at + status` 快照，用於確認時偵測資料已變。
- `fingerprint`：同一來源消息、動作、target 與 payload 的穩定 hash。
- `status`：`pending / executing / completed / cancelled / stale / failed`。

索引：

```sql
CREATE INDEX idx_pending_memory_character_status
ON pending_memory_actions(character_id, status, created_at DESC);

CREATE UNIQUE INDEX idx_pending_memory_fingerprint
ON pending_memory_actions(fingerprint)
WHERE status IN ('pending', 'executing');
```

proposal 完成後不立即刪除，保留作審計與復原依據。可在 90 天後只清理 `cancelled/completed`，`pending` 不因清理工作被自動執行。

## 十二、去重計分規格

第一版不用 embedding，也不呼叫摘要模型。理由是去重必須離線、可解釋、零 token，而且不能因 API 失敗放行重複內容。

### 正規化

1. 移除 App 自動加上的開頭日期標籤，例如 `[8/2]`；正文中的日期保留。
2. 全形英數轉半形，英文轉小寫。
3. 移除標點與多餘空白，但保留數字、否定詞與中英文實詞。
4. 將當前角色名／用戶名轉成穩定 placeholder，避免「昭昭／你／對方」造成純稱謂差異。
5. 觸發詞按現有別名規則拆分並正規化。

### 特徵與初始權重

```text
內容相似度              0.70
觸發詞重疊              0.20
類別兼容                0.10
--------------------------------
基礎分數                1.00
```

內容相似度取以下訊號的最大安全組合：完全相等、較短內容被較長內容包含、中文雙字組 Jaccard、英文單詞 Jaccard。類別只允許相同類別得滿分；「重要事件／約定」這類可能兼容但不相同的組合只得部分分數。

### 強制降級條件

即使分數很高，出現以下差異也禁止自動略過，只能進確認：

- 一方有「不、沒、取消、結束、分開、改成」等否定或反轉詞，另一方沒有。
- 關鍵日期、數字、數量不同。
- 一方是持續偏好，另一方是完成事件。
- permanent 狀態不同。
- 新內容包含舊內容沒有的承諾、界線或關係變化。

### 初始門檻

- `>= 0.92` 且沒有強制降級：明確重複，自動略過。
- `0.72–0.92`：疑似重複，顯示確認卡。
- `< 0.72`：視為新記憶，直接新增。

這些是初始保守值。proposal 的 `score + reasons` 會保留，之後可根據真實誤判調整，而不是靠感覺改門檻。

## 十三、狀態機與冪等

```text
                ┌──────── cancelled
pending ────────┼──────── stale
   │            └──────── failed（可重試）
   │ CAS: pending → executing
   ▼
executing ─────────────── completed
```

確認時先執行條件更新：

```sql
UPDATE pending_memory_actions
SET status = 'executing'
WHERE id = ? AND status = 'pending';
```

只有影響一列的呼叫者能繼續。雙擊、重送、兩個頁面同時確認時，其他呼叫者只重新讀取結果，不得重做 mutation。

執行前逐筆比對 `character_id / status / updated_at`。target 已修改或歸檔時，proposal 變成 `stale`，要求重新預覽；不能拿舊 preview 覆蓋新資料。

## 十四、三種操作的完整流程

### A. 新增記憶

```text
解析 <memo>
  ↓
建立 MemoryCandidate（尚未 insert）
  ↓
查同角色、同 mode 的 active + permanent
  ↓
本地去重評估
  ├─ unique：insert，記錄「已寫入」
  ├─ exact duplicate：不 insert，記錄「已略過重複」
  └─ possible duplicate：建立 proposal，顯示待確認
```

疑似重複卡提供：

- 「保留舊條」：取消候選。
- 「使用新條」：用新內容替換，但先保存舊快照以便復原。
- 「兩條都留」：明確覆寫去重判斷，正常 insert。
- 「合併」：進入可編輯 merge preview。

模型正文照常顯示；`<memo>` 一律剝離。未完成確認時，Thinking／記憶分支顯示「疑似重複，等待確認」，不能顯示「已寫入」。

### B. 刪除記憶

```text
解析 <memo_del> 或 UI 點刪除
  ↓
短號反查真 ID + character scope 驗證
  ↓
建立 delete proposal
  ↓
顯示內容、類別、最近召回時間、永久狀態
  ↓
使用者確認
  ↓
transaction 內 archive
```

取消時 memory 不變。確認後卡片顯示「已移至回收區」與復原入口。若模型短號無效，直接丟棄並寫 debug log，不建立「空刪除」proposal。

### C. 合併記憶

```text
解析 <memo_merge> 或 UI 多選合併
  ↓
驗證至少兩條、同角色、仍 active
  ↓
產生 merge preview
  ↓
檢查遺漏的日期／數字／專名／觸發詞
  ↓
使用者修改或確認
  ↓
transaction：insert 新條 → remap links → archive 舊條
```

preview 不能只顯示模型寫出的新句子，還要顯示「可能遺漏」：

- 原條中未出現在新正文的日期、數字、名字與物品名。
- 原有觸發詞聯集與新觸發詞的差集。
- permanent 原條是否會令合併結果也成為 permanent。

建議規則：只要任一原條 permanent，合併結果預設 permanent，使用者可以取消合併，但不能在同一確認中偷偷降級保護。

## 十五、與現有程式的接點

### `MemoryActions.processReply`

目前 `<memo_del>` 與 `<memo_merge>` 會直接操作資料庫。改造後：

- `<memo>` 呼叫 `MemoryGuard.evaluateCreate`。
- `<memo_del>` 呼叫 `MemoryGuard.proposeDelete`。
- `<memo_merge>` 呼叫 `MemoryGuard.proposeMerge`。
- 標籤剝離行為保持不變。
- `lastActionLogFor` 區分 `completed / skipped / pending`，避免 UI 說謊。

### `DatabaseHelper`

新增 proposal CRUD、原子 claim、resolve、stale 檢查。真正的 archive、insert、link remap 只能由 executor 在 transaction 中調用；UI 和 parser 不直接拼多步資料庫操作。

### `Retriever`

不注入 pending proposal。只有已完成、仍 active 的記憶能進召回，避免模型把尚未批准的候選當成既定事實。

### 記憶頁與聊天頁

- 記憶頁取得角色 pending count，顯示「待確認」分頁／徽標。
- 聊天消息保存後，把本輪 proposal 綁到 `source_message_id`。
- assistant 氣泡下方渲染 proposal card；卡片不是消息正文，不參與 TTS、複製或摘要。
- App 重啟後從資料庫恢復卡片，不依賴記憶體 state。

## 十六、UI 細節規格

### 去重確認卡

```text
疑似重複記憶                         86%

既有：昭昭喜歡雨天一起散步
新增：昭昭很喜歡在下雨時一起散步

相同：昭昭／雨天／一起散步
新增資訊：很喜歡

[保留舊條] [合併／編輯] [兩條都留]
```

百分比只作輔助，不使用「AI 判定」措辭；下方必須列出可理解的命中理由。

### 刪除確認 sheet

- 標題：「移至回收區？」而不是不可逆的「永久刪除」。
- 完整顯示正文，不能只顯示截斷的 26 字操作 log。
- 永久記憶顯示醒目保護標誌，確認按鈕需要第二次點擊。
- 預設焦點與 Enter 行為落在取消。

### 合併 preview

- 原記憶可逐條展開。
- 合併正文和觸發詞可編輯。
- 遺漏警告位於確認按鈕上方。
- 有未處理遺漏時仍可確認，但必須再次點擊，不能靜默阻塞也不能無提示通過。

## 十七、Cache 與 token 精確影響

### 不會改變的內容

- `staticPart`：不新增每輪 proposal 規則。
- `profilePart`：完全無關。
- `windowPart`：pending count、proposal 內容不進窗口快照。
- 已有歷史消息：proposal card 不寫成 user／assistant 正文。

### 允許變動的內容

- Thinking／記憶操作 log 可顯示 pending／skipped，屬 UI metadata，不送回模型。
- 確認後 active memories 改變，後續召回自然反映在 request-only `turnPart`；這和現有記憶召回相同。
- 若確實需要通知角色某個 proposal 被使用者取消／確認，只在下一輪 `turnPart` 放一次性結果，成功送達後消費。

因此單純打開卡片、取消、確認或停留在待確認列表，都不會旋轉 prompt cache，也不會產生摘要／embedding API 消費。

## 十八、測試矩陣

### 去重

- 標點、空白、全半形與稱謂不同仍命中。
- 日期／數字不同不自動略過。
- 否定、取消、結束等反轉不自動合併。
- 同角色同模式才比較；跨角色、跨 story／romance 不互相阻擋。
- 串流重播同一 `<memo>` 只產生一個結果／proposal。

### 刪除

- 未確認時 memories、archive、links 全部不變。
- 無效短號、他角色 ID、已 archive ID 無法建立有效 proposal。
- 永久記憶必須二次確認。
- 確認後可從 archive 還原。

### 合併

- 少於兩條、跨角色、target stale 全部拒絕執行。
- insert、link remap、archive 任一步失敗均完整 rollback。
- links 不自連、不重複，且全部留在正確 character scope。
- 觸發詞聯集和遺漏提示正確。

### 併發與生命週期

- 連點確認只執行一次。
- App 重啟後 pending proposal 可恢復。
- 兩個窗口同時處理同一記憶時，後確認者得到 stale，而不是覆蓋。
- 取消與清理任務不會誤執行 proposal。

### Cache

- proposal 建立前後，`StructuredPrompt.cacheableParts` fingerprint 相同。
- 只更新 pending status，Claude／Gemini cacheable request blocks 完全相同。
- 一次性確認結果只出現在 runtime sidecar，且不寫入 user message。

## 十九、建議拆成的實作批次

### 批次 A：底層安全閘

- schema migration。
- `MemoryActionProposal` model。
- fingerprint、狀態機與 executor。
- transaction、scope、stale、冪等測試。

完成 A 時先不接 UI，也不改現有行為；只建立被測試覆蓋的底層能力。

### 批次 B：新增去重

- `MemoryDuplicateDetector`。
- `<memo>` 接入三段判定。
- 明確重複 skip log。
- 疑似重複 proposal 與記憶頁簡易確認。

### 批次 C：刪除防護

- `<memo_del>` 停止直接 archive。
- 聊天／記憶頁刪除確認。
- permanent 二次確認與 restore。

### 批次 D：合併防護

- merge preview、遺漏分析、可編輯結果。
- transactional insert/remap/archive。
- stale 與 rollback 測試。

### 批次 E：收尾

- pending 徽標、審計歷史、清理策略。
- cache fingerprint 回歸。
- feature flag 移除前的真實資料抽樣與門檻校準。

建議依 A → B → C → D → E 落地，不把 UI 先做在不安全的直寫 API 上，也不在第一批同時調整去重門檻與刪除語義。

## 二十、記憶關係可視化補案

### 現況診斷

目前專案不是完全沒有蛛網畫布，而是「有畫布、幾乎沒有可形成畫面的關係資料」：

- `SpiderWebGraphView` 已能把 `spider_web_links` 畫成曲線。
- `spider_web_links` 只有兩個 memory ID 和建立時間，沒有關係類型、理由、強度、來源或確認狀態。
- 新連線幾乎只在模型主動輸出 `<memo_link>` 時建立。
- 聊天端要同輪至少命中三條記憶，才提醒模型考慮 `<memo_link>`；一般對話很難達成。
- 沒有連線時，畫面只顯示節點數，右上角的連線 badge 整個消失，使用者不會知道是 `0 links`、資料尚未分析，還是畫圖故障。
- edge 不能點擊，無法查看「為什麼相連」、確認建議、解除連線或合併。

所以現象不是線條顏色太淡。Painter 已提高舊記憶連線的最低可見度；真正缺口是關係建立與解釋層。

### 產品定位

蛛網應該是「可理解、可修正的記憶關係圖」，不是純裝飾神經網路。它需要同時服務兩件事：

1. 日常瀏覽：看見哪些回憶彼此牽動。
2. 安全整理：理解重複、衝突與合併會影響哪些節點。

因此視覺優先順序是關係可理解性與危險操作安全，其次才是呼吸、流光等氛圍動畫。

### 關係資料擴充

建議直接擴充既有 `spider_web_links`，保留目前所有 graph 與神經傳導接點：

```sql
ALTER TABLE spider_web_links ADD COLUMN relation_type TEXT
  NOT NULL DEFAULT 'related';
ALTER TABLE spider_web_links ADD COLUMN strength REAL
  NOT NULL DEFAULT 1.0;
ALTER TABLE spider_web_links ADD COLUMN status TEXT
  NOT NULL DEFAULT 'confirmed';
ALTER TABLE spider_web_links ADD COLUMN source TEXT
  NOT NULL DEFAULT 'legacy';
ALTER TABLE spider_web_links ADD COLUMN reason TEXT
  NOT NULL DEFAULT '';
ALTER TABLE spider_web_links ADD COLUMN updated_at TEXT
  NOT NULL DEFAULT '';
```

枚舉：

- `relation_type`：`related / same_event / temporal / duplicate_candidate / conflict_update`。
- `status`：`suggested / confirmed / rejected`。
- `source`：`legacy / model / local_scan / user / merge_remap`。

每對記憶只保留一個「目前最有用的主關係」，避免同一對節點疊五條線。詳細的多重理由放在 `reason`／proposal 審計資料，不全畫在圖上。

既有連線 migration 為：

```text
type=related
strength=1.0
status=confirmed
source=legacy
reason=既有蛛網連線
```

### 哪些關係會影響記憶傳導

- `confirmed + related/same_event/temporal`：參與現有神經傳導和孤島判定。
- `suggested`：只供視覺確認，不提升鄰居清晰度，也不能保護節點免於孤島封存。
- `duplicate_candidate/conflict_update`：屬整理訊號；確認為普通關係前，不參與傳導。
- `rejected`：不畫、不傳導；保存 pair fingerprint，避免掃描器重複建議。

這能防止「掃描器只是覺得可能相似，就讓兩條記憶互相續命」。

### 既有記憶如何產生連線

既有記憶掃描器同時輸出兩種結果：

```text
MemoryDuplicateDetector
  ├─ duplicate/conflict proposal
  └─ relationship suggestion
```

只用本地、可解釋訊號：

- 共享具體觸發詞或別名。
- 同一日期、事件、地點或物品。
- 一條記憶明確延續／取消另一條的狀態。
- 內容高度近似，形成 duplicate candidate。
- 相同來源對話且主題重疊。

禁止僅因角色名、用戶名、「喜歡」「今天」等泛詞建立線。每條 suggested edge 必須有 reason，例如：

```text
共同觸發詞：橘貓
共同事件日期：2026-07-18
狀態反轉：喜歡 → 不再
內容近似度：0.86
```

### 圖形語法

關係不能只靠顏色區分：

| 關係狀態 | 線條 | 附加提示 |
|---|---|---|
| 已確認關聯 | 實線 | 普通光點沿線低頻移動 |
| 待確認建議 | 虛線 | 中點小問號／菱形 |
| 疑似重複 | 雙線或較寬虛線 | 中點「重」標誌 |
| 狀態衝突／更新 | 分段線 | 中點警示菱形 |
| 選中路徑 | 提亮並略增粗 | 其他節點和線降低視覺權重 |

顏色從現有主題 accent 與警示色推導，不另造固定調色盤；線型、圖標和文字共同表意，確保色覺差異下仍可辨識。

### 圖面資訊層級

1. 第一層：節點和已確認主連線。
2. 第二層：選中節點的直接鄰居與關係。
3. 第三層：待確認、重複、衝突標記。
4. 細節：點擊 edge 後才在 bottom sheet 展開理由與操作。

不應把所有 reason 直接貼在 3200×3200 畫布上，否則大量記憶時會變成文字雲。

### 互動

點節點：

- 高亮一跳鄰居與相連 edge。
- 顯示記憶正文、清晰度、最近召回和連線數。
- 提供「查看關係」列表；不強迫使用者精準點細線。

點 edge 或關係列表：

- 顯示兩端完整記憶。
- 顯示 type、status、strength、source、reason。
- suggested：`確認連線 / 不是關聯 / 進入合併`。
- confirmed：`解除連線 / 查看兩端`。
- conflict：`保留時間序列 / 新條取代舊條 / 兩條都留`。

長按空白不建立線，避免手勢誤觸。手動連線使用「先選節點 A，再選節點 B」的明確模式，並提供取消狀態。

### 零連線與掃描狀態

連線 badge 永遠顯示，包括 `0 連線`。當節點大於零、edge 為零時顯示非阻擋式說明：

```text
這些記憶還沒有建立關係
[分析既有記憶]
```

掃描時顯示已分析／總數與可中止狀態；掃描完成後顯示「找到 N 組關係建議」，而不是自動把整張網織滿。

### 篩選與密度

頂部提供最少量篩選：

- 全部
- 已確認
- 待確認
- 重複／衝突
- 孤立節點

預設顯示已確認關係；存在待確認項目時用徽標提示，不強制全部疊在預設圖面。大量節點時先按關聯群組聚焦，避免全圖縮到不可讀。

### 動效

- 已確認 edge 才保留現有低頻流光，表達神經傳導。
- suggested edge 靜止或使用極低幅度虛線相位，不與真實傳導搶注意力。
- 確認連線時只做一次從兩端向中點收束的短反饋。
- 合併時舊節點向新節點收束，完成後定形；不是永久循環。
- 系統開啟 reduced motion 時，取消入場 zoom、節點呼吸、沿線流光和收束位移，改成靜態線型與短淡入，資訊不消失。

### 無障礙替代

Canvas 不是唯一入口。圖下方／bottom sheet 提供可讀的關係列表：

```text
橘貓咖啡店 ↔ 收養小橘
待確認 · 共同觸發詞「橘貓」
```

- 節點和 edge 提供 semantic label、狀態與操作。
- 所有操作觸控區至少 44–48 logical pixels。
- 支援文字放大後 bottom sheet 捲動與換行。
- 關係狀態用線型、圖標、文字共同表達，不只靠顏色。
- 拖動節點必須有非拖動替代；拖動只改布局，不改資料關係。

### 效能邊界

- 本地 scanner 分批建立候選，不在每一幀或每次聊天開啟時重算。
- Graph painter 只接收目前篩選後的可見 edge。
- edge hit test 建立簡單空間索引，不能每次 pointer move 掃全圖所有貝茲路徑。
- 超過 60 條 edge 時停用逐線流光；沿用現有 painter 的效能保護。
- 頁面不可見或 App 進背景時停止 ticker；reduced motion 下直接使用靜態 painter。

### 與記憶防護的整合

去重確認卡與關係圖使用同一份 proposal／relation 資料：

- 疑似重複 proposal 在圖上是一條 `duplicate_candidate + suggested` edge。
- 使用者選「不是重複」後 edge 變 rejected，掃描器不再重複提示。
- 選「保留兩條但有關聯」時轉為 `related + confirmed`。
- 選「合併」時沿用同一 proposal 進 merge preview。
- merge executor 遷移 confirmed edge；suggested edge 重新評估，不直接繼承舊判斷。

如此「整理列表」和「蛛網圖」不是兩套互相矛盾的資料，而是同一關係系統的列表視圖與空間視圖。

### 可視化實作順序

1. Relation schema migration 與既有 edge 回填。
2. 讓 `0 連線`、零連線說明和掃描入口可見。
3. 本地 existing-memory relationship scanner。
4. suggested／confirmed／duplicate／conflict 線型。
5. 節點選中、高亮鄰居與 edge detail sheet。
6. 關係列表、Semantics、文字放大和 reduced-motion。
7. merge／delete proposal 與 graph transaction 整合。

這部分應插在原批次 B 與 C 之間：先讓既有記憶產生可理解的關係候選，再接高風險刪除與合併確認。
