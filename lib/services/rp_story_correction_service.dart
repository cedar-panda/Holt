import '../memory/database.dart';
import 'locale_strings.dart';
import 'model_action_protocol.dart';
import 'rp_character_timeline_service.dart';
import 'rp_story_state_service.dart';

/// Applies narrowly scoped corrections explicitly requested by the latest
/// user message. The model may point at an existing stable key, but cannot
/// create records or treat its own narration as authority.
abstract final class RpStoryCorrectionService {
  static const int actionLimit = 2;

  static Future<List<String>> applyReplyActions(
    String rawReply, {
    required String characterId,
    required String continuityId,
    required String sourceConversationId,
    required int? sourceMessageId,
  }) async {
    if (sourceMessageId == null) return const <String>[];
    final source = await DatabaseHelper.getMessageById(sourceMessageId);
    if (source == null ||
        !source.isUser ||
        source.conversationId != sourceConversationId ||
        source.characterId != characterId) {
      return const <String>[];
    }
    final sourceText = source.promptVisibleText;
    final logs = <String>[];
    var accepted = 0;
    for (final action in ModelActionProtocol.decodeJson(rawReply)) {
      if (accepted >= actionLimit) break;
      final arguments = action.arguments;
      final evidence = _text(arguments, 'evidence');
      final value = _text(arguments, 'value');
      if (evidence.isEmpty || value.isEmpty || !sourceText.contains(evidence)) {
        continue;
      }
      switch (action.type) {
        case 'rp.timeline.correct':
          final eventKey = _text(arguments, 'event_key');
          if (eventKey.isEmpty) continue;
          final changed = await RpCharacterTimelineService.applyModelCorrection(
            characterId: characterId,
            continuityId: continuityId,
            sourceConversationId: sourceConversationId,
            sourceMessageId: sourceMessageId,
            eventKey: eventKey,
            value: value,
            storyTime: _text(arguments, 'story_time'),
            evidence: evidence,
          );
          if (!changed) continue;
          logs.add(
            L.pick(
              en: '↺ RP chronology corrected from the user’s exact text',
              zhTW: '↺ 已依 user 原文修正 RP 時間線',
              zhCN: '↺ 已依 user 原文修正 RP 时间线',
            ),
          );
          accepted += 1;
          continue;
        case 'rp.state.correct':
          final stateKey = _text(arguments, 'state_key');
          if (stateKey.isEmpty) continue;
          final changed = await RpStoryStateService.applyModelCorrection(
            characterId: characterId,
            continuityId: continuityId,
            sourceConversationId: sourceConversationId,
            sourceMessageId: sourceMessageId,
            stateKey: stateKey,
            value: value,
            status: _text(arguments, 'status'),
            evidence: evidence,
          );
          if (!changed) continue;
          logs.add(
            L.pick(
              en: '↺ RP story state corrected from the user’s exact text',
              zhTW: '↺ 已依 user 原文修正 RP 劇情狀態',
              zhCN: '↺ 已依 user 原文修正 RP 剧情状态',
            ),
          );
          accepted += 1;
          continue;
      }
    }
    return List<String>.unmodifiable(logs);
  }

  static String _text(Map<String, Object?> values, String key) =>
      values[key]?.toString().trim() ?? '';
}
