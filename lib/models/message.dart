import 'dart:convert';

import 'email_draft.dart';
import 'context_mode.dart';
import 'web_search_trace.dart';

/// 訊息資料模型（帶角色綁定）
class Message {
  static const String rpChapterContinuationPrefix =
      '[holt:continue_rp_chapter]';
  static const String _rpChapterContinuationSourcePrefix =
      '[holt:continue_rp_source:';
  static const String _rpChapterContinuationAnchorPrefix =
      '[holt:continue_rp_anchor:';

  final int? id;
  final String conversationId;
  final String characterId;
  final String text;
  final bool isUser;
  final String? imagePath;

  /// All images attached to this message. [imagePath] remains the first-image
  /// compatibility field for older callers and database rows.
  final List<String> imagePaths;
  final bool splitMode;
  final bool cacheHit;
  final String status;
  final int revision;

  static const String statusComplete = '';
  static const String statusIncomplete = 'incomplete';

  bool get isIncomplete => status == statusIncomplete;
  bool get isRpChapterContinuation =>
      isUser && text.trimLeft().startsWith(rpChapterContinuationPrefix);

  /// Persists which window an RP continuation came from without adding a
  /// schema column. The marker lives only in the hidden continuation action
  /// and is removed before provider history is assembled.
  static String rpChapterContinuationSourceMarker(String conversationId) =>
      '$_rpChapterContinuationSourcePrefix'
      '${Uri.encodeComponent(conversationId)}]';

  static String rpChapterContinuationAnchorMarker(int messageId) =>
      '$_rpChapterContinuationAnchorPrefix$messageId]';

  String? get rpChapterContinuationSourceId {
    if (!isRpChapterContinuation) return null;
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (!line.startsWith(_rpChapterContinuationSourcePrefix) ||
          !line.endsWith(']')) {
        continue;
      }
      final encoded = line.substring(
        _rpChapterContinuationSourcePrefix.length,
        line.length - 1,
      );
      if (encoded.isEmpty) return null;
      try {
        final decoded = Uri.decodeComponent(encoded).trim();
        return decoded.isEmpty ? null : decoded;
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  int? get rpChapterContinuationAnchorMessageId {
    if (!isRpChapterContinuation) return null;
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (!line.startsWith(_rpChapterContinuationAnchorPrefix) ||
          !line.endsWith(']')) {
        continue;
      }
      return int.tryParse(
        line.substring(
          _rpChapterContinuationAnchorPrefix.length,
          line.length - 1,
        ),
      );
    }
    return null;
  }

  String get promptVisibleText {
    if (!isRpChapterContinuation) return text;
    return text
        .split('\n')
        .where(
          (rawLine) =>
              !rawLine.trim().startsWith(_rpChapterContinuationSourcePrefix) &&
              !rawLine.trim().startsWith(_rpChapterContinuationAnchorPrefix),
        )
        .join('\n')
        .trim();
  }

  /// Provider-facing history is intentionally limited to role and visible
  /// message text. UI metadata such as web-search traces never enters prompts.
  Map<String, String> toPromptHistoryEntry() => <String, String>{
    'role': isUser ? 'user' : 'assistant',
    'content': promptVisibleText,
  };

  /// 記憶過程日誌（本輪注入/寫入/刪除/合併的可視記錄）
  final String memoryLog;
  final WebSearchDisplayTrace? webSearchTrace;
  final EmailDraft? emailDraft;
  final DateTime createdAt;

  Message({
    this.id,
    required this.conversationId,
    this.characterId = 'default',
    required this.text,
    required this.isUser,
    String? imagePath,
    List<String>? imagePaths,
    this.splitMode = false,
    this.cacheHit = false,
    this.status = statusComplete,
    this.revision = 1,
    this.memoryLog = '',
    this.webSearchTrace,
    this.emailDraft,
    DateTime? createdAt,
  }) : imagePath = _firstImagePath(imagePaths, imagePath),
       imagePaths = _normalizeImagePaths(imagePaths, imagePath),
       createdAt = createdAt ?? DateTime.now();

  static String? _firstImagePath(List<String>? paths, String? legacyPath) {
    final normalized = _normalizeImagePaths(paths, legacyPath);
    return normalized.isEmpty ? null : normalized.first;
  }

  static List<String> _normalizeImagePaths(
    List<String>? paths,
    String? legacyPath,
  ) {
    final values = <String>[];
    for (final path in paths ?? const <String>[]) {
      final trimmed = path.trim();
      if (trimmed.isNotEmpty && !values.contains(trimmed)) values.add(trimmed);
    }
    if (values.isEmpty && legacyPath != null && legacyPath.trim().isNotEmpty) {
      values.add(legacyPath.trim());
    }
    return List<String>.unmodifiable(values);
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'conversation_id': conversationId,
      'character_id': characterId,
      'text': text,
      'is_user': isUser ? 1 : 0,
      'image_path': imagePath,
      'image_paths_json': jsonEncode(imagePaths),
      'split_mode': splitMode ? 1 : 0,
      'cache_hit': cacheHit ? 1 : 0,
      'status': status,
      'revision': revision,
      'memory_log': memoryLog,
      'web_search_trace_json': webSearchTrace?.encode() ?? '',
      'email_draft_json': emailDraft?.encode() ?? '',
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory Message.fromMap(Map<String, dynamic> map) {
    final rawPaths = map['image_paths_json'];
    final decodedPaths = <String>[];
    if (rawPaths is String && rawPaths.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPaths);
        if (decoded is List) {
          decodedPaths.addAll(
            decoded.whereType<String>().where((path) => path.trim().isNotEmpty),
          );
        }
      } catch (_) {
        // A legacy or damaged row still falls back to image_path below.
      }
    }
    return Message(
      id: map['id'] as int?,
      conversationId: map['conversation_id'] as String,
      characterId: map['character_id'] as String? ?? 'default',
      text: map['text'] as String,
      isUser: (map['is_user'] as int) == 1,
      imagePath: map['image_path'] as String?,
      imagePaths: decodedPaths,
      splitMode: (map['split_mode'] as int? ?? 0) == 1,
      cacheHit: (map['cache_hit'] as int? ?? 0) == 1,
      status: map['status'] as String? ?? statusComplete,
      revision: map['revision'] as int? ?? 1,
      memoryLog: map['memory_log'] as String? ?? '',
      webSearchTrace: WebSearchDisplayTrace.decode(
        map['web_search_trace_json'] as String?,
      ),
      emailDraft: EmailDraft.decode(map['email_draft_json'] as String?),
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}

/// 對話資料模型（帶角色綁定）
class Conversation {
  final String id;
  final String characterId;
  final ContextMode contextMode;
  final String continuityId;
  final String? userPersonaId;
  final String userPersonaSnapshot;
  final String? worldbookSetId;
  final String windowSummaryId;
  final String? title;
  final bool isStarred;
  final DateTime createdAt;
  final DateTime updatedAt;

  Conversation({
    required this.id,
    this.characterId = 'default',
    this.contextMode = ContextMode.daily,
    this.continuityId = 'main',
    this.userPersonaId,
    this.userPersonaSnapshot = '',
    this.worldbookSetId,
    this.windowSummaryId = '',
    this.title,
    this.isStarred = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'character_id': characterId,
      'context_mode': contextMode.storageValue,
      'continuity_id': continuityId,
      'user_persona_id': userPersonaId,
      'user_persona_snapshot': userPersonaSnapshot,
      'worldbook_set_id': worldbookSetId,
      'window_summary_id': windowSummaryId,
      'title': title,
      'is_starred': isStarred ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Conversation.fromMap(Map<String, dynamic> map) {
    return Conversation(
      id: map['id'] as String,
      characterId: map['character_id'] as String? ?? 'default',
      contextMode: ContextMode.fromStorage(map['context_mode']),
      continuityId: map['continuity_id'] as String,
      userPersonaId: _nullableId(map['user_persona_id']),
      userPersonaSnapshot: map['user_persona_snapshot'] as String? ?? '',
      worldbookSetId: _nullableId(map['worldbook_set_id']),
      windowSummaryId: map['window_summary_id'] as String? ?? '',
      title: map['title'] as String?,
      isStarred: (map['is_starred'] as int? ?? 0) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  static String? _nullableId(Object? raw) {
    final value = raw?.toString().trim() ?? '';
    return value.isEmpty ? null : value;
  }
}

class RpChapterContinuationSource {
  const RpChapterContinuationSource({
    required this.conversation,
    required this.lastMessageAt,
    required this.messages,
    required this.summaries,
  });

  final Conversation conversation;
  final DateTime lastMessageAt;
  final List<Message> messages;
  final List<String> summaries;
}
