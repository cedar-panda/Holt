/// 記憶資料模型（帶角色綁定 + 送審計數）
class Memory {
  final int? id;
  final String characterId;
  final String mode;
  final String category;
  final String content;
  final String? confidence;
  final String? narrativeWeight;
  final bool isPermanent;
  final String? sourceConversationId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime lastAccessed;
  final int mentionCount;
  final String status;
  final int reviewCount;

  /// 觸發詞（逗號分隔）：當前消息含任一觸發詞 → 該記憶被喚起
  final String triggers;

  final int? emotionX;
  final int? emotionY;
  final int? emotionResonance;

  Memory({
    this.id,
    this.characterId = 'default',
    required this.mode,
    required this.category,
    required this.content,
    this.confidence,
    this.narrativeWeight,
    this.isPermanent = false,
    this.sourceConversationId,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.mentionCount = 0,
    this.status = 'active',
    this.reviewCount = 0,
    this.triggers = '',
    this.emotionX,
    this.emotionY,
    this.emotionResonance,
    DateTime? lastAccessed,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now(),
       lastAccessed = lastAccessed ?? createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'character_id': characterId,
      'mode': mode,
      'category': category,
      'content': content,
      'confidence': confidence,
      'narrative_weight': narrativeWeight,
      'is_permanent': isPermanent ? 1 : 0,
      'source_conversation_id': sourceConversationId,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'last_accessed': lastAccessed.toIso8601String(),
      'mention_count': mentionCount,
      'status': status,
      'review_count': reviewCount,
      'triggers': triggers,
      'emotion_x': emotionX,
      'emotion_y': emotionY,
      'emotion_resonance': emotionResonance,
    };
  }

  factory Memory.fromMap(Map<String, dynamic> map) {
    return Memory(
      id: map['id'] as int?,
      characterId: map['character_id'] as String? ?? 'default',
      mode: map['mode'] as String,
      category: map['category'] as String,
      content: map['content'] as String,
      confidence: map['confidence'] as String?,
      narrativeWeight: map['narrative_weight'] as String?,
      isPermanent: (map['is_permanent'] as int) == 1,
      sourceConversationId: map['source_conversation_id'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      mentionCount: map['mention_count'] as int? ?? 0,
      status: map['status'] as String? ?? 'active',
      reviewCount: map['review_count'] as int? ?? 0,
      triggers: map['triggers'] as String? ?? '',
      lastAccessed:
          (map['last_accessed'] != null &&
              (map['last_accessed'] as String).isNotEmpty)
          ? DateTime.parse(map['last_accessed'] as String)
          : DateTime.parse(map['created_at'] as String),
      emotionX: map['emotion_x'] as int?,
      emotionY: map['emotion_y'] as int?,
      emotionResonance: map['emotion_resonance'] as int?,
    );
  }
}
