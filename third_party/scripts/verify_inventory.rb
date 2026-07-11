#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'
require 'open3'
require 'yaml'

ROOT = Pathname.new(File.expand_path('../..', __dir__))
MANIFEST_PATH = ROOT.join('third_party', 'dependencies', 'dependency_manifest.json')
MAVEN_PATH = ROOT.join('third_party', 'dependencies', 'android_maven.json')
NATIVE_PATH = ROOT.join('third_party', 'dependencies', 'native_components.json')
RELEASE_APK = ROOT.join('build', 'app', 'outputs', 'flutter-apk', 'app-release.apk')

errors = []
warnings = []

unless MANIFEST_PATH.file?
  abort "Missing #{MANIFEST_PATH}; run generate_inventory.rb first"
end

manifest = JSON.parse(MANIFEST_PATH.read)
lock_path = ROOT.join('pubspec.lock')
lock = YAML.safe_load(lock_path.read, aliases: true)
current_lock_hash = Digest::SHA256.file(lock_path).hexdigest
expected_lock_hash = manifest.dig('inputs', 'pubspec_lock_sha256')
errors << 'pubspec.lock changed after inventory generation' unless current_lock_hash == expected_lock_hash

expected_package_count = lock.fetch('packages').length
actual_package_count = manifest.fetch('packages').length
errors << "package count mismatch: lock=#{expected_package_count}, manifest=#{actual_package_count}" unless expected_package_count == actual_package_count

manifest.fetch('packages').each do |package|
  package.dig('license', 'files').to_a.each do |license|
    path = ROOT.join(license.fetch('path'))
    unless path.file?
      errors << "missing license file: #{license['path']}"
      next
    end
    actual = Digest::SHA256.file(path).hexdigest
    errors << "license hash mismatch: #{license['path']}" unless actual == license.fetch('sha256')
  end
end

if MAVEN_PATH.file?
  maven = JSON.parse(MAVEN_PATH.read)
  warnings << 'Android Maven snapshot is older than pubspec.lock; rebuild release and regenerate' if maven['stale_against_pubspec_lock']
  unresolved = maven.fetch('components', []).count { |entry| entry['license_status'] == 'UNRESOLVED_DECLARATION' }
  warnings << "#{unresolved} Maven components have unresolved license declarations" if unresolved.positive?
else
  errors << 'missing Android Maven manifest'
end

if NATIVE_PATH.file?
  native = JSON.parse(NATIVE_PATH.read)
  statuses = native.fetch('components').map { |entry| entry.fetch('status') }
  errors << 'QNN exclusion decision is not represented' unless statuses.include?('EXCLUDED_FROM_ANDROID_RELEASE_REDISTRIBUTION_UNVERIFIED')
  native.fetch('components').each do |component|
    component.fetch('license_files', []).each do |license|
      path = ROOT.join(license.fetch('path'))
      unless path.file?
        errors << "missing native license file: #{license['path']}"
        next
      end
      errors << "native license hash mismatch: #{license['path']}" unless Digest::SHA256.file(path).hexdigest == license.fetch('sha256')
    end
  end
else
  errors << 'missing native component manifest'
end

errors << 'missing top-level LICENSE for Holt source' unless ROOT.join('LICENSE').file?

if RELEASE_APK.file?
  apk_entries, status = Open3.capture2('unzip', '-Z1', RELEASE_APK.to_s)
  if status.success?
    forbidden = apk_entries.lines.map(&:strip).grep(%r{lib/[^/]+/(?:libQnn.*\.so|libLiteRtDispatch_Qualcomm\.so|libqdrant_edge_ffi\.so)\z})
    errors << "release APK contains excluded native libraries: #{forbidden.join(', ')}" unless forbidden.empty?
  else
    errors << 'unable to inspect release APK contents'
  end
else
  warnings << 'release APK missing; native exclusion could not be verified'
end

puts "Verified #{actual_package_count} Dart/Flutter package entries"
warnings.each { |warning| warn "WARNING: #{warning}" }
if errors.any?
  errors.each { |error| warn "ERROR: #{error}" }
  exit 1
end
puts 'Third-party inventory integrity checks passed'
