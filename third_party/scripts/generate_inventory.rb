#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates a reproducible third-party dependency/license snapshot from the
# resolved Flutter workspace. This script intentionally does not choose or
# create a license for Holt itself.

require 'cgi'
require 'digest'
require 'fileutils'
require 'json'
require 'pathname'
require 'time'
require 'uri'
require 'yaml'

ROOT = Pathname.new(File.expand_path('../..', __dir__))
THIRD_PARTY = ROOT.join('third_party')
DEPENDENCIES_DIR = THIRD_PARTY.join('dependencies')
DART_LICENSES_DIR = THIRD_PARTY.join('licenses', 'dart')
FLUTTER_LICENSES_DIR = THIRD_PARTY.join('licenses', 'flutter')
ANDROID_LICENSES_DIR = THIRD_PARTY.join('licenses', 'android')
NATIVE_LICENSES_DIR = THIRD_PARTY.join('licenses', 'native')

PUBSPEC_LOCK = ROOT.join('pubspec.lock')
PUBSPEC = ROOT.join('pubspec.yaml')
PACKAGE_CONFIG = ROOT.join('.dart_tool', 'package_config.json')
MAVEN_REPORT = ROOT.join(
  'build', 'app', 'outputs', 'sdk-dependencies', 'release',
  'sdkDependencies.txt'
)

def sha256(path)
  Digest::SHA256.file(path).hexdigest
end

def relative(path)
  Pathname.new(path).relative_path_from(ROOT).to_s
end

def write_text(path, content)
  FileUtils.mkdir_p(path.dirname)
  normalized = content.end_with?("\n") ? content : "#{content}\n"
  path.write(normalized)
end

def copy_exact(source, destination)
  FileUtils.mkdir_p(destination.dirname)
  FileUtils.cp(source, destination, preserve: true)
end

def resolved_package_root(package_config_dir, root_uri)
  uri = URI.parse(root_uri)
  if uri.scheme == 'file'
    Pathname.new(uri.path)
  elsif uri.scheme.nil?
    package_config_dir.join(root_uri).expand_path
  else
    raise "Unsupported package root URI: #{root_uri}"
  end
end

def license_summary(paths, package_name:)
  return ['UNRESOLVED'] if paths.empty?
  return ['COMPOSITE-FLUTTER-ENGINE-NOTICES'] if package_name == 'sky_engine'

  text = paths.map { |path| path.read(encoding: 'UTF-8', invalid: :replace, undef: :replace) }.join("\n")
  ids = []
  ids << 'Apache-2.0' if text.match?(/Apache License|Apache Software License/i)
  ids << 'MPL-2.0' if text.match?(/Mozilla Public License(?: Version)? 2\.0/i)
  ids << 'OFL-1.1' if text.match?(/SIL OPEN FONT LICENSE Version 1\.1/i)
  ids << 'MIT' if text.match?(/MIT License|The MIT License|Permission is hereby granted, free of charge/i)
  if text.match?(/Redistribution and use in source and binary forms/i)
    ids << (text.match?(/Neither the name|names of its contributors/i) ? 'BSD-3-Clause' : 'BSD-2-Clause')
  end
  ids << 'Zlib' if text.match?(/zlib\/libpng license/i)
  ids << 'OTHER' if ids.empty?
  ids.uniq.sort
end

def sanitize_component(value)
  value.gsub(/[^A-Za-z0-9._+\-]/, '_')
end

def package_source_links(name, version, source)
  return {} unless source == 'hosted'

  {
    'package_page' => "https://pub.dev/packages/#{name}/versions/#{version}",
    'license_page' => "https://pub.dev/packages/#{name}/versions/#{version}/license",
    'archive' => "https://pub.dev/api/archives/#{name}-#{version}.tar.gz"
  }
end

def flutter_metadata(package_roots)
  flutter_package = package_roots.fetch('flutter')
  flutter_root = flutter_package.join('..', '..').expand_path
  version_file = flutter_root.join('bin', 'cache', 'flutter.version.json')
  metadata = version_file.file? ? JSON.parse(version_file.read) : {}
  metadata['flutter_root'] = flutter_root.to_s
  metadata
end

def generate_pub_inventory(lock, package_config)
  package_config_dir = PACKAGE_CONFIG.dirname
  configured = package_config.fetch('packages').to_h do |entry|
    [entry.fetch('name'), resolved_package_root(package_config_dir, entry.fetch('rootUri'))]
  end
  flutter = flutter_metadata(configured)
  flutter_version = flutter.fetch('frameworkVersion', 'unknown')
  framework_revision = flutter.fetch('frameworkRevision', 'unknown')
  engine_revision = flutter.fetch('engineRevision', 'unknown')
  flutter_root = Pathname.new(flutter.fetch('flutter_root'))

  FileUtils.rm_rf(DART_LICENSES_DIR)
  FileUtils.mkdir_p([DART_LICENSES_DIR, FLUTTER_LICENSES_DIR])

  flutter_license = flutter_root.join('LICENSE')
  flutter_license_dest = FLUTTER_LICENSES_DIR.join("flutter-#{flutter_version}-LICENSE.txt")
  copy_exact(flutter_license, flutter_license_dest)

  sky_root = configured['sky_engine']
  engine_notices = sky_root&.join('LICENSE')
  engine_notices_dest = FLUTTER_LICENSES_DIR.join(
    "flutter-engine-#{engine_revision}-NOTICES.txt"
  )
  copy_exact(engine_notices, engine_notices_dest) if engine_notices&.file?

  entries = lock.fetch('packages').sort.map do |name, info|
    version = info.fetch('version').to_s
    source = info.fetch('source').to_s
    root = configured[name]
    entry = {
      'name' => name,
      'version' => version,
      'dependency' => info.fetch('dependency').to_s,
      'source' => source,
      'source_links' => package_source_links(name, version, source)
    }

    description = info['description']
    if description.is_a?(Hash)
      entry['hosted_sha256'] = description['sha256'] if description['sha256']
      entry['hosted_repository'] = description['url'] if description['url']
    end

    case name
    when 'flutter', 'flutter_test', 'flutter_web_plugins', 'flutter_localizations'
      entry['license'] = {
        'status' => name == 'flutter' ? 'VERIFIED_LOCAL_COPY' : 'INHERITED_FROM_FLUTTER_SDK',
        'summary' => ['BSD-3-Clause'],
        'files' => [{
          'path' => relative(flutter_license_dest),
          'sha256' => sha256(flutter_license_dest)
        }],
        'official_source' => "https://raw.githubusercontent.com/flutter/flutter/#{framework_revision}/LICENSE"
      }
    when 'sky_engine'
      files = []
      if engine_notices_dest.file?
        files << {
          'path' => relative(engine_notices_dest),
          'sha256' => sha256(engine_notices_dest)
        }
      end
      entry['license'] = {
        'status' => files.empty? ? 'UNRESOLVED' : 'VERIFIED_LOCAL_COMPOSITE_NOTICES',
        'summary' => ['COMPOSITE-FLUTTER-ENGINE-NOTICES'],
        'files' => files,
        'engine_revision' => engine_revision
      }
    else
      source_files = if root&.directory?
                       root.children.select do |child|
                         child.file? && child.basename.to_s.match?(/\A(?:LICENSE|NOTICE|COPYING)/i)
                       end.sort
                     else
                       []
                     end
      destination_dir = DART_LICENSES_DIR.join(
        "#{sanitize_component(name)}-#{sanitize_component(version)}"
      )
      copied = source_files.map do |source_file|
        destination = destination_dir.join(source_file.basename)
        copy_exact(source_file, destination)
        {
          'path' => relative(destination),
          'sha256' => sha256(destination),
          'copied_from' => "$PUB_CACHE/hosted/pub.dev/#{root&.basename}/#{source_file.basename}"
        }
      end
      entry['license'] = {
        'status' => copied.empty? ? 'UNRESOLVED' : 'VERIFIED_LOCAL_COPY',
        'summary' => license_summary(source_files, package_name: name),
        'files' => copied
      }
    end
    entry
  end

  markdown = []
  markdown << '# Dart / Flutter Dependency Components'
  markdown << ''
  markdown << '> Generated by `third_party/scripts/generate_inventory.rb`. Do not edit by hand.'
  markdown << ''
  markdown << "- Flutter: #{flutter_version} (`#{framework_revision}`)"
  markdown << "- Engine: `#{engine_revision}`"
  markdown << "- Packages: #{entries.length}"
  markdown << ''
  markdown << '| Package | Version | Scope | License summary | Status |'
  markdown << '|---|---:|---|---|---|'
  entries.each do |entry|
    license = entry.fetch('license')
    markdown << "| `#{entry['name']}` | `#{entry['version']}` | #{entry['dependency']} | #{license['summary'].join(', ')} | #{license['status']} |"
  end
  write_text(DEPENDENCIES_DIR.join('DART_FLUTTER_COMPONENTS.md'), markdown.join("\n"))

  [entries, flutter.reject { |key, _| key == 'flutter_root' }]
end

def maven_coordinates(report)
  report.scan(
    /groupId:\s*"([^"]+)".*?artifactId:\s*"([^"]+)".*?version:\s*"([^"]+)"/m
  ).map do |group, artifact, version|
    {'group' => group, 'artifact' => artifact, 'version' => version}
  end.uniq
end

def sanitize_cache_path(path)
  gradle_cache = File.expand_path('~/.gradle/caches/modules-2/files-2.1')
  pub_cache = File.expand_path('~/.pub-cache')
  value = File.expand_path(path)
  return value.sub(gradle_cache, '$GRADLE_MODULE_CACHE') if value.start_with?(gradle_cache)
  return value.sub(pub_cache, '$PUB_CACHE') if value.start_with?(pub_cache)

  value
end

def license_declarations_from_pom(path)
  return [] unless path&.file?

  text = path.read(encoding: 'UTF-8', invalid: :replace, undef: :replace)
  licenses = text[/<licenses>(.*?)<\/licenses>/m, 1]
  return [] unless licenses

  licenses.scan(/<license>(.*?)<\/license>/m).map do |match|
    block = match.first
    name = block[/<name>(.*?)<\/name>/m, 1]
    url = block[/<url>(.*?)<\/url>/m, 1]
    {
      'name' => name ? CGI.unescapeHTML(name.strip) : 'UNSPECIFIED',
      'url' => url ? CGI.unescapeHTML(url.strip) : nil,
      'source' => 'POM'
    }.compact
  end
end

def fallback_maven_license(component)
  group = component.fetch('group')
  artifact = component.fetch('artifact')

  if group.start_with?('androidx.')
    return [{
      'name' => 'Apache License 2.0',
      'url' => 'https://www.apache.org/licenses/LICENSE-2.0.txt',
      'source' => 'AndroidX project policy fallback'
    }]
  end
  if group.start_with?('org.jetbrains')
    return [{
      'name' => 'Apache License 2.0',
      'url' => 'https://www.apache.org/licenses/LICENSE-2.0.txt',
      'source' => 'JetBrains project declaration fallback'
    }]
  end
  if group == 'com.google.guava'
    return [{
      'name' => 'Apache License 2.0',
      'url' => 'https://www.apache.org/licenses/LICENSE-2.0.txt',
      'source' => 'Guava project declaration fallback'
    }]
  end
  if group.start_with?('org.apache.commons')
    return [{
      'name' => 'Apache License 2.0',
      'url' => 'https://www.apache.org/licenses/LICENSE-2.0.txt',
      'source' => 'Apache Commons project declaration fallback'
    }]
  end
  if group == 'io.flutter'
    return [{
      'name' => 'Flutter BSD-3-Clause and engine composite notices',
      'source' => 'Pinned Flutter SDK snapshot'
    }]
  end
  if group == 'com.google.protobuf'
    return [{
      'name' => 'BSD-3-Clause',
      'url' => 'https://github.com/protocolbuffers/protobuf/blob/v26.1/LICENSE',
      'source' => 'Official upstream fallback'
    }]
  end
  if group == 'org.codehaus.mojo' && artifact == 'animal-sniffer-annotations'
    return [{
      'name' => 'MIT',
      'url' => 'https://opensource.org/license/mit',
      'source' => 'License text embedded in artifact POM header'
    }]
  end
  []
end

def maven_pom(component)
  base = Pathname.new(File.expand_path('~/.gradle/caches/modules-2/files-2.1'))
  candidates = Dir.glob(
    base.join(
      component.fetch('group'), component.fetch('artifact'),
      component.fetch('version'), '*', '*.pom'
    ).to_s
  ).sort
  candidates.empty? ? nil : Pathname.new(candidates.first)
end

def official_pom_url(component)
  group_path = component.fetch('group').tr('.', '/')
  artifact = component.fetch('artifact')
  version = component.fetch('version')
  base = component.fetch('group').start_with?('androidx.') ?
    'https://dl.google.com/dl/android/maven2' :
    'https://repo1.maven.org/maven2'
  "#{base}/#{group_path}/#{artifact}/#{version}/#{artifact}-#{version}.pom"
end

def generate_maven_inventory(lock_mtime)
  unless MAVEN_REPORT.file?
    payload = {
      'schema_version' => 1,
      'status' => 'UNRESOLVED_NO_RELEASE_REPORT',
      'components' => []
    }
    write_text(DEPENDENCIES_DIR.join('android_maven.json'), JSON.pretty_generate(payload))
    return payload
  end

  report = MAVEN_REPORT.read
  components = maven_coordinates(report).sort_by do |entry|
    [entry['group'], entry['artifact'], entry['version']]
  end.map do |component|
    pom = maven_pom(component)
    declarations = license_declarations_from_pom(pom)
    declarations = fallback_maven_license(component) if declarations.empty?
    component.merge(
      'coordinate' => "#{component['group']}:#{component['artifact']}:#{component['version']}",
      'pom_url' => official_pom_url(component),
      'local_pom' => pom ? sanitize_cache_path(pom) : nil,
      'license_declarations' => declarations,
      'license_status' => declarations.empty? ? 'UNRESOLVED_DECLARATION' : 'DECLARATION_FOUND'
    ).compact
  end

  payload = {
    'schema_version' => 1,
    'source_report' => relative(MAVEN_REPORT),
    'source_report_sha256' => sha256(MAVEN_REPORT),
    'source_report_mtime_utc' => MAVEN_REPORT.mtime.utc.iso8601,
    'stale_against_pubspec_lock' => MAVEN_REPORT.mtime < lock_mtime,
    'component_count' => components.length,
    'components' => components
  }
  write_text(DEPENDENCIES_DIR.join('android_maven.json'), JSON.pretty_generate(payload))

  groups = components.group_by do |entry|
    names = entry.fetch('license_declarations').map { |item| item['name'] }.sort
    names.empty? ? 'UNRESOLVED' : names.join(' OR ')
  end
  markdown = []
  markdown << '# Android Maven Components'
  markdown << ''
  markdown << '> Generated from the most recent local release SDK dependency report.'
  markdown << ''
  markdown << "- Components: #{components.length}"
  markdown << "- Report SHA-256: `#{payload['source_report_sha256']}`"
  markdown << "- Report older than current pubspec.lock: **#{payload['stale_against_pubspec_lock']}**"
  markdown << ''
  markdown << 'A `false` stale flag does not replace a final release rebuild. Native libraries are tracked separately.'
  markdown << ''
  groups.sort.each do |license, entries|
    markdown << "## #{license}"
    markdown << ''
    entries.each { |entry| markdown << "- `#{entry['coordinate']}`" }
    markdown << ''
  end
  write_text(DEPENDENCIES_DIR.join('ANDROID_MAVEN_COMPONENTS.md'), markdown.join("\n"))
  payload
end

def extract_tail_license(source, marker, destination)
  return nil unless source.file?
  text = source.read(encoding: 'UTF-8', invalid: :replace, undef: :replace)
  index = text.index(marker)
  return nil unless index

  write_text(destination, text[index..])
  destination
end

def extract_comment_containing(source, marker, destination)
  return nil unless source.file?
  text = source.read(encoding: 'UTF-8', invalid: :replace, undef: :replace)
  comments = text.scan(%r{/\*.*?\*/}m)
  selected = comments.find { |comment| comment.include?(marker) }
  return nil unless selected

  write_text(destination, selected)
  destination
end

def file_snapshot(path)
  {
    'name' => path.basename.to_s,
    'size' => path.size,
    'sha256' => sha256(path)
  }
end

def snapshot_directory(path, pattern = '*.so')
  return [] unless path.directory?
  Dir.glob(path.join(pattern).to_s).sort.map { |item| file_snapshot(Pathname.new(item)) }
end

def generate_flutter_soloud_licenses(package_root, version)
  target = NATIVE_LICENSES_DIR.join('flutter_soloud')
  FileUtils.mkdir_p(target)
  files = []
  {
    package_root.join('LICENSE') => target.join("flutter_soloud-#{version}-LICENSE.txt"),
    package_root.join('src', 'soloud', 'LICENSE') => target.join('SoLoud-LICENSE.txt'),
    package_root.join('src', 'filters', 'signalsmith-linear', 'LICENSE.txt') => target.join('Signalsmith-Linear-LICENSE.txt'),
    package_root.join('src', 'filters', 'signalsmith-stretch', 'LICENSE.txt') => target.join('Signalsmith-Stretch-LICENSE.txt')
  }.each do |source, destination|
    next unless source.file?
    copy_exact(source, destination)
    files << destination
  end

  files << extract_comment_containing(
    package_root.join('src', 'pffft', 'pffft.c'),
    'FFTPACK license', target.join('PFFFT-FFTPACK-LICENSE.txt')
  )
  files << extract_comment_containing(
    package_root.join('src', 'soloud', 'src', 'filter', 'soloud_fftfilter.cpp'),
    'The Wide Open License', target.join('SoLoud-Wide-Open-License.txt')
  )
  files << extract_tail_license(
    package_root.join('src', 'soloud', 'src', 'backend', 'miniaudio', 'miniaudio.h'),
    'This software is available as a choice of the following licenses.',
    target.join('miniaudio-LICENSE.txt')
  )
  %w[dr_flac.h dr_mp3.h dr_wav.h].each do |filename|
    files << extract_tail_license(
      package_root.join('src', 'soloud', 'src', 'audiosource', 'wav', filename),
      'This software is available as a choice of the following licenses.',
      target.join("#{filename.delete_suffix('.h')}-LICENSE.txt")
    )
  end
  files << extract_tail_license(
    package_root.join('src', 'soloud', 'src', 'audiosource', 'wav', 'stb_vorbis.c'),
    'This software is available under 2 licenses',
    target.join('stb_vorbis-LICENSE.txt')
  )
  files.concat(Dir.glob(target.join('*COPYING*').to_s).map { |path| Pathname.new(path) })
  files.compact.select(&:file?).uniq.map do |path|
    {'path' => relative(path), 'sha256' => sha256(path)}
  end
end

def native_component(name:, version:, status:, source:, files:, license_files: [], notes: [])
  {
    'name' => name,
    'version' => version,
    'status' => status,
    'source' => source,
    'binary_snapshot' => files,
    'license_files' => license_files,
    'notes' => notes
  }
end

def generate_native_inventory(package_config, lock)
  package_config_dir = PACKAGE_CONFIG.dirname
  roots = package_config.fetch('packages').to_h do |entry|
    [entry.fetch('name'), resolved_package_root(package_config_dir, entry.fetch('rootUri'))]
  end
  packages = lock.fetch('packages')
  components = []

  soloud_root = roots['flutter_soloud']
  if soloud_root
    version = packages.dig('flutter_soloud', 'version').to_s
    licenses = generate_flutter_soloud_licenses(soloud_root, version)
    files = snapshot_directory(soloud_root.join('android', 'libs', 'arm64-v8a'))
    components << native_component(
      name: 'flutter_soloud native stack',
      version: version,
      status: 'LICENSE_TEXTS_INCLUDED_BINARY_VERSIONS_UNAVAILABLE',
      source: 'https://pub.dev/packages/flutter_soloud',
      files: files,
      license_files: licenses,
      notes: [
        'Plugin, SoLoud, Signalsmith, PFFFT/FFTPACK, miniaudio, dr_libs and stb_vorbis texts were copied/extracted from the exact package cache.',
        'The prebuilt FLAC/Ogg/Opus/Vorbis libraries do not ship a versioned license manifest; they remain unresolved until upstream supplies one.'
      ]
    )
  end

  llama_root = roots['llamadart']
  if llama_root
    version = packages.dig('llamadart', 'version').to_s
    tag = llama_root.join('hook', 'build.dart').read[/const _llamaCppTag = '([^']+)'/, 1] rescue nil
    bundle_dir = tag ? llama_root.join('.dart_tool', 'llamadart', 'native_bundles', tag, 'android-arm64', 'extracted') : nil
    llama_license_paths = [
      NATIVE_LICENSES_DIR.join("llamadart-native-#{tag}-LICENSE.txt"),
      NATIVE_LICENSES_DIR.join("llama.cpp-#{tag}-LICENSE.txt")
    ].select(&:file?)
    components << native_component(
      name: 'llamadart native / llama.cpp / ggml',
      version: "#{version} / native-tag #{tag || 'unknown'}",
      status: llama_license_paths.length == 2 ? 'LICENSES_VERIFIED_UPSTREAM_TAG_PINNED' : 'UNRESOLVED_NATIVE_LICENSE_FILES',
      source: tag ? "https://github.com/leehack/llamadart-native/releases/tag/#{tag}" : 'https://github.com/leehack/llamadart-native',
      files: bundle_dir ? snapshot_directory(bundle_dir) : [],
      license_files: llama_license_paths.map { |path| {'path' => relative(path), 'sha256' => sha256(path)} },
      notes: [
        "The wrapper pins native tag #{tag}; llamadart-native documents that raw upstream tags identify the llama.cpp source ref used for release assets.",
        "Exact MIT license texts for both llamadart-native and llama.cpp at tag #{tag} are stored locally."
      ]
    )
  end

  gemma_version = packages.dig('flutter_gemma', 'version').to_s
  gemma_cache = Pathname.new(File.expand_path('~/Library/Caches/flutter_gemma/native'))
  litert_files = snapshot_directory(gemma_cache.join('android_arm64'))
  qdrant_files = snapshot_directory(gemma_cache.join('qdrant_edge', 'android_arm64'))
  unless gemma_version.empty?
    litert_license = NATIVE_LICENSES_DIR.join('LiteRT-LM-v0.12.0-LICENSE.txt')
    components << native_component(
      name: 'flutter_gemma LiteRT-LM bundle',
      version: "#{gemma_version} / native-v0.12.0-a",
      status: litert_license.file? ? 'PRIMARY_APACHE_LICENSE_VERIFIED_TRANSITIVE_NOTICES_PARTIAL' : 'UNRESOLVED_PRIMARY_LICENSE',
      source: 'https://github.com/DenisovAV/flutter_gemma/releases/tag/native-v0.12.0-a',
      files: litert_files,
      license_files: litert_license.file? ? [{'path' => relative(litert_license), 'sha256' => sha256(litert_license)}] : [],
      notes: [
        'The exact Apache-2.0 text from LiteRT-LM v0.12.0 is stored locally.',
        'The downloaded binary bundle does not provide a complete native transitive SBOM; Android Maven dependencies are inventoried separately.',
        'Qualcomm QNN binaries are excluded from Holt release APKs.'
      ]
    )
    components << native_component(
      name: 'Qualcomm QNN libraries distributed by flutter_gemma bundle',
      version: 'unknown; extracted upstream from Google AI Edge Gallery APKs',
      status: 'EXCLUDED_FROM_ANDROID_RELEASE_REDISTRIBUTION_UNVERIFIED',
      source: 'No authoritative redistributable source identified',
      files: litert_files.select { |file| file['name'].match?(/Qnn|Qualcomm/) },
      notes: [
        'flutter_gemma hook comments state these binaries were extracted from Google AI Edge Gallery APKs.',
        'No Qualcomm/Google redistribution license, NOTICE, version manifest, or SBOM is present. A generic Apache license cannot cure this.',
        'android/app/build.gradle.kts excludes libQnn*.so and libLiteRtDispatch_Qualcomm.so; the release verifier rejects an APK containing either.'
      ]
    )
    components << native_component(
      name: 'qdrant-edge native FFI',
      version: '0.7.2',
      status: 'EXCLUDED_FROM_ANDROID_RELEASE',
      source: 'https://github.com/DenisovAV/flutter_gemma/releases/tag/qdrant-edge-v0.7.2',
      files: qdrant_files,
      notes: [
        'The binary embeds many Rust crates but the release/cache has no Cargo.lock, cargo-about output, or THIRD_PARTY_LICENSES.',
        'android/app/build.gradle.kts excludes libqdrant_edge_ffi.so; the release verifier rejects an APK containing it.'
      ]
    )
  end

  sqlite_version = packages.dig('sqlite3', 'version')
  if sqlite_version
    sqlite_files = Dir.glob(
      ROOT.join('.dart_tool', 'hooks_runner', 'shared', 'sqlite3', '**', 'libsqlite3.so').to_s
    ).sort.map { |path| file_snapshot(Pathname.new(path)) }.uniq { |entry| entry['sha256'] }
    components << native_component(
      name: 'sqlite3 native library',
      version: sqlite_version.to_s,
      status: 'PRIMARY_LICENSE_VERIFIED_BINARY_BUILD_METADATA_PARTIAL',
      source: "https://pub.dev/packages/sqlite3/versions/#{sqlite_version}",
      files: sqlite_files,
      notes: [
        'sqlite3.dart is MIT; upstream SQLite is public domain.',
        'The exact SQLite source ID should be captured from the final release binary.'
      ]
    )
  end

  payload = {
    'schema_version' => 1,
    'scope' => 'Android arm64 dependency caches; final APK must be re-audited',
    'components' => components
  }
  write_text(DEPENDENCIES_DIR.join('native_components.json'), JSON.pretty_generate(payload))
  payload
end

def copy_common_license_texts(package_config)
  FileUtils.mkdir_p(ANDROID_LICENSES_DIR)
  package_config_dir = PACKAGE_CONFIG.dirname
  roots = package_config.fetch('packages').to_h do |entry|
    [entry.fetch('name'), resolved_package_root(package_config_dir, entry.fetch('rootUri'))]
  end
  candidates = {
    'Apache-2.0.txt' => roots.fetch('app_links').join('LICENSE'),
    'MIT.txt' => roots.fetch('archive').join('LICENSE')
  }
  candidates.each do |name, source|
    copy_exact(source, ANDROID_LICENSES_DIR.join(name)) if source.file?
  end
end

abort "Missing #{PUBSPEC_LOCK}" unless PUBSPEC_LOCK.file?
abort "Missing #{PACKAGE_CONFIG}; run flutter pub get before generating" unless PACKAGE_CONFIG.file?

FileUtils.mkdir_p([DEPENDENCIES_DIR, DART_LICENSES_DIR, FLUTTER_LICENSES_DIR, NATIVE_LICENSES_DIR])
lock = YAML.safe_load(PUBSPEC_LOCK.read, aliases: true)
package_config = JSON.parse(PACKAGE_CONFIG.read)
packages, flutter = generate_pub_inventory(lock, package_config)
maven = generate_maven_inventory(PUBSPEC_LOCK.mtime)
native = generate_native_inventory(package_config, lock)
copy_common_license_texts(package_config)

manifest = {
  'schema_version' => 1,
  'generated_at_utc' => Time.now.utc.iso8601,
  'scope' => {
    'source_tree' => 'All packages resolved in pubspec.lock, including dev and non-Android platform transitive packages',
    'binary_release' => 'Android only; Maven/native snapshots must be regenerated from the final release build'
  },
  'inputs' => {
    'pubspec_yaml_sha256' => PUBSPEC.file? ? sha256(PUBSPEC) : nil,
    'pubspec_lock_sha256' => sha256(PUBSPEC_LOCK),
    'package_config_sha256' => sha256(PACKAGE_CONFIG),
    'android_maven_report_sha256' => MAVEN_REPORT.file? ? sha256(MAVEN_REPORT) : nil
  }.compact,
  'flutter' => flutter,
  'counts' => {
    'dart_flutter_packages' => packages.length,
    'android_maven_components' => maven.fetch('components', []).length,
    'native_component_groups' => native.fetch('components', []).length,
    'unresolved_dart_flutter_licenses' => packages.count { |entry| entry.dig('license', 'status') == 'UNRESOLVED' },
    'unresolved_android_maven_declarations' => maven.fetch('components', []).count { |entry| entry['license_status'] == 'UNRESOLVED_DECLARATION' },
    'blocked_or_unresolved_native_groups' => native.fetch('components', []).count { |entry| entry['status'].match?(/BLOCKED|UNRESOLVED/) }
  },
  'packages' => packages
}
write_text(DEPENDENCIES_DIR.join('dependency_manifest.json'), JSON.pretty_generate(manifest))

puts "Generated #{packages.length} Dart/Flutter package entries"
puts "Generated #{maven.fetch('components', []).length} Android Maven entries"
puts "Generated #{native.fetch('components', []).length} native component groups"
puts "Manifest: #{DEPENDENCIES_DIR.join('dependency_manifest.json')}"
