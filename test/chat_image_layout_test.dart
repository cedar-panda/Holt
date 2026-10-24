import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/widgets/message_image_grid.dart';
import 'package:project_yanci/widgets/pending_image_tray.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

ValueKey<String> _k(String v) => ValueKey<String>(v);

void main() {
  group('PendingImageTray', () {
    testWidgets('shows square tiles, add tile and count; remove reports index',
        (tester) async {
      int? removed;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 400,
            child: PendingImageTray(
              paths: const ['/missing/a.png', '/missing/b.png', '/missing/c.png'],
              onRemove: (i) => removed = i,
              onAdd: () {},
            ),
          ),
        ),
      );
      expect(find.byKey(_k('pending-image-2')), findsOneWidget);
      expect(find.byKey(_k('pending-image-add')), findsOneWidget);
      expect(find.text('3/9'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(_k('pending-image-0'))),
        const Size(PendingImageTray.tileSize, PendingImageTray.tileSize),
      );

      await tester.tap(find.byKey(_k('pending-image-remove-1')));
      expect(removed, 1);
    });

    testWidgets('no add tile when nine images are pending', (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 400,
            child: PendingImageTray(
              paths: List<String>.generate(9, (i) => '/missing/$i.png'),
              onRemove: (_) {},
              onAdd: () {},
            ),
          ),
        ),
      );
      expect(find.byKey(_k('pending-image-add')), findsNothing);
      expect(find.text('9/9'), findsOneWidget);
    });
  });

  group('MessageImageGrid', () {
    testWidgets('seven images show a 2x2 grid with +3 overlay', (tester) async {
      String? tapped;
      await tester.pumpWidget(
        _host(
          MessageImageGrid(
            paths: List<String>.generate(7, (i) => '/missing/$i.png'),
            onTap: (p) => tapped = p,
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        expect(find.byKey(_k('message-image-$i')), findsOneWidget);
      }
      expect(find.byKey(_k('message-image-4')), findsNothing);
      expect(find.text('+3'), findsOneWidget);

      await tester.tap(find.byKey(_k('message-image-3')));
      expect(tapped, '/missing/3.png');
    });

    testWidgets('three images sit in one row', (tester) async {
      await tester.pumpWidget(
        _host(
          MessageImageGrid(
            paths: List<String>.generate(3, (i) => '/missing/$i.png'),
          ),
        ),
      );
      final y0 = tester.getTopLeft(find.byKey(_k('message-image-0'))).dy;
      final y2 = tester.getTopLeft(find.byKey(_k('message-image-2'))).dy;
      expect(y2, y0);
    });

    testWidgets('generating placeholder is not tappable', (tester) async {
      String? tapped;
      await tester.pumpWidget(
        _host(
          MessageImageGrid(
            paths: const ['/missing/a.png', 'generating'],
            onTap: (p) => tapped = p,
          ),
        ),
      );
      await tester.tap(
        find.byKey(_k('message-image-1')),
        warnIfMissed: false,
      );
      expect(tapped, isNull);
    });
  });
}
