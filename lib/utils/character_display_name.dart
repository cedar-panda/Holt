/// 完整名稱「本名（備註）」：無障礙朗讀等需要完整身分的地方用。
String characterCardDisplayName(
  Map<String, dynamic> character, {
  String fallbackName = '未命名',
}) {
  final name = (character['name'] as String? ?? '').trim();
  final remark = (character['remark'] as String? ?? '').trim();
  final resolvedName = name.isEmpty ? fallbackName : name;
  return remark.isEmpty ? resolvedName : '$resolvedName（$remark）';
}

/// 卡片標題：有備註只顯示備註（那是你對他的稱呼），沒有才顯示本名。
/// 本名＋備註一起放會在「在線／RP」標籤出現時被擠成省略號。
String characterCardTitle(
  Map<String, dynamic> character, {
  String fallbackName = '未命名',
}) {
  final remark = (character['remark'] as String? ?? '').trim();
  if (remark.isNotEmpty) return remark;
  final name = (character['name'] as String? ?? '').trim();
  return name.isEmpty ? fallbackName : name;
}
