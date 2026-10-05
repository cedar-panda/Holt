class CharacterDiaryEntry {
  const CharacterDiaryEntry({
    required this.id,
    required this.characterId,
    required this.diaryDate,
    required this.title,
    required this.body,
    required this.sourceConversationId,
    required this.sourceMessageId,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String characterId;
  final String diaryDate;
  final String title;
  final String body;
  final String sourceConversationId;
  final int? sourceMessageId;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory CharacterDiaryEntry.fromRow(Map<String, Object?> row) {
    return CharacterDiaryEntry(
      id: row['id'] as int,
      characterId: row['character_id']?.toString() ?? '',
      diaryDate: row['diary_date']?.toString() ?? '',
      title: row['title']?.toString() ?? '',
      body: row['body']?.toString() ?? '',
      sourceConversationId: row['source_conversation_id']?.toString() ?? '',
      sourceMessageId: row['source_message_id'] as int?,
      createdAt: DateTime.parse(row['created_at']!.toString()).toLocal(),
      updatedAt: DateTime.parse(row['updated_at']!.toString()).toLocal(),
    );
  }
}
