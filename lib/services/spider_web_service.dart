import '../memory/emotion_coordinates.dart';
import 'bio_clock_service.dart';
import 'locale_strings.dart';

class SpiderWebService {
  /// 蛛網記憶專用 Prompt；所有能力共用 Holt JSON 動作協議。
  /// 商店段由 chat_screen 的獨立工具區提供，不在此重複注入。
  static Future<String> abilityPrompt({
    required String userNickname,
    required String characterId,
    required String characterName,
    required bool emotionEnabled,
    required bool bioclockEnabled,
  }) async {
    final name = userNickname.isNotEmpty
        ? userNickname
        : (L.locale == 'en' ? 'the other person' : '對方');
    final charName = characterName.isNotEmpty
        ? characterName
        : (L.locale == 'en' ? '[char name]' : '角色名');

    final sections = <String>[
      L.pick(
        en:
            '''■ Spider-web Memory System
  {"type":"memory.propose","arguments":{"category":"Preference | Promise | Important Event | Self-Disclosure","content":"third-person durable fact","triggers":["event trigger"]}}
  Write in third person using $charName and $name. Keep entries independent and non-repeating. Use at most 2 entries and 2 event-based triggers per entry. Self-Disclosure is a durable fact about who $name is, voluntarily shared by them; it is not a casual preference.

  {"type":"memory.delete","arguments":{"ids":["id"]}}
  {"type":"memory.merge","arguments":{"ids":["id1","id2"],"category":"Category","content":"rebuilt fact","triggers":["trigger"]}}
  Delete or merge only when the injected records make this certain; both operations remain reviewable.

  {"type":"memory.link","arguments":{"ids":["id1","id2"]}}
  Propose a meaningful connection only when every listed memory belongs to the same causal, relational, or ongoing thread. The user reviews it before any link is established.

  {"type":"memory.force_recall","arguments":{"query":"specific event keyword"}}
  Use when details are genuinely hazy. The App retrieves them for a later turn.

  {"type":"self_note.add","arguments":{"content":"one lasting sentence about yourself or how you relate to $name"}}
  Record only a new, durable self-understanding; do not restate an existing note.

  {"type":"search.chat","arguments":{"scope":"daily","query":"specific event keyword"}}
  Search exact prior conversation only when needed. Never mention hidden records, ids, tools, or clarity scores in visible prose.''',
        zhTW:
            '''■ 蛛網記憶系統
  {"type":"memory.propose","arguments":{"category":"偏好｜約定｜重要事件｜自我揭露","content":"第三人稱耐久事實","triggers":["事件觸發詞"]}}
  使用第三人稱，以 $charName 與 $name 指稱雙方。每條獨立且不重複；每輪最多 2 條，每條最多 2 個事件型觸發詞。自我揭露只記 $name 主動說明、能描述其身分／經歷／價值觀的耐久事實，不等同一般偏好。

  {"type":"memory.delete","arguments":{"ids":["id"]}}
  {"type":"memory.merge","arguments":{"ids":["id1","id2"],"category":"類別","content":"重構後事實","triggers":["觸發詞"]}}
  只有帶入記錄已足以確定時才刪除或合併；兩者都須保留可審核性。

  {"type":"memory.link","arguments":{"ids":["id1","id2"]}}
  只有列出的記憶確實屬於同一因果、關係或持續事件時才建議連線；使用者確認前不會建立。

  {"type":"memory.force_recall","arguments":{"query":"具體事件關鍵詞"}}
  只有細節確實模糊時使用，App 會在後續回合提供結果。

  {"type":"self_note.add","arguments":{"content":"一句關於自己或如何與 $name 相處的新耐久認知"}}
  只記新的穩定自我理解，不重複既有內容。

  {"type":"search.chat","arguments":{"scope":"daily","query":"具體事件關鍵詞"}}
  需要精確原文時才搜尋。可見正文不得提隱藏記錄、編號、工具或清晰度。''',
        zhCN:
            '''■ 蛛网记忆系统
  {"type":"memory.propose","arguments":{"category":"偏好｜约定｜重要事件｜自我揭露","content":"第三人称耐久事实","triggers":["事件触发词"]}}
  使用第三人称，以 $charName 与 $name 指称双方。每条独立且不重复；每轮最多 2 条，每条最多 2 个事件型触发词。自我揭露只记 $name 主动说明、能描述其身份／经历／价值观的耐久事实，不等同一般偏好。

  {"type":"memory.delete","arguments":{"ids":["id"]}}
  {"type":"memory.merge","arguments":{"ids":["id1","id2"],"category":"类别","content":"重构后事实","triggers":["触发词"]}}
  只有带入记录已足以确定时才删除或合并；两者都须保留可审核性。

  {"type":"memory.link","arguments":{"ids":["id1","id2"]}}
  只有列出的记忆确实属于同一因果、关系或持续事件时才建议连线；用户确认前不会建立。

  {"type":"memory.force_recall","arguments":{"query":"具体事件关键词"}}
  只有细节确实模糊时使用，App 会在后续回合提供结果。

  {"type":"self_note.add","arguments":{"content":"一句关于自己或如何与 $name 相处的新耐久认知"}}
  只记新的稳定自我理解，不重复既有内容。

  {"type":"search.chat","arguments":{"scope":"daily","query":"具体事件关键词"}}
  需要精确原文时才搜索。可见正文不得提隐藏记录、编号、工具或清晰度。''',
      ),
      if (emotionEnabled) EmotionCoordinates.abilityPrompt(),
      if (bioclockEnabled) BioClockService.abilityPrompt(),
    ];
    return sections.join('\n\n');
  }
}
