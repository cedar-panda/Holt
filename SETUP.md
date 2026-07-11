# Project Yanci — Phase 1 UI 骨架

## 設置步驟

### 1. 複製文件
把這個 zip 裡的文件覆蓋到你的 project_yanci 項目：

- `lib/` 資料夾整個覆蓋（會替換掉預設的 main.dart）
- `assets/` 資料夾放到項目根目錄

### 2. 修改 pubspec.yaml
打開 `pubspec.yaml`，找到 `flutter:` 那一段，加上 assets：

```yaml
flutter:
  uses-material-design: true

  assets:
    - assets/images/
```

### 3. 安裝依賴
```bash
flutter pub get
```

### 4. 運行
```bash
flutter run
```

## 文件結構說明

```
lib/
├── main.dart                    ← 入口 + 路由
├── theme/
│   └── app_theme.dart           ← 所有顏色、字體、間距
├── screens/
│   ├── splash_screen.dart       ← 開屏頁（水獺）
│   ├── home_screen.dart         ← 主頁（水晶球 + 底部導航）
│   ├── chat_screen.dart         ← 聊天頁
│   └── settings_screen.dart     ← 設定頁（API key + Model）
├── widgets/
│   ├── gradient_background.dart ← 共用漸變背景
│   ├── starfield_painter.dart   ← 星光粒子動畫
│   ├── chat_bubble.dart         ← 聊天氣泡
│   └── input_bar.dart           ← 輸入欄（毛玻璃 + 發送鍵）
├── services/                    ← Phase 1 後半段：API 對接
├── memory/                      ← Phase 2：記憶系統
└── models/                      ← Phase 2：資料模型

assets/
└── images/
    ├── otter_splash.png         ← 開屏水獺
    ├── send_leaf.png            ← 綠葉發送鍵
    └── send_paw.png             ← 獺爪發送鍵
```

## 目前狀態
- UI 骨架完成，可以看到所有頁面
- 聊天功能是假的（打字 → 固定回覆），等接 API
- 設定頁可以輸入但還沒存（等加 SharedPreferences）
- 水晶球是佔位，等你給素材

## 下一步（Phase 1 後半段）
1. 加 SharedPreferences 存 API key
2. 接 OpenRouter API
3. 實現 streaming 打字機效果
4. 接通測試

— 晏辭
