import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_yanci/services/encrypted_backup_bundle.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('holt_encrypted_backup_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('round-trips a chunked encrypted backup', () async {
    final source = File(p.join(root.path, 'source.zip'));
    final encrypted = File(p.join(root.path, 'backup.holt.backup'));
    final restored = File(p.join(root.path, 'restored.zip'));
    final bytes = List<int>.generate(12000, (index) => index % 251);
    await source.writeAsBytes(bytes);

    await EncryptedBackupBundle.encrypt(
      source: source,
      destination: encrypted,
      password: 'correct horse battery staple',
      iterations: 10000,
      chunkSize: 4096,
    );

    expect(await EncryptedBackupBundle.isEncrypted(encrypted), isTrue);
    expect(await encrypted.readAsBytes(), isNot(equals(bytes)));

    await EncryptedBackupBundle.decrypt(
      source: encrypted,
      destination: restored,
      password: 'correct horse battery staple',
    );
    expect(await restored.readAsBytes(), bytes);
  });

  test('wrong password fails without leaving plaintext', () async {
    final source = File(p.join(root.path, 'source.zip'))
      ..writeAsBytesSync(List<int>.generate(6000, (index) => index % 251));
    final encrypted = File(p.join(root.path, 'backup.holt.backup'));
    final restored = File(p.join(root.path, 'restored.zip'));
    await EncryptedBackupBundle.encrypt(
      source: source,
      destination: encrypted,
      password: 'right-password',
      iterations: 10000,
      chunkSize: 4096,
    );

    await expectLater(
      EncryptedBackupBundle.decrypt(
        source: encrypted,
        destination: restored,
        password: 'wrong-password',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(await restored.exists(), isFalse);
  });

  test('tampering or truncation is rejected', () async {
    final source = File(p.join(root.path, 'source.zip'))
      ..writeAsBytesSync(List<int>.generate(9000, (index) => index % 251));
    final encrypted = File(p.join(root.path, 'backup.holt.backup'));
    await EncryptedBackupBundle.encrypt(
      source: source,
      destination: encrypted,
      password: 'tamper-test-password',
      iterations: 10000,
      chunkSize: 4096,
    );
    final original = await encrypted.readAsBytes();

    final tampered = File(p.join(root.path, 'tampered.holt.backup'));
    final tamperedBytes = List<int>.from(original);
    tamperedBytes[tamperedBytes.length ~/ 2] ^= 0x01;
    await tampered.writeAsBytes(tamperedBytes);
    await expectLater(
      EncryptedBackupBundle.decrypt(
        source: tampered,
        destination: File(p.join(root.path, 'tampered.zip')),
        password: 'tamper-test-password',
      ),
      throwsA(isA<FormatException>()),
    );

    final truncated = File(p.join(root.path, 'truncated.holt.backup'));
    await truncated.writeAsBytes(original.sublist(0, original.length - 12));
    await expectLater(
      EncryptedBackupBundle.decrypt(
        source: truncated,
        destination: File(p.join(root.path, 'truncated.zip')),
        password: 'tamper-test-password',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
