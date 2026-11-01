import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/call_audio_pipeline.dart';

void main() {
  test('uses progressive call TTS sentence thresholds', () {
    expect(SentenceTtsPipeline.sentenceThresholdForIndex(0), 4);
    expect(SentenceTtsPipeline.sentenceThresholdForIndex(1), 12);
    expect(SentenceTtsPipeline.sentenceThresholdForIndex(2), 26);
    expect(SentenceTtsPipeline.sentenceThresholdForIndex(20), 26);
  });
}
