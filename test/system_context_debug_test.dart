import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/screens/system_context_debug_screen.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/system_context_debug.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    SystemContextDebug.clear();
  });

  test('records actual role transport and keeps secrets redacted', () {
    SystemContextDebug.recordChatRequest(
      provider: 'openrouter',
      model: 'anthropic/claude-sonnet-4.6',
      cacheChannel: 'text',
      sessionId: 'conv-1',
      transport: 'assistant_state_after_cache_breakpoint',
      sourceMessages: const <Map<String, String>>[
        <String, String>{'role': 'assistant', 'content': '上一輪'},
        <String, String>{'role': 'user', 'content': '坐過來'},
      ],
      requestMessages: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'system', 'content': 'stable'},
        <String, dynamic>{
          'role': 'assistant',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': '上一輪'},
            <String, dynamic>{
              'type': 'text',
              'text': '## App Live State\n### 記憶\n秘密',
            },
          ],
        },
        <String, dynamic>{'role': 'user', 'content': '坐過來'},
      ],
      stableContext: '## Control\nkey sk-abcdefghijklmnop',
      liveState: '### 記憶\n[#1] 晚餐\n### 當前時間\n09:30\n生物鐘：飯點',
      cacheEnabled: true,
      cacheBreakpointIndex: 1,
    );

    final snapshot = SystemContextDebug.snapshots.value.single;
    expect(snapshot.userRoleClean, isTrue);
    expect(snapshot.transport, 'assistant_state_after_cache_breakpoint');
    expect(snapshot.roles, <String>['system', 'assistant', 'user']);
    expect(snapshot.hasTime, isTrue);
    expect(snapshot.hasBioClock, isTrue);
    expect(snapshot.hasMemory, isTrue);
    expect(snapshot.stablePreview, contains('[REDACTED_KEY]'));
    expect(snapshot.stablePreview, isNot(contains('sk-abcdefghijklmnop')));
    expect(snapshot.warnings, isEmpty);
  });

  test('detects user pollution and stable prefix drift', () {
    void record({required String stable, required String requestUser}) {
      SystemContextDebug.recordChatRequest(
        provider: 'openrouter',
        model: 'test-model',
        cacheChannel: 'text',
        sessionId: 'conv-1',
        transport: 'system_before_latest_user',
        sourceMessages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': '真實訊息'},
        ],
        requestMessages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': requestUser},
        ],
        stableContext: stable,
        liveState: 'CURRENT TIME=09:30',
        cacheEnabled: true,
      );
    }

    record(stable: 'stable-a', requestUser: '真實訊息');
    record(stable: 'stable-b', requestUser: '真實訊息\n## App Live State\n不該在這裡');

    final latest = SystemContextDebug.snapshots.value.first;
    expect(latest.userRoleClean, isFalse);
    expect(latest.stablePrefixDrifted, isTrue);
    expect(latest.warnings, contains('USER_ROLE_CONTAMINATED'));
    expect(latest.warnings, contains('STABLE_PREFIX_DRIFT'));
  });

  testWidgets('debug screen supports empty and live states without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(home: SystemContextDebugScreen()),
    );
    expect(find.text('等待第一個 Request'), findsOneWidget);

    SystemContextDebug.recordChatRequest(
      provider: 'gemini',
      model: 'gemini-2.5-flash',
      cacheChannel: 'text',
      transport: 'gemini_model_state',
      sourceMessages: const <Map<String, String>>[
        <String, String>{'role': 'assistant', 'content': '上一輪'},
        <String, String>{'role': 'user', 'content': '你好'},
      ],
      requestMessages: const <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'model',
          'parts': <Map<String, String>>[
            <String, String>{'text': '上一輪'},
          ],
        },
        <String, dynamic>{
          'role': 'user',
          'parts': <Map<String, String>>[
            <String, String>{'text': '你好'},
          ],
        },
      ],
      roleKey: 'role',
      contentKey: 'parts',
      stableContext: '## App Context 契約',
      liveState: '### 當前時間\n09:30\n### 記憶\n秘密內容',
    );
    await tester.pump();

    expect(find.textContaining('gemini-2.5-flash'), findsOneWidget);
    expect(find.text('CLEAN'), findsOneWidget);
    expect(find.text('敏感內容預覽'), findsOneWidget);
    expect(find.textContaining('秘密內容'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const SystemContextDebugScreen(),
      ),
    );
    await tester.pump();
    expect(find.textContaining('gemini-2.5-flash'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
