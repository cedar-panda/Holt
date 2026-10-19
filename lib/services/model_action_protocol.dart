import 'dart:convert';

import 'locale_strings.dart';
import 'model_stream_decoder.dart';
import 'tool_runner.dart';

enum HoltActionTransport { nativeToolCall, json, legacyXml }

class HoltAction {
  const HoltAction({
    required this.type,
    required this.arguments,
    required this.transport,
    this.callId,
  });

  final String type;
  final Map<String, Object?> arguments;
  final HoltActionTransport transport;
  final String? callId;

  factory HoltAction.fromToolCall(ToolCall call) => HoltAction(
    type: call.name,
    arguments: call.arguments,
    transport: HoltActionTransport.nativeToolCall,
    callId: call.id,
  );
}

/// Normalizes provider-native calls, Holt JSON actions and legacy XML into one
/// action contract. Existing feature processors still consume their proven XML
/// forms; JSON/native transports are translated locally during migration.
abstract final class ModelActionProtocol {
  static const String jsonStart = ModelStreamDecoder.jsonActionStart;
  static const String jsonEnd = ModelStreamDecoder.jsonActionEnd;

  static final RegExp _jsonBlock = RegExp(
    '${RegExp.escape(jsonStart)}([\\s\\S]*?)${RegExp.escape(jsonEnd)}',
    caseSensitive: false,
  );

  static String promptHeader() => L.pick(
    en:
        '【Available Tools · Private Holt Actions】\n'
        'When an action is needed, put every action together at the very end '
        'in exactly one JSON block. Skip the block when no action is needed. '
        'The visible reply comes first and must never mention the block or its '
        'actions. Use only the action types described below.\n'
        '$jsonStart\n'
        '{"actions":[{"type":"action.name","arguments":{}}]}\n'
        '$jsonEnd',
    zhTW:
        '【可用工具 · Holt 私有動作】\n'
        '需要執行動作時，把本輪所有動作集中放在回覆最末端唯一一個 JSON '
        '區塊內；沒有需要就完全不輸出區塊。可見正文必須在前，且不得提及區塊或動作。'
        '只使用下方已說明的動作類型。\n'
        '$jsonStart\n'
        '{"actions":[{"type":"action.name","arguments":{}}]}\n'
        '$jsonEnd',
    zhCN:
        '【可用工具 · Holt 私有动作】\n'
        '需要执行动作时，把本轮所有动作集中放在回复最末端唯一一个 JSON '
        '区块内；没有需要就完全不输出区块。可见正文必须在前，且不得提及区块或动作。'
        '只使用下方已说明的动作类型。\n'
        '$jsonStart\n'
        '{"actions":[{"type":"action.name","arguments":{}}]}\n'
        '$jsonEnd',
  );

  static List<HoltAction> decodeJson(String raw) {
    final actions = <HoltAction>[];
    for (final match in _jsonBlock.allMatches(raw)) {
      final payload = match.group(1)?.trim() ?? '';
      if (payload.isEmpty) continue;
      try {
        final decoded = jsonDecode(payload);
        final rawActions = decoded is Map
            ? decoded['actions']
            : decoded is List
            ? decoded
            : null;
        if (rawActions is! List) continue;
        for (final rawAction in rawActions) {
          if (rawAction is! Map) continue;
          final type = rawAction['type']?.toString().trim() ?? '';
          if (!RegExp(r'^[a-z][a-z0-9_.-]{1,63}$').hasMatch(type)) continue;
          final arguments = <String, Object?>{};
          final rawArguments = rawAction['arguments'];
          if (rawArguments is Map) {
            for (final entry in rawArguments.entries) {
              arguments[entry.key.toString()] = entry.value;
            }
          }
          actions.add(
            HoltAction(
              type: type,
              arguments: Map<String, Object?>.unmodifiable(arguments),
              transport: HoltActionTransport.json,
            ),
          );
        }
      } on FormatException {
        // Invalid private actions fail closed and never become visible text.
      }
    }
    return List<HoltAction>.unmodifiable(actions);
  }

  static List<HoltAction> decodeToolCalls(Iterable<ToolCall> calls) =>
      List<HoltAction>.unmodifiable(calls.map(HoltAction.fromToolCall));

  static String normalizeForLegacyProcessors(
    String raw, {
    Iterable<ToolCall> toolCalls = const <ToolCall>[],
  }) {
    final actions = <HoltAction>[
      ...decodeToolCalls(toolCalls),
      ...decodeJson(raw),
    ];
    final proseAndLegacyXml = raw.replaceAll(_jsonBlock, '').trimRight();
    if (actions.isEmpty) return proseAndLegacyXml;
    final legacy = actions
        .map(_toLegacyXml)
        .where((value) => value.isNotEmpty)
        .join('\n');
    if (legacy.isEmpty) return proseAndLegacyXml;
    return proseAndLegacyXml.isEmpty ? legacy : '$proseAndLegacyXml\n$legacy';
  }

  static String _toLegacyXml(HoltAction action) {
    final args = action.arguments;
    String text(String key) => _safeText(args[key]);
    String list(String key) {
      final value = args[key];
      if (value is List) {
        return value.map(_safeText).where((part) => part.isNotEmpty).join(',');
      }
      return _safeText(value);
    }

    switch (action.type) {
      case 'memory.propose':
        final category = text('category');
        final content = text('content');
        final triggers = list('triggers');
        if (content.isEmpty) return '';
        return '<memo>[${category.isEmpty ? '重要事件' : category}] $content${triggers.isEmpty ? '' : ' @$triggers'}</memo>';
      case 'memory.delete':
        final ids = list('ids');
        return ids.isEmpty ? '' : '<memo_del>$ids</memo_del>';
      case 'memory.merge':
        final ids = list('ids');
        final category = text('category');
        final content = text('content');
        final triggers = list('triggers');
        if (ids.isEmpty || content.isEmpty) return '';
        return '<memo_merge>$ids|[${category.isEmpty ? '重要事件' : category}] $content${triggers.isEmpty ? '' : ' @$triggers'}</memo_merge>';
      case 'memory.update':
        final id = text('id');
        final content = text('content');
        return id.isEmpty || content.isEmpty
            ? ''
            : '<memo_update>$id|$content</memo_update>';
      case 'memory.link':
        final ids = list('ids');
        return ids.isEmpty ? '' : '<memo_link>$ids</memo_link>';
      case 'memory.force_recall':
        final query = text('query');
        return query.isEmpty ? '' : '<force_recall>$query</force_recall>';
      case 'self_note.add':
        final content = text('content');
        return content.isEmpty ? '' : '<persona_note>$content</persona_note>';
      case 'search.chat':
        final query = text('query');
        final scope = text('scope');
        return query.isEmpty
            ? ''
            : '<search_chat${scope.isEmpty ? '' : ' scope="$scope"'}>$query</search_chat>';
      case 'search.web':
        final query = text('query');
        return query.isEmpty ? '' : '<search_web>$query</search_web>';
      case 'emotion.record':
        final dimension = text('dimension');
        final x = text('x');
        final y = text('y');
        final intensity = text('intensity');
        final note = text('note');
        if (dimension.isEmpty || x.isEmpty || y.isEmpty || intensity.isEmpty) {
          return '';
        }
        return '<emo>$dimension|$x,$y|$intensity|$note</emo>';
      case 'emotion.resolve':
        final dimension = text('dimension');
        return dimension.isEmpty ? '' : '<emo_resolve>$dimension</emo_resolve>';
      case 'clock.record':
        final time = text('time');
        final content = text('content');
        final keywords = list('keywords');
        if (time.isEmpty || content.isEmpty) return '';
        return '<clock>$time $content${keywords.isEmpty ? '' : ' @$keywords'}</clock>';
      case 'clock.keep':
      case 'clock.delete':
        final id = text('id');
        if (id.isEmpty) return '';
        final tag = action.type == 'clock.keep' ? 'clock_keep' : 'clock_del';
        return '<$tag>$id</$tag>';
      case 'clock.update':
        final id = text('id');
        final time = text('time');
        final content = text('content');
        final keywords = list('keywords');
        if (id.isEmpty || time.isEmpty || content.isEmpty) return '';
        return '<clock_update>$id|$time $content${keywords.isEmpty ? '' : ' @$keywords'}</clock_update>';
      case 'image.draw':
        final prompt = text('prompt');
        return prompt.isEmpty ? '' : '<draw>$prompt</draw>';
      case 'home.note':
        final content = text('content');
        return content.isEmpty ? '' : '<home>$content</home>';
      case 'whisper.set':
        final content = text('content');
        return content.isEmpty ? '' : '<whisper>$content</whisper>';
      case 'scratch.send':
        return '<scratch who="${text('who').isEmpty ? 'char' : text('who')}"/>';
      case 'transfer.send':
        final amount = text('amount');
        return amount.isEmpty ? '' : '<transfer amount="$amount"/>';
      case 'transfer.accept':
        return '<transfer_accept/>';
      case 'transfer.decline':
        return '<transfer_decline/>';
      case 'call.start':
        return '<call>${text('opening')}</call>';
      case 'call.decline':
        return '<decline_call/>';
      case 'call.hangup':
        return '<hangup/>';
      case 'shop.view':
        return '<shop_view/>';
      case 'shop.buy':
        final item = text('item');
        final target = text('target');
        return item.isEmpty
            ? ''
            : '<buy item="$item"${target.isEmpty ? '' : ' target="$target"'}/>';
      case 'social.x_post':
        final content = text('content');
        return content.isEmpty ? '' : '<x_post>$content</x_post>';
      case 'marriage.sign':
        return '<sign_marriage/>';
      case 'marriage.propose':
        return '<propose_marriage/>';
      case 'diary.write':
        final title = _xmlText(args['title']);
        final body = _xmlText(args['body'] ?? args['content']);
        if (body.isEmpty) return '';
        return '<holt_diary version="1"><title>$title</title><body>$body</body></holt_diary>';
      case 'email.draft':
        final content = text('content');
        return content.isEmpty ? '' : '<email_draft>$content</email_draft>';
      case 'persona.draft':
        final content = text('content');
        return content.isEmpty
            ? ''
            : '<holt_persona_draft>$content</holt_persona_draft>';
      default:
        return '';
    }
  }

  static String _safeText(Object? value) => (value?.toString() ?? '')
      .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), '')
      .replaceAll('<', '‹')
      .replaceAll('>', '›')
      .trim();

  static String _xmlText(Object? value) => (value?.toString() ?? '')
      .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;')
      .trim();
}
