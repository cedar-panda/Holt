import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/memory/emotion_coordinates.dart';
import 'package:project_yanci/services/bio_clock_service.dart';
import 'package:project_yanci/services/keep_alive_service.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/tool_prompts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('prompt-bearing switches follow all three interface locales', () async {
    await L.setLocale('zh_TW');
    expect(ToolPrompts.toolHeader(), contains('可用工具'));
    expect(BioClockService.abilityPrompt(), contains('生物鐘'));
    expect(KeepAliveService.heartbeatPrompt(), contains('隱藏保活消息'));

    await L.setLocale('zh_CN');
    expect(ToolPrompts.toolHeader(), contains('可用工具'));
    expect(ToolPrompts.toolHeader(), contains('标签'));
    expect(BioClockService.abilityPrompt(), contains('生物钟'));
    expect(KeepAliveService.heartbeatPrompt(), contains('隐藏保活消息'));

    await L.setLocale('en');
    expect(ToolPrompts.toolHeader(), contains('Available Tools'));
    expect(BioClockService.abilityPrompt(), contains('Bio Clock'));
    expect(KeepAliveService.heartbeatPrompt(), contains('Hidden keep-alive'));
  });

  test('legacy and localized emotion dimensions map to canonical DB keys', () {
    EmotionPoint point(String type) => EmotionPoint.fromMap({
      'character_id': 'char',
      'type': type,
      'x': 0,
      'y': 0,
      'concentration': 50,
      'status': 'active',
      'confirmed': 0,
      'created_at': '2026-07-11T00:00:00.000',
      'updated_at': '2026-07-11T00:00:00.000',
    });

    expect(point('desire').type, '慾望');
    expect(point('欲望').type, '慾望');
    expect(point('negative emotion').type, '負面情緒');
    expect(point('负面情绪').type, '負面情緒');
    expect(point('戏谑').type, '戲謔');
  });
}
