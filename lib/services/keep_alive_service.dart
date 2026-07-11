import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../memory/database.dart';
import '../services/api_adapter.dart';
import '../services/keep_alive_foreground.dart';
import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../services/token_estimator.dart';

/// 角色心跳事件。
class KeepAliveHeartbeat {
  final String characterId;
  final int value;

  const KeepAliveHeartbeat({required this.characterId, required this.value});
}

/// claimVisibleWindow 覆蓋前暫存的原保活窗口。
/// 用途：偷看別的對話但沒發消息就退出時，原窗口的保活能原樣恢復。
class _PausedWindow {
  final String conversationId;
  final String characterId;
  final DateTime? startTime;
  final DateTime? lastRequestAt;
  final List<Map<String, String>>? messages;
  final StructuredPrompt? structuredPrompt;
  final ApiAdapter? adapter;
  final String? model;
  final String? provider;

  const _PausedWindow({
    required this.conversationId,
    required this.characterId,
    required this.startTime,
    required this.lastRequestAt,
    required this.messages,
    required this.structuredPrompt,
    required this.adapter,
    required this.model,
    required this.provider,
  });
}

/// 關窗保活服務。
///
/// 只有已確認支持 1 小時 cache TTL 的模型會啟動。無此能力的模型不做
/// 關窗 ping，避免把隱藏心跳變成額外燒錢請求。
class KeepAliveService {
  static KeepAliveService? _instance;
  Timer? _timer;
  String? _conversationId;
  String? _characterId;
  DateTime? _startTime;
  bool _active = false;

  List<Map<String, String>>? _cachedMessages;
  StructuredPrompt? _cachedStructuredPrompt;
  ApiAdapter? _cachedAdapter;
  String? _cachedModel;
  String? _cachedProvider;

  /// 不再硬性 6 小時，由用戶設定決定（默認 2 小時）
  static Duration _maxDuration = const Duration(hours: 2);

  /// tick 制：timer 每 5 分鐘醒一次，只在「距上次成功請求 ≥50 分鐘」時才 ping。
  /// 好處：真消息（rememberActiveWindow）會刷新錨點，永遠不會跟正常聊天重複燒；
  /// app 從後台回來（onAppResumed）也走同一個判斷，補針邏輯只有一份。
  static const Duration _tickInterval = Duration(minutes: 5);
  static const Duration _refreshAfter = Duration(minutes: 50);

  /// resume 補針上限：超過 58 分鐘緩存幾乎必死（1h TTL），
  /// 再 ping 是全量重建，不如留給下一條真消息。
  static const Duration _resumeRefreshMax = Duration(minutes: 58);

  /// 後台補針閾值：WorkManager 名義 15 分鐘一醒（Doze 下會漂移），
  /// 相對上次請求的落點大約在 45/60 分鐘——45 就續，等 50 會整輪錯過。
  static const Duration _bgRefreshAfter = Duration(minutes: 45);

  /// WorkManager 週期任務標識
  static const String _bgTaskUniqueName = 'holt_keepalive_bg';
  static const String _bgTaskName = 'keepAliveTick';
  static int _quietStartHour = 23;
  static int _quietEndHour = 7;

  /// 距上次「真正打到 API」的請求（真消息或成功的保活 ping）
  DateTime? _lastRequestAt;

  /// 被 claimVisibleWindow 覆蓋掉的原保活窗口（等 resumePausedWindow 撿回）
  _PausedWindow? _pausedWindow;

  static const String _keyLegacyHeartbeat = 'keepalive_heartbeat';
  static const String _keyActiveConvId = 'keepalive_conv_id';
  static const String _keyActiveCharId = 'keepalive_char_id';
  static const String _keyActiveConvTitle = 'keepalive_conv_title';
  static const String _keyStartTime = 'keepalive_start_time';
  static const String _keyCachedMessages = 'keepalive_cached_messages';
  static const String _keyCachedStaticPrompt = 'keepalive_cached_static_prompt';
  static const String _keyCachedProfilePrompt =
      'keepalive_cached_profile_prompt';
  static const String _keyCachedDynamicPrompt =
      'keepalive_cached_dynamic_prompt';
  static const String _keyCachedModel = 'keepalive_cached_model';
  static const String _keyCachedProvider = 'keepalive_cached_provider';
  static const String _keyLastRequestAt = 'keepalive_last_request_at';

  KeepAliveService._();

  /// 從設定加載延續時長 + 安靜時段
  static Future<void> _loadSettings() async {
    final hours = await MemorySettings.getKeepAliveDurationHours();
    _maxDuration = Duration(hours: hours);
    _quietStartHour = await MemorySettings.getQuietStartHour();
    _quietEndHour = await MemorySettings.getQuietEndHour();
  }

  static KeepAliveService get instance {
    _instance ??= KeepAliveService._();
    return _instance!;
  }

  /// 啟動關窗保活。由 chat_screen.dispose 傳入最後一次完整請求上下文。
  Future<void> start({
    required String conversationId,
    required String characterId,
    List<Map<String, String>>? messages,
    StructuredPrompt? structuredPrompt,
    ApiAdapter? adapter,
    String? model,
    String? provider,
  }) async {
    await _cancelRenewalOnly();

    // dispose 傳進來的是「早已發過」的上下文，不是新請求——
    // 錨點必須保留在上次真正打 API 的時刻，否則第一針會虛後移，
    // 落點超過 1h TTL 時緩存已死，ping 變成全量重寫。
    await rememberActiveWindow(
      conversationId: conversationId,
      characterId: characterId,
      messages: messages,
      structuredPrompt: structuredPrompt,
      adapter: adapter,
      model: model,
      provider: provider,
      refreshAnchor: false,
    );
  }

  void _startTicker() {
    _timer?.cancel();
    _timer = Timer.periodic(_tickInterval, (_) => _maybePing());
  }

  /// Android 後台雙腿：WorkManager 週期任務（Doze 下會漂移，兜底）
  /// + 前台服務（鎖屏不死的主力，常駐通知）。
  /// iOS 系統不保證後台執行時機，都不註冊——靠 onAppResumed 補針。
  Future<void> _registerBackgroundTask() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await Workmanager().registerPeriodicTask(
        _bgTaskUniqueName,
        _bgTaskName,
        frequency: const Duration(minutes: 15),
      );
    } catch (e) {
      developer.log('後台保活任務註冊失敗', error: e, name: 'KeepAliveService');
    }
    // 前台服務：只在保活窗口期掛通知（backgroundTick 冪等，雙腿不重複 ping）
    await KeepAliveForeground.start();
  }

  Future<void> _cancelBackgroundTask() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await Workmanager().cancelByUniqueName(_bgTaskUniqueName);
    } catch (e) {
      developer.log('後台保活任務取消失敗', error: e, name: 'KeepAliveService');
    }
    await KeepAliveForeground.stop();
  }

  /// WorkManager 後台任務入口（獨立 isolate，不共享主 isolate 內存）。
  /// 全部狀態從 SharedPreferences 重建；只在補針窗口內真的發請求。
  static Future<void> backgroundTick() async {
    final prefs = await SharedPreferences.getInstance();
    final convId = prefs.getString(_keyActiveConvId);
    final charId = prefs.getString(_keyActiveCharId);
    final startTime = DateTime.tryParse(prefs.getString(_keyStartTime) ?? '');
    final lastRequestAt = DateTime.tryParse(
      prefs.getString(_keyLastRequestAt) ?? '',
    );
    if (convId == null ||
        charId == null ||
        startTime == null ||
        lastRequestAt == null) {
      return;
    }

    // 後台 isolate 也要讀設定
    final keepAliveOn = await MemorySettings.getKeepAliveEnabled();
    if (!keepAliveOn) return;
    await _loadSettings();

    final now = DateTime.now();
    if (now.difference(startTime) >= _maxDuration) {
      // 窗口結束，順手把週期任務摘掉，別空轉到天荒地老
      await instance._cancelBackgroundTask();
      return;
    }
    if (_isQuietHours(now)) return;

    final elapsed = now.difference(lastRequestAt);
    if (elapsed < _bgRefreshAfter || elapsed > _resumeRefreshMax) return;

    // 後台 isolate 的 instance 是全新的：從 prefs 重建再 ping
    final svc = instance;
    svc._conversationId = convId;
    svc._characterId = charId;
    svc._startTime = startTime;
    svc._lastRequestAt = lastRequestAt;
    svc._cachedMessages = _decodeMessages(prefs.getString(_keyCachedMessages));
    final staticPrompt = prefs.getString(_keyCachedStaticPrompt);
    final profilePrompt = prefs.getString(_keyCachedProfilePrompt);
    final dynamicPrompt = prefs.getString(_keyCachedDynamicPrompt);
    if (staticPrompt != null || dynamicPrompt != null) {
      svc._cachedStructuredPrompt = StructuredPrompt(
        staticPart: staticPrompt ?? '',
        profilePart: profilePrompt,
        dynamicPart: dynamicPrompt ?? '',
      );
    }
    svc._cachedModel = prefs.getString(_keyCachedModel);
    svc._cachedProvider = prefs.getString(_keyCachedProvider);
    svc._active = true;
    await svc._ping();
    svc._active = false;
  }

  /// 記住最後真正發過消息的窗口。這是首頁「正在聊」入口的來源；
  /// 即使沒有 1 小時 TTL 保活，也要持久化。
  Future<void> rememberActiveWindow({
    required String conversationId,
    required String characterId,
    List<Map<String, String>>? messages,
    StructuredPrompt? structuredPrompt,
    ApiAdapter? adapter,
    String? model,
    String? provider,
    bool refreshAnchor = true,
  }) async {
    // 有真消息落地 = 保活歸屬換人，claim 暫存的舊窗口作廢
    _pausedWindow = null;

    final sameConv = _conversationId == conversationId;
    if (refreshAnchor ||
        !sameConv ||
        _lastRequestAt == null ||
        _startTime == null) {
      final now = DateTime.now();
      _startTime = now;
      // refreshAnchor = 剛發過一條真消息，緩存錨點刷新；
      // refreshAnchor=false（dispose 路徑）且同窗口 → 保留原錨點
      _lastRequestAt = now;
    }
    _conversationId = conversationId;
    _characterId = characterId;
    _cachedMessages = _copyMessages(messages);
    _cachedStructuredPrompt = structuredPrompt;
    _cachedAdapter = adapter;
    _cachedModel = model;
    _cachedProvider = provider;

    await _persistActiveWindow();
    await _ensureRenewalTicker();
  }

  /// 可見聊天窗口接管「正在聊」歸屬，但不憑空重建 prompt。
  ///
  /// 打開另一個窗口時，舊窗口的 timer/background ping 必須停下；新的窗口要等
  /// 下一條真消息產生完整 StructuredPrompt 後，才會重新啟動續期 tick。
  Future<void> claimVisibleWindow({
    required String conversationId,
    required String characterId,
    List<Map<String, String>>? messages,
  }) async {
    if (_conversationId == conversationId) return;

    // 覆蓋前把還有完整保活上下文的原窗口暫存起來——
    // 沒有這一步，「點開別的對話看一眼」就會無聲殺死保活（prefs 裡的
    // cached prompt / 錨點會被下面的 _persistActiveWindow 一起清掉）。
    if (_conversationId != null &&
        _characterId != null &&
        _cachedStructuredPrompt != null &&
        _lastRequestAt != null) {
      _pausedWindow = _PausedWindow(
        conversationId: _conversationId!,
        characterId: _characterId!,
        startTime: _startTime,
        lastRequestAt: _lastRequestAt,
        messages: _cachedMessages,
        structuredPrompt: _cachedStructuredPrompt,
        adapter: _cachedAdapter,
        model: _cachedModel,
        provider: _cachedProvider,
      );
    }

    await _cancelRenewalOnly();
    _conversationId = conversationId;
    _characterId = characterId;
    _startTime = DateTime.now();
    _lastRequestAt = null;
    _cachedMessages = _copyMessages(messages);
    _cachedStructuredPrompt = null;
    _cachedAdapter = null;
    _cachedModel = null;
    _cachedProvider = null;

    await _persistActiveWindow();
  }

  /// 停止保活（新窗口第一句話、回到原窗口時調用）。
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _active = false;
    _pausedWindow = null;
    await _cancelBackgroundTask();
    _conversationId = null;
    _characterId = null;
    _startTime = null;
    _lastRequestAt = null;
    _cachedMessages = null;
    _cachedStructuredPrompt = null;
    _cachedAdapter = null;
    _cachedModel = null;
    _cachedProvider = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyActiveConvId);
    await prefs.remove(_keyActiveCharId);
    await prefs.remove(_keyStartTime);
    await prefs.remove(_keyActiveConvTitle);
    await prefs.remove(_keyCachedMessages);
    await prefs.remove(_keyCachedStaticPrompt);
    await prefs.remove(_keyCachedProfilePrompt);
    await prefs.remove(_keyCachedDynamicPrompt);
    await prefs.remove(_keyCachedModel);
    await prefs.remove(_keyCachedProvider);
    await prefs.remove(_keyLastRequestAt);
  }

  /// 打開正在聊窗口時只暫停 timer，保留首頁入口與心跳。
  Future<void> pauseActiveWindow() async {
    _timer?.cancel();
    _timer = null;
    _active = false;
    await _cancelBackgroundTask();
  }

  /// 偷看別的對話但沒發真消息就退出時，恢復被 claim 覆蓋的原保活窗口。
  ///
  /// 第一個 await 之前的同步段先把字段還原——chat_screen.dispose 裡
  /// 空窗口刪除的異步回調會拿 activeConversationId 判斷要不要 stop()，
  /// 字段同步還原保證那個判斷看到的是恢復後的舊窗口。
  Future<void> resumePausedWindow() async {
    final paused = _pausedWindow;
    if (paused == null) return;
    _pausedWindow = null;

    _conversationId = paused.conversationId;
    _characterId = paused.characterId;
    _startTime = paused.startTime;
    _lastRequestAt = paused.lastRequestAt;
    _cachedMessages = paused.messages;
    _cachedStructuredPrompt = paused.structuredPrompt;
    _cachedAdapter = paused.adapter;
    _cachedModel = paused.model;
    _cachedProvider = paused.provider;

    // claim 時 prefs 被覆蓋過，重新持久化；_ensureRenewalTicker 會做
    // 全部資格檢查 + 重啟 timer + 重新註冊後台任務（pause 時被取消掉的）。
    await _persistActiveWindow();
    await _ensureRenewalTicker();
  }

  /// app 啟動時恢復最後正在聊窗口；若模型仍支持 1h TTL，再恢復保活 timer。
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final convId = prefs.getString(_keyActiveConvId);
    final charId = prefs.getString(_keyActiveCharId);
    final startStr = prefs.getString(_keyStartTime);

    if (convId == null || charId == null || startStr == null) return;

    final startTime = DateTime.tryParse(startStr);
    if (startTime == null) return;

    _conversationId = convId;
    _characterId = charId;
    _startTime = startTime;
    _cachedMessages = _decodeMessages(prefs.getString(_keyCachedMessages));
    final staticPrompt = prefs.getString(_keyCachedStaticPrompt);
    final profilePrompt = prefs.getString(_keyCachedProfilePrompt);
    final dynamicPrompt = prefs.getString(_keyCachedDynamicPrompt);
    if (staticPrompt != null || dynamicPrompt != null) {
      _cachedStructuredPrompt = StructuredPrompt(
        staticPart: staticPrompt ?? '',
        profilePart: profilePrompt,
        dynamicPart: dynamicPrompt ?? '',
      );
    }
    _cachedModel = prefs.getString(_keyCachedModel);
    _cachedProvider = prefs.getString(_keyCachedProvider);
    final lastReqStr = prefs.getString(_keyLastRequestAt);
    _lastRequestAt = lastReqStr == null ? null : DateTime.tryParse(lastReqStr);

    if (!await MemorySettings.getKeepAliveEnabled()) return;
    await _loadSettings();

    if (!await _canUseCloseWindowKeepAlive(
      provider: _cachedProvider,
      model: _cachedModel,
    )) {
      return;
    }
    if (DateTime.now().difference(startTime) >= _maxDuration) return;

    _active = true;
    _startTicker();
    await _registerBackgroundTask();
    // app 剛啟動也算一次「回前台」：緩存還在 50-58 分鐘窗口內就立刻補一針
    await onAppResumed();
  }

  /// tick：只在距上次成功請求滿 [_refreshAfter] 時才真的 ping。
  Future<void> _maybePing() async {
    if (!_active) return;
    final last = _lastRequestAt;
    if (last == null) return;
    if (DateTime.now().difference(last) < _refreshAfter) return;
    await _ping();
  }

  /// App 回前台 / 啟動時的補針。
  /// Dart Timer 在後台不走——鎖屏或切走 app 期間 tick 全部凍結，
  /// 這裡是唯一能救回緩存的機會：
  ///   距上次請求 50~58 分鐘 → 立刻補一針續 TTL；
  ///   超過 58 分鐘 → 緩存已死，不燒這一發，等下一條真消息自然重建。
  Future<void> onAppResumed() async {
    if (_conversationId == null || _characterId == null) return;
    final startTime = _startTime;
    if (startTime == null ||
        DateTime.now().difference(startTime) >= _maxDuration) {
      _cancelTimerOnly();
      return;
    }
    // timer 被系統凍結過的話，回前台重新拉起
    if (_active && _timer == null) _startTicker();

    final last = _lastRequestAt;
    if (last == null) return;
    final elapsed = DateTime.now().difference(last);
    if (elapsed >= _refreshAfter && elapsed <= _resumeRefreshMax) {
      await _ping();
    }
  }

  Future<void> _ping() async {
    final convId = _conversationId;
    final charId = _characterId;
    if (!_active || convId == null || charId == null) return;

    final now = DateTime.now();
    if (_startTime != null && now.difference(_startTime!) >= _maxDuration) {
      _cancelTimerOnly();
      return;
    }

    if (_isQuietHours(now)) return;

    try {
      final provider = _cachedProvider ?? await ApiSettings.getApiProvider();
      final model = _cachedModel ?? await ApiSettings.getModel();
      if (!await _canUseCloseWindowKeepAlive(
        provider: provider,
        model: model,
      )) {
        _cancelTimerOnly();
        return;
      }

      final structuredPrompt = _cachedStructuredPrompt;
      if (structuredPrompt == null) return;
      if (!_hasCacheableStaticPrompt(
        structuredPrompt,
        provider: provider,
        model: model,
      )) {
        return;
      }

      final baseMessages = _copyMessages(_cachedMessages);
      if (baseMessages == null || baseMessages.isEmpty) return;

      final messages = <Map<String, String>>[
        ...baseMessages,
        {'role': 'user', 'content': heartbeatPrompt()},
      ];

      final adapter =
          _cachedAdapter ??
          await ApiSettings.buildAdapter(
            overrideProvider: provider,
            overrideModel: model,
          );

      CacheSession.conversationId = convId;
      final response = await adapter.sendMessage(
        messages: messages,
        model: model,
        structuredPrompt: structuredPrompt,
      );

      // ping 成功 = 緩存 TTL 續期，刷新錨點
      _lastRequestAt = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _keyLastRequestAt,
        _lastRequestAt!.toIso8601String(),
      );

      final heartbeat = parseHeartbeat(response);
      if (heartbeat != null) {
        await _saveHeartbeat(charId, heartbeat);
      }
    } catch (e) {
      developer.log('保活 ping 失敗', error: e, name: 'KeepAliveService');
    }
  }

  static List<Map<String, String>>? _copyMessages(
    List<Map<String, String>>? messages,
  ) {
    if (messages == null || messages.isEmpty) return null;
    return messages
        .where((m) => (m['content'] ?? '').trim().isNotEmpty)
        .map(
          (m) => <String, String>{
            'role': m['role'] ?? 'user',
            'content': m['content'] ?? '',
          },
        )
        .toList();
  }

  static List<Map<String, String>>? _decodeMessages(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final messages = decoded
          .whereType<Map>()
          .map(
            (m) => <String, String>{
              'role': m['role']?.toString() ?? 'user',
              'content': m['content']?.toString() ?? '',
            },
          )
          .where((m) => m['content']!.trim().isNotEmpty)
          .toList();
      return messages.isEmpty ? null : messages;
    } catch (_) {
      return null;
    }
  }

  void _cancelTimerOnly() {
    _timer?.cancel();
    _timer = null;
    _active = false;
  }

  Future<void> _cancelRenewalOnly() async {
    _cancelTimerOnly();
    await _cancelBackgroundTask();
  }

  Future<void> _ensureRenewalTicker() async {
    if (!await MemorySettings.getKeepAliveEnabled()) {
      await _cancelRenewalOnly();
      return;
    }

    final convId = _conversationId;
    final charId = _characterId;
    final startTime = _startTime;
    final lastRequestAt = _lastRequestAt;
    final structuredPrompt = _cachedStructuredPrompt;
    final messages = _copyMessages(_cachedMessages);
    if (convId == null ||
        charId == null ||
        startTime == null ||
        lastRequestAt == null ||
        structuredPrompt == null ||
        messages == null ||
        messages.isEmpty) {
      await _cancelRenewalOnly();
      return;
    }

    await _loadSettings();
    if (DateTime.now().difference(startTime) >= _maxDuration) {
      await _cancelRenewalOnly();
      return;
    }

    final provider = (_cachedProvider?.trim().isNotEmpty == true)
        ? _cachedProvider!.trim()
        : await ApiSettings.getApiProvider();
    final model = (_cachedModel?.trim().isNotEmpty == true)
        ? _cachedModel!.trim()
        : await TokenEstimator.currentModelForProvider(provider);
    if (!TokenEstimator.supportsCloseWindowKeepAlive(
      provider: provider,
      model: model,
    )) {
      await _cancelRenewalOnly();
      return;
    }

    if (!_hasCacheableStaticPrompt(
      structuredPrompt,
      provider: provider,
      model: model,
    )) {
      await _cancelRenewalOnly();
      return;
    }

    _active = true;
    // 不立刻 ping。tick 每 5 分鐘檢查一次，距上次請求滿 50 分鐘才發。
    if (_timer == null) _startTicker();
    await _registerBackgroundTask();
  }

  Future<void> _persistActiveWindow() async {
    final convId = _conversationId;
    final charId = _characterId;
    final startTime = _startTime;
    if (convId == null || charId == null || startTime == null) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyActiveConvId, convId);
    await prefs.setString(_keyActiveCharId, charId);
    await prefs.setString(_keyStartTime, startTime.toIso8601String());
    if (_lastRequestAt != null) {
      await prefs.setString(
        _keyLastRequestAt,
        _lastRequestAt!.toIso8601String(),
      );
    } else {
      await prefs.remove(_keyLastRequestAt);
    }

    final conv = await DatabaseHelper.getConversation(convId);
    if (conv?.title != null && conv!.title!.isNotEmpty) {
      await prefs.setString(_keyActiveConvTitle, conv.title!);
    } else {
      await prefs.remove(_keyActiveConvTitle);
    }

    final messages = _copyMessages(_cachedMessages);
    if (messages == null) {
      await prefs.remove(_keyCachedMessages);
    } else {
      await prefs.setString(_keyCachedMessages, jsonEncode(messages));
    }

    final structuredPrompt = _cachedStructuredPrompt;
    if (structuredPrompt == null) {
      await prefs.remove(_keyCachedStaticPrompt);
      await prefs.remove(_keyCachedProfilePrompt);
      await prefs.remove(_keyCachedDynamicPrompt);
    } else {
      await prefs.setString(
        _keyCachedStaticPrompt,
        structuredPrompt.staticPart,
      );
      if (structuredPrompt.profilePart != null) {
        await prefs.setString(
          _keyCachedProfilePrompt,
          structuredPrompt.profilePart!,
        );
      } else {
        await prefs.remove(_keyCachedProfilePrompt);
      }
      await prefs.setString(
        _keyCachedDynamicPrompt,
        structuredPrompt.dynamicPart,
      );
    }

    if (_cachedModel == null || _cachedModel!.isEmpty) {
      await prefs.remove(_keyCachedModel);
    } else {
      await prefs.setString(_keyCachedModel, _cachedModel!);
    }

    if (_cachedProvider == null || _cachedProvider!.isEmpty) {
      await prefs.remove(_keyCachedProvider);
    } else {
      await prefs.setString(_keyCachedProvider, _cachedProvider!);
    }
  }

  static Future<bool> _canUseCloseWindowKeepAlive({
    String? provider,
    String? model,
  }) async {
    if (!await MemorySettings.getEnablePromptCaching()) return false;
    final p = (provider?.trim().isNotEmpty == true)
        ? provider!.trim()
        : await ApiSettings.getApiProvider();
    final m = (model?.trim().isNotEmpty == true)
        ? model!.trim()
        : await TokenEstimator.currentModelForProvider(p);
    return TokenEstimator.supportsCloseWindowKeepAlive(provider: p, model: m);
  }

  static bool _isQuietHours([DateTime? at]) {
    final hour = (at ?? DateTime.now()).hour;
    // 首尾相同 = 沒有安靜時段
    if (_quietStartHour == _quietEndHour) return false;
    // 不跨夜（如 13→18）：閉開區間直判。
    // 舊版只有 || 寫法，對不跨夜區間恆為 true → 全天安靜、永不 ping
    if (_quietStartHour < _quietEndHour) {
      return hour >= _quietStartHour && hour < _quietEndHour;
    }
    // 跨夜（如 23→7）
    return hour >= _quietStartHour || hour < _quietEndHour;
  }

  static bool _hasCacheableStaticPrompt(
    StructuredPrompt prompt, {
    required String provider,
    required String model,
  }) {
    final staticPart = prompt.staticPart.trim();
    if (staticPart.isEmpty) return false;

    // Gemini explicit cachedContents 只緩存 systemInstruction/staticPart；
    // 門檻不到時 GeminiService 會降級普通請求，所以保活也不該發。
    if (provider.toLowerCase() == 'gemini') {
      final threshold = TokenEstimator.cacheThresholdForModel(
        provider: provider,
        model: model,
      );
      return TokenEstimator.estimate(staticPart) >= threshold;
    }

    return true;
  }

  static String _heartbeatKey(String characterId) =>
      'keepalive_heartbeat_$characterId';

  static Future<void> _saveHeartbeat(String characterId, int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_heartbeatKey(characterId), value);
    await prefs.setInt(_keyLegacyHeartbeat, value);
    instance._heartbeatController.add(
      KeepAliveHeartbeat(characterId: characterId, value: value),
    );
  }

  /// 解析心跳數字。只接受 45-150。
  static int? parseHeartbeat(String response) {
    final cleaned = response.trim();

    final direct = int.tryParse(cleaned);
    if (direct != null && direct >= 45 && direct <= 150) return direct;

    final match = RegExp(r'\b(\d{2,3})\b').firstMatch(cleaned);
    if (match != null) {
      final n = int.parse(match.group(1)!);
      if (n >= 45 && n <= 150) return n;
    }

    return null;
  }

  bool get isActive => _active;
  String? get activeConversationId => _conversationId;
  String? get activeCharacterId => _characterId;

  static Future<int?> getLastHeartbeat({String? characterId}) async {
    final prefs = await SharedPreferences.getInstance();
    if (characterId != null && characterId.isNotEmpty) {
      return prefs.getInt(_heartbeatKey(characterId));
    }
    return prefs.getInt(_keyLegacyHeartbeat);
  }

  static Future<String?> getActiveConvTitle({String? characterId}) async {
    final prefs = await SharedPreferences.getInstance();
    if (characterId != null &&
        prefs.getString(_keyActiveCharId) != characterId) {
      return null;
    }
    return prefs.getString(_keyActiveConvTitle);
  }

  static Future<String?> getActiveConvId({String? characterId}) async {
    final prefs = await SharedPreferences.getInstance();
    if (characterId != null &&
        prefs.getString(_keyActiveCharId) != characterId) {
      return null;
    }
    return prefs.getString(_keyActiveConvId);
  }

  static Future<String?> getActiveCharId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyActiveCharId);
  }

  final _heartbeatController = StreamController<KeepAliveHeartbeat>.broadcast();
  Stream<KeepAliveHeartbeat> get heartbeatStream => _heartbeatController.stream;

  Future<void> forcePing() => _ping();

  Future<void> setHeartbeatFromChat(
    int value, {
    required String characterId,
  }) async {
    await _saveHeartbeat(characterId, value);
  }

  static String heartbeatPrompt() {
    const name = r'$name';
    if (L.locale == 'en') {
      return '''[Hidden keep-alive message]
Keep-alive is active. $name is temporarily busy.
Using this window's context, reply with only one reasonable heartbeat number from 45 to 150.
This message and your reply are not part of the formal conversation; do not affect continuity.
When normal conversation resumes, continue the previous context, tone, and relationship state.''';
    }
    return L.pick(
      en: '',
      zhTW:
          '''【隱藏保活消息】
保活機制啟動。$name暫時在忙。
請結合該窗口上下文，只回覆一個 45-150 的合理心跳數字。
這條消息與你的回覆都不屬於正式對話內容；請勿影響上下文流暢度。
恢復正常對話時，請延續先前上下文、語氣與關係狀態。''',
    );
  }
}
