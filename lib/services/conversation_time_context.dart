/// Request-only temporal context for ordinary daily conversations.
///
/// Message timestamps remain local metadata. These helpers only format the
/// small live-state hints sent with the current request.
abstract final class ConversationTimeContext {
  static const Duration gapThreshold = Duration(minutes: 5);

  static String buildGapPrompt({
    required DateTime previousMessageAt,
    required DateTime currentMessageAt,
    required String locale,
  }) {
    final elapsed = currentMessageAt.difference(previousMessageAt);
    if (elapsed.isNegative || elapsed < gapThreshold) return '';

    final duration = _formatElapsed(elapsed, locale: locale);
    if (locale == 'en') {
      return 'About $duration has passed since the previous visible message. '
          'Use this only to sense the passage of time; do not announce the '
          'time or mention this note unless it matters naturally.';
    }
    if (locale == 'zh_CN') {
      return '距离上一条可见消息约$duration。这只用于感知时间流逝；无需刻意报时或提及这段说明。';
    }
    return '距離上一條可見消息約$duration。這只用於感知時間流逝；無需刻意報時或提及這段說明。';
  }

  static String formatAbsoluteTimestamp(
    DateTime timestamp, {
    required String locale,
  }) {
    final local = timestamp.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    if (locale == 'en') {
      const weekdays = <String>[
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      return '$year/$month/$day ${weekdays[local.weekday - 1]} $hour:$minute';
    }
    const weekdays = <String>['一', '二', '三', '四', '五', '六', '日'];
    final weekPrefix = locale == 'zh_CN' ? '周' : '週';
    return '$year/$month/$day $weekPrefix${weekdays[local.weekday - 1]} '
        '$hour:$minute';
  }

  static String _formatElapsed(Duration elapsed, {required String locale}) {
    final totalMinutes = elapsed.inMinutes;
    final days = totalMinutes ~/ Duration.minutesPerDay;
    final hours = (totalMinutes % Duration.minutesPerDay) ~/ 60;
    final minutes = totalMinutes % 60;

    if (locale == 'en') {
      if (days > 0) {
        return '$days ${days == 1 ? 'day' : 'days'}'
            '${hours > 0 ? ' $hours ${hours == 1 ? 'hour' : 'hours'}' : ''}';
      }
      if (hours > 0) {
        return '$hours ${hours == 1 ? 'hour' : 'hours'}'
            '${minutes > 0 ? ' $minutes ${minutes == 1 ? 'minute' : 'minutes'}' : ''}';
      }
      return '$totalMinutes ${totalMinutes == 1 ? 'minute' : 'minutes'}';
    }

    final dayUnit = locale == 'zh_CN' ? '天' : '天';
    final hourUnit = locale == 'zh_CN' ? '小时' : '小時';
    final minuteUnit = locale == 'zh_CN' ? '分钟' : '分鐘';
    if (days > 0) {
      return '$days $dayUnit${hours > 0 ? ' $hours $hourUnit' : ''}';
    }
    if (hours > 0) {
      return '$hours $hourUnit${minutes > 0 ? ' $minutes $minuteUnit' : ''}';
    }
    return '$totalMinutes $minuteUnit';
  }
}
