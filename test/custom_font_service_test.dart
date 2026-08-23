import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/custom_font_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('recognizes TrueType and OpenType headers', () {
    expect(
      CustomFontService.hasSupportedHeader(
        Uint8List.fromList(const [0x00, 0x01, 0x00, 0x00]),
      ),
      isTrue,
    );
    expect(
      CustomFontService.hasSupportedHeader(
        Uint8List.fromList('OTTO'.codeUnits),
      ),
      isTrue,
    );
    expect(
      CustomFontService.hasSupportedHeader(
        Uint8List.fromList('true'.codeUnits),
      ),
      isTrue,
    );
    expect(
      CustomFontService.hasSupportedHeader(
        Uint8List.fromList('typ1'.codeUnits),
      ),
      isTrue,
    );
  });

  test('rejects truncated and unrelated file headers', () {
    expect(CustomFontService.hasSupportedHeader(Uint8List(0)), isFalse);
    expect(
      CustomFontService.hasSupportedHeader(
        Uint8List.fromList('wOFF'.codeUnits),
      ),
      isFalse,
    );
    expect(
      CustomFontService.hasSupportedHeader(
        Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47]),
      ),
      isFalse,
    );
  });

  test('display name comes from the filename and is length bounded', () {
    expect(
      CustomFontService.displayNameFromFilename('/tmp/My Font.otf'),
      'My Font',
    );
    final longName = List<String>.filled(80, '字').join();
    expect(
      CustomFontService.displayNameFromFilename('$longName.ttf').runes.length,
      60,
    );
  });

  test('missing active font fails closed and clears saved metadata', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'custom_font_family': 'HoltCustomFont1',
      'custom_font_display_name': 'Missing',
      'custom_font_file_path': '/path/that/does/not/exist.ttf',
      'custom_font_active': true,
    });

    expect(await CustomFontService.restoreActiveFont(), isNull);
    expect(await CustomFontService.isActive(), isFalse);
    expect(await CustomFontService.getSavedFont(), isNull);
  });

  test('invalid local font is rejected before FontLoader', () async {
    final directory = await Directory.systemTemp.createTemp('holt_font_test_');
    final invalid = File('${directory.path}/invalid.ttf');
    await invalid.writeAsBytes('not a font'.codeUnits);
    addTearDown(() => directory.delete(recursive: true));

    await expectLater(
      CustomFontService.activate(
        CustomFontInfo(
          family: 'HoltCustomFontInvalid',
          displayName: 'Invalid',
          filePath: invalid.path,
        ),
      ),
      throwsA(
        isA<CustomFontException>().having(
          (error) => error.failure,
          'failure',
          CustomFontFailure.invalidFont,
        ),
      ),
    );
  });
}
