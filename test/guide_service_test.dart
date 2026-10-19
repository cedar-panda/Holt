import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/guide_manual.dart';
import 'package:project_yanci/services/guide_service.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/settings/guide_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app_locale': 'zh_TW',
    });
    await L.load();
  });

  test('manual retrieval finds concrete Holt sections in Chinese', () {
    final backup = GuideManual.retrieve('我要把資料傳到另一台手機，怎麼備份？');
    final rp = GuideManual.retrieve('日常和 RP 模式會共用摘要嗎？');
    final windowStatus = GuideManual.retrieve('右上角三條滑桿可以看窗口摘要和快取嗎？');
    final homeGreeting = GuideManual.retrieve('怎麼關閉模型在首頁寫的問候語？');
    final sidebar = GuideManual.retrieve('側邊欄的模型設定和功能開關在哪裡？');
    final cache = GuideManual.retrieve('Claude 適合用緩存還是上下文限制？');

    expect(backup, isNotEmpty);
    expect(backup.first.id, 'backup');
    expect(rp.map((section) => section.id), contains('modes'));
    expect(
      windowStatus.map((section) => section.id),
      contains('window_status'),
    );
    expect(
      homeGreeting.map((section) => section.id),
      contains('home_greeting'),
    );
    expect(sidebar.map((section) => section.id), contains('sidebar_settings'));
    expect(cache.map((section) => section.id), contains('cache_context'));
  });

  test(
    'manual snapshot is versioned and older restore cannot downgrade it',
    () async {
      await GuideManual.ensureSnapshotPersisted();
      final firstSnapshot = await GuideSettings.manualSnapshot();

      expect(
        await GuideSettings.manualVersion(),
        GuideSettings.bundledManualVersion,
      );
      expect(firstSnapshot, contains('備份與裝置同步'));
      expect(firstSnapshot, contains('窗口模型與活動'));
      expect(firstSnapshot, contains('首頁模型問候語'));
      expect(firstSnapshot, contains('側邊欄設定導覽'));

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'guide_manual_version_v1',
        GuideSettings.bundledManualVersion + 1,
      );
      await prefs.setString('guide_manual_snapshot_v1', 'newer-snapshot');
      await GuideManual.ensureSnapshotPersisted();

      expect(await GuideSettings.manualSnapshot(), 'newer-snapshot');
    },
  );

  test(
    'persona proposal stays hidden from visible answer and parses safely',
    () {
      final parsed = GuideService.parseAnswer('''
我們可以先從這個方向繼續聊。
<holt_persona_draft>{"name":"顧遠","gender":"女","relationship":"旅伴","description":"寡言而敏銳","race":"人類","skill":"辨藥","age":"24","height":"168"}</holt_persona_draft>
''');

      expect(parsed.visibleText, '我們可以先從這個方向繼續聊。');
      expect(parsed.personaDraft?.name, '顧遠');
      expect(parsed.personaDraft?.skill, '辨藥');
      expect(parsed.visibleText, isNot(contains('holt_persona_draft')));
    },
  );

  test('incomplete draft tag never leaks machine JSON while streaming', () {
    final parsed = GuideService.parseAnswer(
      '先看看這個方向。<holt_persona_draft>{"name":"未完成',
    );

    expect(parsed.visibleText, '先看看這個方向。');
    expect(parsed.personaDraft, isNull);
  });

  test('local greeting is deterministic for tests and does not need API', () {
    final first = GuideService.localGreeting(
      userName: '小禾',
      now: DateTime(2026, 10, 4, 9),
      seed: 7,
    );
    final second = GuideService.localGreeting(
      userName: '小禾',
      now: DateTime(2026, 10, 4, 9),
      seed: 7,
    );

    expect(first, second);
    expect(first, contains('小禾'));
  });

  test('an unsent Guide session refreshes its greeting on next open', () {
    final first = GuideService.localGreeting(
      userName: '小禾',
      now: DateTime(2026, 10, 4, 9),
    );
    final second = GuideService.localGreeting(
      userName: '小禾',
      now: DateTime(2026, 10, 4, 9, 1),
    );

    expect(second, isNot(first));
  });

  test('system reply uses the bundled manual without an API request', () async {
    final answer = await GuideService.systemAnswer('世界書和人物關係有什麼不同？');

    expect(answer.visibleText, contains('世界書'));
    expect(answer.visibleText, contains('人物關係'));
    expect(answer.followUps, isNotEmpty);
  });

  test('pending persona draft is portable preference data', () async {
    const draft = <String, String>{'name': '顧遠', 'description': '安靜'};
    await GuideSettings.savePendingDraft(jsonEncode(draft));
    expect(await GuideSettings.pendingDraft(), jsonEncode(draft));
    await GuideSettings.clearPendingDraft();
    expect(await GuideSettings.pendingDraft(), isEmpty);
  });
}
