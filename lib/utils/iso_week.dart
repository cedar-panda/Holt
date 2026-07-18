/// Returns an ISO-8601 week-year key such as `2026-W01`.
///
/// ISO weeks start on Monday and the week belongs to the year containing its
/// Thursday. This matters around New Year, where the calendar year alone is
/// not sufficient.
String isoWeekGroup(DateTime value) {
  final day = DateTime.utc(value.year, value.month, value.day);
  final thursday = day.add(Duration(days: DateTime.thursday - day.weekday));
  final yearStart = DateTime.utc(thursday.year, 1, 1);
  final week = ((thursday.difference(yearStart).inDays + 1) / 7).ceil();
  return '${thursday.year}-W${week.toString().padLeft(2, '0')}';
}
