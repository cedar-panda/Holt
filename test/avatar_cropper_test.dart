import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/widgets/avatar_cropper.dart';

File _squarePng(Directory directory) {
  final file = File('${directory.path}/avatar-source.png');
  file.writeAsBytesSync(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  );
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('crop route dismisses keyboard and permits safe zoom out', (
    tester,
  ) async {
    final directory = Directory(
      '/private/tmp/avatar-crop-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    addTearDown(() => directory.deleteSync(recursive: true));
    final source = _squarePng(directory);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                TextField(focusNode: focusNode),
                FilledButton(
                  key: const ValueKey('open-cropper'),
                  onPressed: () => unawaited(
                    AvatarCropperScreen.show(
                      context,
                      imageFile: source,
                      outputPath: '${directory.path}/avatar-output.png',
                    ),
                  ),
                  child: const Text('Crop'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.showKeyboard(find.byType(TextField));
    expect(focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.byKey(const ValueKey('open-cropper')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    final cropScaffold = tester
        .widgetList<Scaffold>(find.byType(Scaffold))
        .last;
    expect(cropScaffold.resizeToAvoidBottomInset, isFalse);
    expect(
      avatarCropMinimumScale(
        displayedImageSize: const Size(600, 600),
        cropDiameter: 450,
      ),
      .75,
    );
  });
}
