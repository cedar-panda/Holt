class ChatDiagnosticEvent {
  const ChatDiagnosticEvent({
    this.id,
    required this.conversationId,
    required this.sourceMessageId,
    required this.anchorMessageId,
    required this.category,
    this.statusCode,
    this.provider = '',
    this.model = '',
    this.rawLog = '',
    required this.createdAt,
  });

  final int? id;
  final String conversationId;
  final int sourceMessageId;
  final int anchorMessageId;
  final String category;
  final int? statusCode;
  final String provider;
  final String model;
  final String rawLog;
  final DateTime createdAt;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'conversation_id': conversationId,
    'source_message_id': sourceMessageId,
    'anchor_message_id': anchorMessageId,
    'category': category,
    'status_code': statusCode,
    'provider': provider,
    'model': model,
    'raw_log': rawLog,
    'created_at': createdAt.toIso8601String(),
  };

  factory ChatDiagnosticEvent.fromMap(Map<String, Object?> map) {
    return ChatDiagnosticEvent(
      id: map['id'] as int?,
      conversationId: map['conversation_id'] as String,
      sourceMessageId: map['source_message_id'] as int,
      anchorMessageId: map['anchor_message_id'] as int,
      category: map['category'] as String,
      statusCode: map['status_code'] as int?,
      provider: map['provider'] as String? ?? '',
      model: map['model'] as String? ?? '',
      rawLog: map['raw_log'] as String? ?? '',
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
