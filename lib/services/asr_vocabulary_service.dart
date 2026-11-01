import 'package:lpinyin/lpinyin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通話「常用詞彙」：語音辨識出來的字，讀音跟常用詞彙相同或相近時，
/// 換成常用詞彙（例：「遲遲」「詞詞」→「辭辭」）。
///
/// - 每個角色各存一份（SharedPreferences）；角色名字自動算進來，不用手動加。
/// - 只比對中日韓字 2–8 字的詞；單字太容易誤傷，不收。
/// - 讀音用「模糊拼音」：平翹舌（z/zh、c/ch、s/sh）、n/l、前後鼻音
///   （an/ang、en/eng、in/ing）視為相同；聲調要一樣（不然「次次」「此次」
///   也會被換成「辭辭」）。
/// - 校正發生在辨識結果之後，系統辨識和本地模型兩條路都吃得到。
abstract final class AsrVocabularyService {
  static const int minTermLength = 2;
  static const int maxTermLength = 8;
  static const int maxTerms = 30;

  static String _key(String characterId) => 'call_asr_vocab_v1_$characterId';

  static final RegExp _cjk = RegExp(r'^[㐀-鿿]+$');

  /// 這個詞能不能拿來校正（長度、全是漢字）。
  static bool isUsableTerm(String term) {
    final t = term.trim();
    return t.length >= minTermLength &&
        t.length <= maxTermLength &&
        _cjk.hasMatch(t);
  }

  static Future<List<String>> load(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key(characterId)) ?? const <String>[];
  }

  static Future<List<String>> add(String characterId, String term) async {
    final t = term.trim();
    final current = List<String>.of(await load(characterId));
    if (!isUsableTerm(t) || current.contains(t)) return current;
    if (current.length >= maxTerms) return current;
    current.add(t);
    await _save(characterId, current);
    return current;
  }

  static Future<List<String>> remove(String characterId, String term) async {
    final current = List<String>.of(await load(characterId))..remove(term);
    await _save(characterId, current);
    return current;
  }

  static Future<void> _save(String characterId, List<String> terms) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key(characterId), terms);
  }

  /// 把 [text] 裡讀音跟 [terms] 相近的片段換成該詞。長詞優先，
  /// 已換過的位置不再被短詞覆蓋。本來就寫對的不動。
  static String correct(String text, Iterable<String> terms) {
    if (text.isEmpty) return text;
    final usable =
        terms.map((t) => t.trim()).where(isUsableTerm).toSet().toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    if (usable.isEmpty) return text;

    final chars = text.split('');
    final locked = List<bool>.filled(chars.length, false);
    final keys = List<String?>.filled(chars.length, null);
    String? keyAt(int i) {
      final ch = chars[i];
      if (!_cjk.hasMatch(ch)) return null;
      return keys[i] ??= fuzzyKey(ch);
    }

    for (final term in usable) {
      final termKeys = term.split('').map(fuzzyKey).toList();
      if (termKeys.any((k) => k.isEmpty)) continue;
      final n = term.length;
      var i = 0;
      while (i + n <= chars.length) {
        var match = true;
        for (var j = 0; j < n; j++) {
          if (locked[i + j] || keyAt(i + j) != termKeys[j]) {
            match = false;
            break;
          }
        }
        if (!match) {
          i++;
          continue;
        }
        for (var j = 0; j < n; j++) {
          chars[i + j] = term[j];
          locked[i + j] = true;
        }
        i += n;
      }
    }
    return chars.join();
  }

  /// 單字的模糊拼音鍵；查不到讀音回空字串（不參與比對）。
  static String fuzzyKey(String char) {
    final raw = PinyinHelper.getPinyinE(
      char,
      defPinyin: '',
      format: PinyinFormat.WITH_TONE_NUMBER,
    ).trim().toLowerCase();
    if (raw.isEmpty) return '';
    return normalizePinyin(raw);
  }

  /// 模糊拼音正規化（純函式，方便測試）。
  /// 尾端數字聲調保留（chi2 → ci2）。
  static String normalizePinyin(String pinyin) {
    final toneMatch = RegExp(r'[0-5]$').firstMatch(pinyin);
    final tone = toneMatch?.group(0) ?? '';
    var p = tone.isEmpty ? pinyin : pinyin.substring(0, pinyin.length - 1);
    p = p.replaceAll('ü', 'v').replaceAll('u:', 'v');
    if (p.startsWith('zh') || p.startsWith('ch') || p.startsWith('sh')) {
      p = p[0] + p.substring(2);
    }
    if (p.startsWith('l')) p = 'n${p.substring(1)}';
    if (p.endsWith('ang') || p.endsWith('eng') || p.endsWith('ing')) {
      p = p.substring(0, p.length - 1);
    }
    return '$p$tone';
  }
}
