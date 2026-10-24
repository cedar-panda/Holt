# 對話框多圖 + 加號收起 施工單（2026-10-20）

> 寫單：晏辭　施工：小澈　審核：晏辭
> 原則：簡單、少抽象。新元件各一個檔，不寫通用框架。

## 現況（已查證）
- **資料層已支援多圖**：`Message.imagePaths`（`image_paths_json`），送出時 `chat_screen_generation.dart:274` 會帶全部待發圖。資料庫、刪除、備份不用動。
- **問題在 UI**：掛起（`chat_screen.dart:1147`）和已發送（`chat_bubble.dart:826`）都用 `ImageCardStack`——它是 `PageView`，**一次只顯示一張**，要左右滑才看得到其他張，所以「發多圖看起來像只有一張」。
- 待發上限目前寫 `>= 10`（`chat_screen.dart:1458`），要改成 **9**。
- 加號選單狀態是 `input_bar.dart` 內的 `_drawerOpen`。

---

## A. 掛起（待發）：`PendingImageTray`（新檔 `lib/widgets/pending_image_tray.dart`）
取代 `chat_screen.dart:1147` 的 `ImageCardStack`。

- 橫向 `ListView`，可左右滑，放在輸入框上方。
- 每格 **正方形 68pt**，圓角跟主題一致，`BoxFit.cover`，格距 8。
- **叉叉**：視覺 22pt 圓（黑色 55% 底 + 白色 ×），**可點範圍 ≥ 32pt**。
  - **必須畫在格子內側**（右上角內縮 4pt），不能凸出格外——橫向 ListView 會裁掉凸出部分。
  - 點叉 = 移除該張，沿用現有 `removeAt(index)` 邏輯。
- 點縮圖 = 沿用 `_openPendingImagePreview`。
- 未滿 9 張時，**最後一格是 `＋`**（同尺寸虛線框），點了走現有選圖流程。
- 列尾或右上角小字 `n/9`。
- 滿 9 張時選圖要提示（沿用現有超量提示，數字改 9）。
- 縮圖解碼：`Image.file(..., cacheWidth: 68*dpr)`，不要解原圖尺寸。

## B. 已發送：`MessageImageGrid`（新檔 `lib/widgets/message_image_grid.dart`）
取代 `chat_bubble.dart:826` 的 `ImageCardStack`。

| 張數 | 排法 |
|---|---|
| 1 | 單張，保持原比例，最大寬度沿用現在單圖的寬度 |
| 2 | 兩張並排，正方形 |
| 3 | 一排三張，正方形 |
| ≥4 | **2×2 方格**；第 4 格若後面還有圖，蓋一層半透明黑 + 白字 `+N` |

- 格距 4，整體圓角，格內 `BoxFit.cover`，縮圖同樣用 `cacheWidth`。
- **點任一張 → 全螢幕檢視器，從那一張開始，可左右滑看這則訊息全部圖片**（含被 `+N` 蓋住的）。
  - `_openFullScreenImage` 目前只收單一路徑，改成收 `List<String> paths, int initialIndex`，內部用 `PageView`。
  - 舊的單圖呼叫點改成傳 `[path], 0`。
- **保留 `'generating'` 佔位路徑的處理**：該格顯示現在的生成中樣式，點擊無反應（現在 826 行的 `path == 'generating' ? null` 邏輯要搬過來）。
- 字是平鋪的、沒有氣泡底色，方格不要另外加框。

## C. `ImageCardStack`
- 兩處都換掉後若無其他引用，**刪除檔案**（`lib/widgets/image_card_stack.dart`）和其測試。先 grep 確認。

## D. 加號選單：點空白收起
- `InputBar` 新增 `ValueChanged<bool>? onDrawerOpenChanged`，`_drawerOpen` 變化時呼叫。
- `chat_screen.dart` 收到 `true` 時，在**訊息列表上方**蓋一層透明 `GestureDetector`（`behavior: opaque`，`onTapDown` → 呼叫 InputBar 收起）。
  - 這樣點空白**只收起，不會同時點到訊息／圖片／連結**。第一下觸碰只負責收起，這是刻意的。
  - InputBar 需要提供收起方法：用 `GlobalKey<InputBarState>` 或傳一個 `ValueNotifier<bool>` 進去，二選一，選簡單的。
- 另外在這些時機自動收起：輸入框取得焦點（開始打字）、按下發送。

---

## 驗收
- `flutter analyze` 無新警告，既有測試全過。
- 新增測試（虛構資料）：
  - Tray：3 張 → 3 格 + 1 個 `＋`；9 張 → 無 `＋`；點叉移除對應 index。
  - Grid：1/2/3/4/7 張的格數正確；7 張時顯示 `+3`；`'generating'` 格不可點。
- 昭昭真機看：叉叉好不好按、`+N` 是否清楚、全螢幕滑動、加號點空白收起時不會誤觸訊息。

## 不做
- 拖曳排序待發圖片（之後再說）。
- 長按發送（已在 backlog）。
