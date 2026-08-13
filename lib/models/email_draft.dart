import 'dart:convert';

/// A local-only email draft attached to one assistant message.
///
/// It is deliberately excluded from provider-facing prompt history. Opening an
/// email app is always a separate user action.
class EmailDraft {
  EmailDraft({
    required String to,
    required String subject,
    required String body,
  }) : to = _sanitizeHeader(to, maxRunes: 320),
       subject = _sanitizeHeader(subject, maxRunes: 200),
       body = _sanitizeBody(body, maxRunes: 8000);

  final String to;
  final String subject;
  final String body;

  bool get isEmpty => to.isEmpty && subject.isEmpty && body.isEmpty;

  EmailDraft copyWith({String? to, String? subject, String? body}) {
    return EmailDraft(
      to: to ?? this.to,
      subject: subject ?? this.subject,
      body: body ?? this.body,
    );
  }

  Map<String, String> toJson() => <String, String>{
    'to': to,
    'subject': subject,
    'body': body,
  };

  String encode() => jsonEncode(toJson());

  static EmailDraft? decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final draft = EmailDraft(
        to: decoded['to']?.toString() ?? '',
        subject: decoded['subject']?.toString() ?? '',
        body: decoded['body']?.toString() ?? '',
      );
      return draft.isEmpty ? null : draft;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static String _sanitizeHeader(String value, {required int maxRunes}) {
    final cleaned = value
        .replaceAll(RegExp(r'[\x00-\x1F\x7F\u202A-\u202E\u2066-\u2069]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return _truncate(cleaned, maxRunes);
  }

  static String _sanitizeBody(String value, {required int maxRunes}) {
    final cleaned = value
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(
          RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\u202A-\u202E\u2066-\u2069]'),
          ' ',
        )
        .trim();
    return _truncate(cleaned, maxRunes);
  }

  static String _truncate(String value, int maxRunes) {
    final runes = value.runes.toList(growable: false);
    return runes.length <= maxRunes
        ? value
        : String.fromCharCodes(runes.take(maxRunes));
  }

  @override
  bool operator ==(Object other) {
    return other is EmailDraft &&
        other.to == to &&
        other.subject == subject &&
        other.body == body;
  }

  @override
  int get hashCode => Object.hash(to, subject, body);
}
