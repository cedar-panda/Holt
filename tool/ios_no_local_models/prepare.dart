import 'dart:io';

/// Creates an isolated iOS Flutter workspace from the shared app sources.
///
/// The Android workspace and its pubspec stay untouched. The three on-device
/// inference dependencies resolve to empty packages only in this iOS copy.
Future<void> main() async {
  final toolDir = File.fromUri(Platform.script).parent;
  final root = toolDir.parent.parent;
  final destination = await Directory.systemTemp.createTemp('holt-ios-lite-');

  Future<void> copyDirectory(String relative, List<String> excludes) async {
    final target = Directory('${destination.path}/$relative');
    await target.create(recursive: true);
    final result = await Process.run('rsync', [
      '-a',
      for (final exclude in excludes) '--exclude=$exclude',
      '${root.path}/$relative/',
      '${target.path}/',
    ]);
    if (result.exitCode != 0) {
      throw StateError('Could not copy $relative: ${result.stderr}');
    }
  }

  await copyDirectory('lib', const []);
  await copyDirectory('assets', const []);
  await copyDirectory('ios', const [
    'Pods',
    '.symlinks',
    'ephemeral',
    'xcuserdata',
    'Package.resolved',
  ]);
  await copyDirectory('third_party', const []);
  for (final name in [
    'pubspec.yaml',
    'pubspec.lock',
    '.metadata',
    'analysis_options.yaml',
    'LICENSE',
    'THIRD_PARTY_NOTICES.md',
    'PRIVACY.md',
  ]) {
    final source = File('${root.path}/$name');
    if (await source.exists()) {
      await source.copy('${destination.path}/$name');
    }
  }

  // The shared pubspec bundles native licenses for both mobile platforms.
  // Keep the iOS audio licenses but omit Android-only and on-device AI ones.
  final iosPubspec = File('${destination.path}/pubspec.yaml');
  final sharedPubspec = await iosPubspec.readAsString();
  const nativeLicenseAsset = '    - third_party/licenses/native/\n';
  const androidLicenseAsset = '    - third_party/licenses/android/\n';
  if (!sharedPubspec.contains(nativeLicenseAsset) ||
      !sharedPubspec.contains(androidLicenseAsset)) {
    throw StateError(
      'The shared license asset list changed; review iOS assets.',
    );
  }
  await iosPubspec.writeAsString(
    sharedPubspec
        .replaceFirst(nativeLicenseAsset, '')
        .replaceFirst(androidLicenseAsset, ''),
  );

  await File(
    '${toolDir.path}/local_model_service_ios.dart',
  ).copy('${destination.path}/lib/services/local_model_service.dart');
  await File(
    '${toolDir.path}/local_model_screen_ios.dart',
  ).copy('${destination.path}/lib/screens/local_model_screen.dart');

  final overrides = <String, String>{
    'flutter_gemma': 'flutter_gemma',
    'llamadart': 'llamadart',
    'llamadart_llama_cpp_flutter': 'llamadart_llama_cpp_flutter',
  };
  final yaml = StringBuffer('dependency_overrides:\n');
  for (final entry in overrides.entries) {
    yaml.writeln('  ${entry.key}:');
    yaml.writeln('    path: ${toolDir.path}/stubs/${entry.value}');
  }
  await File(
    '${destination.path}/pubspec_overrides.yaml',
  ).writeAsString(yaml.toString());

  stdout.writeln(destination.path);
}
