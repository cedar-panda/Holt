import 'package:shared_preferences/shared_preferences.dart';

import 'locale_strings.dart';

/// X（推文）發文設定 —— 每個角色獨立
///
/// 三個旋鈕：
///   enabled    總開關，關 = 這個角色完全不發
///   unlimited  起念不限制，開 = 解除每日上限（但確認卡仍在）
///   dailyLimit 每日上限 slider，0–20，unlimited 開時失效
///
/// 計數以「角色 + 日期」為 key，跨日自然歸零，不需手動清。
class XPostSettings {
  /// X API 目前先關閉入口與模型提示；功能碼保留，日後改 true 即可恢復。
  static const bool featureEnabled = false;
  static const bool showEntry = featureEnabled;

  static const int maxDailyLimit = 20;
  static const int defaultDailyLimit = 20;

  static String _k(String base, String id) => 'x_${base}_$id';

  static String _todayKey(String id) {
    final d = DateTime.now();
    final ymd =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return 'x_count_${id}_$ymd';
  }

  // ─── 總開關 ───
  static Future<bool> isEnabled(String id) async {
    if (!featureEnabled) return false;
    final p = await SharedPreferences.getInstance();
    return p.getBool(_k('enabled', id)) ?? false;
  }

  static Future<void> setEnabled(String id, bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_k('enabled', id), v);
  }

  // ─── 起念不限制 ───
  static Future<bool> isUnlimited(String id) async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_k('unlimited', id)) ?? false;
  }

  static Future<void> setUnlimited(String id, bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_k('unlimited', id), v);
  }

  // ─── 每日上限 ───
  static Future<int> dailyLimit(String id) async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_k('limit', id)) ?? defaultDailyLimit;
  }

  static Future<void> setDailyLimit(String id, int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_k('limit', id), v.clamp(0, maxDailyLimit));
  }

  // ─── 綁定 handle（正式 OAuth 為下一步，這裡先存 @handle）───
  static Future<String> handle(String id) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_k('handle', id)) ?? '';
  }

  static Future<void> setHandle(String id, String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_k('handle', id), v.trim().replaceAll('@', ''));
  }

  // ─── 今日計數 ───
  static Future<int> todayCount(String id) async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_todayKey(id)) ?? 0;
  }

  static Future<void> incrementToday(String id) async {
    final p = await SharedPreferences.getInstance();
    final k = _todayKey(id);
    await p.setInt(k, (p.getInt(k) ?? 0) + 1);
  }

  /// 今日剩餘可發數；unlimited 時回傳 null 代表無上限
  static Future<int?> remainingToday(String id) async {
    if (await isUnlimited(id)) return null;
    final lim = await dailyLimit(id);
    final used = await todayCount(id);
    final r = lim - used;
    return r < 0 ? 0 : r;
  }

  /// 程式兜底：此刻是否還能發（解析 inline tag 時呼叫）
  static Future<bool> canPost(String id) async {
    if (!featureEnabled) return false;
    if (!await isEnabled(id)) return false;
    if (await isUnlimited(id)) return true;
    final rem = await remainingToday(id) ?? 0;
    return rem > 0;
  }

  /// 注入 system prompt 的一句話 —— 讓模型知道分寸與餘額
  static Future<String> promptHint(String id) async {
    if (!featureEnabled) return '';
    if (!await isEnabled(id)) return '';
    final h = await handle(id);
    final acct = h.isNotEmpty
        ? L.pick(en: ' (account @$h)', zhTW: '（帳號 @$h）')
        : '';
    if (await isUnlimited(id)) {
      return L.pick(
        en: 'You have connected X$acct. You may consider posting when something truly feels worth sharing; there is no daily limit. Do not post every time. Each post is shown to the other person for confirmation before it is sent.',
        zhTW: '你已綁定 X$acct，可在真正值得的時候起念發文，沒有每日上限。不必每次都發；每一則都會先經對方過目確認，才會真的送出。',
      );
    }
    final rem = await remainingToday(id) ?? 0;
    return L.pick(
      en: 'You have connected X$acct and can post $rem more time(s) today. Post only when it feels worthwhile; every post is shown to the other person for confirmation before it is sent.',
      zhTW: '你已綁定 X$acct，今天還剩 $rem 則可發。不必都發，值得的才起念；每一則都會先經對方過目確認才送出。',
    );
  }
}
