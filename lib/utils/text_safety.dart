import 'package:characters/characters.dart';

String truncateGraphemes(String value, int maxLength) {
  if (maxLength <= 0) return '';
  final graphemes = value.characters;
  return graphemes.length <= maxLength
      ? value
      : graphemes.take(maxLength).toString();
}
