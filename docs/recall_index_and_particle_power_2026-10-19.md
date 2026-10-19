# RP 關鍵詞召回記憶體 + 粒子耗電 — 方案 2026-10-19

> 規劃：晏辭（只讀代碼）　施工：Codex　⚠️ 全部未真機驗證

---

## 一、RP 關鍵詞召回：記憶體爆，不是 token 爆

### 根因（✅ 已讀代碼）
- 注入的 token **已經有上限**：`getRpDynamicSummarySegments()` 和 `getRpDynamicSummaryMaxChars()` 卡住了召回段數與字數。關鍵詞再多，送出去的量也不會變多。
- 問題在**每一輪**的召回流程（`context_compressor.dart` `_rpRecallRows` → `_recallKeywordSummarySegment`）：
  1. `getContextSummarySegments` 把該故事線**所有** segment 連 `content` 全文一起撈進 Dart；
  2. `getContextKeywords` 再把所有舊版 keyword row 連 `source_summary_content` 全文撈進來；
  3. 對每一行重新跑 `RecallTextMatcher.splitKeywords`（多個 RegExp）+ normalize；
  4. 最後只用其中 1～N 段。
- 另外：`getContextKeywords` 在 RP 模式下**每次讀都會先跑 `restoreArchivedSummaryKeywords`**（是寫入路徑），等於每輪都多做一次 DB 寫檢查。
- 文字和圖片兩條路徑都會跑；`memory_summary_tab.dart:161` 打開時也是全量撈。

所以研究上下文壓縮解決不了這個問題（壓縮省的是 token，這裡缺的是索引）。**做索引，不用壓縮。**

### 階段 1（最小改動，預期收益最大）
1. **兩段式查詢**
   - 第一段只撈輕量欄位：`id, source_summary_id, segment_order, title, keywords, source_window_id, created_at`（**不撈 content**）。
   - 在 Dart 端照原邏輯打分、排序。
   - 第二段只對前 `maxRecalledSummaries × 3` 個候選用 `WHERE id IN (...)` 撈 content（×3 是給指紋去重與字數預算跳過留餘量）。
   - 排序、去重、預算邏輯一行都不改 → 召回結果應與現在完全一致。
2. **關鍵詞解析快取**
   - 按 `(characterId, contextMode, continuityId)` 快取 `List<(rowRef, List<String> normalizedKeywords)>`。
   - 任何寫入 `context_summary_segments` / `context_keywords` / 摘要失效 / 備份還原時，把全域 `recallIndexRevision++`；快取比對 revision，不一致就重建。
   - ⚠️ 雙路徑檢查：寫入點包括 `insertContextSummary*`、`_replaceContextSummarySegments`、`archiveContextSummaryWith*`、`restoreArchivedSummaryKeywords`、`_invalidateSummaryChainForMessage`、`deleteConversation`、`clearContextData`、`backup_service` 的 import 與 restore。漏一個就會召回到過時資料。
3. **把 `restoreArchivedSummaryKeywords` 移出讀路徑**
   - 改成每個 scope 每次 App 啟動只跑一次（in-memory `Set<String>` 記錄已修復的 scope），`recycleSupersededSummaries` 尾端原本就會調用，保留。
4. **摘要頁分頁**：`memory_summary_tab` 改成分頁 / 懶載入（每頁 50），列表不撈 content，點開才撈。

### 階段 2（關鍵詞上萬時再做）
- 新表 `context_recall_terms(scope…, row_kind, row_id, term_compact TEXT)`，寫入時就把 `splitKeywords` + `_compact(_normalize())` 的結果存進去；加 scope 索引。
- 召回時：`SELECT DISTINCT row_kind, row_id FROM context_recall_terms WHERE <scope> AND instr(:compactQuery, term_compact) > 0`，掃描交給 SQLite 原生做，只把命中的 row 拉回 Dart，再用原本的 `_score` 精排（保證排序一致）。
- 這個 SQL 預篩只覆蓋「連續包含」（原分數 1000/900）。多詞全含（800）和拉丁字母容錯（600）兩種情況：把關鍵詞的每個 ≥2 字的詞、以及長度 ≥4 的純拉丁詞另外存成 term，預篩命中後交回 Dart 原邏輯判定。
- 要寫 migration（`_dbVersion` +1），並補 backup 的 export/import 欄位。

### 想再省 token（可選，跟記憶體無關）
- 召回門檻：只命中 1 個 ≤2 字的關鍵詞時不召回，或要求 score ≥ 某值。目前 2 字詞命中就會召回一整段。
- 這會改變行為，先做成設定項，預設關。

### 驗收
- 準備一個 3000+ segment 的 RP 測試庫（可寫 test fixture 腳本灌資料）。
- 比較改前改後：同一組 20 條訊息的召回結果**逐字一致**、單輪召回耗時、峰值記憶體（DevTools Memory）。

---

## 二、粒子耗電

### 先看昭昭給的數字
| 情境 | 耗電 | 每小時 |
|---|---|---|
| 無特效 | 71 分鐘 12% | **≈10.1%/h** |
| 開特效（優化前，長時間） | 283 分鐘 67% | **≈14.2%/h** |
| 開特效（誇張情況） | 9 分鐘 4% | **≈26.7%/h**（9 分鐘樣本誤差大：3～4.99% 都會顯示 4%，約 20～33%/h） |

→ 長時間平均下，特效只多了約 **4%/h**（約 +40%），對一個全螢幕 30fps 動畫來說不算離譜。
→ 真正要抓的是「**誇張情況**」：同樣開特效，耗電卻是平均的 2 倍。那不是粒子本身的問題，是粒子在**某些頁面/設定下帶動了別的昂貴東西**。

### 嫌疑（✅ 代碼已確認存在，❓ 是否主因要實測）
1. **背景圖模糊（`gradient_background.dart` 的 `ImageFiltered` blur，最大 sigma 20）**
   - Impeller（iOS 預設，新版 Android 也是）**沒有 raster cache**。畫面上任何東西重繪時，全螢幕的模糊會被整張重算一次。
   - 粒子每秒 30 幀 → 背景圖的模糊每秒也重算 30 次。這是最可能的「誇張情況」：自訂背景圖 + 開模糊 + 開粒子。
2. **毛玻璃 `BackdropFilter`**：聊天輸入框 sigma 15、首頁底部導航 sigma 16、側邊欄。每一幀都會重新讀取背景、重新模糊。
3. **漣漪特效每幀大量 `MaskFilter.blur`**：7 個漣漪 × 最多 3 圈 × 每圈 2～3 次模糊繪製，最多約 60 次模糊/幀。餘燼和蒲公英已改成疊圓，不用模糊，漣漪還沒改。
4. 聊天生成中（`isBusy`）已降到 15fps ✅；閒置 20 秒降到 15fps ✅；離開頁面、退後台會停 ✅。這部分已經做得很好。

### 先量，再改（昭昭做，約 1 小時）
`flutter run --profile` + 打開 performance overlay，或者 Xcode Instruments → Energy Log。每組 10 分鐘，**電量 ≥80%、亮度固定、關自動亮度**：

| # | 頁面 | 粒子 | 背景圖 | 背景模糊 |
|---|---|---|---|---|
| 1 | 聊天 | 關 | 有 | 有 |
| 2 | 聊天 | 開（星星） | 有 | 有 |
| 3 | 聊天 | 開（星星） | 有 | **關** |
| 4 | 聊天 | 開（漣漪） | 有 | 關 |
| 5 | 首頁 | 開（星星） | 有 | 有 |

看 GPU raster 時間：如果 2 遠高於 3，主因就是嫌疑 1；如果 4 遠高於 3，就是漣漪。

### 方案（依實測結果挑）
**A. 背景模糊預烘焙（預期最大收益，不犧牲畫質）**
- 背景圖或模糊值改變時，把「圖 + blur + scale/offset」用 `PictureRecorder` 畫一次 → `toImage()` → 存成 `ui.Image`（也可以存檔快取）。之後每幀只畫一張普通圖片。
- 只有滑動切換背景的那段過場保留即時 `ImageFiltered`（那是動畫，本來就需要即時算）。
- 畫面效果應該完全相同，GPU 不再每幀做全螢幕模糊。

**B. 漣漪去模糊**
- 把 `diffusePaint` 的 MaskFilter 改成 2～3 層加寬、遞減透明度的描邊來模擬（跟餘燼的做法一樣）。
- 或者預先渲染一張柔邊圓環 sprite，用 `drawImageRect` 縮放成橢圓。
- 要真機比對質感，昭昭點頭再改。

**C. 毛玻璃**
- 粒子開著時，輸入框和導航改用「預烘焙背景的對應切片」當底，取代即時 `BackdropFilter`，看起來一樣，但不用每幀讀背景。
- 或者升級 Flutter 後用 `BackdropGroup` 共用同一次背景讀取（❓ 要先確認目前 Flutter 版本有沒有這個 API）。

**D. 閒置凍結（可選開關）**
- 閒置超過 60 秒就把粒子停在當前幀（不是消失），觸碰後恢復。
- 讀長回覆時你也是「閒置」，所以做成設定項，預設關。

**E. 小優化（CPU / GC）**
- 每顆粒子每幀 new 3 個 `Paint` → 改成複用（只改 color）。
- 星星、餘燼、蒲公英可改用 `drawRawAtlas` + 一張預渲染的柔光點 sprite，一次 draw call 畫完。

建議順序：**實測 → A →（若是漣漪）B → C → E**，D 看昭昭要不要。

---

## 三、補充：昭昭確認誇張情況時「背景模糊是開著的」→ 方案 A 優先

### A 的實作規格（給 Codex）
位置：`lib/widgets/gradient_background.dart` 中靜態背景的 `ImageFiltered`（約 397–410 行那段 `RepaintBoundary > ClipRect > ImageFiltered(image)`；約 235 行的 `custom-background-visibility` 若也是靜態顯示，同樣處理）。

1. **新增 `BlurredBackgroundCache`**（`lib/services/` 或 widget 內私有類）
   - key：`(imagePath, fileMtime, blurSigma, scale, offset.dx, offset.dy, logicalSize, devicePixelRatio)`。
   - 生成：解碼原圖 → `PictureRecorder` + `Canvas` → 按現有 scale/offset 規則 `drawImageRect`，Paint 帶 `imageFilter: ImageFilter.blur(sigma, sigma, tileMode: TileMode.clamp)` → `picture.toImage(w, h)`。
   - **降解析度烘焙**：模糊後的圖不需要全解析度。以 `0.5 × 物理像素` 生成、sigma 同步 ×0.5，顯示時拉伸回去，肉眼看不出差別，記憶體從約 12MB 降到約 3MB（以 1170×2532 計）。sigma < 3 時用全解析度，避免變糊。
   - 只保留目前背景的 1 份 + 上一份（過場用），舊的要 `dispose()`。
2. **顯示**：烘焙完成前先用現有的 `ImageFiltered` 即時路徑（不閃白）；完成後換成 `RawImage`/`Image` 直接畫烘焙結果。
3. **保留即時模糊的地方**：背景滑動切換過場（約 285–300 行、515–520 行的 swipe blur），還有主題工坊裡拖模糊滑桿的即時預覽，這些是動畫，本來就需要即時算。拖滑桿時用即時路徑，放手後 debounce 300ms 再烘焙。
4. **失效時機**：背景圖更換、blur/scale/offset 改變、螢幕旋轉或尺寸改變、主題切換、`didChangeMetrics`。
5. **邊界**：圖片解碼失敗時退回即時路徑；App 退後台時不要丟快取（回來會白屏閃一下）；Web 版如果 `toImage` 不可用或很慢，維持現狀（❓ 要測）。

### 驗收
- 同一張背景、同一個模糊值：烘焙版和即時版截圖肉眼比對一致（主題工坊預覽與聊天頁都看）。
- performance overlay：開粒子 + 開模糊時，raster 柱應該接近「開粒子 + 關模糊」。
- 重跑耗電：開特效 + 模糊，30 分鐘以上（樣本太短誤差大），對比 10.1%/h 基線。
