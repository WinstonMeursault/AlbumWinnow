#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
export PATH="$HOME/.cargo/bin:$PATH"
profile="${1:-release}"
if [[ "$profile" == --help ]]; then
    echo 'Usage: Tools/Core/build-apple.sh [debug|release] [--if-needed]'
    echo 'Prepares generated bindings and .local/core/AlbumWinnowRustFFI.xcframework before Swift package resolution.'
    exit 0
fi
[[ $# -le 2 && ( "$profile" == debug || "$profile" == release ) && ( $# -lt 2 || "$2" == --if-needed ) ]] || exit 2
targets=(aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)
if [[ "${2:-}" == --if-needed ]] && python3 Tools/Core/manifest.py --check-apple "$profile" "${targets[@]}"; then
    echo 'Reusing verified Apple native artifacts.'
    exit 0
fi
Tools/Core/generate-bindings.sh
export MACOSX_DEPLOYMENT_TARGET=26.0
export IPHONEOS_DEPLOYMENT_TARGET=26.0
flags=(--profile dev)
[[ "$profile" == release ]] && flags=(--release)
for target in "${targets[@]}"; do
    rustup target list --installed | rg -qx "$target" || { echo "Missing Rust target: $target; run rustup target add $target" >&2; exit 1; }
    cargo build -p albumwinnow-ffi --lib --locked --target "$target" "${flags[@]}"
done
output="$root/.local/core"
mkdir -p "$output"
staging="$(mktemp -d "$output/apple-build.XXXXXX")"
mkdir -p "$staging/macos" "$staging/simulator"
xcrun lipo -create "target/aarch64-apple-darwin/$profile/libalbumwinnow_ffi.a" \
    "target/x86_64-apple-darwin/$profile/libalbumwinnow_ffi.a" -output "$staging/macos/libalbumwinnow_ffi.a"
xcrun lipo -create "target/aarch64-apple-ios-sim/$profile/libalbumwinnow_ffi.a" \
    "target/x86_64-apple-ios/$profile/libalbumwinnow_ffi.a" -output "$staging/simulator/libalbumwinnow_ffi.a"
xcodebuild -create-xcframework \
    -library "$staging/macos/libalbumwinnow_ffi.a" -headers Packages/AlbumWinnowRust/Headers \
    -library "target/aarch64-apple-ios/$profile/libalbumwinnow_ffi.a" -headers Packages/AlbumWinnowRust/Headers \
    -library "$staging/simulator/libalbumwinnow_ffi.a" -headers Packages/AlbumWinnowRust/Headers \
    -output "$staging/AlbumWinnowRustFFI.xcframework"
python3 Tools/Core/manifest.py "$profile" "$staging/apple-manifest.json" "${targets[@]}"
python3 - "$staging" "$output" <<'PYTHON'
from pathlib import Path
import shutil
import sys
import uuid
staging, output = map(Path, sys.argv[1:])
framework = output / 'AlbumWinnowRustFFI.xcframework'
backup = output / ('apple-prior-' + str(uuid.uuid4()) + '.xcframework')
if framework.exists():
    framework.rename(backup)
try:
    (staging / framework.name).rename(framework)
    (staging / 'apple-manifest.json').replace(output / 'apple-manifest.json')
except OSError:
    if framework.exists():
        framework.rename(staging / framework.name)
    if backup.exists():
        backup.rename(framework)
    raise
shutil.rmtree(staging)
PYTHON
