import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Voice-call audio routing — Bluetooth microphone (Android) and
/// AVAudioSession configuration (iOS).
///
/// Android 12+: `speech_to_text`'s Bluetooth permission request is skipped
/// when RECORD_AUDIO was granted earlier. Holt asks for that missing
/// permission before initializing STT, and temporarily selects the Bluetooth
/// communication input for the app-local recorder used by hold-to-talk.
///
/// iOS: SoLoud/miniaudio may override the AVAudioSession category that
/// `speech_to_text` configured. [configureCallAudioSession] re-applies
/// `.playAndRecord` with `.allowBluetooth` + `.allowBluetoothA2DP` so both
/// microphone input and TTS playback route through Bluetooth when connected.
class CallAudioRouteService {
  const CallAudioRouteService._();

  static const MethodChannel _channel = MethodChannel(
    'com.yanci.holt/call_audio_route',
  );

  static bool get _usesAndroidBridge =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get _usesIOSBridge =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static Future<bool> ensureBluetoothPermission() async {
    if (!_usesAndroidBridge) return true;
    return _invokeBool('ensureBluetoothPermission');
  }

  static Future<bool> activateBluetoothMicrophone() async {
    // iOS 沒有 Android 那套 communication device API；本地 ASR 開錄前
    // 改為重新套用 playAndRecord + 藍牙 HFP。
    if (_usesIOSBridge) return configureCallAudioSession();
    if (!_usesAndroidBridge) return true;
    return _invokeBool('activateBluetoothMicrophone');
  }

  static Future<void> releaseBluetoothMicrophone() async {
    if (!_usesAndroidBridge) return;
    try {
      await _channel.invokeMethod<void>('releaseBluetoothMicrophone');
    } on MissingPluginException {
      // Keeps widget tests and non-Android hosts independent of the bridge.
    } on PlatformException catch (error) {
      debugPrint('Bluetooth microphone release failed: ${error.code}');
    }
  }

  /// Configure iOS AVAudioSession for voice call with Bluetooth support.
  ///
  /// Call this AFTER SoLoud.init() to override any category reset, and
  /// again before STT starts to ensure the session stays in playAndRecord.
  static Future<bool> configureCallAudioSession() async {
    if (!_usesIOSBridge) return true;
    return _invokeBool('configureCallAudioSession');
  }

  /// Reset iOS AVAudioSession back to normal playback after call ends.
  static Future<void> resetAudioSession() async {
    if (!_usesIOSBridge) return;
    try {
      await _channel.invokeMethod<void>('resetAudioSession');
    } on MissingPluginException {
      // Widget tests and non-iOS hosts.
    } on PlatformException catch (error) {
      debugPrint('Audio session reset failed: ${error.code}');
    }
  }

  static Future<bool> _invokeBool(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException catch (error) {
      debugPrint('Audio route setup failed ($method): ${error.code}');
      return false;
    }
  }
}
