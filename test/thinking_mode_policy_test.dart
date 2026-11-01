import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/openrouter_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('en');
  });

  test('Thinking instructions stay outside the cacheable prefix', () {
    final off = ThinkingModePolicy.runtimeInstruction(enabled: false);
    final prompt = StructuredPrompt(
      staticPart: 'STATIC',
      profilePart: 'PROFILE',
      windowPart: 'WINDOW',
      controlPart: 'STABLE CONTROL',
      liveStatePart: off,
    );

    expect(prompt.cacheableParts.join('\n'), isNot(contains('Thinking Mode')));
    expect(prompt.cacheableParts.join('\n'), isNot(contains('<think>')));
    expect(prompt.requestOnlyPart, contains('Thinking Mode is off'));
  });

  test('off mode removes only new visible thinking blocks', () {
    expect(
      ThinkingModePolicy.sanitizeVisibleReply(
        '<think>private chain</think>Final answer',
        enabled: false,
      ),
      'Final answer',
    );
    expect(
      ThinkingModePolicy.sanitizeVisibleReply(
        '<thinking>unfinished chain',
        enabled: false,
      ),
      isEmpty,
    );
    expect(
      ThinkingModePolicy.sanitizeVisibleReply(
        '<think>visible chain</think>Final answer',
        enabled: true,
      ),
      '<think>visible chain</think>Final answer',
    );
  });

  test('clock tags survive a thinking block when Thinking is off', () {
    final normalized = ThinkingModePolicy.moveProtocolTagsOutsideThinking(
      '<think>記錄作息 <clock>08:00 早餐 @早餐</clock></think>早安',
    );
    expect(
      ThinkingModePolicy.sanitizeVisibleReply(normalized, enabled: false),
      '<clock>08:00 早餐 @早餐</clock>早安',
    );
  });

  test('clock tags survive truncated thinking output', () {
    final normalized = ThinkingModePolicy.moveProtocolTagsOutsideThinking(
      '<think>記錄作息 <clock>08:00 早餐 @早餐</clock>',
    );
    expect(
      ThinkingModePolicy.sanitizeVisibleReply(normalized, enabled: false),
      '<clock>08:00 早餐 @早餐</clock>',
    );
  });

  test('visible model output hides protocol blocks even with Thinking on', () {
    const raw =
        '<think>先想想 <memo>不應顯示</memo></think>正文'
        '<persona_note>內部註記</persona_note>';
    final visible = VisibleModelOutput.reply(raw, thinkingEnabled: true);
    expect(visible, '<think>先想想 </think>正文');
    expect(visible, isNot(contains('內部註記')));
    expect(visible, isNot(contains('<memo>')));
  });

  test('stream output hides unfinished persona JSON and partial tags', () {
    expect(
      VisibleModelOutput.streaming(
        '先說的正文<holt_persona_draft>{"name":"',
        thinkingEnabled: false,
      ),
      '先說的正文',
    );
    expect(
      VisibleModelOutput.streaming('先說的正文<mem', thinkingEnabled: false),
      '先說的正文',
    );
  });

  test('final-only output cannot leak thinking or XML into titles', () {
    expect(
      VisibleModelOutput.finalOnly(
        '<think>English reasoning</think><memo>fact</memo>夜雨',
      ),
      '夜雨',
    );
  });

  test('OpenRouter sends Thinking as a top-level request policy', () async {
    final offBody =
        await OpenRouterService(
          apiKey: 'test',
          thinkingEnabled: false,
        ).debugBuildBodyForTesting(
          messages: const <Map<String, String>>[
            <String, String>{'role': 'user', 'content': 'hello'},
          ],
          model: 'anthropic/claude-sonnet-4',
          structuredPrompt: StructuredPrompt(
            staticPart: 'SAME STATIC PREFIX',
            liveStatePart: ThinkingModePolicy.runtimeInstruction(
              enabled: false,
            ),
          ),
        );
    final offStaticHash = OpenRouterService.lastCacheDiagnostics['static_hash'];
    final onBody =
        await OpenRouterService(
          apiKey: 'test',
          thinkingEnabled: true,
        ).debugBuildBodyForTesting(
          messages: const <Map<String, String>>[
            <String, String>{'role': 'user', 'content': 'hello'},
          ],
          model: 'anthropic/claude-sonnet-4',
          structuredPrompt: StructuredPrompt(
            staticPart: 'SAME STATIC PREFIX',
            liveStatePart: ThinkingModePolicy.runtimeInstruction(enabled: true),
          ),
        );
    final onStaticHash = OpenRouterService.lastCacheDiagnostics['static_hash'];

    expect(offBody.containsKey('reasoning'), isFalse);
    expect(onBody['reasoning'], <String, dynamic>{'effort': 'medium'});
    expect(offStaticHash, isNotEmpty);
    expect(onStaticHash, offStaticHash);
  });
}
