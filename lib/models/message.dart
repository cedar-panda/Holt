/// 訊息資料模型（帶角色綁定）
class Message {
  final int? id;
  final String conversationId;
  final String characterId;
  final String text;
  final bool isUser;
  final String? imagePath;
  final bool splitMode;
  final bool cacheHit;

  /// 記憶過程日誌（本輪注入/寫入/刪除/合併的可視記錄）
  final String memoryLog;
  final DateTime createdAt;

  Message({
    this.id,
    required this.conversationId,
    this.characterId = 'default',
    required this.text,
    required this.isUser,
    this.imagePath,
    this.splitMode = false,
    this.cacheHit = false,
    this.memoryLog = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'conversation_id': conversationId,
      'character_id': characterId,
      'text': text,
      'is_user': isUser ? 1 : 0,
      'image_path': imagePath,
      'split_mode': splitMode ? 1 : 0,
      'cache_hit': cacheHit ? 1 : 0,
      'memory_log': memoryLog,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['id'] as int?,
      conversationId: map['conversation_id'] as String,
      characterId: map['character_id'] as String? ?? 'default',
      text: map['text'] as String,
      isUser: (map['is_user'] as int) == 1,
      imagePath: map['image_path'] as String?,
      splitMode: (map['split_mode'] as int? ?? 0) == 1,
      cacheHit: (map['cache_hit'] as int? ?? 0) == 1,
      memoryLog: map['memory_log'] as String? ?? '',
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}

/// 對話資料模型（帶角色綁定）
class Conversation {
  final String id;
  final String characterId;
  final String windowSummaryId;
  final String? title;
  final bool isStarred;
  final DateTime createdAt;
  final DateTime updatedAt;

  Conversation({
    required this.id,
    this.characterId = 'default',
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
      windowSummaryId: map['window_summary_id'] as String? ?? '',
      title: map['title'] as String?,
      isStarred: (map['is_starred'] as int? ?? 0) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }
}
