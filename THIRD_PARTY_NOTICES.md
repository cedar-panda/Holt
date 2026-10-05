# Third-Party Notices

Holt includes third-party Dart/Flutter packages, Android Maven artifacts,
native libraries, speech models and fonts. Those components remain under their
original licenses; Holt's GNU AGPL-3.0 license does not replace or relicense
them.

The last generated dependency inventory snapshot is stored in:

- `third_party/dependencies/DART_FLUTTER_COMPONENTS.md`
- `third_party/dependencies/ANDROID_MAVEN_COMPONENTS.md`
- `third_party/dependencies/native_components.json`
- `third_party/dependencies/dependency_manifest.json`

Corresponding license texts are stored under `third_party/licenses/`. The
inventory includes versions, source references and SHA-256 hashes. It may be
older than the current source tree. Run
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

## Speech recognition model

### Chinese streaming Zipformer (14M)

- Files: `assets/asr_zh/encoder-epoch-99-avg-1.int8.onnx`,
  `decoder-epoch-99-avg-1.onnx`, `joiner-epoch-99-avg-1.int8.onnx`,
  and `tokens.txt`
- Upstream: `https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23`
- License: Apache License 2.0
- Text: `third_party/licenses/asr_zh/Apache-2.0.txt`
- The three ONNX files' SHA-256 values match the upstream model files:
  - encoder: `1c556ea57cec304e55ec4b72e52c1cc098bb01476ed7d90f3de939fe126487b1`
  - decoder: `5ee0f03a2768ff1d5c83ef3a493243c7935d316cd41280037b14783a3467cc78`
  - joiner: `a7cf9d82757bdcf786059454495a9ca95e4bd7347f72473fc08d794475c36169`

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

### Cormorant Garamond

- File: `assets/fonts/CormorantGaramond-Regular.ttf`
- License: SIL Open Font License 1.1
- Text: `third_party/licenses/cormorant-garamond/OFL.txt`
- Copyright 2015 the Cormorant Project Authors
- Upstream license: `https://github.com/google/fonts/blob/main/ofl/cormorantgaramond/OFL.txt`

Upstream source and license URLs for the previously inventoried fonts are
recorded in the generated snapshot. This notice is an index; the stored license
texts are controlling.
