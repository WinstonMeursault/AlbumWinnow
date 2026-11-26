#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
export PATH="$HOME/.cargo/bin:$PATH"
profile="${1:-release}"
if [[ "$profile" == --help ]]; then
    echo 'Usage: ANDROID_SDK_ROOT=/path/to/sdk Tools/Core/build-android.sh [debug|release]'
    echo 'Requires NDK 28.2.13676358. Generates Kotlin bindings and arm64-v8a/x86_64 libraries in .local/core/android/jniLibs.'
    exit 0
fi
[[ $# -le 1 && ( "$profile" == debug || "$profile" == release ) ]] || exit 2
sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
case "$(uname -s):$(uname -m)" in
    Darwin:*) host_tag=darwin-x86_64 ;;
    Linux:x86_64) host_tag=linux-x86_64 ;;
    *) echo 'Android preparation requires macOS or a Linux x86_64 build host.' >&2; exit 1 ;;
esac
ndk="$sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/$host_tag/bin"
[[ -x "$ndk/aarch64-linux-android26-clang" ]] || { echo 'Install Android NDK 28.2.13676358 and set ANDROID_SDK_ROOT.' >&2; exit 1; }
Tools/Core/generate-bindings.sh
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$ndk/aarch64-linux-android26-clang"
export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$ndk/x86_64-linux-android26-clang"
export CC_aarch64_linux_android="$ndk/aarch64-linux-android26-clang"
export CC_x86_64_linux_android="$ndk/x86_64-linux-android26-clang"
export AR_aarch64_linux_android="$ndk/llvm-ar"
export AR_x86_64_linux_android="$ndk/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384'
export CARGO_TARGET_X86_64_LINUX_ANDROID_RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384'
flags=(--profile dev)
[[ "$profile" == release ]] && flags=(--release)
for pair in aarch64-linux-android:arm64-v8a x86_64-linux-android:x86_64; do
    target="${pair%:*}"
    abi="${pair#*:}"
    cargo build -p albumwinnow-ffi --lib --locked --target "$target" "${flags[@]}"
    output="$root/.local/core/android/jniLibs/$abi"
    mkdir -p "$output"
    cp "target/$target/$profile/libalbumwinnow_ffi.so" "$output/"
    "$ndk/llvm-readelf" -l "$output/libalbumwinnow_ffi.so"
done
licenses="$root/.local/core/android/assets/licenses"
mkdir -p "$licenses"
cp LICENSE THIRD-PARTY-NOTICES.txt "$licenses/"
cp Tests/AndroidCoreSmoke/licenses/*.txt "$licenses/"
python3 Tools/Core/manifest.py "$profile" "$root/.local/core/android/manifest.json" aarch64-linux-android x86_64-linux-android
