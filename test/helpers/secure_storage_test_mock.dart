import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory replacement for flutter_secure_storage's platform channel.
///
/// Widget/unit tests do not load Android Keystore or Apple Keychain plugins.
/// Installing this mock keeps "missing key" scenarios intentional instead of
/// emitting caught MissingPluginException logs that look like test failures.
class SecureStorageTestMock {
  static const MethodChannel _channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  final Map<String, String> _values;

  SecureStorageTestMock({Map<String, String> initialValues = const {}})
    : _values = Map<String, String>.from(initialValues);

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }

  Future<Object?> _handle(MethodCall call) async {
    final arguments = (call.arguments as Map?) ?? const <Object?, Object?>{};
    final key = arguments['key']?.toString() ?? '';

    switch (call.method) {
      case 'read':
        return _values[key];
      case 'write':
        final value = arguments['value']?.toString();
        if (key.isNotEmpty && value != null) _values[key] = value;
        return null;
      case 'delete':
        _values.remove(key);
        return null;
      case 'readAll':
        return Map<String, String>.from(_values);
      case 'deleteAll':
        _values.clear();
        return null;
      case 'containsKey':
        return _values.containsKey(key);
      default:
        throw MissingPluginException(
          'Unsupported flutter_secure_storage test method: ${call.method}',
        );
    }
  }
}
