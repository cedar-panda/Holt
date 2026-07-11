# Third-Party Notices

Holt includes third-party Dart/Flutter packages, Android Maven artifacts,
native libraries and fonts. Those components remain under their original
licenses; Holt's MIT license does not replace or relicense them.

The exact resolved inventory for this source tree is stored in:

- `third_party/dependencies/DART_FLUTTER_COMPONENTS.md`
- `third_party/dependencies/ANDROID_MAVEN_COMPONENTS.md`
- `third_party/dependencies/native_components.json`
- `third_party/dependencies/dependency_manifest.json`

Corresponding license texts are stored under `third_party/licenses/`. The
inventory includes versions, source references and SHA-256 hashes. Run
`ruby third_party/scripts/verify_inventory.rb` after the final Android release
build to verify that the dependency snapshot is current and that excluded
native libraries are absent from the APK.

## Native components

- llama.cpp / ggml and llamadart-native: MIT
- LiteRT-LM: Apache License 2.0
- flutter_soloud / SoLoud and bundled audio codecs: their included MIT, zlib,
  public-domain and Xiph/BSD-style terms
- SQLite: public domain upstream; Dart bindings under MIT

Qualcomm QNN libraries from the flutter_gemma download bundle are deliberately
excluded from Holt Android release APKs because authoritative redistribution
terms were not present. qdrant-edge is also excluded because its binary bundle
did not include a complete Rust transitive-license manifest.

## Fonts

### Lora

- File: `assets/fonts/Lora-Regular.ttf`
- License: SIL Open Font License 1.1
- Text: `third_party/licenses/lora/OFL.txt`
- Copyright 2011 The Lora Project Authors

### LXGW WenKai TC / 霞鶩文楷 TC

- File: `assets/fonts/LXGWWenKaiTC-Regular.ttf`
- License: SIL Open Font License 1.1
- Text: `third_party/licenses/lxgw-wenkai-tc/OFL.txt`
- Copyright 2022-2026 The LXGW WenKai Project Authors
- Font metadata also credits Copyright 2020 The Klee Project Authors

Upstream source and license URLs are recorded in the generated inventory. This
notice is an index; the stored license texts are controlling.
