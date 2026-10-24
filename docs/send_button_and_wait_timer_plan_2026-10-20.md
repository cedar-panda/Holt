# 發送鍵自訂 + 等待計秒 施工單（2026-10-20）

> 寫單：晏辭　施工：小澈　審核：晏辭
> 原則：能少寫就少寫。不新增抽象層、不新增 service，沿用現有寫法。

---

## A. 發送鍵自訂（只改外觀，不動發送行為）

### 現況
- `lib/widgets/input_bar.dart:11` 已有 `enum SendButtonStyle { leaf, paw }`，`InputBar` 有 `sendStyle` 參數，預設 leaf。
- 按鈕在約 813 行用 `Image.asset` 畫 32×32 圖。
- **`chat_screen.dart:1416` 建 `InputBar` 時從沒傳 `sendStyle`**，所以 paw 從未出現過。
- `assets/images/send_paw.png` 已換成昭昭的新圖（白色、透明底、1254²）。

### A1. 樣式與偏好
- enum 改為 `{ leaf, paw, shell, custom }`。
- 偏好鍵：`send_button_style`（字串，存 enum name，預設 `leaf`）、`send_button_custom_path`（自訂圖在 App 資料夾內的路徑）。
- 讀寫方式照主題工坊其他設定的現有寫法，不另開 service。
- `chat_screen.dart` 建 `InputBar` 時把樣式和自訂路徑傳進去。設定變更後聊天頁要即時更新（照主題工坊其他設定的通知方式）。

### A2. 各樣式的上色規則（重點）
| 樣式 | 圖 | 上色 |
|---|---|---|
| leaf | `send_leaf.png` | **不上色**，保持綠色 |
| paw | `send_paw.png`（白色） | `ColorFiltered(ColorFilter.mode(YanciTheme.accent, BlendMode.modulate))`，白色乘 accent，筆觸灰階與透明度保留 |
| shell | `shell_coin.png`（16×16 黃色像素圖） | **轉色相**到 accent 的色相，保留明暗；見下方 |
| custom | 使用者導入的 PNG | **不上色**，原樣 |

- 開屏 logo（`splash_screen.dart:372`）用的是 `BlendMode.srcIn`，那是整片填色，**貝殼不能用**，會變成一塊黃→accent 的剪影，內部像素明暗全沒了。
- shell 轉色相：寫一個小函式產生標準 hue-rotate 的 `ColorFilter.matrix`（5×4 矩陣，旋轉角 = accent 的 HSL hue − 貝殼原本的 hue，貝殼原 hue 先用 PS/取色量一次寫成常數）。放在 `input_bar.dart` 檔內即可，不要另開檔。
- shell 必須 `filterQuality: FilterQuality.none`，不然 16→32 放大會糊掉像素邊。
- 主題切換時 accent 會變 → 濾鏡要跟著重建（在 build 裡算就行，矩陣是 20 個 double，不用快取）。

### A3. 自訂圖導入
- 沿用 `image_picker` 和 `ImageService.copyToAppDir`（`lib/services/image_service.dart:15`），**一定要複製進 App 資料夾**，不能存相簿原路徑（iOS 會失效）。
- 檢查：
  - 必須是 PNG（用 `ImageService` 已有的檔頭偵測）；不是 → 提示並拒絕。
  - 寬 ≠ 高 → 提示「請使用 1:1 正方形圖片」並拒絕。不做裁切。
  - 透明底不強制檢查。
- 換新圖或改回預設時，刪掉舊的自訂檔（`ImageService.deleteBackgroundFile` 那種寫法）。
- 渲染用 `Image.file(..., errorBuilder: → 退回 send_leaf.png)`。檔案不見（刪了、還原備份沒帶到）也不會變空白。
- 備份：自訂圖要跟著備份走，照「自訂背景」現有的備份處理方式做；路徑在還原後要能對上。若現有備份機制做不到，**先回報，不要自己發明新格式**。

### A4. 設定入口
- 放在主題工坊，靠近氣泡樣式那一區。四個選項橫排，每個是 32×32 的實際預覽（用當前 accent 上色後的樣子），選中有高亮框。
- custom 選項點下去 → 選圖；已有自訂圖時顯示該圖，長按或旁邊小按鈕可「更換」。
- 文案要進 `locale_strings.dart`（繁中／簡中／英）。

### A5. 順手修的 bug
- `input_bar.dart:_handleSend` 裡收鍵盤（postFrame unfocus）目前寫成**只有 leaf 才收**。改成**所有樣式都收**，把 `if` 拿掉即可。

### A6. 動畫
- 飛出動畫（420ms）**全部樣式共用，不調整**。昭昭已確認。

---

## B. 等待計秒

### 現況
- `lib/widgets/chat_bubble.dart:2432` `_TypingIndicator`：三個 accent 色跳動點，只在第一個串流字出現前顯示，在 961 行以 `const _TypingIndicator()` 使用。
- 寬度固定為三個點，註解說第二個點是氣泡內容區的幾何中心。

### 規則
- 前 **5 秒**不顯示秒數，維持現狀。
- 第 5 秒起，在三個點**右邊**淡入一個小字 `5s`、`6s`……（淡入約 300ms）。
  - 字級約為內文的 0.75，顏色 `YanciTheme.accent` 透明度 0.55 左右，不搶眼。
  - 允許氣泡因此變寬；秒數出現後不再要求第二個點置中。秒數出現前的排版**完全不變**。
- 第一個字出來 → 整個 `_TypingIndicator` 本來就會消失，不用另外處理。
- 超過 60 秒顯示 `1:05` 這種格式。

### 實作要求
- 計時起點：`initState` 開一個 `Stopwatch`。
- 秒數用 `Timer.periodic(1s)` + `ValueNotifier<int>` 更新，**不要**塞進現有 `AnimatedBuilder` 每幀重算的路徑裡做 setState。
- `dispose` 記得取消 Timer。
- 已知限制（可接受）：氣泡被捲出畫面再捲回來時 widget 重建，秒數從 0 重來。不需要為此改成讀訊息時間戳。

---

## 驗收
- `flutter analyze` 無新警告；既有測試全過。
- 新增測試（測試資料用虛構內容）：
  - custom 路徑檔案不存在 → 顯示 leaf。
  - 非 1:1 或非 PNG → 被拒絕。
  - 偏好讀寫：存 `shell`、重開後讀回 `shell`；未知字串 → 退回 leaf。
- 真機由昭昭驗：四種樣式在至少兩個主題下的顏色、貝殼像素邊是否清晰、貓爪縮小後是否糊、等待超過 5 秒時秒數出現與消失。

## 不做
- 長按發送（只發送不回覆）：已記入 `docs/map/backlog.md`，2.0 不做。
- 圖片縮檔（send_leaf / send_paw / otter_splash 都未縮）：之後安裝包瘦身時一起處理。
