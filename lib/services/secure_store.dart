import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 密鑰安全存儲（Android Keystore / iOS Keychain）
///
/// 取代 SharedPreferences 明文存 API Key：
/// 明文存儲會隨系統雲備份離開設備，開源項目這是必修項。
///
/// ⚠️ 需要依賴：在項目根目錄執行
///   flutter pub add flutter_secure_storage
///
/// 讀取時自動遷移：SharedPreferences 裡的舊明文值會被
/// 搬入安全存儲並從明文裡刪除，老用戶無感升級。
class SecureStore {
  static const _storage = FlutterSecureStorage();

  static Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);
    final p = await SharedPreferences.getInstance();
    await p.remove(key);
  }

  static Future<String> read(String key) async {
    try {
      final v = await _storage.read(key: key);
      if (v != null) return v;
    } catch (e) {
      // Keystore/Keychain 暫時性錯誤 ≠ 「沒設定過」。至少留下痕跡，
      // 否則「密鑰莫名消失」永遠查不到原因。
      debugPrint('SecureStore.read($key) 失敗: $e');
    }
    // 舊明文遷移
    final p = await SharedPreferences.getInstance();
    final legacy = p.getString(key);
    if (legacy != null && legacy.isNotEmpty) {
      try {
        await _storage.write(key: key, value: legacy);
        await p.remove(key);
      } catch (e) {
        debugPrint('SecureStore 遷移 $key 失敗（下次再試）: $e');
      }
      return legacy;
    }
    return '';
  }

  static Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugPrint('SecureStore.delete($key) 失敗: $e');
    }
  }
}
