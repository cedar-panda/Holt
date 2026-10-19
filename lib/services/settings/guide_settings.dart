import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 嚮導只保存可攜式偏好與草稿；API 密鑰仍由 SecureStore 管理。
///
/// 這些 key 不屬於裝置瞬時狀態，會隨 Holt 完整備份一併導出。
abstract final class GuideSettings {
  static const int bundledManualVersion = 2;

  static const String _enabledKey = 'guide_enabled_v1';
  static const String _introSeenKey = 'guide_intro_seen_v1';
  static const String _manualVersionKey = 'guide_manual_version_v1';
  static const String _manualSnapshotKey = 'guide_manual_snapshot_v1';
  static const String _pendingDraftKey = 'guide_pending_persona_draft_v1';
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
    revision.value++;
  }

  static Future<bool> hasSeenIntro() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_introSeenKey) ?? false;
  }

  static Future<void> markIntroSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_introSeenKey, true);
  }

  /// 新版內置指南優先於備份裡的舊快照。只有內置版本不比已保存版本舊時
  /// 才覆蓋，避免還原舊備份把新版說明書降級。
  static Future<void> refreshBundledManual(String snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    final storedVersion = prefs.getInt(_manualVersionKey) ?? 0;
    final storedSnapshot = prefs.getString(_manualSnapshotKey) ?? '';
    if (storedVersion > bundledManualVersion && storedSnapshot.isNotEmpty) {
      return;
    }
    if (storedVersion == bundledManualVersion && storedSnapshot == snapshot) {
      return;
    }
    await prefs.setInt(_manualVersionKey, bundledManualVersion);
    await prefs.setString(_manualSnapshotKey, snapshot);
  }

  static Future<int> manualVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_manualVersionKey) ?? 0;
  }

  static Future<String> manualSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_manualSnapshotKey) ?? '';
  }

  static Future<void> savePendingDraft(String encoded) async {
    final prefs = await SharedPreferences.getInstance();
    if (encoded.trim().isEmpty) {
      await prefs.remove(_pendingDraftKey);
    } else {
      await prefs.setString(_pendingDraftKey, encoded);
    }
  }

  static Future<String> pendingDraft() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_pendingDraftKey) ?? '';
  }

  static Future<void> clearPendingDraft() => savePendingDraft('');
}
