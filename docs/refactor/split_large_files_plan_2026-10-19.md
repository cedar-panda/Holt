# 大檔拆分施工單（純搬家，不改行為）— 2026-10-19

> ⚠️ 已被 `split_large_files_plan_v2_2026-10-19.md` 取代（行號已漂移），請改看 v2。

> 規劃：晏辭　施工：Codex　驗收：昭昭
> 本單所有行號以 2026-10-19 當前工作區為準（含未提交改動）。**動手前先重新核對行號**，搬家時**由檔案底部往上搬**，避免行號漂移。

---

## 〇、鐵律（每一批都適用）

1. **純搬家。** 不改任何邏輯、條件、常量、字串、SQL、註解內容。不改名、不「順手」優化、不合併重複代碼。
2. **公開 API 一個字都不變。** `DatabaseHelper.xxx` 在 `lib/` + `test/` 裡有 176 個不同的成員被 120 個檔案呼叫。所有 public 靜態方法的簽名、預設值、named 參數、`@visibleForTesting`、`///` 文檔註解都必須原樣保留在 `DatabaseHelper` 上。
3. **沿用專案既有模式，不發明新模式：**
   - `DatabaseHelper`（全是 static）→ 參考 `database_memory_search.dart` 的 `_MemorySearch`：part 檔裡放 `class _XxxStore { static ... }`，`DatabaseHelper` 上保留一行轉發。
   - `State` 類 → 參考 `chat_screen_actions.dart` / `home_screen_profile.dart`：`part of` + `extension _XxxMethods on _YyyState { ... }`。
4. **不碰的東西：** `backups/`、`Claude outputs/`、`_archive_dev/`、`*.bak`、`Holt_pwa/`、`build/`、所有 `test/` 檔（除非 analyze 證明必須改，且要在報告中說明）。
5. **只對新建的 part 檔跑 `dart format`**，不要對整個 `lib/` 跑，避免無關 diff。
6. **一批一個 commit。** 一批沒過驗收，不准開下一批。
7. 遇到看不懂/不確定能不能搬的方法：**留在原處**，記在報告「未搬清單」裡，不要猜。

---

## 一、第 0 步：安全快照（必做，先於一切）

```bash
cd project_yanci

# 1) 把當前 WIP（208 個改動 + 新檔）凍結成一個 commit
#    注意：不要 add backups/、Claude outputs/、*.bak
git checkout -b refactor/split-large-files
git add lib test pubspec.yaml pubspec.lock docs ios android web macos linux windows tool assets
git status --short   # 確認沒有 backups/ 或 .apk 被加進來
git commit -m "wip: snapshot before large-file split"

# 2) 檔案級備份（給昭昭肉眼可找的那份）
mkdir -p backups/split-20261019
for f in lib/memory/database.dart lib/memory/database_schema.dart \
         lib/screens/chat_screen.dart lib/screens/chat_screen_generation.dart \
         lib/screens/theme_workshop_screen.dart lib/screens/home_screen.dart \
         lib/screens/memory_screen.dart; do
  mkdir -p "backups/split-20261019/$(dirname $f)"
  cp -p "$f" "backups/split-20261019/$f"
done
(cd backups/split-20261019 && find . -name '*.dart' -exec shasum -a 256 {} \; > SHA256SUMS.txt)

# 3) 記錄基線
flutter analyze > docs/refactor/analyze_baseline.txt 2>&1 || true
flutter test     > docs/refactor/test_baseline.txt    2>&1 || true
```

> 如果昭昭想自己 commit WIP，第 1) 步跳過，從第 2) 開始。

---

## 二、每批驗收標準（每批都跑）

```bash
# A. 靜態檢查：issue 數不得多於基線，且不得出現新的 error
flutter analyze

# B. 測試：失敗清單不得多於 test_baseline.txt
flutter test

# C. 方法清單守恆（搬前搬後名字集合一致；轉發 stub 會重複，用 sort -u）
extract() { grep -hoE '^  (static )?[A-Za-z_<>?, \[\]]+ +_?[a-zA-Z][A-Za-z0-9_]*\(' "$@" \
            | sed -E 's/.* (_?[a-zA-Z][A-Za-z0-9_]*)\($/\1/' | sort -u; }
extract backups/split-20261019/lib/<原檔> > /tmp/before.txt
extract lib/<原檔> lib/<新 part 檔們> > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt   # 只允許出現新 _XxxStore 類名，不允許少方法

# D. 總行數：新舊總和差距應僅來自 part 頭、類殼、轉發 stub
wc -l backups/split-20261019/lib/<原檔>
wc -l lib/<原檔> lib/<新 part 檔們>
```

E. **昭昭真機冒煙**（iOS + Android 各一次，每批列出對應的點擊路徑，見各批末尾）。

F. Commit：`refactor(<範圍>): split <檔名> into parts (no behavior change)`，commit message 內附「新檔清單 + 行數 + 未搬清單」。

---

## 三、批次 1：`lib/memory/database.dart`（6859 行 → 目標本體 ≤ 1500）

### 做法
- 每組新建 `lib/memory/database_<組>.dart`，首行 `part of 'database.dart';`，在 `database.dart` 頂部 `part '...';` 區塊按字母序加上。
- 組內方法搬進 `class _<組>Store { ... }`，保持 `static`。
- **搬過去的代碼裡，所有原本不帶前綴引用 `DatabaseHelper` 靜態成員的地方都要補 `DatabaseHelper.`**：
  `database` → `DatabaseHelper.database`、`_windowIdRandom` → `DatabaseHelper._windowIdRandom`、跨組呼叫如 `getCharacter(...)` → `DatabaseHelper.getCharacter(...)`。（同一 library 的 part 可以存取 `_` 私有成員，所以私有成員不用改成公開。）漏補的話 analyze 會直接報 undefined，屬於編譯期可見錯誤。
- **public 方法**：`DatabaseHelper` 上留轉發 stub，簽名完全一致，`///` 註解留在 stub 上：
  ```dart
  /// （原文檔註解原樣保留）
  static Future<bool> appendSelfNote(String characterId, String note) =>
      _SelfNoteStore.appendSelfNote(characterId, note);
  ```
  named 參數要逐一轉發，預設值只寫在 stub 上，Store 端改為 `required`（或保持相同預設值，二選一，全檔統一）。
- **只在組內使用的私有 helper**（如 `_selfNoteLines`、`_levenshtein`）：整個搬走，不留 stub。
- **被多組共用的私有 helper**（如 `_imagePathsFromRow`、`_likeContains`、`_generateWindowSummaryId`）：**留在 `DatabaseHelper`**，被搬走的代碼用 `DatabaseHelper._xxx` 引用。
- **留在本體不動**：靜態欄位、`database` getter、`_initDatabase`、`_onCreate/_onUpgrade/_safeAddColumn`、所有 `*ForTesting`、`_create*Table` 系列、`rebuildMemoryFts`/`ensureAllSchemaTables`/`searchMemoriesByText`（已轉發到 `_MemorySearch`）、檔案頂部的 enum 與 `ContextSummarySegmentDraft`。

### 分組（行號為當前檔案，請核對 `// ═══` 段落標題）

| 新檔 | 類名 | 約略行號 | 內容 |
|---|---|---|---|
| `database_keep_alive.dart` | `_KeepAliveGuardStore` | 210–380 | tryClaim / complete / release / resetKeepAlivePing |
| `database_voices.dart` | `_VoiceStore` | 547–670（`_createVoiceTable` 留本體） | saveVoice … getVoiceCount |
| `database_self_notes.dart` | `_SelfNoteStore` | 786–1389 | appendSelfNote … clearSelfNotes 及全部 selfNote 私有 helper |
| `database_characters.dart` | `_CharacterStore` | 671–785 中屬於角色的 + 1390–1711 | insert/update/get/deleteCharacter、sanitize… |
| `database_conversations.dart` | `_ConversationStore` | 1712–2762 | 對話、RP storyline、chapter continuation、pinned summary、window summary id、deleteConversation |
| `database_messages.dart` | `_MessageStore` | 2763–3374 + 675–785 中訊息類（updateMessageDraw / searchMessages / getLastMessageTime / getCharacterActiveDateKeys） | 訊息 CRUD、branch、diagnostics、persona card |
| `database_message_invalidation.dart` | `_MessageInvalidation` | 3375–3844 | `_archiveMessageRevision`、`_invalidateSummaryChainForMessage`、RP 投影回滾、updateMessageStatus |
| `database_memories.dart` | `_MemoryStore` | 3871–4180 + 4228–4561 | 記憶 CRUD、歸檔/還原/硬刪 |
| `database_notes_stickers.dart` | `_NoteStickerStore` | 4181–4227 + 4562–4656 | 表情包、便利貼、`_ensureNoteCharacterColumn` |
| `database_usage.dart` | `_UsageStore` | 4657–5199 | Web search 預約/結算、logUsage、用量統計 |
| `database_saved_messages.dart` | `_SavedMessageStore` | 5200–5355（`_create*` 兩個建表 helper 留本體；`_likeContains` 留本體） | 收藏消息 |
| `database_context_summaries.dart` | `_ContextSummaryStore` | 5356–6455 | 上下文摘要寫入/讀取/歸檔/修復 |
| `database_context_keywords.dart` | `_ContextKeywordStore` | 6456–6619 | keywords CRUD、`clearContextData` |
| `database_spider_web.dart` | `_SpiderWebStore` | 6620–檔尾 | 蜘蛛網關聯 |

> 搬家順序：**由下往上**（spider_web → context_keywords → … → keep_alive），每搬完一組跑一次 `flutter analyze lib/memory`。

### 特別注意
- **transaction 內的代碼**：`txn` / `db` 是參數，不要誤改成 `DatabaseHelper.database`。只替換「原本寫 `await database`」的地方。
- `_invalidateSummaryChainForMessage` 會被訊息刪改兩邊呼叫；搬後兩處呼叫改為 `_MessageInvalidation._invalidateSummaryChainForMessage(...)`（或 DatabaseHelper 上留私有轉發，二選一，全檔統一）。
- 不要改 `_dbVersion`、不要動 `database_schema.dart`（第 6 批才處理）。

### 真機冒煙
新建角色 → 聊天發 3 條 → 重新生成 → 刪一條訊息 → 開記憶頁歸檔/還原一條 → 收藏一條訊息 → 觸發一次上下文壓縮（或手動總結）→ 用量頁看數字 → 退出重開 App 確認資料都在 → 備份匯出一次。

---

## 四、批次 2：`lib/screens/theme_workshop_screen.dart`（4118 行 → 目標本體 ≤ 900）

### 做法
- `theme_workshop_screen.dart` 加 `part` 宣告；新檔 `part of 'theme_workshop_screen.dart';` + `extension _ThemeWorkshopXxx on _ThemeWorkshopScreenState { ... }`。
- **留在 State 類內**：所有欄位、`initState`、`dispose`、`build`、任何 `@override`、任何 `static` 成員（extension 不能宣告欄位、不能 override；若被搬的方法引用 State 的 static 成員，前綴 `_ThemeWorkshopScreenState.`）。
- 私有小 widget（檔案 3914 行起的 `_ParticleEffectOption`、`_ChatBackgroundColorRole`、`_AlternatingDoubleChevronHint(+State)`、`_HexColorInput(+State)`、`_ColorEntry`）整段搬到 part 檔，保持私有。

| 新檔 | 約略行號 | 內容 |
|---|---|---|
| `theme_workshop_background_logic.dart` | 100–469 | 背景槽讀寫、選圖、縮放/位移/模糊、聊天底色讀寫 |
| `theme_workshop_background_page.dart` | 470–1206 | `_openBackgroundPage`、槽位選擇器、角色綁定 |
| `theme_workshop_background_preview.dart` | 1207–1943 | 對話框預覽、直向首頁/聊天預覽、底色預覽與控制列 |
| `theme_workshop_bubbles.dart` | 2190–2805 | 背景選單鈕、AI 氣泡樣式、氣泡區塊 |
| `theme_workshop_particles_hero.dart` | 2806–3276 | 粒子區、快捷開關、Hero 卡、`_slider` |
| `theme_workshop_color_picker.dart` | 3277–3913 | 進階設定、顏色列、取色器、hex 轉換 |
| `theme_workshop_widgets.dart` | 3914–檔尾 | 私有 widget/類別 |

本體保留：0–99（宣告、欄位、initState）、178–238（偏好讀寫、`_applyPreset`、`_notifyThemeChanged`）、`dispose`、`build`（1944–2189）。

### 真機冒煙
主題工坊：切換預設 → 自訂一個顏色（hex 輸入）→ 換背景圖、拖縮放/位移/模糊 → 綁定背景到角色 → 改氣泡樣式與透明度 → 切粒子效果 → 回首頁與聊天頁確認生效。另跑 `test/theme_workshop_background_test.dart`、`test/theme_workshop_bubble_customization_test.dart`。

---

## 五、批次 3：`lib/screens/chat_screen.dart`（4183 行 → 目標本體 ≤ 1800）

新增 part（加入 121–125 行那串 `part` 宣告中）：

| 新檔 | 約略行號 | 內容 |
|---|---|---|
| `chat_screen_loading.dart` | 636–1287（`initState`/`dispose`/`didChangeMetrics` 留本體） | `_initializeChat`、`_loadSettings`、`_loadMessages`、記憶提議、月經時間線掃描、閉幕簽名 |
| `chat_screen_message_list.dart` | 2446–3393 | `_buildMessageList`、總結分隔線、窗口總結編輯器、手動總結選取列 |
| `chat_screen_app_bar.dart` | 3394–3856 | `_buildAppBar`、模型名、`_buildEmptyState` |
| `chat_screen_widgets.dart` | 3857–檔尾中屬於頂層私有類/函式的部分 | 核對後再搬 |

> `build`（1620–2121）、`_buildSearchCard`、`_buildRpContinuationHeader` 先留本體。1–500 行之間若有頂層私有類，先不動，列進報告。

### 真機冒煙
開聊天 → 上滑載入更早訊息 → 發訊息看串流 → 看 AppBar 模型名 → 空對話空狀態 → 手動總結選取 → 編輯窗口總結。

---

## 六、批次 4：`lib/screens/chat_screen_generation.dart`（5736 行）

本檔已經是 `extension _ChatGenerationMethods on _ChatScreenState`。拆法：新建 part，各用自己的 extension 名。

| 新檔 | extension 名 | 約略行號 |
|---|---|---|
| `chat_screen_stream.dart` | `_ChatStreamMethods` | 45–303（串流呈現、generation 狀態） |
| `chat_screen_prompt_parts.dart` | `_ChatPromptPartMethods` | 304–856（標籤抽取、金幣/時間 prompt、`_buildCommonStaticParts`、selfNotes delta） |
| `chat_screen_draw.dart` | `_ChatDrawMethods` | 857–945 |
| `chat_screen_compression.dart` | `_ChatCompressionMethods` | 946–1318（壓縮、窗口總結、回合記錄、維護觸發） |
| `chat_screen_failure_retry.dart` | `_ChatFailureRetryMethods` | 1319–1585 |
| `chat_screen_web_search.dart` | `_ChatWebSearchMethods` | 1586–1942 |
| `chat_screen_rp_continuation.dart` | `_ChatRpContinuationMethods` | 1996–2790 |

留在本檔：`_processScopedMemoryReply`、`_onSendMessage`、`_sendMessageLocked`（2791–4503，**1713 行單一方法**）、`_sendImageLocked`（4504–5644，**1141 行**）、`_buildUserProfilePrompt`、`_autoNameConversation`。

> ⚠️ **本輪不拆 `_sendMessageLocked` / `_sendImageLocked` 內部。** 這兩個方法拆內部屬於真重構，有行為風險。本批只需在報告中附一份「兩方法重複段落對照表」（行號對行號，標出可共用的步驟），留給下一輪由昭昭和晏辭決定。

### 真機冒煙
普通發訊息 → 中途停止 → 重試失敗訊息 → 觸發 web search 確認流程 → 發圖片 → 抽卡/畫圖 → RP 續章/新章 → 長對話觸發自動壓縮 → 自動命名對話。

---

## 七、批次 5：`home_screen.dart`（3318）與 `memory_screen.dart`（3277）

### home_screen（已有 `home_screen_profile.dart` part）
| 新檔 | 約略行號 |
|---|---|
| `home_screen_carousel.dart` | 1428–1986（角色輪播、心跳值、當前對話入口） |
| `home_screen_manual_summary.dart` | 1987–2303（手動總結、snack、心跳線、脈衝點） |
| `home_screen_sheets.dart` | 2304–3071（便利貼 sheet、對話列表、標題編輯、導航） |
| `home_screen_painters.dart` | 3072–檔尾（`_EcgPainter`、`_MiniYanciPainter`、`_SegmentedUsageIcon*`） |

冒煙：首頁滑輪播 → 切角色 → 開便利貼 → 開對話列表、改標題、刪除 → 手動總結全部 → 底部導航切頁。

### memory_screen（目前無 part，需先加）
| 新檔 | 約略行號 |
|---|---|
| `memory_screen_dialogs.dart` | 321–727（新增記憶、預算、發送上限、選取模式） |
| `memory_screen_curation.dart` | 728–1645（整理送審、掃描、關聯報告、分析選擇、刪除/歸檔確認） |
| `memory_screen_links.dart` | 1646–2277（關聯詳情、標籤、跨層連結、建議關聯、連結列表） |
| `memory_screen_archive.dart` | 2278–2754 |
| （`_MemoryCurationChoice`、`_MemoryConnectionReport` 兩個私有類可一起搬到 `memory_screen_curation.dart`） | 54–85 |

冒煙：記憶頁搜尋 → 新增 → 多選送審 → 掃描現有記憶 → 看關聯/蜘蛛網 → 歸檔、還原、永久刪除。

---

## 八、批次 6（可選，最後做）：`lib/memory/database_schema.dart`（3949）

- 新建 `database_migrations.dart`，`class _SchemaMigrations`，搬入 `_migrateToV*`、`_repair*`、`_backfill*`、`_cleanLegacySignature`、`_migrateWebSearchUsageProviders`（約 2135–3936）。
- `_onUpgrade` 內對應呼叫補前綴 `_SchemaMigrations.`；被遷移函式反向呼叫的 `_DatabaseSchema` helper（如 `_columnNames`、`_tableExists`、`_safeAddColumn`）補前綴 `_DatabaseSchema.`。
- **必跑** `test/database_schema_v33_test.dart` 與所有 migration 相關測試；真機用一份舊版備份（v1.5.x）還原再升級一次。

---

## 九、施工報告格式（每批交回）

```
批次 N：<檔名>
- 新檔與行數：
- 本體前/後行數：
- analyze：基線 X issues → 現在 Y issues（新增項逐條列出）
- test：基線失敗 A 個 → 現在 B 個（新增失敗逐條列出）
- 方法清單 diff：（貼結果）
- 未搬清單（及原因）：
- 需要昭昭真機確認的路徑：
```

---

## 十、回滾

- 單批回滾：`git revert <該批 commit>`
- 全部回滾：`git reset --hard <wip snapshot commit>`（**先確認沒有未提交的新工作**）
- 檔案級：從 `backups/split-20261019/` 複製回去，並用 `SHA256SUMS.txt` 校驗。
