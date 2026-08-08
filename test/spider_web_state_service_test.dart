import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/spider_web_state_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('node positions persist by character without memory text', () async {
    await SpiderWebStateService.savePositions('char-a', {
      7: const SpiderWebNodePosition(12.5, -80.25),
      9: const SpiderWebNodePosition(-3, 4),
    });

    final restored = await SpiderWebStateService.loadPositions('char-a');
    expect(restored.keys, {7, 9});
    expect(restored[7]!.x, 12.5);
    expect(restored[7]!.y, -80.25);
    expect(
      (await SharedPreferences.getInstance()).getKeys(),
      isNot(contains('memory text')),
    );
    expect(await SpiderWebStateService.loadPositions('char-b'), isEmpty);
  });

  test(
    'unfinished curation job can be restored and explicitly cleared',
    () async {
      final job = SpiderWebCurationJob(
        memoryIds: const [3, 4, 4],
        status: 'running',
        updatedAt: DateTime(2026, 8, 5, 12),
      );
      await SpiderWebStateService.saveCurationJob('char-a', job);

      final restored = await SpiderWebStateService.loadCurationJob('char-a');
      expect(restored, isNotNull);
      expect(restored!.memoryIds, [3, 4]);
      expect(restored.canResume, isTrue);

      await SpiderWebStateService.clearCurationJob('char-a');
      expect(await SpiderWebStateService.loadCurationJob('char-a'), isNull);
    },
  );

  test('deleting a character clears its graph state only', () async {
    await SpiderWebStateService.savePositions('char-a', {
      1: const SpiderWebNodePosition(2, 3),
    });
    await SpiderWebStateService.savePositions('char-b', {
      2: const SpiderWebNodePosition(4, 5),
    });
    await SpiderWebStateService.saveCurationJob(
      'char-a',
      SpiderWebCurationJob(
        memoryIds: const [1, 3],
        status: 'failed',
        updatedAt: DateTime(2026, 8, 5),
      ),
    );

    await SpiderWebStateService.clearCharacterState('char-a');

    expect(await SpiderWebStateService.loadPositions('char-a'), isEmpty);
    expect(await SpiderWebStateService.loadCurationJob('char-a'), isNull);
    expect(await SpiderWebStateService.loadPositions('char-b'), isNotEmpty);
  });
}
