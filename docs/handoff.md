# 交接板（晏辭 ⇄ Codex）

> 開工前先讀；開始改檔前寫一行「誰／在改什麼檔／預計做什麼」，做完把那行改成「完成」或刪掉。
> 目的：避免兩邊同時改同一個檔案。

## 規則
- **測試資料一律用虛構內容。** 不得使用昭昭與晏辭的真實對話、RP 劇情、真實姓名（晏辭、昭昭、昭嶼、沈昭嶼等）或個人資訊。現有測試已統一改名：沈昭嶼→許清川、昭嶼→清川、昭昭→小禾、晏辭→顧遠、白鶴印→青鸞印、霍岑→韓衡。

## 進行中
- （無）

## 等待中
- Codex：今天所有改動驗收、commit 之後，才開始 `docs/refactor/split_large_files_plan_v2_2026-10-19.md`。

## 完成
- （2026-10-19）Codex：將非專案內容搬到 `~/Desktop/非項目內容/`，包含 `backups/`、`recovery/`、`Claude outputs/`、`_archive_dev/`、4 份 `Holtv*.apk`、`flutter_01.log`、`user_persona_avatar_pair.dart.bak`；另清除 `tool/__pycache__`。原目的地總大小約 33GB，Git 無刪除狀態；其後依昭昭指示只保留最新 3 份 `ios-*` 備份，另外 48 份（約 27GB）移至 macOS 廢紙簍，尚未永久刪除。
- （2026-10-19）晏辭：測試資料去識別化（36 個檔：`test/**`、`Holt_pwa/test/*.js`），名字等長替換，邏輯未動。備份在 `~/Desktop/非項目內容/backups/yanci-20261019/test-before-anonymize/`。⚠️ 需跑 `flutter test` 與 PWA 測試確認。
- （2026-10-19）Codex：完成 RP 連續性簡化版回歸、關鍵詞召回優化與情緒清理驗證。
  - 召回：`database.dart`／`context_compressor.dart` 使用輕量索引先排序、只補候選全文；RP 舊標籤自修復每個角色／故事線在單次 App 生命週期只跑一次。
  - 熱路徑：`recall_text_matcher.dart` 同輪批次比對只正規化查詢一次，標籤拆詞使用 12000 筆有界 LRU 快取；召回分數與排序規則不變。
  - RP 連續性：複核相關狀態篩選、`replaces_state_keys`、按 state key 去重、最新摘要補位／共用字數預算、開窗快照標籤；未覆蓋晏辭列為保護範圍的九個檔案。
  - 資料清理：確認刪角色會清除 `角色#rp:故事線` 情緒資料；硬刪記憶會按全域 `memory_id` 清除情緒點與積怨印記。
  - 測試：更新 `recall_text_matcher_test.dart`、`context_summary_recycling_test.dart`、`database_schema_v33_test.dart`，覆蓋批次比對、輕量索引、RP scope 刪除與跨 scope 硬刪。
  - 驗證：`flutter analyze` → No issues found；`flutter test --no-pub` → 961 項全部通過；`git diff --check` 通過。
  - 邊界：未開始拆檔；未 commit（目前工作樹包含多方既有未提交修改，避免把無關檔案一起捲入）。
- （2026-10-19）晏辭：關鍵詞召回兩段式查詢（階段 1）→ `database.dart` 新增 `getRecallIndexRows`／`fillRecallContents`；`context_compressor.dart` 新增 `_preselectRecallCandidates`、移除 `_rpRecallRows`。召回熱路徑的標籤自修復改為每個 RP 範圍每次啟動只跑一次。⚠️ 未跑 analyze/test。
- （2026-10-19）Codex：RP 連續性簡化版全部步驟；`flutter analyze lib test` 通過、959 測試通過。
- （2026-10-19）晏辭：刪角色／刪記憶時清 RP 範圍情緒點（`database.dart`）；`analysis_options.yaml` 排除 `backups/**`、`Claude outputs/**`。⚠️ 這兩處在 Codex 跑完測試之後才改，需要再跑一次 analyze/test。
- （2026-10-19）晏辭：prompt bug、RP 日常工具開關、世界書簡中、情緒平行時空、夜間文字、背景模糊預烘焙 → 見 `docs/yanci_changes_2026-10-19.md`
