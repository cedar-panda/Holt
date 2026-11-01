import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/retriever.dart';
import 'package:project_yanci/models/memory.dart';

void main() {
  test('memory short ids are isolated per conversation window', () {
    Retriever.resetWindowIds('window-a');
    Retriever.resetWindowIds('window-b');

    expect(Retriever.shortFor(101, windowId: 'window-a'), 1);
    expect(Retriever.shortFor(202, windowId: 'window-a'), 2);
    expect(Retriever.shortFor(999, windowId: 'window-b'), 1);

    expect(Retriever.realIdFor(1, windowId: 'window-a'), 101);
    expect(Retriever.realIdFor(1, windowId: 'window-b'), 999);
    expect(Retriever.realIdFor(2, windowId: 'window-b'), isNull);

    Retriever.releaseWindowIds('window-a');
    expect(Retriever.realIdFor(1, windowId: 'window-a'), isNull);
    expect(Retriever.realIdFor(1, windowId: 'window-b'), 999);
    Retriever.releaseWindowIds('window-b');
  });

  test('forced recall can match a dormant memory trigger', () {
    final memory = Memory(
      id: 7,
      mode: 'romance',
      category: '重要事件',
      content: '兩人曾在雨夜談起童年。',
      triggers: '舊車站,藍傘',
    );

    expect(Retriever.forceRecallMatchesForTesting(memory, '藍傘'), isTrue);
    expect(Retriever.forceRecallMatchesForTesting(memory, '海邊'), isFalse);
  });
}
