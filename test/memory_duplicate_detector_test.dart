import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/services/memory_duplicate_detector.dart';

void main() {
  test('exact content ignores app date prefix, punctuation and full width', () {
    final assessment = MemoryDuplicateDetector.assess(
      memory(null, content: '[8/6] 昭昭喜歡喝熱牛奶。', triggers: '熱牛奶'),
      [memory(1, content: '[8/1] 昭昭喜歡喝熱牛奶！', triggers: '熱牛奶')],
    );

    expect(assessment.disposition, MemoryDuplicateDisposition.clearDuplicate);
    expect(assessment.best?.exactContent, isTrue);
  });

  test('similar wording becomes a review candidate instead of auto skip', () {
    final assessment = MemoryDuplicateDetector.assess(
      memory(null, content: '昭昭喜歡下雨天在家裡看電影', triggers: '下雨天'),
      [memory(1, content: '昭昭很喜歡下雨天窩在家裡慢慢看電影', triggers: '下雨天,電影')],
    );

    expect(
      assessment.disposition,
      MemoryDuplicateDisposition.possibleDuplicate,
    );
    expect(assessment.best?.score, greaterThanOrEqualTo(0.68));
  });

  test('negation and number changes can never be clear duplicates', () {
    final negation = MemoryDuplicateDetector.assess(
      memory(null, content: '昭昭不喜歡睡前喝熱牛奶'),
      [memory(1, content: '昭昭喜歡睡前喝熱牛奶')],
    );
    final number = MemoryDuplicateDetector.assess(
      memory(null, content: '昭昭每天吃3顆藥'),
      [memory(2, content: '昭昭每天吃2顆藥')],
    );

    expect(negation.disposition, MemoryDuplicateDisposition.possibleDuplicate);
    expect(negation.best?.hasConflict, isTrue);
    expect(number.disposition, MemoryDuplicateDisposition.possibleDuplicate);
    expect(number.best?.hasConflict, isTrue);
  });

  test('unrelated content is a new memory', () {
    final assessment = MemoryDuplicateDetector.assess(
      memory(null, content: '昭昭今天收養了一隻橘貓', triggers: '橘貓'),
      [memory(1, content: '昭昭喜歡喝熱牛奶', triggers: '熱牛奶')],
    );

    expect(assessment.disposition, MemoryDuplicateDisposition.newMemory);
    expect(assessment.matches, isEmpty);
  });

  test('permanent mismatch requires review even when content is exact', () {
    final assessment = MemoryDuplicateDetector.assess(
      memory(null, content: '昭昭答應週末一起看電影', permanent: true),
      [memory(1, content: '昭昭答應週末一起看電影')],
    );

    expect(
      assessment.disposition,
      MemoryDuplicateDisposition.possibleDuplicate,
    );
    expect(assessment.best?.hasConflict, isTrue);
  });
}

Memory memory(
  int? id, {
  required String content,
  String triggers = '',
  String category = '重要事件',
  bool permanent = false,
}) {
  final now = DateTime.utc(2026, 8, 6);
  return Memory(
    id: id,
    characterId: 'char-a',
    mode: 'romance',
    category: category,
    content: content,
    confidence: 'high',
    isPermanent: permanent,
    triggers: triggers,
    createdAt: now,
    updatedAt: now,
  );
}
