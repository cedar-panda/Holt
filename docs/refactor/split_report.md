# 大檔拆分報告（批次 1～5）

- 基線：`19cd9943132acc93300de9dc605542e9fd26c902`
- 分支：`refactor/split-large-files`
- 原則：純搬家、公開 API 不變、不新增業務抽象、不拆 `_sendMessageLocked`／`_sendImageLocked` 內部。
- 共通門禁：每批最終 `flutter analyze lib test` 均為 `No issues found`；每批最終 `flutter test` 均為 961 項通過，與基線相同。

## 批次 1：`lib/memory/database.dart`

- commit：`7f4f8a0`
- 本體：6981 → 1716 行
- 新檔與行數：
  - `database_keep_alive.dart`：177
  - `database_voices.dart`：116
  - `database_self_notes.dart`：599
  - `database_characters.dart`：309
  - `database_conversations.dart`：989
  - `database_messages.dart`：668
  - `database_message_invalidation.dart`：463
  - `database_memories.dart`：630
  - `database_notes_stickers.dart`：134
  - `database_usage.dart`：525
  - `database_saved_messages.dart`：117
  - `database_context_summaries.dart`：1179
  - `database_context_keywords.dart`：165
  - `database_spider_web.dart`：238
- analyze：0 → 0。
- test：961 通過 → 961 通過。
- 未搬：schema/migration、memory search、reply variants 依施工單留在既有檔案。
- 真機要點：建角色／刪角色、訊息增刪、摘要與關鍵詞、記憶／自我註記、蛛網、用量、語音與 Keep-Alive 的讀寫。

```text
檔案（拆檔後）：18 個
    1716  lib/memory/database.dart
     309  lib/memory/database_characters.dart
     165  lib/memory/database_context_keywords.dart
    1179  lib/memory/database_context_summaries.dart
     989  lib/memory/database_conversations.dart
     177  lib/memory/database_keep_alive.dart
     630  lib/memory/database_memories.dart
     387  lib/memory/database_memory_search.dart
     463  lib/memory/database_message_invalidation.dart
     668  lib/memory/database_messages.dart
     134  lib/memory/database_notes_stickers.dart
     373  lib/memory/database_reply_variants.dart
     117  lib/memory/database_saved_messages.dart
    3949  lib/memory/database_schema.dart
     599  lib/memory/database_self_notes.dart
     238  lib/memory/database_spider_web.dart
     525  lib/memory/database_usage.dart
     116  lib/memory/database_voices.dart

只在拆檔前（應為 0）：0

只在拆檔後（只該是 part/類殼/轉發）：390
```

`只在拆檔後` 的 390 個片段全部是 `DatabaseHelper` 對各 store 的簽名保留轉發與 store 類殼；稽核工具完整輸出會列出大量參數片段，沒有業務實作差異。

## 批次 2：`theme_workshop_screen.dart`

- commit：`57c584e`
- 本體：4118 → 431 行
- 新檔與行數：
  - `theme_workshop_background_logic.dart`：301
  - `theme_workshop_background_page.dart`：741
  - `theme_workshop_background_preview.dart`：737
  - `theme_workshop_bubbles.dart`：620
  - `theme_workshop_color_picker.dart`：643
  - `theme_workshop_particles_hero.dart`：473
  - `theme_workshop_widgets.dart`：207
- analyze：0 → 0。
- test：961 通過 → 961 通過。
- 未搬：無；只保留 State 本體、欄位與生命週期。
- 真機要點：背景選取／綁定、預覽、氣泡、粒子、色彩選擇及各 bottom sheet。

```text
檔案（拆檔後）：8 個
     301  lib/screens/theme_workshop_background_logic.dart
     741  lib/screens/theme_workshop_background_page.dart
     737  lib/screens/theme_workshop_background_preview.dart
     620  lib/screens/theme_workshop_bubbles.dart
     643  lib/screens/theme_workshop_color_picker.dart
     473  lib/screens/theme_workshop_particles_hero.dart
     431  lib/screens/theme_workshop_screen.dart
     207  lib/screens/theme_workshop_widgets.dart

只在拆檔前（應為 0）：0

只在拆檔後（只該是 part/類殼/轉發）：6
  +[1] extension_ThemeWorkshopBackgroundLogicon_ThemeWorkshopScreenState
  +[1] extension_ThemeWorkshopBackgroundPageon_ThemeWorkshopScreenState
  +[1] extension_ThemeWorkshopBackgroundPreviewon_ThemeWorkshopScreenState
  +[1] extension_ThemeWorkshopBubbleMethodson_ThemeWorkshopScreenState
  +[1] extension_ThemeWorkshopColorPickerMethodson_ThemeWorkshopScreenState
  +[1] extension_ThemeWorkshopParticleHeroMethodson_ThemeWorkshopScreenState
```

## 批次 3：`chat_screen.dart`

- commit：`b43e60f`
- 本體：4183 → 2193 行（批次 4 新增 7 條 `part` 宣告後的最終行數）。
- 新檔與行數：
  - `chat_screen_loading.dart`：623
  - `chat_screen_message_list.dart`：963
  - `chat_screen_app_bar.dart`：465
- analyze：0 → 0。
- test：961 通過 → 961 通過。中途門禁抓到 extension 不能直接讀 State static；補上唯讀轉發 getter 後再跑全套並通過。
- 未搬：`build`、`_buildSearchCard`、`_buildRpContinuationHeader`、`_ChatToolPermissionPolicy`、`_createChatToolRunner`，依施工單保留。
- 真機要點：進窗載入、更早訊息、待確認記憶、訊息列表捲動、摘要編輯、頂欄模型選擇及空狀態。

```text
檔案（拆檔後）：4 個
    2193  lib/screens/chat_screen.dart
     465  lib/screens/chat_screen_app_bar.dart
     623  lib/screens/chat_screen_loading.dart
     963  lib/screens/chat_screen_message_list.dart

只在拆檔前（應為 0）：0

只在拆檔後（只該是 part/類殼/轉發）：14
  +[2] intget_renderPageSize=>_ChatScreenState._renderPageSize
  +[1] extension_ChatAppBarMethodson_ChatScreenState
  +[1] extension_ChatLoadingMethodson_ChatScreenState
  +[1] intget_ctxAnchorMaxMessages=>_ChatScreenState._ctxAnchorMaxMessages
  +[1] extension_ChatMessageListMethodson_ChatScreenState
  +[1] RegExpget_callActionRe=>_ChatScreenState._callActionRe
  +[1] RegExpget_callDividerRe=>_ChatScreenState._callDividerRe
  +[1] RegExpget_giftTagRe=>_ChatScreenState._giftTagRe
  +[1] RegExpget_marriageCertTagRe=>_ChatScreenState._marriageCertTagRe
  +[1] Stringget_marriageCertCharTag=>_ChatScreenState._marriageCertCharTag
  +[1] doubleget_chatHeaderHeight=>_ChatScreenState._chatHeaderHeight
  +[1] doubleget_messageListBottomBreathingSpace=>_ChatScreenState._messageListBottomBreathingSpace
  +[1] doubleget_composerViewportUnderlay=>_ChatScreenState._composerViewportUnderlay
```

## 批次 4：`chat_screen_generation.dart`

- commit：`99c4c5f`
- 本體：5865 → 3191 行
- 新檔與行數：
  - `chat_screen_stream.dart`：254
  - `chat_screen_prompt_parts.dart`：590
  - `chat_screen_draw.dart`：93
  - `chat_screen_compression.dart`：429
  - `chat_screen_failure_retry.dart`：272
  - `chat_screen_web_search.dart`：362
  - `chat_screen_rp_continuation.dart`：792
- analyze：0 → 0。
- test：961 通過 → 961 通過。
- 未搬：`_processScopedMemoryReply`、`_onSendMessage`、`_sendMessageLocked`、`_sendImageLocked`、`_buildUserProfilePrompt`、`_autoNameConversation`；邊界外的 `_rpContinuationSummaryPreview` 亦保留。
- 真機要點：文字／圖片送出、串流、停止生成、畫圖、壓縮摘要、失敗重試、搜尋二次回覆、RP 續接。

```text
檔案（拆檔後）：8 個
     429  lib/screens/chat_screen_compression.dart
      93  lib/screens/chat_screen_draw.dart
     272  lib/screens/chat_screen_failure_retry.dart
    3191  lib/screens/chat_screen_generation.dart
     590  lib/screens/chat_screen_prompt_parts.dart
     792  lib/screens/chat_screen_rp_continuation.dart
     254  lib/screens/chat_screen_stream.dart
     362  lib/screens/chat_screen_web_search.dart

只在拆檔前（應為 0）：0

只在拆檔後（只該是 part/類殼/轉發）：7
  +[1] extension_ChatCompressionMethodson_ChatScreenState
  +[1] extension_ChatDrawMethodson_ChatScreenState
  +[1] extension_ChatFailureRetryMethodson_ChatScreenState
  +[1] extension_ChatPromptPartMethodson_ChatScreenState
  +[1] extension_ChatRpContinuationMethodson_ChatScreenState
  +[1] extension_ChatStreamMethodson_ChatScreenState
  +[1] extension_ChatWebSearchMethodson_ChatScreenState
```

### `_sendMessageLocked`／`_sendImageLocked` 重複段落對照

以下只記錄可疑的共用階段，沒有在本批抽取或改寫：

| 階段 | 文字路徑 | 圖片路徑 | 未來可共用的步驟／不能硬併的差異 |
|---|---:|---:|---|
| 接受送出與輸入入庫 | 228–448 | 1937–2077 | generation serial、輸入入庫、UI 進入生成態可共用；圖片另含媒體複製與重試沿用路徑。 |
| 身分、設定與穩定前綴 | 449–626 | 2078–2214 | session identity、persona、工具能力、`_buildCommonStaticParts` 可考慮共用；圖片路徑另帶 vision 輸入能力。 |
| 動態 Prompt 與延遲副作用 | 627–994 | 2215–2518 | 記憶、日記、摘要、背包、商店、情緒、生物鐘、自我註記、首輪快照、時間與回覆樣式高度重複；提交副作用的時機必須維持成功後才落地。 |
| Adapter、歷史與串流 | 995–1166 | 2519–2705 | adapter 準備、歷史整理、串流佇列、停止／未完成處理可共用；圖文 request payload 不同。 |
| 可見正文、工具協議與後處理 | 1167–1752 | 2706–2958 | 內部標籤清理、記憶動作、可見文字定稿可共用；文字路徑含 web search 第二次 pass，不能直接套到圖片路徑。 |
| AI 入庫、維護與錯誤收尾 | 1753–1936 | 2959–3107 | AI 訊息入庫、完成回合、保活／摘要維護、API 失敗與 incomplete reply 收尾可共用；保留各路徑的媒體欄位與命名條件。 |

## 批次 5：`home_screen.dart`、`memory_screen.dart`

- commit：`7090c8e`
- 本體：`home_screen.dart` 3318 → 1492 行；`memory_screen.dart` 3277 → 875 行。
- 新檔與行數：
  - `home_screen_carousel.dart`：556
  - `home_screen_manual_summary.dart`：317
  - `home_screen_sheets.dart`：740
  - `home_screen_painters.dart`：250
  - `memory_screen_dialogs.dart`：404
  - `memory_screen_curation.dart`：948
  - `memory_screen_links.dart`：636
  - `memory_screen_archive.dart`：471
- analyze：0 → 0。
- test：961 通過 → 961 通過。
- 未搬：首頁／記憶頁生命週期、主 build、核心狀態與施工單未點名的視圖方法均保留。
- 真機要點：角色輪盤、手動摘要、記事／窗口清單、首頁畫筆、記憶新增與預算、批次整理、蛛網連結、封存／恢復／永久刪除。

```text
檔案（拆檔後）：11 個
    1492  lib/screens/home_screen.dart
     556  lib/screens/home_screen_carousel.dart
     317  lib/screens/home_screen_manual_summary.dart
     250  lib/screens/home_screen_painters.dart
    1444  lib/screens/home_screen_profile.dart
     740  lib/screens/home_screen_sheets.dart
     875  lib/screens/memory_screen.dart
     471  lib/screens/memory_screen_archive.dart
     948  lib/screens/memory_screen_curation.dart
     404  lib/screens/memory_screen_dialogs.dart
     636  lib/screens/memory_screen_links.dart

只在拆檔前（應為 0）：0

只在拆檔後（只該是 part/類殼/轉發）：8
  +[1] extension_HomeCarouselMethodson_HomeScreenState
  +[1] extension_HomeManualSummaryMethodson_HomeScreenState
  +[1] extension_HomeSheetMethodson_HomeScreenState
  +[1] doubleget_homeCarouselOffsetY=>_HomeScreenState._homeCarouselOffsetY
  +[1] extension_MemoryArchiveMethodson_MemoryScreenState
  +[1] extension_MemoryCurationMethodson_MemoryScreenState
  +[1] extension_MemoryDialogMethodson_MemoryScreenState
  +[1] extension_MemoryLinkMethodson_MemoryScreenState
```

## 最終狀態

- 批次 1～5 完成；批次 6 未開始。
- 沒有 push，沒有合併回原分支。
- 最終全量：`flutter analyze lib test` 無問題；`flutter test` 961 項全部通過。
- Step 0 額外門禁：PWA `node --test test/*.test.js` 23 項全部通過。

## 附錄：各批 `split_audit` 完整原始輸出

### 批次 1

```text
檔案（拆檔後）：18 個
    1716  lib/memory/database.dart
     309  lib/memory/database_characters.dart
     165  lib/memory/database_context_keywords.dart
    1179  lib/memory/database_context_summaries.dart
     989  lib/memory/database_conversations.dart
     177  lib/memory/database_keep_alive.dart
     630  lib/memory/database_memories.dart
     387  lib/memory/database_memory_search.dart
     463  lib/memory/database_message_invalidation.dart
     668  lib/memory/database_messages.dart
     134  lib/memory/database_notes_stickers.dart
     373  lib/memory/database_reply_variants.dart
     117  lib/memory/database_saved_messages.dart
    3949  lib/memory/database_schema.dart
     599  lib/memory/database_self_notes.dart
     238  lib/memory/database_spider_web.dart
     525  lib/memory/database_usage.dart
     116  lib/memory/database_voices.dart

只在拆檔前（應為 0）：0

只在拆檔後（只該是 part/類殼/轉發）：390
  +[9] requiredStringcharacterId
  +[5] String?characterId
  +[5] ContextModecontextMode=ContextMode.daily,StringcontinuityId='main'
  +[3] StringcharacterId='default'
  +[2] intlimit=50
  +[2] Stringreason='delete'
  +[2] StringcharacterId='default',ContextModecontextMode=ContextMode.daily,StringcontinuityId='main'
  +[2] requiredStringcharacterId,ContextMode?contextMode,StringcontinuityId='main'
  +[2] requiredStringrelationType,requireddoublestrength,requiredStringstatus,requiredStringsource,requiredStringreason
  +[1] staticFuture<bool>tryClaimKeepAlivePing(
  +[1] requiredStringconversationId,requiredStringcharacterId,requiredStringleaseToken,requiredDateTimenow,DurationclaimFor=constDuration(minutes:10)
  +[1] )=>tryClaimKeepAlivePing(conversationId:conversationId,characterId:characterId,leaseToken:leaseToken,now:now,claimFor:claimFor)
  +[1] staticFuture<bool>completeKeepAlivePing(
  +[1] requiredStringconversationId,requiredStringcharacterId,requiredStringleaseToken,requiredDateTimecompletedAt,Durationcooldown=constDuration(minutes:50)
  +[1] )=>completeKeepAlivePing(conversationId:conversationId,characterId:characterId,leaseToken:leaseToken,completedAt:completedAt,cooldown:cooldown)
  +[1] staticFuture<void>releaseKeepAlivePing(
  +[1] requiredStringconversationId,requiredStringcharacterId,requiredStringleaseToken,requiredDateTimereleasedAt
  +[1] )=>releaseKeepAlivePing(conversationId:conversationId,characterId:characterId,leaseToken:leaseToken,releasedAt:releasedAt)
  +[1] staticFuture<void>resetKeepAlivePingGuard(
  +[1] requiredStringconversationId,requiredStringcharacterId,requiredStringleaseToken,requiredDateTimenow
  +[1] )=>resetKeepAlivePingGuard(conversationId:conversationId,characterId:characterId,leaseToken:leaseToken,now:now)
  +[1] staticFuture<int>saveVoice(
  +[1] requiredStringfilePath,requiredStringname,String?messageId,String?sourceConversationId,String?sourceConversationTitle,StringcharacterId='default',intdurationMs=
  +[1] )=>saveVoice(filePath:filePath,name:name,messageId:messageId,sourceConversationId:sourceConversationId,sourceConversationTitle:sourceConversationTitle,character
  +[1] staticFuture<String?>getVoicePathByMessageId(StringmessageId)=>getVoicePathByMessageId(messageId)
  +[1] staticFuture<List<Map<String,dynamic>>>getSavedVoices(
  +[1] )=>getSavedVoices(characterId:characterId)
  +[1] staticFuture<void>updateVoiceName(intid,StringnewName)=>updateVoiceName(id,newName)
  +[1] staticFuture<void>deleteVoice(intid)=>deleteVoice(id)
  +[1] staticFuture<void>clearAllVoices(
  +[1] )=>clearAllVoices(characterId:characterId)
  +[1] staticFuture<int>getVoiceCount()=>getVoiceCount()
  +[1] staticFuture<void>updateMessageDraw(intmessageId,String?imagePath,StringmemoryLog)=>updateMessageDraw(messageId,imagePath,memoryLog)
  +[1] staticFuture<List<Map<String,dynamic>>>searchMessages(
  +[1] requiredStringkeyword,requiredStringcharacterId,Stringscope='current',ContextModecurrentMode=ContextMode.daily,intlimit=5
  +[1] )=>searchMessages(keyword:keyword,characterId:characterId,scope:scope,currentMode:currentMode,limit:limit)
  +[1] staticFuture<DateTime?>getLastMessageTime(StringcharacterId)=>getLastMessageTime(characterId)
  +[1] staticFuture<Set<String>>getCharacterActiveDateKeys(StringcharacterId,
  +[1] ContextModecontextMode=ContextMode.daily
  +[1] )=>getCharacterActiveDateKeys(characterId,contextMode:contextMode)
  +[1] staticFuture<bool>appendSelfNote(StringcharacterId,Stringnote)=>appendSelfNote(characterId,note)
  +[1] staticFuture<(
  +[1] boolaccepted,int?recordId
  +[1] )>appendSelfNoteDetailed(StringcharacterId,Stringnote,
  +[1] requiredboolretainLongTerm,Stringprovider='',StringmodelId='',StringmodelVersion='',StringsourceConversationId='',List<int>sourceMessageIds=const<int>[]
  +[1] )=>appendSelfNoteDetailed(characterId,note,retainLongTerm:retainLongTerm,provider:provider,modelId:modelId,modelVersion:modelVersion,sourceConversationId:source
  +[1] staticFuture<bool>deleteSelfNote(StringcharacterId,Stringnote)=>deleteSelfNote(characterId,note)
  +[1] @visibleForTestingstaticStringmergeSelfNotes(Stringexisting,Stringincoming)=>mergeSelfNotes(existing,incoming)
  +[1] staticFuture<String>getSelfNotes(StringcharacterId)=>getSelfNotes(characterId)
  +[1] staticFuture<String>getSelfNotesForPrompt(StringcharacterId,
  +[1] requiredintlimit
  +[1] )=>getSelfNotesForPrompt(characterId,limit:limit)
  +[1] staticFuture<List<CharacterSelfNote>>getSelfNoteRecords(StringcharacterId)=>getSelfNoteRecords(characterId)
  +[1] staticFuture<bool>setSelfNoteLocked(intid,boollocked)=>setSelfNoteLocked(id,locked)
  +[1] staticFuture<void>bindSelfNotesToMessage(Iterable<int>ids,intmessageId)=>bindSelfNotesToMessage(ids,messageId)
  +[1] staticFuture<void>_backfillCharacterSelfNotes(DatabaseExecutordb,
  +[1] )=>_backfillCharacterSelfNotes(db,characterId:characterId)
  +[1] staticFuture<void>_deduplicateAllStoredSelfNotes(Databasedb)=>_deduplicateAllStoredSelfNotes(db)
  +[1] staticFuture<void>clearSelfNotes(StringcharacterId)=>clearSelfNotes(characterId)
  +[1] staticFuture<void>insertCharacter(Map<String,dynamic>char)=>insertCharacter(char)
  +[1] staticFuture<void>updateCharacter(Stringid,Map<String,dynamic>updates)=>updateCharacter(id,updates)
  +[1] staticFuture<void>updateCharacterWhisper(Stringid,
  +[1] String?userText,String?modelText,String?source,bool?modelOverrideEnabled
  +[1] )=>updateCharacterWhisper(id,userText:userText,modelText:modelText,source:source,modelOverrideEnabled:modelOverrideEnabled)
  +[1] staticFuture<void>updateCharacterSignature(Stringid,Stringsignature)=>updateCharacterSignature(id,signature)
  +[1] String?updatedAt
  +[1] )=>sanitizeCharacterUpdates(updates,updatedAt:updatedAt)
  +[1] staticFuture<List<Map<String,dynamic>>>getCharacters()=>getCharacters()
  +[1] staticFuture<Map<String,dynamic>?>getCharacter(Stringid)=>getCharacter(id)
  +[1] staticFuture<void>deleteCharacter(Stringid)=>deleteCharacter(id)
  +[1] staticFuture<void>createConversation(Conversationconv)=>createConversation(conv)
  +[1] staticFuture<List<Map<String,Object?>>>getRpStorylines(StringcharacterId,
  +[1] boolincludeArchived=false
  +[1] )=>getRpStorylines(characterId,includeArchived:includeArchived)
  +[1] staticFuture<void>ensureDefaultRpStoryline(StringcharacterId)=>ensureDefaultRpStoryline(characterId)
  +[1] staticFuture<String>createRpStoryline(
  +[1] requiredStringcharacterId,requiredStringname
  +[1] )=>createRpStoryline(characterId:characterId,name:name)
  +[1] staticFuture<void>renameRpStoryline(
  +[1] requiredStringcharacterId,requiredStringstorylineId,requiredStringname
```

### 批次 2

```text
檔案（拆檔後）：8 個
     301  lib/screens/theme_workshop_background_logic.dart
     741  lib/screens/theme_workshop_background_page.dart
     737  lib/screens/theme_workshop_background_preview.dart
     620  lib/screens/theme_workshop_bubbles.dart
     643  lib/screens/theme_workshop_color_picker.dart
     473  lib/screens/theme_workshop_particles_hero.dart
     431  lib/screens/theme_workshop_screen.dart
     207  lib/screens/theme_workshop_widgets.dart

只在拆檔前（應為 0）：0

只在拆檔後（只該是 part/類殼/轉發）：6
  +[1] extension_ThemeWorkshopBackgroundLogicon_ThemeWorkshopScreenState
  +[1] extension_ThemeWorkshopBackgroundPageon_ThemeWorkshopScreenState
  +[1] extension_ThemeWorkshopBackgroundPreviewon_ThemeWorkshopScreenState
  +[1] extension_ThemeWorkshopBubbleMethodson_ThemeWorkshopScreenState
  +[1] extension_ThemeWorkshopColorPickerMethodson_ThemeWorkshopScreenState
  +[1] extension_ThemeWorkshopParticleHeroMethodson_ThemeWorkshopScreenState
```

### 批次 3

```text
檔案（拆檔後）：4 個
    2193  lib/screens/chat_screen.dart
     465  lib/screens/chat_screen_app_bar.dart
     623  lib/screens/chat_screen_loading.dart
     963  lib/screens/chat_screen_message_list.dart

只在拆檔前（應為 0）：0

只在拆檔後（只該是 part/類殼/轉發）：14
  +[2] intget_renderPageSize=>_ChatScreenState._renderPageSize
  +[1] extension_ChatAppBarMethodson_ChatScreenState
  +[1] extension_ChatLoadingMethodson_ChatScreenState
  +[1] intget_ctxAnchorMaxMessages=>_ChatScreenState._ctxAnchorMaxMessages
  +[1] extension_ChatMessageListMethodson_ChatScreenState
  +[1] RegExpget_callActionRe=>_ChatScreenState._callActionRe
  +[1] RegExpget_callDividerRe=>_ChatScreenState._callDividerRe
  +[1] RegExpget_giftTagRe=>_ChatScreenState._giftTagRe
  +[1] RegExpget_marriageCertTagRe=>_ChatScreenState._marriageCertTagRe
  +[1] Stringget_marriageCertCharTag=>_ChatScreenState._marriageCertCharTag
  +[1] doubleget_chatHeaderHeight=>_ChatScreenState._chatHeaderHeight
  +[1] doubleget_messageListBottomBreathingSpace=>_ChatScreenState._messageListBottomBreathingSpace
  +[1] doubleget_composerViewportUnderlay=>_ChatScreenState._composerViewportUnderlay
```

### 批次 4

```text
檔案（拆檔後）：8 個
     429  lib/screens/chat_screen_compression.dart
      93  lib/screens/chat_screen_draw.dart
     272  lib/screens/chat_screen_failure_retry.dart
    3191  lib/screens/chat_screen_generation.dart
     590  lib/screens/chat_screen_prompt_parts.dart
     792  lib/screens/chat_screen_rp_continuation.dart
     254  lib/screens/chat_screen_stream.dart
     362  lib/screens/chat_screen_web_search.dart

只在拆檔前（應為 0）：0

只在拆檔後（只該是 part/類殼/轉發）：7
  +[1] extension_ChatCompressionMethodson_ChatScreenState
  +[1] extension_ChatDrawMethodson_ChatScreenState
  +[1] extension_ChatFailureRetryMethodson_ChatScreenState
  +[1] extension_ChatPromptPartMethodson_ChatScreenState
  +[1] extension_ChatRpContinuationMethodson_ChatScreenState
  +[1] extension_ChatStreamMethodson_ChatScreenState
  +[1] extension_ChatWebSearchMethodson_ChatScreenState
```

### 批次 5

```text
檔案（拆檔後）：11 個
    1492  lib/screens/home_screen.dart
     556  lib/screens/home_screen_carousel.dart
     317  lib/screens/home_screen_manual_summary.dart
     250  lib/screens/home_screen_painters.dart
    1444  lib/screens/home_screen_profile.dart
     740  lib/screens/home_screen_sheets.dart
     875  lib/screens/memory_screen.dart
     471  lib/screens/memory_screen_archive.dart
     948  lib/screens/memory_screen_curation.dart
     404  lib/screens/memory_screen_dialogs.dart
     636  lib/screens/memory_screen_links.dart

只在拆檔前（應為 0）：0

只在拆檔後（只該是 part/類殼/轉發）：8
  +[1] extension_HomeCarouselMethodson_HomeScreenState
  +[1] extension_HomeManualSummaryMethodson_HomeScreenState
  +[1] extension_HomeSheetMethodson_HomeScreenState
  +[1] doubleget_homeCarouselOffsetY=>_HomeScreenState._homeCarouselOffsetY
  +[1] extension_MemoryArchiveMethodson_MemoryScreenState
  +[1] extension_MemoryCurationMethodson_MemoryScreenState
  +[1] extension_MemoryDialogMethodson_MemoryScreenState
  +[1] extension_MemoryLinkMethodson_MemoryScreenState
```
