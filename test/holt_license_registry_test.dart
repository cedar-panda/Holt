import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/holt_license_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled licenses and notices cover the ASR model and Cormorant', () async {
    final asr = await rootBundle.loadString(
      'third_party/licenses/asr_zh/Apache-2.0.txt',
    );
    final font = await rootBundle.loadString(
      'third_party/licenses/cormorant-garamond/OFL.txt',
    );
    final notices = await rootBundle.loadString('THIRD_PARTY_NOTICES.md');

    expect(asr, contains('Apache License'));
    expect(asr, contains('Version 2.0'));
    expect(font, contains('the Cormorant Project Authors'));
    expect(font, contains('SIL OPEN FONT LICENSE Version 1.1'));
    expect(notices, contains('Chinese streaming Zipformer (14M)'));
    expect(notices, contains('### Cormorant Garamond'));
  });

  test('open-source license page registers both assets', () async {
    HoltLicenseRegistry.register();
    final matching = await LicenseRegistry.licenses
        .where(
          (entry) =>
              entry.packages.contains('Cormorant Garamond') ||
              entry.packages.contains('Chinese ASR Zipformer 14M model'),
        )
        .take(2)
        .toList();

    expect(matching, hasLength(2));
  });
}
