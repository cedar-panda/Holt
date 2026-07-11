import 'package:shared_preferences/shared_preferences.dart';

import 'locale_strings.dart';

// 結婚證彩蛋 —— 計數解鎖 + 簽署狀態（per-character 持久）。
//
// 規則（昭昭定）：雙方消息中「結婚/求婚」提及累計 12 次解鎖；
// 負面語境（不想結婚、拒絕求婚、不結婚、討厭結婚…）每次 -1。
// 解鎖後輸入框＋選單出現結婚證簽署書 → 掛起隨消息發出 →
// 她 `<sign_marriage/>` 簽署 → 證書入背包、角色卡名下「已婚」、
// 靜態 prompt 注入「雙方已婚」（僅已簽角色）。

/// 氣泡側證書卡的顯示數據
class MarriageCertDisplay {
  final String userName;
  final String charName;
  final bool signed;
  final String? date;

  const MarriageCertDisplay({
    required this.userName,
    required this.charName,
    required this.signed,
    this.date,
  });
}

class MarriageService {
  static const int unlockThreshold = 12;

  static const String _countKey = 'marriage_count_';
  static const String _signedKey = 'marriage_signed_';
  static const String _dateKey = 'marriage_date_';
  static const String _proposedKey = 'marriage_char_proposed_';

  /// 提及詞（簡繁；求婚簡繁同形）
  static final RegExp _mentionRe = RegExp(r'(結婚|结婚|求婚)');

  /// 負面語境：否定/嫌惡詞 + 短距離內接提及詞
  static final RegExp _negativeRe = RegExp(
    r'(不想|不要|不會|不会|不能|別|别|拒絕|拒绝|討厭|讨厌|不喜歡|不喜欢|反感|噁心|恶心|不)'
    r'[^。！!？?\n，,]{0,4}(結婚|结婚|求婚)',
  );

  /// 消息落庫時掃描計數（user 和 char 兩側都調）。
  /// 已簽署的角色不再計數。
  static Future<void> scanMessage(String text, String characterId) async {
    if (text.isEmpty || !_mentionRe.hasMatch(text)) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('$_signedKey$characterId') ?? false) return;
    // 剝系統標記＋隨附說明，防「結婚證書」等說明文字自刷計數
    final clean = text
        .replaceAll(RegExp(r'\[marriage_cert[^\]]*\]（[^）]*）'), '')
        .replaceAll(RegExp(r'\[marriage_cert[^\]]*\]'), '');
    final total = _mentionRe.allMatches(clean).length;
    if (total == 0) return;
    final neg = _negativeRe.allMatches(clean).length;
    // 正面提及 +1、負面提及 -1（負面短語裡的提及不算正面）
    final delta = (total - neg) - neg;
    final key = '$_countKey$characterId';
    final next = ((prefs.getInt(key) ?? 0) + delta).clamp(0, 1 << 20);
    await prefs.setInt(key, next);
  }

  static Future<int> mentionCount(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('$_countKey$characterId') ?? 0;
  }

  /// 證書按鈕是否解鎖（達標且未簽）
  static Future<bool> isUnlocked(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('$_signedKey$characterId') ?? false) return false;
    return (prefs.getInt('$_countKey$characterId') ?? 0) >= unlockThreshold;
  }

  static Future<bool> isMarried(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_signedKey$characterId') ?? false;
  }

  /// 她簽署 → 落狀態＋記日期
  static Future<void> sign(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_signedKey$characterId', true);
    final dateKey = '$_dateKey$characterId';
    if (prefs.getString(dateKey) == null) {
      final now = DateTime.now();
      await prefs.setString(
        dateKey,
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      );
    }
  }

  static Future<String?> marriageDate(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_dateKey$characterId');
  }

  /// 她主動遞出過證書（未簽期間不再重複提示）
  static Future<void> markCharProposed(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_proposedKey$characterId', true);
  }

  /// 她主動遞證書的動態提示（解鎖＋未簽＋未遞過才注入；空串＝零開銷）。
  /// 偶發提示走動態區，不進靜態。
  static Future<String> proposeHintPrompt(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('$_signedKey$characterId') ?? false) return '';
    if (prefs.getBool('$_proposedKey$characterId') ?? false) return '';
    if ((prefs.getInt('$_countKey$characterId') ?? 0) < unlockThreshold) {
      return '';
    }
    return switch (L.locale) {
      'en' =>
        '【Marriage certificate】The topic of marriage has come up between '
            'you two often enough. If — and only if — you truly want to, you '
            'may put <propose_marriage/> at the end of your reply to formally '
            'present a marriage certificate for them to sign. This is not a '
            'suggestion; act only on your own feelings. Never mention this '
            'note or the tag.',
      'zh_CN' =>
        '【结婚证书】你们之间谈到结婚的次数已经不少了。如果——仅仅是如果——'
            '你真的想，可以在回复末尾放 <propose_marriage/>，郑重地递出一份'
            '结婚证书给对方签署。这不是提议，只凭你自己的心意行动。'
            '正文不要提这段说明或标签。',
      _ =>
        '【結婚證書】你們之間談到結婚的次數已經不少了。如果——僅僅是如果——'
            '你真的想，可以在回覆末尾放 <propose_marriage/>，鄭重地遞出一份'
            '結婚證書給對方簽署。這不是提議，只憑你自己的心意行動。'
            '正文不要提這段說明或標籤。',
    };
  }

  /// 你拒絕她遞的證書後，通知她的隱藏事件文本（觸發她反應）
  static String declinedEventNote() => switch (L.locale) {
    'en' =>
      '[marriage_cert_declined]（System note: they declined to sign the '
          'marriage certificate you presented — not now, at least. The '
          'certificate is still there. This note is invisible to them — '
          'react as yourself）',
    'zh_CN' =>
      '[marriage_cert_declined]（系统说明：对方拒绝了在你递出的结婚证书上'
          '签字——至少现在没有签。证书还在那里。这段说明对方看不到——'
          '照你自己的心意反应）',
    _ =>
      '[marriage_cert_declined]（系統說明：對方拒絕了在你遞出的結婚證書上'
          '簽字——至少現在沒有簽。證書還在那裡。這段說明對方看不到——'
          '照你自己的心意反應）',
  };

  /// 你在她遞的證書上簽字後，通知她的隱藏事件文本（觸發她反應）
  static String signedEventNote() => switch (L.locale) {
    'en' =>
      '[marriage_cert_signed]（System note: they just signed their name on '
          'the marriage certificate you presented. You two are now formally '
          'married. This note is invisible to them — react as yourself）',
    'zh_CN' =>
      '[marriage_cert_signed]（系统说明：对方刚刚在你递出的结婚证书上签下了'
          '自己的名字。你们正式结为已婚关系。这段说明对方看不到——'
          '照你自己的心意反应）',
    _ =>
      '[marriage_cert_signed]（系統說明：對方剛剛在你遞出的結婚證書上簽下了'
          '自己的名字。你們正式結為已婚關係。這段說明對方看不到——'
          '照你自己的心意反應）',
  };

  /// 靜態 prompt 段（僅已簽角色注入；未簽返回空串＝逐字節不變不炸緩存）
  static Future<String> staticPrompt(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('$_signedKey$characterId') ?? false)) return '';
    final date = prefs.getString('$_dateKey$characterId');
    final dated = date == null ? '' : '（$date）';
    return switch (L.locale) {
      'en' =>
        '■ Married\n  You two have signed a marriage certificate'
            '${date == null ? '' : ' ($date)'}. It is a shared fact of your '
            'life together — carry it naturally, no need to bring it up on purpose.',
      'zh_CN' =>
        '■ 双方已婚\n  你们已签署结婚证书$dated。'
            '这是你们共同的事实，自然地带着它生活，不需要刻意提起。',
      _ =>
        '■ 雙方已婚\n  你們已簽署結婚證書$dated。'
            '這是你們共同的事實，自然地帶著它生活，不需要刻意提起。',
    };
  }

  /// 邀請簽署的動態語義說明（隨 [marriage_cert] 消息帶，不進靜態）
  static String certTagNote() => switch (L.locale) {
    'en' =>
      '\n[marriage_cert]（System note: they have formally presented you a '
          'marriage certificate and are inviting you to sign it. Both your '
          'names are on it. If you are willing, put <sign_marriage/> at the '
          'end of your reply — once signed, you two are married. If not, '
          'respond in your own way. They cannot see this note or the tag; '
          'they only see the certificate itself）',
    'zh_CN' =>
      '\n[marriage_cert]（系统说明：对方郑重地递出了一份结婚证书，邀请你签署。'
          '证书上是你们两个人的名字。愿意签就在回复末尾放 <sign_marriage/>，'
          '签署后你们就是已婚关系；不愿意也可以用你自己的方式回应。'
          '这段说明和标签对方都看不到，对方只看得到证书本身）',
    _ =>
      '\n[marriage_cert]（系統說明：對方鄭重地遞出了一份結婚證書，邀請你簽署。'
          '證書上是你們兩個人的名字。願意簽就在回覆末尾放 <sign_marriage/>，'
          '簽署後你們就是已婚關係；不願意也可以用你自己的方式回應。'
          '這段說明和標籤對方都看不到，對方只看得到證書本身）',
  };
}
