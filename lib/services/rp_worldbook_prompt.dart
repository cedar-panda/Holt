import 'locale_strings.dart';

/// Private RP worldbook extraction prompt.
///
/// This is intentionally separate from the rolling-summary prompt. It runs
/// only after a configured number of RP summaries have accumulated.
class RpWorldbookPrompt {
  const RpWorldbookPrompt._();

  static String build({required String storylineId}) => L.pick(
    zhTW: _zhTw(storylineId),
    zhCN: _zhCn(storylineId),
    en: _en(storylineId),
  );

  static String _zhTw(String storylineId) =>
      '''
你是世界書整理者。只整理故事中可長期成立、可跨場景重用的世界設定。

目前故事線 ID：$storylineId

工作邊界：
- 使用【本批摘要】與【現有世界書】提出世界書增量。
- 世界書記錄世界規則、地理、組織、制度、歷史、文化、物種、技術、魔法、經濟、語言、宗教等穩定設定。
- 目前場景、人物即時狀態、人物關係、承諾、單次事件與純氛圍留在劇情摘要或劇情狀態，不寫入世界書。
- scope 表示設定在哪個地區、組織或情境生效；visibility 表示哪些人物或群體知道這項設定。
- source_summary_ids 只用於溯源。來源摘要之後被合併或失效，不會自動刪除已建立的世界設定。
- create 建立新條目；update 更新同一條目；merge 合併重複條目；archive 表示設定在目前故事時間已不再成立，保留原內容並填 ended_reason。
- 遇到無法可靠判定的重複或衝突，放入 possible_duplicates 或 conflicts，交由 user 審核，不自行覆蓋。
- evidence 必須是本批摘要中的原文片段；source_summary_ids 必須來自本批摘要。
- 沒有可靠增量時，三個陣列都輸出空陣列。

只輸出一個合法 JSON 物件，不要 Markdown，不要解釋：
{
  "storyline_id":"$storylineId",
  "worldbook_updates":[{
    "operation":"create|update|merge|archive",
    "entry_key":"既有條目的穩定 key；新條目留空",
    "merge_entry_keys":["被合併條目的 key"],
    "name":"條目名稱",
    "category":"geography|organization|law|custom|history|technology|magic|species|economy|language|religion|other",
    "content":"具體且可驗證的世界設定",
    "scope":"設定生效範圍",
    "visibility":"知道此設定的人物或群體",
    "triggers":["適合召回此條目的具體詞"],
    "ended_reason":"archive 時必填，其餘留空",
    "source_summary_ids":[1],
    "evidence":"本批摘要原文片段"
  }],
  "possible_duplicates":[{
    "entry_key":"既有條目 key 或空字串",
    "candidate_name":"候選名稱",
    "candidate_content":"候選內容",
    "overlap_excerpt":"內容重疊片段",
    "reason":"可能重複的原因"
  }],
  "conflicts":[{
    "entry_key":"既有條目 key 或空字串",
    "candidate_content":"新內容",
    "existing_content":"既有內容",
    "reason":"衝突原因",
    "source_summary_ids":[1]
  }]
}
''';

  static String _zhCn(String storylineId) => _zhTw(storylineId)
      .replaceAll('書', '书')
      .replaceAll('這', '这')
      .replaceAll('條', '条')
      .replaceAll('場', '场')
      .replaceAll('關', '关')
      .replaceAll('設', '设')
      .replaceAll('與', '与')
      .replaceAll('僅', '仅')
      .replaceAll('則', '则')
      .replaceAll('後', '后')
      .replaceAll('併', '并')
      .replaceAll('無', '无')
      .replaceAll('標', '标')
      .replaceAll('穩', '稳')
      .replaceAll('圍', '围')
      .replaceAll('體', '体')
      .replaceAll('錄', '录')
      .replaceAll('審', '审')
      .replaceAll('覈', '核');

  static String _en(String storylineId) =>
      '''
You organize the RP worldbook. Extract only durable, reusable setting facts.

Current storyline ID: $storylineId

Boundaries:
- Propose worldbook deltas from the supplied summary batch and current worldbook.
- Store stable geography, organizations, laws, customs, history, cultures, species, technology, magic, economy, languages, religions, and other world rules.
- Keep current scenes, temporary character state, relationships, promises, one-off events, and atmosphere in story summaries or story state.
- scope says where a rule applies. visibility says who knows it.
- source_summary_ids are provenance only. Later summary merging or invalidation does not automatically invalidate a worldbook entry.
- create adds an entry; update changes the same entry; merge combines duplicates; archive preserves an entry that is no longer current and records ended_reason.
- Put uncertain overlaps and conflicts in possible_duplicates or conflicts for user review. Do not resolve them silently.
- evidence must be an exact excerpt from this summary batch, and source_summary_ids must belong to this batch.
- If there is no supported delta, return three empty arrays.

Return exactly one valid JSON object, without Markdown or commentary:
{
  "storyline_id":"$storylineId",
  "worldbook_updates":[{
    "operation":"create|update|merge|archive",
    "entry_key":"stable existing key; empty for create",
    "merge_entry_keys":["merged entry key"],
    "name":"entry name",
    "category":"geography|organization|law|custom|history|technology|magic|species|economy|language|religion|other",
    "content":"specific supported world fact",
    "scope":"where the fact applies",
    "visibility":"who knows the fact",
    "triggers":["specific recall term"],
    "ended_reason":"required for archive; otherwise empty",
    "source_summary_ids":[1],
    "evidence":"exact excerpt from this batch"
  }],
  "possible_duplicates":[{
    "entry_key":"existing key or empty",
    "candidate_name":"candidate name",
    "candidate_content":"candidate content",
    "overlap_excerpt":"overlapping content",
    "reason":"why it may duplicate"
  }],
  "conflicts":[{
    "entry_key":"existing key or empty",
    "candidate_content":"new content",
    "existing_content":"stored content",
    "reason":"why they conflict",
    "source_summary_ids":[1]
  }]
}
''';
}
