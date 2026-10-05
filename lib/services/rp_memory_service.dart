import '../memory/retriever.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../models/context_mode.dart';
import 'deferred_prompt.dart';
import 'memory_actions.dart';

/// RP memory facade. The storage/search primitives are shared, while this
/// boundary permanently selects the ordinary engine and RP scope.
abstract final class RpMemoryService {
  static String abilityPrompt({
    required String userNickname,
    required String characterName,
  }) => MemoryActions.abilityPrompt(
    userNickname: userNickname,
    characterName: characterName,
    contextMode: ContextMode.rp,
  );

  static Future<DeferredPrompt> buildPrompt({
    required String mode,
    required String currentMessage,
    required String characterId,
    required String windowId,
    required String continuityId,
    bool emotionEnabled = true,
  }) async {
    final prompt = await Retriever.buildMemoryPrompt(
      mode: mode,
      currentMessage: currentMessage,
      characterId: characterId,
      windowId: windowId,
      emotionEnabled: emotionEnabled,
      contextMode: ContextMode.rp,
      continuityId: continuityId,
    );
    debugPrint(
      '[RpMemoryDebug] phase=recall character=$characterId '
      'continuity=$continuityId chars=${prompt.text.length}',
    );
    return prompt;
  }

  static Future<String> processReply(
    String text, {
    required String characterId,
    required String mode,
    required String windowId,
    required String continuityId,
    bool emotionEnabled = true,
    bool resetState = true,
  }) async {
    final visible = await MemoryActions.processReply(
      text,
      characterId: characterId,
      mode: mode,
      windowId: windowId,
      emotionEnabled: emotionEnabled,
      resetState: resetState,
      contextMode: ContextMode.rp,
      continuityId: continuityId,
    );
    debugPrint(
      '[RpMemoryDebug] phase=write character=$characterId '
      'continuity=$continuityId actions='
      '${MemoryActions.lastActionLogFor(windowId).length}',
    );
    return visible;
  }
}
