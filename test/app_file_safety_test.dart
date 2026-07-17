import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/utils/app_file_safety.dart';

void main() {
  test('app file boundary rejects traversal and prefix lookalikes', () {
    const root = '/data/user/0/app/documents';

    expect(AppFileSafety.isWithinRoot('$root/chat_images/a.jpg', root), isTrue);
    expect(
      AppFileSafety.isWithinRoot('$root/../secrets/key.txt', root),
      isFalse,
    );
    expect(
      AppFileSafety.isWithinRoot('/data/user/0/app/documents-evil/a.jpg', root),
      isFalse,
    );
    expect(AppFileSafety.isWithinRoot('relative/a.jpg', root), isFalse);
  });
}
