import 'package:uuid/uuid.dart';

import '../memory/database.dart';
import 'settings/user_settings.dart';

class InitialCharacterDraft {
  const InitialCharacterDraft({
    required this.name,
    this.gender = '',
    this.relationship = '',
    this.description = '',
  });

  final String name;
  final String gender;
  final String relationship;
  final String description;
}

/// 首次設定只負責建立完整角色系統能直接使用的最小資料列。
class InitialSetupService {
  static Future<String> createCharacter(InitialCharacterDraft draft) async {
    final name = draft.name.trim();
    if (name.isEmpty) throw ArgumentError.value(draft.name, 'name');

    final id = const Uuid().v4();
    final now = DateTime.now().toIso8601String();
    await DatabaseHelper.insertCharacter({
      'id': id,
      'name': name,
      'gender': draft.gender.trim(),
      'relationship': draft.relationship.trim(),
      'description': draft.description.trim(),
      'created_at': now,
      'updated_at': now,
    });
    await UserSettings.saveCharacterName(name);
    await UserSettings.saveActiveCharacterId(id);
    return id;
  }
}
