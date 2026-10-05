import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/context_compressor.dart';
import 'package:project_yanci/theme/theme_presets.dart';
import 'package:project_yanci/widgets/memory_summary_tab.dart';
import 'package:project_yanci/widgets/neural_field.dart';

void main() {
  test('ivory keeps a very light warm background and restrained particles', () {
    for (final color in ivoryPreset.gradient) {
      expect(color.computeLuminance(), greaterThan(0.88));
    }
    expect(ivoryPreset.starColor.a, lessThan(0.5));
    expect(ivoryPreset.starGlow.a, lessThan(0.2));
  });

  test('every preset uses the same restrained particle alpha as ivory', () {
    for (final preset in presets) {
      expect(
        preset.starColor.a,
        closeTo(ivoryPreset.starColor.a, 0.0001),
        reason: '${preset.id} particle alpha drifted',
      );
      expect(
        preset.starGlow.a,
        closeTo(ivoryPreset.starGlow.a, 0.0001),
        reason: '${preset.id} glow alpha drifted',
      );
    }
    expect(NeuralFieldWidget.particleColorMix, 0.72);
    expect(NeuralFieldWidget.particleGlowMix, 0.74);
    expect(NeuralFieldWidget.particleOpacityBoost, 1.12);
    expect(NeuralFieldWidget.connectionStrength, 0.32);
    expect(NeuralFieldWidget.connectionMaxOpacity, 0.38);
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

  test('markdown summary keeps its headings and bullet layout intact', () {
    const source =
        '**1. 重要事件與決定**\n'
        '* **約會：** 兩人決定週末看電影\n\n'
        '**2. 關係與情緒變化**\n'
        '* **和解：** 兩人已經說開';

    expect(MemorySummaryTab.containsMarkdown(source), isTrue);
    expect(MemorySummaryTab.formatForReading(source), source);
  });

  test('summary reader hides redundant canonical headings only in the UI', () {
    const source =
        '## 前情提要\n'
        '顧淵與江離已成婚。\n\n'
        '## 本次摘要\n'
        '**[關係] 共謀復仇**\n'
        '兩人決定合作追查舊案。';

    final formatted = MemorySummaryTab.formatForReading(source);

    expect(formatted, isNot(contains('前情提要')));
    expect(formatted, isNot(contains('本次摘要')));
    expect(formatted, contains('顧淵與江離已成婚'));
    expect(formatted, contains('**[關係] 共謀復仇**'));
  });

  test('automatic summary prompt requests the comfortable markdown format', () {
    final zh = ContextCompressor.compressionPromptForTesting();
    final en = ContextCompressor.compressionPromptForTesting(english: true);

    expect(zh, contains('**1. 重要事件與決定**'));
    expect(zh, contains('* **主題：** 事實'));
    expect(zh, contains('## 前情提要'));
    expect(zh, contains('## 本次摘要'));
    expect(zh, contains('約 250～700 個中文字'));
    expect(zh, isNot(contains('中文約 180～450 字')));
    expect(zh, contains('「第 N 天」只保留在 value 與 evidence'));
    expect(en, contains('**1. Important events and decisions**'));
    expect(en, contains('* **Topic:** fact'));
    expect(en, contains('## Prior Context'));
    expect(en, contains('## This Update'));
    expect(en, contains('"day N" only in value and evidence'));
  });

  test('every summary response is finalized into one canonical structure', () {
    expect(
      ContextCompressor.normalizeSummaryFormat(
        'GPT 自己改成的一段純文字摘要',
        locale: 'zh_TW',
      ),
      '## 前情提要\n—\n\n## 本次摘要\n'
      '**1. 重要事件與決定**\n'
      '* **摘要：** GPT 自己改成的一段純文字摘要',
    );
    expect(
      ContextCompressor.normalizeSummaryFormat(
        '【手動摘要】\n## Previous Summary\nold\n\n'
        '## Latest Summary\nnew',
        locale: 'en',
      ),
      '## Prior Context\nold\n\n## This Update\n'
      '**1. Important events and decisions**\n'
      '* **Summary:** new',
    );
  });
}
