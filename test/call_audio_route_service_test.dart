import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/call_audio_route_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.yanci.holt/call_audio_route');
  final calls = <String>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    calls.clear();
  });

  test(
    'requests permission before activating and releases the route',
    () async {
      expect(await CallAudioRouteService.ensureBluetoothPermission(), isTrue);
      expect(await CallAudioRouteService.activateBluetoothMicrophone(), isTrue);
      await CallAudioRouteService.releaseBluetoothMicrophone();

      expect(calls, <String>[
        'ensureBluetoothPermission',
        'activateBluetoothMicrophone',
        'releaseBluetoothMicrophone',
      ]);
    },
  );

  test('permission denial is returned without throwing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => false);

    expect(await CallAudioRouteService.ensureBluetoothPermission(), isFalse);
  });
}
