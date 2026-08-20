# Holt

Holt is a local-first, multi-provider AI companion app built with Flutter. The
currently supported distributable target is Android arm64.

Conversations, memories and emotion data are stored locally on your device.
When you use a remote model or another network feature, the content required
for that request is sent to the provider or endpoint **you** configure. Holt
operates no analytics, advertising or telemetry backend. It supports multiple
model providers and offline local models, with deep prompt-caching optimisation
to keep long-conversation costs down. Build and signing instructions are below;
privacy details are in [PRIVACY.md](PRIVACY.md).

**[Download Holt v1.3.7 APK](https://github.com/cedar-panda/Holt/releases/tag/v1.3.7)**

## Screenshots

<p>
  <img src="screenshots/chat.png" width="200">
  <img src="screenshots/chars.png" width="200">
  <img src="screenshots/call.png" width="200">
  <img src="screenshots/theme.png" width="200">
  <img src="screenshots/me.png" width="200">
</p>

## Features

- Multiple remote API providers and OpenAI-compatible endpoints
- Local model execution through llama.cpp and LiteRT-LM
- Per-character conversations, memories, summaries and voice settings
- Voice calls, text-to-speech, speech recognition and local backup/restore
- Traditional Chinese, Simplified Chinese and English interface

## Android requirements

- Flutter 3.44.2 / Dart 3.11 or a compatible newer toolchain
- Android arm64-v8a device
- Java 17

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

Release signing is read from `android/key.properties`. Release APK/AAB tasks
fail when it or the referenced keystore is missing; the project never falls
back to a debug signature for a release artifact.

## Data and network behavior

Chats and app settings are stored locally. Network requests are sent only to
providers or endpoints configured by the user, except for explicitly requested
model/file downloads and platform integrations. Public compatible endpoints
must use HTTPS; plain HTTP is accepted only for localhost and private-network
model servers. See [PRIVACY.md](PRIVACY.md).

Changing the visible product name does not change the Android application ID or
the backup data format. New portable exports are password-encrypted; existing
JSON and `.holt.zip` exports remain importable.

## Licensing

Holt source code is available under the [GNU AGPL-3.0](LICENSE) — free to use
and modify, but derivative works must remain open source under the same
license. Third-party
components, native libraries, fonts and their notices remain under their own
licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
[`third_party/dependencies/`](third_party/dependencies/).

The dependency inventory is reproducible:

```sh
ruby third_party/scripts/generate_inventory.rb
ruby third_party/scripts/verify_inventory.rb
```

Artwork and audio committed to this repository are treated as part of the
Software under the top-level license unless a nearby notice states otherwise.
