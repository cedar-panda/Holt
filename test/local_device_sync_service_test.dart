import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/local_device_sync_service.dart';

void main() {
  test('pairing codes are fresh, valid and human-readable', () {
    final first = LocalDeviceSyncService.createPairingCode();
    final second = LocalDeviceSyncService.createPairingCode();
    expect(first, isNot(second));
    expect(first.split('-').map((part) => part.length), [5, 5, 5, 5]);
    expect(LocalDeviceSyncService.isValidCode(first), isTrue);
    expect(LocalDeviceSyncService.isValidCode(first.toLowerCase()), isTrue);
    expect(LocalDeviceSyncService.normalizeCode(first).length, 20);
    expect(LocalDeviceSyncService.isValidCode('1234'), isFalse);
  });

  test('only literal private IPv4 targets are accepted', () {
    for (final address in [
      '192.168.1.10',
      '10.0.0.2',
      '172.20.0.3',
      '169.254.1.1',
    ]) {
      expect(LocalDeviceSyncService.isPrivateIpv4(address), isTrue);
      expect(LocalDeviceSyncService.parseTarget('$address:43567').port, 43567);
    }
    for (final target in [
      'localhost:8080',
      '127.0.0.1:8080',
      '8.8.8.8:8080',
      '192.168.1.4:0',
      '192.168.1.4:65536',
      '192.168.1.4/path:8000',
      '192.168.1.4:8000@elsewhere',
    ]) {
      expect(
        () => LocalDeviceSyncService.parseTarget(target),
        throwsFormatException,
        reason: target,
      );
    }
  });
}
