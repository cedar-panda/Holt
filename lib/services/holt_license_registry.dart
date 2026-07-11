import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Adds non-Dart licenses to Flutter's standard LicensePage. Dart/Flutter
/// package licenses are registered automatically by the toolchain.
class HoltLicenseRegistry {
  HoltLicenseRegistry._();

  static bool _registered = false;

  static const _assets = <String, List<String>>{
    'LICENSE': ['Holt'],
    'third_party/licenses/lora/OFL.txt': ['Lora'],
    'third_party/licenses/lxgw-wenkai-tc/OFL.txt': ['LXGW WenKai TC'],
    'third_party/licenses/native/llamadart-native-b9829-LICENSE.txt': [
      'llamadart-native',
    ],
    'third_party/licenses/native/llama.cpp-b9829-LICENSE.txt': [
      'llama.cpp',
      'ggml',
    ],
    'third_party/licenses/native/LiteRT-LM-v0.12.0-LICENSE.txt': ['LiteRT-LM'],
    'third_party/licenses/native/flutter_soloud/flutter_soloud-4.0.12-LICENSE.txt':
        ['flutter_soloud'],
    'third_party/licenses/native/flutter_soloud/SoLoud-LICENSE.txt': ['SoLoud'],
    'third_party/licenses/native/flutter_soloud/Signalsmith-Linear-LICENSE.txt':
        ['Signalsmith Linear'],
    'third_party/licenses/native/flutter_soloud/Signalsmith-Stretch-LICENSE.txt':
        ['Signalsmith Stretch'],
    'third_party/licenses/native/flutter_soloud/PFFFT-FFTPACK-LICENSE.txt': [
      'PFFFT',
      'FFTPACK',
    ],
    'third_party/licenses/native/flutter_soloud/SoLoud-Wide-Open-License.txt': [
      'SoLoud FFT filter',
    ],
    'third_party/licenses/native/flutter_soloud/miniaudio-LICENSE.txt': [
      'miniaudio',
    ],
    'third_party/licenses/native/flutter_soloud/dr_flac-LICENSE.txt': [
      'dr_flac',
    ],
    'third_party/licenses/native/flutter_soloud/dr_mp3-LICENSE.txt': ['dr_mp3'],
    'third_party/licenses/native/flutter_soloud/dr_wav-LICENSE.txt': ['dr_wav'],
    'third_party/licenses/native/flutter_soloud/stb_vorbis-LICENSE.txt': [
      'stb_vorbis',
    ],
    'third_party/licenses/native/flutter_soloud/FLAC-COPYING.Xiph.txt': [
      'FLAC',
    ],
    'third_party/licenses/native/flutter_soloud/Ogg-COPYING.txt': ['Ogg'],
    'third_party/licenses/native/flutter_soloud/Opus-COPYING.txt': ['Opus'],
    'third_party/licenses/native/flutter_soloud/Vorbis-COPYING.txt': ['Vorbis'],
    'third_party/licenses/android/Apache-2.0.txt': [
      'Android Maven components (Apache-2.0)',
    ],
    'third_party/licenses/android/MIT.txt': ['Android Maven components (MIT)'],
  };

  static void register() {
    if (_registered) return;
    _registered = true;
    LicenseRegistry.addLicense(() async* {
      for (final entry in _assets.entries) {
        try {
          final text = await rootBundle.loadString(entry.key);
          yield LicenseEntryWithLineBreaks(entry.value, text);
        } catch (error) {
          debugPrint('Unable to load bundled license ${entry.key}: $error');
        }
      }
    });
  }
}
