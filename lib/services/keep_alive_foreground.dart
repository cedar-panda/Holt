import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'keep_alive_service.dart';
import 'locale_strings.dart';

/// 前台服務殼 —— 鎖屏後 WorkManager 被 Doze 漂移（名義 15 分鐘實際
/// 30-60 分鐘），錯過 45-58 分鐘補針窗，保活名存實亡。
/// 前台服務豁免 Doze 的網絡與計時限制，是 Android 上唯一穩的腿。
///
/// 只在保活開關開啟的窗口期掛常駐通知；stop / 窗口到期即撤。
/// WorkManager 保留作雙保險（backgroundTick 冪等，不會重複 ping）。
@pragma('vm:entry-point')
void keepAliveForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    // 獨立 isolate：backgroundTick 從 prefs 全量重建，
    // 只在補針窗（45-58 分鐘）內真的發請求——5 分鐘粒度下天然冪等
    unawaited(KeepAliveService.backgroundTick());
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

/// 生成保護 —— 熄屏/退後台時 OS 凍結 CPU 與網絡，流式回覆中途卡斷。
/// 回覆開始掛前台服務（幾十秒的短命通知），流式結束即撤，
/// 期間豁免凍結，鎖屏也能把回覆跑完落庫。與保活通知互相獨立。
class GenerationForegroundGuard {
  GenerationForegroundGuard._();

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// 是否由本 guard 啟動（保活服務正掛著時不搶、也不誤停）
  static bool _startedByGuard = false;

  static Future<void> begin() async {
    if (!_supported) return;
    try {
      KeepAliveForeground._ensureInit();
      if (await FlutterForegroundTask.isRunningService) {
        _startedByGuard = false; // 保活服務在跑，它本身就豁免凍結
        return;
      }
      await FlutterForegroundTask.startService(
        serviceId: 772,
        notificationTitle: 'Holt',
        notificationText: L.pick(en: 'Replying…', zhTW: '回覆中……', zhCN: '回复中……'),
        callback: keepAliveForegroundCallback,
      );
      _startedByGuard = true;
    } catch (e) {
      developer.log('生成保護啟動失敗', error: e, name: 'GenerationGuard');
    }
  }

  static Future<void> end() async {
    if (!_supported || !_startedByGuard) return;
    _startedByGuard = false;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
      // 交錯場景：生成中退出窗口 → 保活已 start 但被本 guard 的服務擋住
      // 沒真正掛上 → 這裡撤掉後替它重掛，別把保活誤殺
      if (KeepAliveService.instance.isActive) {
        await KeepAliveForeground.start();
      }
    } catch (e) {
      developer.log('生成保護停止失敗', error: e, name: 'GenerationGuard');
    }
  }
}

class KeepAliveForeground {
  KeepAliveForeground._();

  static bool get _supported => !kIsWeb && Platform.isAndroid;
  static bool _inited = false;

  static void _ensureInit() {
    if (_inited) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'holt_keepalive',
        channelName: L.pick(
          en: 'Window keep-alive',
          zhTW: '窗口保活',
          zhCN: '窗口保活',
        ),
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5 * 60 * 1000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
    _inited = true;
  }

  /// 保活窗口開始（keep_alive_service 註冊後台任務的同一時機調用）
  static Future<void> start() async {
    if (!_supported) return;
    try {
      _ensureInit();
      // Android 13+ 通知權限：拒了服務照跑，只是通知不顯示
      await FlutterForegroundTask.requestNotificationPermission();
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        serviceId: 771,
        notificationTitle: 'Holt',
        notificationText: L.pick(
          en: 'Keeping the window warm…',
          zhTW: '窗口還熱著……',
          zhCN: '窗口还热着……',
        ),
        callback: keepAliveForegroundCallback,
      );
    } catch (e) {
      developer.log('前台保活服務啟動失敗', error: e, name: 'KeepAliveForeground');
    }
  }

  /// 保活結束/關閉（取消後台任務的同一時機調用）
  static Future<void> stop() async {
    if (!_supported) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      developer.log('前台保活服務停止失敗', error: e, name: 'KeepAliveForeground');
    }
  }
}
