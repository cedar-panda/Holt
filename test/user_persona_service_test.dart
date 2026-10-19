import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/user_persona_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'user_profile_nickname': '小禾',
      'user_profile_pronouns': '他',
      'user_profile_bio': '預設身分',
    });
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    final now = DateTime.now().toIso8601String();
    await db.insert('characters', <String, Object?>{
      'id': 'char-a',
      'name': 'A',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('characters', <String, Object?>{
      'id': 'char-b',
      'name': 'B',
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('legacy profile hydrates the stable default persona', () async {
    final persona = await UserPersonaService.ensureDefaultPersona();

    expect(persona.id, UserPersonaService.defaultPersonaId);
    expect(persona.displayName, '小禾');
    expect(persona.pronouns, '他');
    expect(persona.bio, '預設身分');
    expect(persona.isDefault, isTrue);
  });

  test(
    'identity and Profile overrides are isolated by persona and mode',
    () async {
      final persona = await UserPersonaService.createPersona(
        id: 'mode-role',
        displayName: 'Shared name',
        bio: 'Shared bio',
      );
      await UserPersonaService.saveModeIdentity(
        personaId: persona.id,
        contextMode: ContextMode.rp,
        displayName: 'RP name',
        pronouns: 'he',
        bio: 'RP bio',
      );
      await UserPersonaService.saveProfileGuide(
        persona.id,
        ContextMode.daily,
        'daily guide',
      );
      await UserPersonaService.saveProfileGuide(
        persona.id,
        ContextMode.rp,
        'rp guide',
      );

      final daily = (await UserPersonaService.personaForMode(
        persona.id,
        ContextMode.daily,
      ))!;
      final rp = (await UserPersonaService.personaForMode(
        persona.id,
        ContextMode.rp,
      ))!;
      expect(daily.displayName, 'Shared name');
      expect(daily.bio, 'Shared bio');
      expect(daily.promptContent, 'daily guide');
      expect(rp.displayName, 'RP name');
      expect(rp.bio, 'RP bio');
      expect(rp.promptContent, 'rp guide');
    },
  );

  test('RP inherits Daily fields until each RP field diverges', () async {
    final persona = await UserPersonaService.createPersona(
      id: 'inherited-role',
      displayName: 'Base name',
    );
    await UserPersonaService.saveModeIdentity(
      personaId: persona.id,
      contextMode: ContextMode.daily,
      displayName: 'Daily name',
      pronouns: '他',
      bio: 'Daily bio',
    );
    await UserPersonaService.saveProfileGuide(
      persona.id,
      ContextMode.daily,
      'first line\nsecond line\nthird line',
    );

    var rp = (await UserPersonaService.personaForMode(
      persona.id,
      ContextMode.rp,
    ))!;
    expect(rp.displayName, 'Daily name');
    expect(rp.bio, 'Daily bio');
    expect(rp.promptContent, 'first line\nsecond line\nthird line');

    await UserPersonaService.saveModeIdentity(
      personaId: persona.id,
      contextMode: ContextMode.rp,
      displayName: 'RP name',
      pronouns: '他',
      bio: 'Daily bio',
    );
    rp = (await UserPersonaService.personaForMode(persona.id, ContextMode.rp))!;
    expect(rp.displayName, 'RP name');
    expect(rp.bio, 'Daily bio');

    await UserPersonaService.selectPersona(persona.id);
    final window = await UserPersonaService.resolveForNewWindow(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
    );
    final snapshot = UserPersona.fromPromptSnapshot(window.promptSnapshot);
    expect(snapshot.promptContent, 'first line\nsecond line\nthird line');
  });

  test(
    'persona prompt uses the existing profile slot in three languages',
    () async {
      final now = DateTime.now();
      final persona = UserPersona(
        id: 'persona-language',
        displayName: 'Zhao',
        pronouns: 'he',
        bio: 'traveler',
        promptContent: 'night watchman',
        createdAt: now,
        updatedAt: now,
      );

      await L.setLocale('zh_TW');
      expect(UserPersonaService.buildPrompt(persona), contains('【用戶角色】'));
      expect(UserPersonaService.buildPrompt(persona), contains('角色身分：'));
      await L.setLocale('zh_CN');
      expect(UserPersonaService.buildPrompt(persona), contains('【用户角色】'));
      expect(UserPersonaService.buildPrompt(persona), contains('角色身份：'));
      await L.setLocale('en');
      expect(
        UserPersonaService.buildPrompt(persona),
        contains('【User Persona】'),
      );
      expect(UserPersonaService.buildPrompt(persona), contains('Persona:'));
    },
  );

  test('binding is shared while persona files remain mode-specific', () async {
    final persona = await UserPersonaService.createPersona(
      id: 'persona-shared',
      displayName: '平時的我',
    );
    await UserPersonaService.saveModeIdentity(
      personaId: persona.id,
      contextMode: ContextMode.daily,
      displayName: '日常的我',
      pronouns: '他',
      bio: '日常檔案',
    );
    await UserPersonaService.saveModeIdentity(
      personaId: persona.id,
      contextMode: ContextMode.rp,
      displayName: '劇中人',
      pronouns: '他',
      bio: 'RP 檔案',
    );
    await UserPersonaService.bindPersona(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
      continuityId: 'route-b',
      personaId: persona.id,
    );

    final daily = await UserPersonaService.resolveForNewWindow(
      characterId: 'char-a',
      contextMode: ContextMode.daily,
    );
    final rp = await UserPersonaService.resolveForNewWindow(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
      continuityId: 'another-route',
    );
    expect(daily.persona.id, persona.id);
    expect(daily.persona.displayName, '日常的我');
    expect(rp.persona.id, persona.id);
    expect(rp.persona.displayName, '劇中人');
  });

  test('rebinding replaces the shared future-window binding', () async {
    final first = await UserPersonaService.createPersona(
      id: 'persona-first',
      displayName: 'First',
    );
    final second = await UserPersonaService.createPersona(
      id: 'persona-second',
      displayName: 'Second',
    );
    await UserPersonaService.bindPersona(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
      personaId: first.id,
    );
    await UserPersonaService.bindPersona(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
      personaId: second.id,
    );

    expect(await db.query('character_persona_bindings'), hasLength(1));
    expect(
      await UserPersonaService.boundPersonaId(
        characterId: 'char-a',
        contextMode: ContextMode.daily,
      ),
      second.id,
    );
  });

  test('single companion policy keeps the multi-bind storage seam', () async {
    final persona = await UserPersonaService.createPersona(
      id: 'single-binding-role',
    );
    await UserPersonaService.bindSingleCompanion(
      personaId: persona.id,
      characterId: 'char-a',
      contextMode: ContextMode.rp,
    );
    await UserPersonaService.bindSingleCompanion(
      personaId: persona.id,
      characterId: 'char-b',
      contextMode: ContextMode.daily,
    );

    expect(
      await UserPersonaService.companionIdForPersona(
        personaId: persona.id,
        contextMode: ContextMode.daily,
      ),
      'char-b',
    );
    expect(
      await UserPersonaService.bindingsForPersona(
        persona.id,
        contextMode: ContextMode.rp,
      ),
      hasLength(1),
    );
  });

  test('unbound characters use the explicitly selected role', () async {
    final persona = await UserPersonaService.createPersona(
      id: 'selected-role',
      displayName: 'Selected',
    );
    await UserPersonaService.selectPersona(persona.id);

    final resolved = await UserPersonaService.resolveForNewWindow(
      characterId: 'char-a',
      contextMode: ContextMode.daily,
    );
    expect(resolved.persona.id, persona.id);
  });

  test('window keeps its birth persona after edits and rebinding', () async {
    final original = await UserPersonaService.createPersona(
      id: 'persona-original',
      displayName: '阿昭',
      promptContent: '王國的巡夜人',
      avatarPath: '/avatar/original.webp',
    );
    final replacement = await UserPersonaService.createPersona(
      id: 'persona-replacement',
      displayName: '另一個我',
    );
    await UserPersonaService.bindPersona(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
      personaId: original.id,
    );
    final resolved = await UserPersonaService.resolveForNewWindow(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
    );
    await DatabaseHelper.createConversation(
      Conversation(
        id: 'rp-window',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        userPersonaId: resolved.persona.id,
        userPersonaSnapshot: resolved.promptSnapshot,
      ),
    );

    await UserPersonaService.updatePersona(
      UserPersona(
        id: original.id,
        displayName: '已改名',
        promptContent: '已改寫的人設',
        avatarPath: '/avatar/new.webp',
        createdAt: original.createdAt,
        updatedAt: original.updatedAt,
      ),
    );
    await UserPersonaService.bindPersona(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
      personaId: replacement.id,
    );

    final window = (await DatabaseHelper.getConversation('rp-window'))!;
    final pinned = await UserPersonaService.personaForConversation(window);
    expect(pinned.id, original.id);
    expect(pinned.displayName, '阿昭');
    expect(pinned.promptContent, '王國的巡夜人');
    expect(
      pinned.avatarPath,
      '/avatar/new.webp',
      reason: 'avatar media has one canonical portable path',
    );
    expect(
      (await UserPersonaService.resolveForNewWindow(
        characterId: 'char-a',
        contextMode: ContextMode.rp,
      )).persona.id,
      replacement.id,
    );
  });

  test('v1 window snapshots gain only the missing mode guide', () async {
    final persona = await UserPersonaService.createPersona(
      id: 'legacy-window-role',
      displayName: 'Today name',
    );
    await UserPersonaService.saveProfileGuide(
      persona.id,
      ContextMode.rp,
      'RP guide',
    );
    await DatabaseHelper.createConversation(
      Conversation(
        id: 'legacy-v1-window',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        userPersonaId: persona.id,
        userPersonaSnapshot:
            '{"version":1,"id":"legacy-window-role",'
            '"display_name":"Old name","pronouns":"old",'
            '"bio":"Old bio","prompt_content":""}',
      ),
    );

    final conversation = (await DatabaseHelper.getConversation(
      'legacy-v1-window',
    ))!;
    final resolved = await UserPersonaService.personaForConversation(
      conversation,
    );
    expect(resolved.displayName, 'Old name');
    expect(resolved.bio, 'Old bio');
    expect(resolved.promptContent, 'RP guide');
    expect(
      (await DatabaseHelper.getConversation(
        'legacy-v1-window',
      ))!.userPersonaSnapshot,
      contains('"version":2'),
    );
  });

  test('archiving removes future bindings but preserves old windows', () async {
    final persona = await UserPersonaService.createPersona(
      id: 'persona-archive',
      displayName: '封存前的我',
    );
    await UserPersonaService.bindPersona(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
      personaId: persona.id,
    );
    final resolved = await UserPersonaService.resolveForNewWindow(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
    );
    await DatabaseHelper.createConversation(
      Conversation(
        id: 'archived-persona-window',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        userPersonaId: persona.id,
        userPersonaSnapshot: resolved.promptSnapshot,
      ),
    );

    expect(await UserPersonaService.archivePersona(persona.id), isTrue);
    expect(await db.query('character_persona_bindings'), isEmpty);
    expect(
      (await UserPersonaService.resolveForNewWindow(
        characterId: 'char-a',
        contextMode: ContextMode.rp,
      )).persona.id,
      UserPersonaService.defaultPersonaId,
    );

    final oldWindow = (await DatabaseHelper.getConversation(
      'archived-persona-window',
    ))!;
    final pinned = await UserPersonaService.personaForConversation(oldWindow);
    expect(pinned.id, persona.id);
    expect(pinned.displayName, '封存前的我');
  });

  test(
    'archiving the initial identity selects another active identity',
    () async {
      final initial = await UserPersonaService.ensureDefaultPersona();
      final replacement = await UserPersonaService.createPersona(
        id: 'replacement-identity',
        displayName: '替代身分',
      );
      await UserPersonaService.selectPersona(initial.id);

      expect(await UserPersonaService.archivePersona(initial.id), isTrue);
      expect((await UserPersonaService.selectedPersona()).id, replacement.id);
      expect(
        (await UserPersonaService.listPersonas()).map((item) => item.id),
        contains(replacement.id),
      );
      expect(
        (await UserPersonaService.listPersonas()).map((item) => item.id),
        isNot(contains(initial.id)),
      );
    },
  );

  test('the last active identity cannot be archived', () async {
    final initial = await UserPersonaService.ensureDefaultPersona();

    expect(await UserPersonaService.archivePersona(initial.id), isFalse);
    expect((await UserPersonaService.selectedPersona()).id, initial.id);
  });

  test('legacy window is pinned to default, not the current binding', () async {
    final rp = await UserPersonaService.createPersona(
      id: 'persona-current-rp',
      displayName: 'Current RP',
    );
    await UserPersonaService.bindPersona(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
      personaId: rp.id,
    );
    await DatabaseHelper.createConversation(
      Conversation(
        id: 'legacy-window',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
      ),
    );

    final legacy = (await DatabaseHelper.getConversation('legacy-window'))!;
    final pinned = await UserPersonaService.ensureConversationPersona(legacy);
    expect(pinned.userPersonaId, UserPersonaService.defaultPersonaId);
    expect(
      (await UserPersonaService.personaForConversation(pinned)).displayName,
      '小禾',
    );
  });
}
