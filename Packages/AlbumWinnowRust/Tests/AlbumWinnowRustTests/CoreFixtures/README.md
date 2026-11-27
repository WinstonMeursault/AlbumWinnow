# Shared core reference inputs

All media is generated test material. No personal photos are included.

This directory is the canonical corpus, stored inside the Swift package so
SwiftPM copies real resources on supported Xcode versions. `Tests/CoreFixtures`
is a shared alias for Rust, Android and Xcode test hosts. Do not replace this
package resource directory with a symlink: older SwiftPM copies that link into
the bundle without its target.

- `swift-v1-fingerprints.json` and the root `.rgba` files freeze the v1 Swift
  fingerprint result at `ba4f125`. Each buffer is 128 × 128 RGBA8, sRGB,
  premultiplied alpha, top row first, stride 512. Hashes and means are exact;
  continuous edge metrics use the recorded absolute tolerance of `1e-10`.
- `bridge.json` records the raw BLAKE3/type/buffer bridge fixture. Raw byte hashes
  are separate from v2 oriented byte identities.
- `decode/` contains a transparent PNG and JPEG for the minimal Android native
  decoding path. The Android adapter converts `getPixels` ARGB values into
  explicit premultiplied RGBA rather than reinterpreting Bitmap storage.
- `scene/reference.json` freezes the unchanged v1 SceneSimilarity/SceneGrouping
  rules before their Rust migration. The 16 `.rgba` files are the actual
  512-thumbnail → 128-grid scene-quality inputs; they need not equal the root
  fingerprint buffers. `.f32le` files contain 768 IEEE float32 values, explicitly
  little endian, extracted from the named Apple Vision provider. Keys and
  quality metrics are fixed. The 120 distances were measured by Apple Vision;
  Rust consumes these measurements and does not replace `computeDistance`.
  Normal and A/B group members, real edges and recommendation reasons are frozen.
- `difference/reference.json` freezes six pairs from the unchanged v1 difference
  analyzer. Its `.rgba` files are 256 × 256 working grids. Each case separately
  records the native bounded-preview dimensions, which determine geometry and
  detail availability. Rectangles use top-left normalized coordinates.

The scene/difference exporter was run from the P3 worktree while those three
algorithm files were byte-identical to `ba4f125`. The temporary exporter source
and execution log are saved in `.local/docs/v2-evidence/`; it is not a production
fallback or a second core. The scene fixtures test projection/grouping arithmetic
on fixed inputs; they do not claim that Android supports Apple's model or archives.
