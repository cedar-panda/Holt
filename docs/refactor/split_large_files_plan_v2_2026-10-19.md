# 大檔拆分施工單 v2（純搬家）— 2026-10-19

> 規劃／審核：晏辭　施工：Codex　拍板：昭昭
> **取代** `split_large_files_plan_2026-10-19.md`（v1 用行號定位，今天的修改已讓行號全部漂移；v2 改用「方法名」定位）。
> 完成後交給晏辭審核，晏辭有權直接修改不滿意的地方。

---

## 〇、開工前提（缺一不可）

1. 今天這批改動（晏辭的 `docs/yanci_changes_2026-10-19.md` ＋ Codex 的 RP 連續性、關鍵詞召回）已經：`flutter analyze` 無新增錯誤、`flutter test` 無新增失敗、昭昭真機確認過、**已 commit**。
2. 工作區乾淨：`git status --short` 只剩 `backups/`、`Claude outputs/`、`*.bak` 這類不追蹤的東西。
3. 開新分支：`git checkout -b refactor/split-large-files`，記下起點 commit：`git rev-parse HEAD > docs/refactor/split_base.txt`。
4. 在 `docs/handoff.md` 寫一行「Codex：拆檔中，以下檔案請勿修改：…」，做完再刪。

> 前提不滿足就不要開工：拆檔會把「改到一半的邏輯」和「搬家」混在同一個 diff 裡，誰都審不出來。

---

## 一、鐵律

1. **純搬家。** 不改任何邏輯、條件、字串、SQL、常量、註解內容；不改名；不合併重複代碼；不「順手」修 bug（看到就寫進報告）。
2. **公開 API 一字不變。** `DatabaseHelper.xxx` 有 170+ 個成員被 120+ 個檔案呼叫，簽名、預設值、named 參數、`@visibleForTesting`、`///` 文檔全部原樣留在 `DatabaseHelper` 上。
3. **只用專案已有的兩種模式**，不發明新架構：
   - **DatabaseHelper（全是 static）** → 照 `database_memory_search.dart` 的 `_MemorySearch`：part 檔裡 `class _XxxStore { static ... }`，`DatabaseHelper` 上留一行 `=>` 轉發。
   - **State 類** → 照 `chat_screen_actions.dart`：`part of` ＋ `extension _XxxMethods on _YyyState { ... }`。
4. 不新增 mixin、抽象類、介面、DI、新的資料夾層級；不新增 package。
5. `@override` 方法、欄位、`initState`/`dispose`/`build`、State 的 `static` 成員**留在原類**（extension 不能有欄位、不能 override）。
6. 只對**新建**的 part 檔跑 `dart format`。
7. **由檔案底部往上搬**，每搬完一組跑一次 `flutter analyze <該資料夾>`。
8. 不確定能不能搬的方法：留在原處，寫進報告「未搬清單」。

---

## 二、自查工具（每批必跑，結果貼進報告）

```bash
python3 tool/split_audit.py --base $(cat docs/refactor/split_base.txt) '<這批的檔案 glob>'
```
- 原理：去掉空白／註解／尾逗號後，把代碼切成片段，比對拆前拆後的多重集合；換行、縮排、檔案位置都不影響結果。`DatabaseHelper.` 與 `_XxxStore.`／`_XxxMethods.` 這類前綴會自動忽略。
- **「只在拆檔前」必須是 0。** 不是 0 = 有代碼消失或被改，退回去修。
- 「只在拆檔後」只允許：part 宣告、類殼、extension 宣告、轉發 stub。
- 再加：`flutter analyze`（不多於基線）、`flutter test`（失敗不多於基線）。

---

## 三、批次（一批一個 commit，依序做）

### 批次 1：`lib/memory/database.dart`
新檔 `lib/memory/database_<組>.dart`，首行 `part of 'database.dart';`；`database.dart` 頂部的 `part` 宣告按字母序加入。

| 新檔 | 類名 | 搬哪些（按方法名） |
|---|---|---|
| `database_keep_alive.dart` | `_KeepAliveGuardStore` | `tryClaimKeepAlivePing`、`completeKeepAlivePing`、`releaseKeepAlivePing`、`resetKeepAlivePingGuard` |
| `database_voices.dart` | `_VoiceStore` | `saveVoice`、`getVoicePathByMessageId`、`getSavedVoices`、`updateVoiceName`、`deleteVoice`、`clearAllVoices`、`getVoiceCount` |
| `database_self_notes.dart` | `_SelfNoteStore` | `appendSelfNote` 到 `clearSelfNotes` 之間全部（含 `_selfNote*`、`_levenshtein`、`_normalizeSelfNote`、`_backfillCharacterSelfNotes`、`_deduplicateAllStoredSelfNotes`） |
| `database_characters.dart` | `_CharacterStore` | `insertCharacter`、`updateCharacter`、`updateCharacterWhisper`、`updateCharacterSignature`、`sanitizeCharacterUpdates`、`getCharacters`、`getCharacter`、`deleteCharacter` |
| `database_conversations.dart` | `_ConversationStore` | 「對話操作」段：`createConversation` 到 `deleteConversation`（含 RP storyline、chapter continuation、pinned summary／self-notes／coin snapshot、window summary id） |
| `database_messages.dart` | `_MessageStore` | 「訊息操作」段：`insertMessage` 到 `addCharacterFromPersonaCard`；另加 `updateMessageDraw`、`searchMessages`、`getLastMessageTime`、`getCharacterActiveDateKeys` |
| `database_message_invalidation.dart` | `_MessageInvalidation` | `_archiveMessageRevision`、`_invalidateSummaryChainForMessage`、`_rollbackInvalidatedRpStoryProjections`、`_restoreRpStoryCharacterAliases`、`_deleteInvalidatedRpTimelineProjection`、`updateMessageStatus` |
| `database_memories.dart` | `_MemoryStore` | 記憶 CRUD 與「歸檔操作」段（`insertMemory` … `_hardDeleteMemoryInTransaction`，不含表情包） |
| `database_notes_stickers.dart` | `_NoteStickerStore` | 「表情包操作」段＋「便利貼」段（含 `_ensureNoteCharacterColumn`） |
| `database_usage.dart` | `_UsageStore` | 「用量記錄」段：web search 預約／結算、`logUsage`、`getUsage*` |
| `database_saved_messages.dart` | `_SavedMessageStore` | 「收藏消息」段的 `saveMessage` … `deleteSavedMessage`（`_create*` 建表 helper 與 `_likeContains` 留本體） |
| `database_context_summaries.dart` | `_ContextSummaryStore` | 「上下文壓縮 CRUD」段：`insertContextSummary` … `deleteOldestContextSummary` |
| `database_context_keywords.dart` | `_ContextKeywordStore` | `insertContextKeywords` … `clearContextData`（⚠️ 先確認 Codex 的召回索引改動已合併） |
| `database_spider_web.dart` | `_SpiderWebStore` | `getSpiderWebLinks` 到檔尾 |

**留在本體**：靜態欄位、`database` getter、`_initDatabase`、`_onCreate/_onUpgrade/_safeAddColumn`、所有 `*ForTesting`、`_create*Table`、`rebuildMemoryFts`／`ensureAllSchemaTables`／`searchMemoriesByText`（已轉發 `_MemorySearch`）、頂部 enum 與 `ContextSummarySegmentDraft`、被多組共用的私有 helper（`_imagePathsFromRow`、`_likeContains`、`_generateWindowSummaryId` 等）。

**搬家規則**：
- 搬過去的代碼裡，原本不帶前綴引用的 `DatabaseHelper` 靜態成員一律補 `DatabaseHelper.`（`database`、`_windowIdRandom`、跨組呼叫的 `getCharacter(...)` 等）。漏補 analyze 會直接報 undefined。
- **transaction 裡的 `txn`／`db` 是參數，不要改成 `DatabaseHelper.database`。**
- public 方法：`DatabaseHelper` 上留 `=>` 轉發，簽名完全一致，`///` 留在 stub 上；Store 端參數預設值與 stub 相同。
- 只在組內使用的私有 helper：整個搬走，不留 stub。被別組呼叫的私有方法：留一個私有轉發，或呼叫端改成 `_XxxStore._方法`，二選一，全檔統一。

### 批次 2：`lib/screens/theme_workshop_screen.dart`
`part` ＋ `extension _ThemeWorkshopXxx on _ThemeWorkshopScreenState`。

| 新檔 | 搬哪些 |
|---|---|
| `theme_workshop_background_logic.dart` | `_loadBackgroundSlot` … `_pickChatBackgroundColor`（不含 `dispose`、`_loadColorHistory`、`_saveColorHistory`、`_loadShortcutPresets`、`_setShortcutPreset`、`_applyPreset`、`_notifyThemeChanged`） |
| `theme_workshop_background_page.dart` | `_openBackgroundPage`、`_buildBackgroundSlotSelector`、`_buildBackgroundCharacterBindingEntry`、`_openBackgroundCharacterBindings` |
| `theme_workshop_background_preview.dart` | `_bgDialogPreview` … `_offsetDisplay` |
| `theme_workshop_bubbles.dart` | `_buildBackgroundMenuButton` … `_bubbleColorRow` |
| `theme_workshop_particles_hero.dart` | `_buildParticleSection` … `_slider` |
| `theme_workshop_color_picker.dart` | `_showAdvancedSettings` … `_hexToColor` |
| `theme_workshop_widgets.dart` | 檔尾全部私有類（`_ParticleEffectOption`、`_ChatBackgroundColorRole`、`_AlternatingDoubleChevronHint(+State)`、`_HexColorInput(+State)`、`_ColorEntry`） |

### 批次 3：`lib/screens/chat_screen.dart`
加進現有那串 `part` 宣告：

| 新檔 | 搬哪些 |
|---|---|
| `chat_screen_loading.dart` | `_initializeChat`、`_retryInitialization`、`_loadSettings`、`_persistContextAnchor`、`_loadOlderForDisplay`、`_loadMessages`、`_refreshPendingMemoryActionCounts`、`_applyInlineMemoryProposal`、`_bindMemoryProposalsToMessage`、`_openMemoryReview`、`_scanExplicitMenstrualTimeline`、`_generateClosingSignatureOnDispose` |
| `chat_screen_message_list.dart` | `_buildMessageList`、`_buildSummaryRecordedDivider`、`_showWindowSummaryEditor`、`_buildManualSummarySelectionBar` |
| `chat_screen_app_bar.dart` | `_buildAppBar`、`_shortModelName`、`_fullModelName`、`_savedThemeColor`、`_buildEmptyState` |

`build`、`_buildSearchCard`、`_buildRpContinuationHeader`、檔頭的 `_ChatToolPermissionPolicy`／`_createChatToolRunner` 先不動。

### 批次 4：`lib/screens/chat_screen_generation.dart`
本檔已是 `extension _ChatGenerationMethods`；新建 part，各自用新的 extension 名：

| 新檔 | extension | 搬哪些 |
|---|---|---|
| `chat_screen_stream.dart` | `_ChatStreamMethods` | `_setGenerating` … `_invalidateGenerationState` |
| `chat_screen_prompt_parts.dart` | `_ChatPromptPartMethods` | `_extractXPostAndStrip` … `_hysteresisKeepFrom`（含 `_buildCommonStaticParts`、`_firstRoundSnapshotParts`、`_memoLinkNotice`、`_emotionScopeId`） |
| `chat_screen_draw.dart` | `_ChatDrawMethods` | `_runDrawAsync` |
| `chat_screen_compression.dart` | `_ChatCompressionMethods` | `_triggerContextCompression` … `_maybeRunTokenTriggeredMaintenance`（含窗口摘要的 static／dynamic／format） |
| `chat_screen_failure_retry.dart` | `_ChatFailureRetryMethods` | `_clearComposerIfUnchanged` … `_recoverEscapedGenerationFailure` |
| `chat_screen_web_search.dart` | `_ChatWebSearchMethods` | `_webSearchProviderLabel` … `_runWebSearchIntent` |
| `chat_screen_rp_continuation.dart` | `_ChatRpContinuationMethods` | `_persistUserFirstContinuationAction` … `_rpContinuationMessagePreview`（含 `_continuePreviousRpChapter`） |

留在本檔：`_processScopedMemoryReply`、`_onSendMessage`、`_sendMessageLocked`、`_sendImageLocked`、`_buildUserProfilePrompt`、`_autoNameConversation`。

⚠️ **不拆 `_sendMessageLocked`／`_sendImageLocked` 的內部。** 只交一份「兩方法重複段落對照表」（片段起訖、可共用的步驟），留給昭昭和晏辭決定。

### 批次 5：`home_screen.dart`、`memory_screen.dart`
- **home**（已有 `home_screen_profile.dart`）：
  - `home_screen_carousel.dart`：`_buildCharacterCarousel`、`_buildHeartbeatValue`、`_buildActiveConvEntry`
  - `home_screen_manual_summary.dart`：`_showManualSummaryOptions` … `_buildPulsingDot`
  - `home_screen_sheets.dart`：`_showNotesSheet`、`_showConversationList`、`_historyAction`、`_editConversationTitle`
  - `home_screen_painters.dart`：`_EcgPainter`、`_MiniYanciPainter`、`_SegmentedUsageIcon`、`_SegmentedUsageIconPainter`
- **memory_screen**（先加 `part`）：
  - `memory_screen_dialogs.dart`：`_showAddMemoryDialog`、`_showBudgetSettings`、`_onSearchChanged`、`_showSendLimitSettings`、選取模式四個方法
  - `memory_screen_curation.dart`：`_sendSelectedForCuration` … `_deleteSelectedMemories`，連同 `_MemoryCurationChoice`、`_MemoryConnectionReport`
  - `memory_screen_links.dart`：`_saveNodePosition` … `_showLinkList`
  - `memory_screen_archive.dart`：`_showArchive`、`_confirmDelete`

### 批次 6（可選，最後）：`database_schema.dart`
`_migrateToV*`、`_repair*`、`_backfill*`、`_cleanLegacySignature`、`_migrateWebSearchUsageProviders`、`_migrateToV82SharedPersonaBindings` 搬到 `database_migrations.dart` 的 `class _SchemaMigrations`；`_onUpgrade` 裡的呼叫補前綴，被遷移函式反向使用的 `_DatabaseSchema` helper 補 `_DatabaseSchema.`。必跑所有 migration 測試，並用一份 v1.5.x 的舊備份實際還原升級一次。

---

## 四、每批交回的報告（貼給昭昭轉交晏辭）

```
批次 N：<檔名>
commit：<hash>
新檔與行數：
本體前／後行數：
split_audit：只在拆檔前 = 0？（貼全文輸出）
analyze：基線 X → 現在 Y（新增項逐條列）
test：基線失敗 A → 現在 B（新增失敗逐條列）
未搬清單（及原因）：
真機要點的路徑：
```

---

## 五、晏辭審核流程（昭昭說「審拆檔」即開始）

1. 讀 `docs/handoff.md` 和報告。
2. 跑 `split_audit.py`，「只在拆檔前」不為 0 → 直接定位到片段並修正。
3. 抽查轉發 stub：簽名、預設值、`@visibleForTesting`、文檔是否完整。
4. 抽查補前綴的地方：`txn`／`db` 有沒有被誤改成 `DatabaseHelper.database`。
5. 不滿意的地方直接改，改完把修改記錄追加到報告最後，並再跑一次 audit。

## 六、回滾
- 單批：`git revert <該批 commit>`
- 全部：`git checkout <split_base.txt 裡的 commit> -- lib/`，或直接刪分支。
