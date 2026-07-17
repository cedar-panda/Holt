import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/utils/text_safety.dart';

void main() {
  test('home-note truncation never splits an emoji grapheme', () {
    const family = '👨‍👩‍👧‍👦';
    final text = '12345678901${family}tail';

    expect(truncateGraphemes(text, 12), '12345678901$family');
  });
}
