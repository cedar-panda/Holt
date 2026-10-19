import 'dart:convert';

class GuidePersonaDraft {
  const GuidePersonaDraft({
    required this.name,
    this.gender = '',
    this.relationship = '',
    this.description = '',
    this.race = '',
    this.skill = '',
    this.age = '',
    this.height = '',
  });

  final String name;
  final String gender;
  final String relationship;
  final String description;
  final String race;
  final String skill;
  final String age;
  final String height;

  Map<String, String> toJson() => <String, String>{
    'name': name,
    'gender': gender,
    'relationship': relationship,
    'description': description,
    'race': race,
    'skill': skill,
    'age': age,
    'height': height,
  };

  String encode() => jsonEncode(toJson());

  static GuidePersonaDraft? fromJson(Object? value) {
    if (value is String) {
      try {
        return fromJson(jsonDecode(value));
      } catch (_) {
        return null;
      }
    }
    if (value is! Map) return null;
    String field(String key) => '${value[key] ?? ''}'.trim();
    final name = field('name');
    if (name.isEmpty) return null;
    return GuidePersonaDraft(
      name: name,
      gender: field('gender'),
      relationship: field('relationship'),
      description: field('description'),
      race: field('race'),
      skill: field('skill'),
      age: field('age'),
      height: field('height'),
    );
  }

  GuidePersonaDraft copyWith({
    String? name,
    String? gender,
    String? relationship,
    String? description,
    String? race,
    String? skill,
    String? age,
    String? height,
  }) => GuidePersonaDraft(
    name: name ?? this.name,
    gender: gender ?? this.gender,
    relationship: relationship ?? this.relationship,
    description: description ?? this.description,
    race: race ?? this.race,
    skill: skill ?? this.skill,
    age: age ?? this.age,
    height: height ?? this.height,
  );
}

class PersonaCardState {
  const PersonaCardState({required this.draft, this.createdCharacterId});

  final GuidePersonaDraft draft;
  final String? createdCharacterId;

  bool get isAdded => createdCharacterId?.trim().isNotEmpty == true;

  String encode() => jsonEncode(<String, Object?>{
    'draft': draft.toJson(),
    'created_character_id': createdCharacterId,
  });

  static PersonaCardState? decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final draft = GuidePersonaDraft.fromJson(decoded['draft']);
      if (draft == null) return null;
      final id = '${decoded['created_character_id'] ?? ''}'.trim();
      return PersonaCardState(
        draft: draft,
        createdCharacterId: id.isEmpty ? null : id,
      );
    } catch (_) {
      return null;
    }
  }
}
