# 貝殼經濟

## 它是做什麼的（一兩句話）
管理 user／角色貝殼餘額、商店商品、背包、贈送、轉帳、刮刮卡與結婚相關狀態，並把部分狀態以提示或卡片呈現給對話。

## 資料存在哪（資料表 / SharedPreferences key）
- `shop_items`：商品、價格、分類與圖片路徑。
- `backpack_items`：持有人、商品、數量、贈送者、星標與時間。
- `conversations`：窗口固定的角色／user 貝殼快照。
- 刮刮卡、轉帳與待贈送預約主要使用消息關聯資料及 SharedPreferences journal／operation key。
- 結婚狀態與日期由 `MarriageService` 的 SharedPreferences key 保存。

## 誰寫入（檔案：函式）
- 商品／背包：`lib/services/shop_service.dart:ShopService.addShopItem`、`updateShopItem`、`deleteShopItem`、`buyItem`、`grantToBackpack`、`removeOne`
- 贈送預約：`reserveShopGift`、`reserveBackpackGift`、`deliverPendingGift`
- 轉帳：`lib/services/transfer_service.dart:TransferService.acceptTransfer`、`declineTransfer`
- 刮刮卡／錢包：`lib/services/scratch_service.dart:ScratchService.applyWalletOperation`、`claimScratch`、`earn`、`spend`
- 結婚：`lib/services/marriage_service.dart:MarriageService.sign`、`markCharProposed`、`scanMessage`

## 誰讀取、怎麼注入（檔案：函式；注入 prompt 的哪一層）
- 商店／背包提示：`ShopService.buildShopListPromptText`、`buildPackPrompt`、`buildPackDelta`，由生成流程按需加入本輪內容。
- 窗口快照：`DatabaseHelper.getConversationPinnedCoinSnapshot` 與寫入方法，進 `windowPart`。
- 結婚已婚狀態：`MarriageService.staticPrompt`，進穩定窗口／靜態內容；證書事件用動態 note。
- 刮刮卡、轉帳與商店回覆透過消息處理器和工具 action 產生可見卡片或事件。

## 檢索方式（字面 / BM25 / 向量 / 名字觸發 / 無）
主要是 owner／character ID、conversation ID、商品 ID、消息 ID 與 SharedPreferences key 查找；沒有 BM25 或向量檢索。

## 日常 / RP 差異
貝殼、商店、背包與婚姻是共享功能，但 RP 的消息與故事狀態會另外受 RP 窗口／故事線 scope 影響。RP 世界書不會由貝殼資料自動替代。

## 相關開關
- 貝殼／商店／背包功能開關。
- 婚姻、刮刮卡、轉帳與相關工具提示詞開關。
- keep-alive 會保存窗口快照，但不應把瞬時 keep-alive pref 當跨設備資料。

## 量大時的風險
- 背包同一 owner／item／givenBy 有唯一性，但商品與背包數量增加會使列表與提示變長。
- SharedPreferences journal 若長期保存過多 operation，恢復與清理成本上升。
- 每輪把完整背包／商店內容放進 prompt 會造成 token 浪費；目前服務提供摘要／delta 入口。

## 相關測試檔
- `test/shop_service_test.dart`
- `test/transfer_service_test.dart`
- `test/scratch_service_test.dart`
- `test/marriage_service_test.dart`

## ❓ 不確定的地方
- 具體錢包／刮刮卡 journal 的 SharedPreferences key 及清理週期應以 `scratch_service.dart` 內當前常數為準，這裡不列出易變的完整 key 清單。
- 部分可見卡片是由消息 UI 依標籤渲染，並非所有顯示都由服務直接注入 prompt。
