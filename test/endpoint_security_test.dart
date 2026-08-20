import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/utils/endpoint_security.dart';

void main() {
  test('accepts HTTPS public endpoints', () {
    expect(
      EndpointSecurity.parseAndValidate('https://api.example.com/v1').host,
      'api.example.com',
    );
  });

  test('accepts HTTP only for local and private-network model servers', () {
    const accepted = <String>[
      'http://localhost:1234/v1',
      'http://127.0.0.1:1234/v1',
      'http://10.0.2.2:1234/v1',
      'http://172.16.4.2:1234/v1',
      'http://192.168.1.20:1234/v1',
      'http://modelbox.local:1234/v1',
      'http://[::1]:1234/v1',
      'http://[fd00::20]:1234/v1',
    ];
    for (final endpoint in accepted) {
      expect(
        () => EndpointSecurity.parseAndValidate(endpoint),
        returnsNormally,
        reason: endpoint,
      );
    }
  });

  test('rejects public HTTP, credentials and non-web schemes', () {
    const rejected = <String>[
      'http://api.example.com/v1',
      'http://8.8.8.8/v1',
      'http://fdexample.com/v1',
      'https://user:password@example.com/v1',
      'ftp://192.168.1.20/v1',
    ];
    for (final endpoint in rejected) {
      expect(
        () => EndpointSecurity.parseAndValidate(endpoint),
        throwsA(isA<FormatException>()),
        reason: endpoint,
      );
    }
  });
}
