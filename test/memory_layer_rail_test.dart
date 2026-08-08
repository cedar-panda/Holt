import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/spider_web_layers.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/widgets/memory_layer_rail.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    await L.setLocale('zh_TW');
  });

  testWidgets('compact layer icons keep labels in semantics only', (
    tester,
  ) async {
    var selected = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              height: 220,
              child: MemoryLayerRail(
                layers: _layers,
                selectedIndex: 0,
                onSelected: (index) => selected = index,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('1'), findsNothing);
    expect(find.text('2'), findsNothing);
    expect(find.text('3'), findsNothing);
    final second = find.bySemanticsLabel('第 2 層，1 條記憶');
    expect(second, findsOneWidget);
    await tester.tap(second);
    expect(selected, 1);
    expect(tester.takeException(), isNull);
  });
}

final _layers = List<SpiderWebLayerPlan>.generate(3, (index) {
  final memory = Memory(
    id: index + 1,
    mode: 'romance',
    category: '偏好',
    content: 'memory ${index + 1}',
  );
  return SpiderWebLayerPlan(
    id: 'layer-$index',
    mode: 'romance',
    label: '偏好',
    webs: [
      SpiderWebClusterPlan(
        id: 'web-$index',
        isSmall: false,
        memories: [memory],
      ),
    ],
    links: const [],
    crossLayerLinks: const [],
    crossLayerLinkCount: 0,
  );
});
