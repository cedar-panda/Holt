import '../models/email_draft.dart';
import '../memory/database.dart';

class EmailDraftRepository {
  const EmailDraftRepository._();

  static Future<void> saveForMessage(int messageId, EmailDraft? draft) async {
    final database = await DatabaseHelper.database;
    final updated = await database.update(
      'messages',
      <String, Object?>{'email_draft_json': draft?.encode() ?? ''},
      where: 'id = ?',
      whereArgs: <Object?>[messageId],
    );
    if (updated != 1) {
      throw StateError('Email draft message no longer exists.');
    }
  }
}
