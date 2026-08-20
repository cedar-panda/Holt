import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/chat_search_follow_up.dart';

void main() {
  test('local search results stay in request-only App state', () {
    final context = ChatSearchFollowUp.context(
      query: '小痣',
      excerpts: const <String>['[2026-08-20] 晏辭：睫毛根旁邊有一顆小痣。'],
    );
    final prompt = StructuredPrompt(
      staticPart: 'STATIC',
      liveStatePart: context,
    );

    expect(context, contains('Status: completed'));
    expect(context, contains('睫毛根旁邊有一顆小痣'));
    expect(prompt.cacheableParts.join('\n'), isNot(contains('小痣')));
    expect(prompt.requestOnlyPart, contains('Local Chat Retrieval'));
  });

  test('failed local search tells the model not to invent a result', () {
    final context = ChatSearchFollowUp.context(query: '跨窗口', failed: true);

    expect(context, contains('Status: failed'));
    expect(context, contains('do not invent a result'));
    expect(context, isNot(contains('SQLite')));
  });

  test('empty local search is distinct from execution failure', () {
    final context = ChatSearchFollowUp.context(query: '不存在的內容');

    expect(context, contains('Status: no matches'));
    expect(context, isNot(contains('Status: failed')));
  });
}
