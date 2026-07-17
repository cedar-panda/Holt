import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/utils/latest_request_gate.dart';

class _RaceHarness extends StatefulWidget {
  const _RaceHarness({required this.first, required this.second});

  final Future<String> first;
  final Future<String> second;

  @override
  State<_RaceHarness> createState() => _RaceHarnessState();
}

class _RaceHarnessState extends State<_RaceHarness> {
  final LatestRequestGate _gate = LatestRequestGate();
  String _value = 'none';

  Future<void> load(Future<String> request) async {
    final generation = _gate.begin();
    final value = await request;
    if (!mounted || !_gate.isCurrent(generation)) return;
    setState(() => _value = value);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Column(
        children: [
          Text(_value, key: const ValueKey('race-value')),
          TextButton(
            key: const ValueKey('load-first'),
            onPressed: () => load(widget.first),
            child: const Text('first'),
          ),
          TextButton(
            key: const ValueKey('load-second'),
            onPressed: () => load(widget.second),
            child: const Text('second'),
          ),
        ],
      ),
    );
  }
}

void main() {
  testWidgets('older character load cannot overwrite the latest selection', (
    tester,
  ) async {
    final first = Completer<String>();
    final second = Completer<String>();
    await tester.pumpWidget(
      _RaceHarness(first: first.future, second: second.future),
    );

    await tester.tap(find.byKey(const ValueKey('load-first')));
    await tester.tap(find.byKey(const ValueKey('load-second')));
    second.complete('new-character');
    await tester.pump();
    expect(find.text('new-character'), findsOneWidget);

    first.complete('old-character');
    await tester.pump();
    expect(find.text('new-character'), findsOneWidget);
    expect(find.text('old-character'), findsNothing);
  });
}
