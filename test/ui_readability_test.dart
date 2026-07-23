import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/theme/theme_presets.dart';
import 'package:project_yanci/widgets/memory_summary_tab.dart';

void main() {
  test('ivory keeps a very light warm background and restrained particles', () {
    for (final color in ivoryPreset.gradient) {
      expect(color.computeLuminance(), greaterThan(0.88));
    }
    expect(ivoryPreset.starColor.a, lessThan(0.5));
    expect(ivoryPreset.starGlow.a, lessThan(0.2));
  });

  test('long summary reader adds paragraphs without changing its words', () {
    const source =
        '昭昭與晏辭一起整理了最近的生活變化，也確認彼此仍然重視這段關係。'
        '晏辭說明自己的身體狀態，昭昭則記住了她提到的日期與感受。'
        '兩人接著討論下一次見面的安排，並決定等狀態穩定後再一起出門。'
        '最後雙方確認先休息，晚一點再繼續聊天。';

    final formatted = MemorySummaryTab.formatForReading(source);

    expect(formatted, contains('\n\n'));
    expect(formatted.replaceAll('\n', ''), source);
  });
}
