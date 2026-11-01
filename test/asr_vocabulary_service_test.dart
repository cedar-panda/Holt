import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/asr_vocabulary_service.dart';

void main() {
  const terms = ['晏辭', '辭辭'];

  test('fuzzy pinyin folds retroflex, n/l and nasal finals', () {
    expect(AsrVocabularyService.normalizePinyin('chi'), 'ci');
    expect(AsrVocabularyService.normalizePinyin('zhang'), 'zan');
    expect(AsrVocabularyService.normalizePinyin('ling'), 'nin');
    expect(AsrVocabularyService.normalizePinyin('nü'), 'nv');
    expect(AsrVocabularyService.normalizePinyin('chi2'), 'ci2');
  });

  test('corrects similar-sounding names', () {
    expect(AsrVocabularyService.correct('遲遲你在嗎', terms), '辭辭你在嗎');
    expect(AsrVocabularyService.correct('詞詞，晚安', terms), '辭辭，晚安');
    expect(AsrVocabularyService.correct('我想跟宴詞說', terms), '我想跟晏辭說');
  });

  test('leaves unrelated words and correct text alone', () {
    expect(AsrVocabularyService.correct('這首歌詞很好聽', terms), '這首歌詞很好聽');
    expect(AsrVocabularyService.correct('辭辭', terms), '辭辭');
    // 聲調不同不換：次次（ci4）、此次（ci3 ci4）
    expect(AsrVocabularyService.correct('次次都這樣', terms), '次次都這樣');
    expect(AsrVocabularyService.correct('此次', terms), '此次');
    expect(AsrVocabularyService.correct('', terms), '');
  });

  test('rejects single characters and non-Chinese terms', () {
    expect(AsrVocabularyService.isUsableTerm('辭'), isFalse);
    expect(AsrVocabularyService.isUsableTerm('Arden'), isFalse);
    expect(AsrVocabularyService.isUsableTerm('辭小姐'), isTrue);
  });
}
