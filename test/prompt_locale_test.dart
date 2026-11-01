import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/memory/emotion_coordinates.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/services/bio_clock_service.dart';
import 'package:project_yanci/services/keep_alive_service.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/memory_actions.dart';
import 'package:project_yanci/services/spider_web_service.dart';
import 'package:project_yanci/services/tool_prompts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('prompt-bearing switches follow all three interface locales', () async {
    await L.setLocale('zh_TW');
    expect(ToolPrompts.toolHeader(), contains('可用工具'));
    expect(ToolPrompts.whisper(), contains('對方輸入時看到的那句話。'));
    expect(ToolPrompts.voiceCall(), contains('"type":"call.start"'));
    expect(ToolPrompts.voiceCall(), contains('<call>'));
    expect(ToolPrompts.voiceCall(), contains('只使用其中一種格式'));
    expect(BioClockService.abilityPrompt(), contains('生物鐘'));
    expect(KeepAliveService.heartbeatPrompt(), contains('隱藏保活消息'));

    await L.setLocale('zh_CN');
    expect(ToolPrompts.toolHeader(), contains('可用工具'));
    expect(ToolPrompts.toolHeader(), contains('JSON'));
    expect(BioClockService.abilityPrompt(), contains('生物钟'));
    expect(KeepAliveService.heartbeatPrompt(), contains('隐藏保活消息'));

    await L.setLocale('en');
    expect(ToolPrompts.toolHeader(), contains('Available Tools'));
    expect(ToolPrompts.voiceCall(), contains('Compatibility form'));
    expect(ToolPrompts.voiceCall(), contains('<call>'));
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

  test(
    'emotion protocol and five dimensions follow all three locales',
    () async {
      await L.setLocale('zh_TW');
      expect(EmotionCoordinates.abilityPrompt(), contains('安全感／慾望／愜意／負面情緒／戲謔'));
      expect(EmotionCoordinates.displayDimension('負面情緒'), '負面情緒');

      await L.setLocale('zh_CN');
      expect(EmotionCoordinates.abilityPrompt(), contains('安全感／欲望／惬意／负面情绪／戏谑'));
      expect(EmotionCoordinates.displayDimension('慾望'), '欲望');
      expect(EmotionCoordinates.displayDimension('負面情緒'), '负面情绪');

      await L.setLocale('en');
      final prompt = EmotionCoordinates.abilityPrompt();
      expect(
        prompt,
        contains('Security / Desire / Comfort / Negative emotion / Banter'),
      );
      expect(prompt, isNot(contains('write these Chinese labels')));
      expect(EmotionCoordinates.displayDimension('安全感'), 'Security');
      expect(EmotionCoordinates.displayDimension('慾望'), 'Desire');
      expect(EmotionCoordinates.displayDimension('愜意'), 'Comfort');
      expect(EmotionCoordinates.displayDimension('負面情緒'), 'Negative emotion');
      expect(EmotionCoordinates.displayDimension('戲謔'), 'Banter');
    },
  );

  test('memo prompts omit the retired long-term emotion label', () async {
    await L.setLocale('zh_TW');
    final memoryPrompt = MemoryActions.abilityPrompt();
    final spiderPrompt = await SpiderWebService.abilityPrompt(
      userNickname: '小禾',
      characterId: 'char',
      characterName: '顧遠',
      emotionEnabled: true,
      bioclockEnabled: true,
    );

    for (final prompt in [memoryPrompt, spiderPrompt]) {
      expect(prompt, isNot(contains('類別：長期情緒')));
      expect(prompt, isNot(contains('長期情緒只記錄')));
    }
    expect(spiderPrompt, contains('情緒打點不是長期記憶'));

    final quietSpiderPrompt = await SpiderWebService.abilityPrompt(
      userNickname: '小禾',
      characterId: 'char',
      characterName: '顧遠',
      emotionEnabled: false,
      bioclockEnabled: false,
    );
    expect(quietSpiderPrompt, contains('■ 進階記憶系統'));
    expect(quietSpiderPrompt, isNot(contains('<emo>')));
    expect(quietSpiderPrompt, isNot(contains('<clock>')));

    await L.setLocale('en');
    final englishPrompt = MemoryActions.abilityPrompt();
    expect(englishPrompt, isNot(contains('Categories: Long-term Emotion')));
    expect(englishPrompt, isNot(contains('this feeling will still matter')));
  });

  test('RP correction tools are request-only instead of static', () async {
    await L.setLocale('zh_TW');
    final staticPrompt = MemoryActions.abilityPrompt(
      contextMode: ContextMode.rp,
    );
    expect(staticPrompt, isNot(contains('rp.timeline.correct')));
    expect(staticPrompt, isNot(contains('rp.state.correct')));
    expect(MemoryActions.isRpCorrectionIntent('請修正前面的時間線'), isTrue);
    final runtimePrompt = MemoryActions.rpCorrectionRuntimeInstruction();
    expect(runtimePrompt, contains('rp.timeline.correct'));
    expect(runtimePrompt, contains('rp.state.correct'));
  });
}
