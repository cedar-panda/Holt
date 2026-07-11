# Holt

Holt is a local-first, multi-provider AI companion app built with Flutter. The
currently supported distributable target is Android arm64.

本地優先的 AI 伴侶應用：對話、記憶、情緒數據全部留在你自己的設備上，
網絡請求只發往**你自己配置的 API**，無統計、無廣告、無遙測。
支援多家模型接入與離線本地模型，深度優化 prompt 緩存以壓低長對話成本。
構建與簽名見下文；隱私細節見 [PRIVACY.md](PRIVACY.md)。

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

Release signing is read from `android/key.properties`. If it or the referenced
keystore is missing, the project intentionally falls back to a debug signature;
such an APK must not be distributed.

## Data and network behavior

Chats and app settings are stored locally. Network requests are sent only to
providers or endpoints configured by the user, except for explicitly requested
model/file downloads and platform integrations. See [PRIVACY.md](PRIVACY.md).

Changing the visible product name does not change the Android application ID or
the Holt JSON backup format. Existing exports remain importable.

## Licensing

Holt source code is available under the [GNU GPL-3.0](LICENSE) — free to use
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
