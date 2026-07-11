import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/retriever.dart';

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
}
