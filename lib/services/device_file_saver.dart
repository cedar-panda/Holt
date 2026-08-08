import 'dart:io';

import 'package:flutter/services.dart';

/// Streams an app-owned file into Android's system document picker.
///
/// The native side opens ACTION_CREATE_DOCUMENT and copies from the source
/// path into the selected content URI without loading the whole backup into
/// Dart memory. Other platforms keep their existing file-picker flows.
class DeviceFileSaver {
  static const MethodChannel _channel = MethodChannel(
    'com.yanci.holt/file_saver',
  );

  static Future<String?> saveAndroidFile({
    required String sourcePath,
    required String suggestedName,
    required String mimeType,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Android document saving is only available on Android.',
      );
    }
    return _channel.invokeMethod<String>('saveFile', <String, Object?>{
      'sourcePath': sourcePath,
      'suggestedName': suggestedName,
      'mimeType': mimeType,
    });
  }
}
