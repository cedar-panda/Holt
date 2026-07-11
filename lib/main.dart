import 'dart:async';
import 'dart:io' show Platform;

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:workmanager/workmanager.dart';
import 'services/x_post_service.dart';
import 'theme/app_theme.dart';
import 'services/settings_manager.dart';
import 'services/locale_strings.dart';
import 'services/local_model_service.dart';
import 'services/holt_license_registry.dart';
import 'services/keep_alive_service.dart';
import 'services/character_timeline_service.dart';
import 'screens/splash_screen.dart';
import 'screens/home_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/api_settings_screen.dart';
import 'screens/cost_context_screen.dart';
import 'screens/voice_call_screen.dart';
import 'screens/tool_model_screen.dart';
import 'screens/character_card_screen.dart';
import 'screens/character_list_screen.dart';
import 'screens/memory_screen.dart';
import 'screens/sticker_library_screen.dart';
import 'screens/user_profile_screen.dart';
import 'screens/voice_library_screen.dart';
import 'screens/theme_workshop_screen.dart';
import 'screens/local_model_screen.dart';
import 'screens/usage_dashboard_screen.dart';
import 'screens/game_screen.dart';
import 'screens/developer_diagnostics_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/yanci_sprite_overlay.dart';

/// 全局主題通知器（任何頁面都能觸發重建）
final themeNotifier = ValueNotifier<int>(0);

/// WorkManager 後台任務入口。獨立 isolate，@pragma 保住不被 tree-shake。
/// 保活的後台補針邏輯全在 KeepAliveService.backgroundTick 裡，
/// 這裡只負責接住任務、吞掉異常（失敗就等下個週期，不讓系統重試疊加）。
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await KeepAliveService.backgroundTick();
    } catch (e) {
      debugPrint('後台保活 tick 失敗: $e');
    }
    return true;
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HoltLicenseRegistry.register();

  // Android 後台保活調度（iOS 不註冊，靠回前台補針）
  await _startupStep('background scheduler', () async {
    if (!kIsWeb && Platform.isAndroid) {
      await Workmanager().initialize(callbackDispatcher);
      // 前台保活服務的主/服務 isolate 通信端口（flutter_foreground_task）
      FlutterForegroundTask.initCommunicationPort();
    }
  });

  // 讀取主題偏好
  await _startupStep('theme', () async {
    final presetId = await ThemeSettings.getThemePreset();
    YanciTheme.setPreset(presetId);
    themeNotifier.value++;

    // 讀取自定義微調
    YanciTheme.bubbleOpacity = await ThemeSettings.getBubbleOpacity();
    YanciTheme.bubbleBrightness = await ThemeSettings.getBubbleBrightness();
    YanciTheme.bubbleRadius = await ThemeSettings.getBubbleRadius();
    YanciTheme.starEnabled = await ThemeSettings.getStarEnabled();
    YanciTheme.starDensity = await ThemeSettings.getStarDensity();
    YanciTheme.homeBackgroundImagePath =
        await ThemeSettings.getBackgroundImagePath('home');
    YanciTheme.homeBackgroundImageScale =
        await ThemeSettings.getBackgroundImageScale('home');
    YanciTheme.homeBackgroundImageOffsetX =
        await ThemeSettings.getBackgroundImageOffsetX('home');
    YanciTheme.homeBackgroundImageOffsetY =
        await ThemeSettings.getBackgroundImageOffsetY('home');
    YanciTheme.chatBackgroundImagePath =
        await ThemeSettings.getBackgroundImagePath('chat');
    YanciTheme.chatBackgroundImageScale =
        await ThemeSettings.getBackgroundImageScale('chat');
    YanciTheme.chatBackgroundImageOffsetX =
        await ThemeSettings.getBackgroundImageOffsetX('chat');
    YanciTheme.chatBackgroundImageOffsetY =
        await ThemeSettings.getBackgroundImageOffsetY('chat');

    // 讀取字體偏好
    final fontCn = await ThemeSettings.getFontChinese();
    final fontEn = await ThemeSettings.getFontEnglish();
    final fontScale = await ThemeSettings.getFontSizeScale();
    YanciTheme.setFont(fontCn, fontEn);
    YanciTheme.setFontScale(fontScale);
  });

  await _startupStep(
    'system overlay',
    () => _applySystemOverlay(YanciTheme.isDark),
  );

  // 讀取界面語言
  await _startupStep('locale', L.load);

  await _startupStep(
    'local model downloads',
    LocalModelService.initializeBackgroundDownloads,
  );

  // 恢復保活（如果有）
  await _startupStep('keep alive', KeepAliveService.instance.restore);

  // 全局像素小人開關
  await _startupStep('sprite overlay', SpriteOverlaySettings.load);

  // 時間線啟動維護：過期事件清理 + 健康自動回正（fire-and-forget）
  unawaited(
    UserSettings.getActiveCharacterId()
        .then((id) => CharacterTimelineService.startupMaintenance(id))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Startup step "timeline maintenance" failed: $error');
        }),
  );

  // Even if a platform plugin or a damaged preference failed above, there is
  // always a Flutter root. Each affected feature can retry from inside the app
  // instead of leaving the user on a permanent native splash/blank screen.
  runApp(const YanciApp());
}

Future<void> _startupStep(String name, FutureOr<void> Function() action) async {
  try {
    await action();
  } catch (error, stackTrace) {
    debugPrint('Startup step "$name" failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}

void _applySystemOverlay(bool isDark) {
  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
    ),
  );
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
}

/// 切換主題（兼容舊代碼，新代碼用主題工坊）
Future<void> toggleTheme() async {
  final newIsDark = !YanciTheme.isDark;
  YanciTheme.setDark(newIsDark);
  await ThemeSettings.saveThemePreset(YanciTheme.presetId);
  themeNotifier.value++;
  _applySystemOverlay(newIsDark);
}

/// 切換字體（任何地方都能呼叫）
Future<void> changeFont(String cn) async {
  final primary = YanciTheme.fontPairings.containsKey(cn) ? cn : 'Lora';
  final en = YanciTheme.fontPairings[primary] ?? 'LXGW WenKai TC';
  YanciTheme.setFont(primary, en);
  await ThemeSettings.saveFontChinese(primary);
  await ThemeSettings.saveFontEnglish(en);
  themeNotifier.value++;
}

void previewFontScale(double scale) {
  final next = scale.clamp(0.8, 1.5).toDouble();
  if ((YanciTheme.fontScale - next).abs() < 0.001) return;
  YanciTheme.setFontScale(next);
  themeNotifier.value++;
}

/// 切換字體大小（任何地方都能呼叫）
Future<void> changeFontScale(double scale) async {
  previewFontScale(scale);
  await ThemeSettings.saveFontSizeScale(YanciTheme.fontScale);
}

class YanciApp extends StatefulWidget {
  const YanciApp({super.key});

  @override
  State<YanciApp> createState() => _YanciAppState();
}

class _YanciAppState extends State<YanciApp> with WidgetsBindingObserver {
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // X OAuth2 回調 deep link（web 無此需求）
    if (!kIsWeb) {
      _linkSub = AppLinks().uriLinkStream.listen((uri) {
        if (uri.scheme == 'holt' && uri.host == 'x-callback') {
          XPostService.handleCallback(uri);
        }
      }, onError: (_) {});
    }
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Dart Timer 在後台被凍結，保活的 tick 不會走。
    // 回前台時補針：距上次請求 50-58 分鐘 → 續 TTL；超了 → 不白燒。
    if (state == AppLifecycleState.resumed) {
      KeepAliveService.instance.onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: themeNotifier,
      builder: (_, _, _) => MaterialApp(
        title: 'Holt',
        debugShowCheckedModeBanner: false,
        navigatorKey: rootNavigatorKey,
        locale: switch (L.locale) {
          'zh_CN' => const Locale('zh', 'CN'),
          'zh_TW' => const Locale('zh', 'TW'),
          _ => const Locale('en', 'US'),
        },
        supportedLocales: const [
          Locale('zh', 'TW'),
          Locale('zh', 'CN'),
          Locale('en', 'US'),
        ],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        // 像素小人住在最頂層：換什麼路由都在，狀態不丟
        builder: (context, child) {
          final reduceMotion = MediaQuery.disableAnimationsOf(context);
          return TickerMode(
            enabled: !reduceMotion,
            child: YanciSpriteLayer(child: child ?? const SizedBox.shrink()),
          );
        },
        theme: YanciTheme.themeData,
        initialRoute: '/',
        routes: {
          '/': (context) => const SplashScreen(),
          '/settings': (context) => const SettingsScreen(),
          '/home': (context) => const HomeScreen(),
          '/api_settings': (context) => const ApiSettingsScreen(),
          '/cost_context': (context) => const CostContextScreen(),
          '/voice_call': (context) => const VoiceCallScreen(),
          '/tool_model': (context) => const ToolModelScreen(),
          '/character_list': (context) => const CharacterListScreen(),
          '/user_profile': (context) => const UserProfileScreen(),
          '/theme_workshop': (context) => const ThemeWorkshopScreen(),
          '/local_models': (context) => const LocalModelScreen(),
          '/usage': (context) => const UsageDashboardScreen(),
          '/game': (context) => const GameScreen(),
          '/developer_diagnostics': (context) =>
              const DeveloperDiagnosticsScreen(),
        },
        onGenerateRoute: (settings) {
          if (settings.name == '/memory') {
            final args = settings.arguments;
            String charId;
            var initialTab = 0;
            if (args is Map) {
              charId = args['characterId'] as String? ?? 'default';
              initialTab = args['initialTab'] as int? ?? 0;
            } else {
              charId = args as String? ?? 'default';
            }
            return MaterialPageRoute(
              builder: (_) =>
                  MemoryScreen(characterId: charId, initialTab: initialTab),
            );
          }
          if (settings.name == '/sticker') {
            final charId = settings.arguments as String? ?? 'default';
            return MaterialPageRoute(
              builder: (_) => StickerLibraryScreen(characterId: charId),
            );
          }
          if (settings.name == '/voice_library') {
            // voice_library 用 didChangeDependencies 讀 arguments
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => const VoiceLibraryScreen(),
            );
          }
          if (settings.name == '/chat') {
            final args = settings.arguments;
            String convId;
            var manualSummarySelection = false;
            if (args is Map) {
              convId = args['conversationId'] as String? ?? '';
              manualSummarySelection = args['manualSummarySelection'] == true;
            } else {
              convId = args as String;
            }
            return MaterialPageRoute(
              builder: (context) => ChatScreen(
                conversationId: convId,
                startManualSummarySelection: manualSummarySelection,
              ),
            );
          }
          if (settings.name == '/character') {
            final charId = settings.arguments as String?;
            return MaterialPageRoute(
              builder: (context) => CharacterCardScreen(characterId: charId),
            );
          }
          return null;
        },
      ),
    );
  }
}
