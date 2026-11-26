# Shared core build

The production Apple application uses the Rust v2 core through native Swift services.
P8 cleanup and the final P9 acceptance matrix remain in progress. P0–P9 evidence is kept locally in `.local/docs/v2.0.0-progress.md`
and `.local/docs/v2.0.0-validation.md`; generated native libraries stay outside Git.

## Prerequisites

Install Rust using [rustup](https://rustup.rs/) and put `$HOME/.cargo/bin` on PATH.
`rust-toolchain.toml` fixes Rust 1.100.0, components and targets. `Cargo.lock` fixes
transitive dependencies. The project retains AGPL-3.0 licensing.

Apple builds require macOS, Xcode and the existing macOS/iOS 26 deployment target.
Run the preparation command **before** resolving the local Swift package:

```sh
Tools/Core/build-apple.sh debug
swift test --package-path Packages/AlbumWinnowRust -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

`build-apple.sh [debug|release] [--if-needed]` generates bindings, builds the Rust static
libraries, combines architectures separately for macOS and the simulator, then creates
`.local/core/AlbumWinnowRustFFI.xcframework`. Device arm64 and simulator arm64 are
separate platform slices. The Swift package references that relative artifact;
no machine-specific path or copied prebuilt library is required.
Swift production packages have no GRDB or Swift BLAKE3 dependency. Review and
cache storage are Rust-owned; native test fault injection uses the system SQLite3
module against disposable fixtures. The Swift review-state benchmark also calls
Rust through the production bridge.
`apple-manifest.json` records toolchain, dependency versions, targets, configuration,
source/binding hashes and native artifact hashes. It identifies dirty source by
its hash, rather than claiming the recorded Git commit includes uncommitted work.
`--if-needed` reuses artifacts only when the profile, all five targets, source and
build scripts, both generated bindings, Rust/Xcode versions and every artifact hash
match. Assembly happens in a staging directory; the previous framework remains
available until successful installation and is retained as a local backup.
The application test entry scripts prepare the Release native library before
Swift package resolution, using this verification to avoid redundant builds.

`Tools/Core/generate-bindings.sh [--check]` uses the pinned UniFFI 0.29.4 host
library to generate both languages. `--check` compares regenerated output against
the tracked Swift/Kotlin/header/module-map files without replacing them. Generated
Swift includes UniFFI's documented synchronization and Sendable declarations;
strict concurrency remains enabled for consumers.

Native FileSystemSource/PhotoLibrarySource constructors require an explicit core
source ID. Before registering a directory, read its identity with
`FileSystemSource.sourceIdentity(directory:)`; construct the source only after
registration. Directory roots and saved physical file identities use v2 namespaces.
Readable fixture source IDs are confined to the Apple test target and remapped by
FixtureScanEngine before production scan preparation.

`python3 Tools/Core/notices.py [--check]` generates/checks the bundled Rust notices
from Cargo.lock, normal dependency trees for the pinned supported targets, and
the actual package license files. Run `cargo fetch --locked` once if the registry
cache is incomplete; generation itself runs Cargo offline. UniFFI template and standard MIT texts missing
from package archives are pinned under `Tools/Core/licenses`. The command works
with the system Python 3.9 and does not download replacement license texts.
Missing or unrecognized license content fails generation. Android host framework
notices are separate from this shared Rust dependency list.
The pinned `rust-docs` component supplies standard-library distribution notices;
the generator preserves their attributions and references identical full license
bodies once. These are bundled in the same offline notice document.

## Android development smoke host

Install Android SDK command-line tools, platform-tools, Android 35 platform,
35.0.0 build-tools, NDK **28.2.13676358**, an emulator and an Android 35 arm64 system
image. Set `ANDROID_SDK_ROOT` (and `ANDROID_HOME` for Gradle) to that SDK. Use JDK 17.

```sh
Tools/Core/build-android.sh debug
cd Tests/AndroidCoreSmoke
./gradlew :core:assembleDebug :core:connectedDebugAndroidTest
```

The Gradle wrapper fixes 8.11.1 with its distribution checksum, AGP is 8.9.2,
Kotlin is 2.1.20 and JNA is 5.17.0 (AAR). The test host uses minSdk 26 and compileSdk
35; these are smoke-test conditions, not future Android product requirements.
The native build creates arm64-v8a and x86_64 libraries in
`.local/core/android/jniLibs`, uses bundled SQLite and 16 KB segment alignment.
Inspect **all** native dependencies in the final test APK as well as APK alignment;
self-owned library alignment alone is not full acceptance.

If a network proxy is required, configure Gradle's standard HTTP/HTTPS proxy
properties in the user's Gradle configuration or command arguments. The scripts
do not embed a developer's proxy address. The smoke test has no media permissions
or deletion adapter. It is not an Android AlbumWinnow client.

The Android build scripts support macOS and Linux x86_64 build hosts. Linux is
used only for Android tooling, with no Linux application target. The CI smoke job
builds both ABIs, runs API 35 x86_64 instrumentation, and verifies each APK native
library's architecture, 16 KB load alignment and ZIP alignment. This workflow
configuration is not evidence of a completed remote run. No persistent cross-run
native artifact cache is configured.
The smoke host locks its main and instrumentation runtime graphs. Reviewed
framework notices live in `Tests/AndroidCoreSmoke/licenses`; native preparation
copies them, the shared notices and AlbumWinnow's license into APK assets. The APK
verifier requires byte-identical copies of every reviewed license resource.

## Validation

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo test --workspace --release --locked
Tools/Core/generate-bindings.sh --check
```

P1 probes version/UInt64/optional/nested values, bounded BLAKE3, typed errors,
independent cancellation, explicit Kotlin release, and bundled SQLite linking.
They are a bridge gate, not evidence of completed algorithm/state/UI migration.

### Native Apple cleanup fixtures

After preparing the Apple library, run the generated-file tests with
`swift test --package-path Packages/AlbumWinnowApple -c release`. They move only
their own temporary copies to Trash, restore the moved copies and verify bytes.

PhotoKit needs an isolated iOS simulator and the opt-in `CoreNativeCleanup`
scheme in `Tests/Bridge-project.yml`. Generate that project with
`ALBUMWINNOW_ROOT="$PWD" xcodegen generate --spec Tests/Bridge-project.yml --project-root "$PWD/.local/bridge-tests" --project .local/bridge-tests`,
then run its scheme on the dedicated simulator. The scheme enables
`ALBUMWINNOW_PHOTOS_FIXTURE=1`; missing opt-in fails. The fixture host additionally
refuses physical-device execution. Its foreground test application creates two
photos and an album per case, registers their exact identifiers with the Rust
owner, executes the native adapter and checks actual Photos results. UI tests
handle only that fixture host's access/recoverable-deletion confirmations.
Generated retained fixtures remain in the dedicated simulator; do not use a
personal photo library or broadly delete fixtures by album/title matching.

Interrupted PhotoKit operations can leave outstanding system confirmations. Use
a fresh dedicated simulator when validating a new fixture host, and retain failed
or interrupted results as failures. Do not turn missing access, OS confirmation,
or unfinished operations into skipped/passed cleanup tests. The portable Android
smoke executor remains controlled fake facts/outcomes with no media permission.

### Native Apple scan pipeline

`ScanEngine.scan` accepts a registered `AppleAssetSources` context and the single
`RustReviewSession`; scan scope/source preference/scene enablement come from that
session. A successful call returns `AppleScanReceipt` after the Rust review
transaction commits, with counts/issues/unavailable source IDs and cache
maintenance status. Read results through Rust summary pages and single-group
details. Do not restore the removed source-array/full-group-result API.

Run `swift test --package-path Packages/AlbumWinnowApple -c release` for the
recognition regressions and native transaction tests. The existing tests use a
test-only fixture projection; no complete-group projection is compiled into
ScanEngine or the native scene driver. The CoreBridge iOS scheme includes the
native transaction tests as well as portable bridge/normalization coverage.
Production SwiftUI now uses AppleReviewOwner, native receipts, bounded summaries
and lazy current/neighbor detail reads. Its new focused application tests are in
Tests/AppTests/V2ApplicationTests.swift. The retained application tests now use
v2 APIs and compile for macOS/iOS; test-only ModelWorkspace scopes each suite and
owner lifetime. The complete runtime/UI/regression/delivery matrix remains P7–P9
work. Build-for-testing is compilation evidence, not a passing full suite.
During development run only checks necessary for a change, and reserve full
suites plus clean candidate builds for delivery.
