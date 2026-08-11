import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/web_search_intent.dart';

void main() {
  group('WebSearchIntentParser', () {
    test('parses the first non-empty search_web tag case-insensitively', () {
      final intent = WebSearchIntentParser.parse('''
Before
<SEARCH_WEB>   Taipei\n  weather\t today   </SeArCh_WeB>
Between
<search_web>second query</search_web>
After
''');

      expect(intent.query, 'Taipei weather today');
      expect(intent.visibleText, 'Before\n\nBetween\n\nAfter');
    });

    test('skips an empty tag and accepts the next valid query', () {
      final intent = WebSearchIntentParser.parse(
        '<search_web> \n </search_web>'
        '<search_web>valid query</search_web>',
      );

      expect(intent.query, 'valid query');
      expect(intent.visibleText, isEmpty);
    });

    test('parses a generic web.search tool call', () {
      final intent = WebSearchIntentParser.parse('''
Visible
<TOOL_CALL id="1" NAME='WEB.SEARCH'>
  <PARAMETER required="true" Name="QUERY">  latest   Dart news </PARAMETER>
</Tool_Call>
Tail
''');

      expect(intent.query, 'latest Dart news');
      expect(intent.visibleText, 'Visible\n\nTail');
    });

    test('uses source order across the two supported syntaxes', () {
      final intent = WebSearchIntentParser.parse('''
<tool_call name="web.search">
  <parameter name="query">first</parameter>
</tool_call>
<search_web>second</search_web>
''');

      expect(intent.query, 'first');
      expect(intent.visibleText, isEmpty);
    });

    test('accepts exactly 240 runes and rejects a longer query', () {
      final maxLengthQuery = List.filled(240, '🦊').join();
      final tooLongQuery = List.filled(241, '🦊').join();
      final accepted = WebSearchIntentParser.parse(
        '<search_web>$maxLengthQuery</search_web>',
      );
      final rejected = WebSearchIntentParser.parse(
        '<search_web>$tooLongQuery</search_web>',
      );

      expect(accepted.query?.runes.length, 240);
      expect(rejected.query, isNull);
      expect(rejected.visibleText, isEmpty);
    });

    test('rejects unsafe controls but allows collapsible whitespace', () {
      final unsafe = WebSearchIntentParser.parse(
        '<search_web>safe\u0000looking</search_web>',
      );
      final whitespace = WebSearchIntentParser.parse(
        '<search_web>one\r\n\ttwo</search_web>',
      );

      expect(unsafe.query, isNull);
      expect(unsafe.visibleText, isEmpty);
      expect(whitespace.query, 'one two');
    });

    test('strips unclosed search_web without executing it', () {
      final intent = WebSearchIntentParser.parse(
        'Visible<search_web>must not execute',
      );

      expect(intent.query, isNull);
      expect(intent.visibleText, 'Visible');
    });

    test('strips an unclosed matching tool call without executing it', () {
      final intent = WebSearchIntentParser.parse('''
Visible
<tool_call name="web.search">
  <parameter name="query">must not execute</parameter>
''');

      expect(intent.query, isNull);
      expect(intent.visibleText, 'Visible');
    });

    test(
      'strips invalid matching tool calls and never falls back to any param',
      () {
        final intent = WebSearchIntentParser.parse('''
Before
<tool_call name="web.search">
  <parameter name="keyword">wrong field</parameter>
</tool_call>
After
''');

        expect(intent.query, isNull);
        expect(intent.visibleText, 'Before\n\nAfter');
      },
    );

    test('preserves and never executes unrelated tags or tools', () {
      const reply = '''
<search_chat>local only</search_chat>
<tool_call name="memory.delete">
  <parameter name="query">do not execute</parameter>
</tool_call>
''';

      final intent = WebSearchIntentParser.parse(reply);

      expect(intent.query, isNull);
      expect(intent.visibleText, reply.trim());
    });

    test('does not mistake text inside another attribute for a tool name', () {
      const reply = '''<tool_call note=" name='web.search'">
<parameter name="query">do not execute</parameter>
</tool_call>''';

      final intent = WebSearchIntentParser.parse(reply);

      expect(intent.query, isNull);
      expect(intent.visibleText, reply);
    });
  });

  group('explicit user request fallback', () {
    test('accepts clear English and Chinese web-search requests', () {
      expect(
        WebSearchIntentParser.explicitUserQuery(
          'Please search the web for Taipei weather right now',
        ),
        'Please search the web for Taipei weather right now',
      );
      expect(
        WebSearchIntentParser.explicitUserQuery('幫我查一下台北現在的天氣'),
        '幫我查一下台北現在的天氣',
      );
      expect(
        WebSearchIntentParser.explicitUserQuery('老婆你看能不能用搜索功能看看台北天氣'),
        '老婆你看能不能用搜索功能看看台北天氣',
      );
    });

    test('rejects ordinary text and hidden app metadata', () {
      expect(WebSearchIntentParser.explicitUserQuery('我們來聊聊台北的天氣'), isNull);
      expect(
        WebSearchIntentParser.explicitUserQuery(
          'Please search the web [gift:secret] for weather',
        ),
        isNull,
      );
    });
  });
}
