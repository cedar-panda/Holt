import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/bio_clock_service.dart';

void main() {
  tearDown(BioClockService.consumeLastActionLog);

  test('bio-clock action log is consumed only once', () {
    BioClockService.lastActionLog.add('clock action');

    expect(BioClockService.consumeLastActionLog(), <String>['clock action']);
    expect(BioClockService.consumeLastActionLog(), isEmpty);
  });
}
