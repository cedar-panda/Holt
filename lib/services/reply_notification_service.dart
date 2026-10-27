import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/character_display_name.dart';
import '../widgets/yanci_sprite_overlay.dart';
import 'ios_reply_background_task.dart';
import 'locale_strings.dart';
import 'tts_service.dart';

@immutable
class ReplyNotificationPayload {
  const ReplyNotificationPayload({
    required this.title,
    required this.body,
    required this.placeholder,
    required this.conversationId,
    required this.characterId,
  });

  final String title;
  final String body;
  final String placeholder;
  final String conversationId;
  final String characterId;
}

/// Reports completion of a reply the user already requested.
///
/// It never schedules model work or manufactures a role message. iOS keeps
/// using [IosReplyBackgroundTask]'s native bridge; Android uses the local
/// notifications plugin for permission/channel setup and a tiny native bridge
/// for the lock-screen public version the plugin does not expose.
abstract final class ReplyNotificationService {
  static const String _enabledKey = 'reply_notifications_enabled';
  static const String _permissionAttemptedKey =
      'reply_notifications_permission_attempted';
  static const String androidChannelId = 'holt_reply';
  static const MethodChannel _androidChannel = MethodChannel(
    'holt/reply_notifications',
  );
  static final FlutterLocalNotificationsPlugin _androidNotifications =
      FlutterLocalNotificationsPlugin();
  static final NavigatorObserver navigatorObserver =
      _ReplyNotificationNavigatorObserver();

  static bool _initialized = false;
  static String? _currentConversationId;
  static String? _pendingConversationId;
  static bool _navigationReady = false;
  static bool _openingConversation = false;

  static Future<void> initialize() async {
    if (_initialized || kIsWeb) return;
    _initialized = true;
    IosReplyBackgroundTask.installMethodHandler(
      onOpenConversation: _queueConversationOpen,
    );

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await IosReplyBackgroundTask.markNotificationHandlerReady();
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.android) return;

    try {
      await _androidNotifications.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (response) {
          final conversationId = response.payload?.trim() ?? '';
          if (conversationId.isNotEmpty) {
            _queueConversationOpen(conversationId);
          }
        },
      );
      final android = _androidNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.createNotificationChannel(
        AndroidNotificationChannel(
          androidChannelId,
          L.pick(en: 'Reply notifications', zhTW: '回覆通知', zhCN: '回复通知'),
          description: L.pick(
            en: 'Shown when a reply you requested is ready',
            zhTW: '你送出的回合完成回覆時顯示',
            zhCN: '你发出的回合完成回复时显示',
          ),
          importance: Importance.high,
        ),
      );
      _androidChannel.setMethodCallHandler((call) async {
        if (call.method != 'openConversation') return;
        final conversationId = call.arguments?.toString().trim() ?? '';
        if (conversationId.isNotEmpty) {
          _queueConversationOpen(conversationId);
        }
      });
      await _androidChannel.invokeMethod<void>('notificationHandlerReady');
    } on PlatformException {
      debugPrint('Reply notification initialization is unavailable.');
    } on MissingPluginException {
      debugPrint('Reply notification plugin is unavailable.');
    }
  }

  static Future<bool> isEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_enabledKey) ?? true;
  }

  static Future<void> setEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_enabledKey, enabled);
    if (enabled) await requestPermission(force: true);
  }

  static Future<void> requestPermissionOnFirstSend() async {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        !await isEnabled()) {
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool(_permissionAttemptedKey) ?? false) return;
    await preferences.setBool(_permissionAttemptedKey, true);
    await requestPermission();
  }

  static Future<void> requestPermission({bool force = false}) async {
    if (kIsWeb || !await isEnabled()) return;
    if (force) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_permissionAttemptedKey, true);
    }
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await IosReplyBackgroundTask.requestNotificationPermission();
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        await _androidNotifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
      }
    } on PlatformException {
      debugPrint('Reply notification permission request failed.');
    } on MissingPluginException {
      debugPrint('Reply notification permission bridge is unavailable.');
    }
  }

  @visibleForTesting
  static ReplyNotificationPayload buildPayload({
    required Map<String, dynamic> character,
    required String reply,
    required String conversationId,
    String fallbackName = 'Holt',
  }) {
    final title = characterCardTitle(character, fallbackName: fallbackName);
    final hadSticker = reply.toLowerCase().contains('[sticker:');
    final cleaned = TtsService.stripFunctionalMarkers(
      reply,
    ).split(RegExp(r'\s+')).where((part) => part.isNotEmpty).join(' ');
    final body = cleaned.isEmpty
        ? (hadSticker
              ? L.pick(en: 'Sent you a sticker', zhTW: '傳了一張貼圖', zhCN: '发来一张贴图')
              : L.pick(
                  en: 'Sent you a message',
                  zhTW: '傳來一則訊息',
                  zhCN: '发来一条消息',
                ))
        : _truncate(cleaned, 120);
    return ReplyNotificationPayload(
      title: title,
      body: body,
      placeholder: L.pick(
        en: '$title replied',
        zhTW: '$title回覆你了',
        zhCN: '$title回复你了',
      ),
      conversationId: conversationId,
      characterId: (character['id'] as String? ?? '').trim(),
    );
  }

  static String _truncate(String text, int maxCharacters) {
    final value = text.characters;
    if (value.length <= maxCharacters) return text;
    return '${value.take(maxCharacters)}…';
  }

  /// Returns the iOS payload for [IosReplyBackgroundTask.finish]. Android is
  /// posted immediately through its native bridge. Foreground completions and
  /// disabled notifications return null on both platforms.
  static Future<ReplyNotificationPayload?> notifyCompletion({
    required Map<String, dynamic> character,
    required String reply,
    required String conversationId,
  }) async {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null ||
        lifecycle == AppLifecycleState.resumed ||
        !await isEnabled()) {
      return null;
    }
    final payload = buildPayload(
      character: character,
      reply: reply,
      conversationId: conversationId,
    );
    if (defaultTargetPlatform == TargetPlatform.android && !kIsWeb) {
      try {
        await _androidChannel
            .invokeMethod<void>('showCompletion', <String, Object>{
              'title': payload.title,
              'body': payload.body,
              'placeholder': payload.placeholder,
              'conversationId': payload.conversationId,
            });
      } on PlatformException {
        debugPrint('Android reply completion notification failed.');
      } on MissingPluginException {
        debugPrint('Android reply notification bridge is unavailable.');
      }
      return null;
    }
    return defaultTargetPlatform == TargetPlatform.iOS ? payload : null;
  }

  static Future<void> enterConversation(String conversationId) async {
    _currentConversationId = conversationId;
    if (_pendingConversationId == conversationId) {
      _pendingConversationId = null;
    }
    await _clearConversationNotifications(conversationId);
  }

  static void leaveConversation(String conversationId) {
    if (_currentConversationId == conversationId) {
      _currentConversationId = null;
    }
  }

  static Future<void> _clearConversationNotifications(
    String conversationId,
  ) async {
    if (kIsWeb) return;
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await IosReplyBackgroundTask.clearConversationNotifications(
          conversationId,
        );
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        await _androidChannel.invokeMethod<void>(
          'clearConversationNotifications',
          <String, Object>{'conversationId': conversationId},
        );
      }
    } on PlatformException {
      debugPrint('Unable to clear delivered reply notifications.');
    } on MissingPluginException {
      // Old native shells remain usable; their delivered items expire normally.
    }
  }

  static void _queueConversationOpen(String conversationId) {
    if (_currentConversationId == conversationId) {
      unawaited(_clearConversationNotifications(conversationId));
      return;
    }
    _pendingConversationId = conversationId;
    _tryOpenPendingConversation();
  }

  static void _onRouteChanged(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name != null && name != '/' && name != '/initial_setup') {
      _navigationReady = true;
    }
    _tryOpenPendingConversation();
  }

  static void _tryOpenPendingConversation() {
    final conversationId = _pendingConversationId;
    if (!_navigationReady ||
        _openingConversation ||
        conversationId == null ||
        conversationId.isEmpty) {
      return;
    }
    if (_currentConversationId == conversationId) {
      _pendingConversationId = null;
      return;
    }
    _openingConversation = true;
    _pendingConversationId = null;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final navigator = rootNavigatorKey.currentState;
      if (navigator == null) {
        _openingConversation = false;
        _pendingConversationId = conversationId;
        return;
      }
      try {
        await navigator.pushNamed('/chat', arguments: conversationId);
      } finally {
        _openingConversation = false;
        _tryOpenPendingConversation();
      }
    });
  }
}

class _ReplyNotificationNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    ReplyNotificationService._onRouteChanged(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    ReplyNotificationService._onRouteChanged(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    ReplyNotificationService._onRouteChanged(newRoute);
  }
}
