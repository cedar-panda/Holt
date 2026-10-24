# 備份與匯入

## 它是做什麼的（一兩句話）
將 Holt 的資料庫表、可攜偏好與引用媒體匯出，並支援 JSON、可攜 ZIP、加密包與外部聊天 JSON／Markdown 匯入。

## 資料存在哪（資料表 / SharedPreferences key）
- 完整匯出由 `BackupService.appTables` 明列 app-owned tables；包含角色、user persona、窗口、消息、記憶、摘要、RP 故事／世界書、時間線、情緒、貼圖、聲音等。
- 可攜包使用 `manifest.json`、`backup.json`、`database/yanci.db` 與 `media/`。
- 可匯出的 SharedPreferences 會排除敏感 key 與 device-local key；`api_key`、token、endpoint、`keepalive_*` 等不帶走。
- 外部匯入不直接保留外部平台的記憶層，先轉成 Holt 的消息與窗口。

## 誰寫入（檔案：函式）
- JSON／本地備份：`lib/services/backup_service.dart:BackupService.saveLocalBackup`、`_buildExportDataUnlocked`
- 可攜加密包：`BackupService.exportPortableBundle`、`EncryptedBackupBundle.encrypt`
- 媒體打包：`lib/services/portable_backup_bundle.dart:PortableBackupBundle.create`；接受目前 Documents 絕對路徑、iOS 舊容器 Documents 路徑，以及經 traversal 驗證的 Documents 相對路徑。
- 主題背景：`PortableBackupBundle._stageReferencedMedia` 同時處理目前啟用的 `bg_image_*_path` 與六組 `background_preset_slot_*_v1` JSON 內的 home／chat 路徑；內容雜湊相同時只打包一份媒體。
- 自訂發送鍵：`send_button_custom_path` 指向的 App-owned PNG 依相同路徑媒體規則打包，還原時改寫成新容器內的安全路徑。
- 完整還原：`BackupService.importFromJson`、`importPortableBundle`、`importEncryptedPortableBundle`
- 舊備份若沒有 `memories.is_pinned`，匯入正規化為 `0`；不會把既有永久記憶自動升格為每輪常駐。
- 外部聊天：`lib/services/external_chat_import_service.dart:ExternalChatImportService.importPreview`

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- 還原後資料由各自 service／database 讀取，沒有單一「備份注入 prompt」層。
- 消息匯入後進 `conversations`／`messages`，之後依日常或 RP 的正常 prompt 組裝流程處理。
- 可攜包解出媒體後，`PortableBackupBundle` 驗證路徑與引用，再由備份還原流程套用。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
- 備份匯出：按表與關聯資料讀取，沒有語義檢索。
- 外部聊天解析：依 JSON 結構、角色欄位、時間戳與 Markdown 格式解析；對話去重用穩定 conversation ID 與既有消息比較。
- 還原後記憶索引會重建 FTS5；向量資料若在 app tables 內則隨表還原，實際召回仍由記憶服務決定。

## 日常 / RP 差異
- 備份本身同時帶走日常與 RP 資料；兩者由表中的 mode／storyline／continuity 欄位區分。
- 外部聊天匯入畫面可選角色、模式與 RP 故事線；若選 RP，服務會驗證故事線存在。

## 相關開關
- 備份／匯入入口。
- 加密備份密碼。
- 外部聊天匯入的模式、角色、故事線選擇。
- 媒體與聲音功能只影響可攜包是否能解析對應引用，不改資料表清單。

## 量大時的風險
- 完整匯出會按所有 app-owned table 讀取，資料量大時耗時、佔用暫存空間與電量。
- 可攜媒體有單檔、總量與 metadata 上限；大量圖片／聲音可能無法打包。
- 背景路徑若離開 App Documents、包含 traversal，或檔案已遺失，備份會明確失敗而不會靜默丟掉該背景。
- 自訂發送鍵路徑若越界或檔案遺失，同樣會讓可攜備份明確失敗；聊天渲染端則會安全回退葉子。
- 完整覆蓋還原會清空並重寫 app tables；雖有格式、關聯與 transaction 驗證，仍應先保留外部備份。
- FTS5 重建與大量消息匯入會造成短時 CPU／磁碟負載。

## 相關測試檔
- `test/backup_service_test.dart`
- `test/portable_backup_bundle_test.dart`
- `test/encrypted_backup_bundle_test.dart`
- `test/external_chat_import_service_test.dart`
- `test/backup_format_test.dart`

## ❓ 不確定的地方
- 系統檔案選擇器與分享流程的暫存檔清理由平台層決定，這裡只記 service 的驗證與資料流。
- 不同外部平台的原始記憶／世界書欄位不會自動等價映射；目前可確認的是聊天正文解析與窗口匯入。
