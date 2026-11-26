#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
export PATH="$HOME/.cargo/bin:$PATH"
if [[ "${1:-}" == --help ]]; then
    echo 'Usage: Tools/Core/generate-bindings.sh [--check]'
    echo 'Regenerates tracked Swift/Kotlin bindings using the pinned host library; --check rejects differences.'
    exit 0
fi
[[ $# == 0 || ( $# == 1 && $1 == --check ) ]] || { echo 'Invalid arguments' >&2; exit 2; }
case "$(uname -s)" in
    Darwin) host_library=target/debug/libalbumwinnow_ffi.dylib ;;
    Linux) host_library=target/debug/libalbumwinnow_ffi.so ;;
    *) echo 'Binding generation requires a macOS or Linux build host.' >&2; exit 1 ;;
esac
output="$root/.local/core/bindings"
rm -rf "$output"
mkdir -p "$output" Packages/AlbumWinnowRust/Sources/AlbumWinnowRust Packages/AlbumWinnowRust/Headers Tests/AndroidCoreSmoke/core/src/main/kotlin/org/albumwinnow/core
cargo build -p albumwinnow-ffi --features bindgen --locked
for language in swift kotlin; do
    cargo run -p albumwinnow-ffi --features bindgen --locked --bin albumwinnow-bindgen -- generate \
        --library "$host_library" --language "$language" \
        --config Core/albumwinnow-ffi/uniffi.toml --out-dir "$output/$language" --no-format
done
# Normalize generator whitespace identically for regeneration and --check.
python3 - "$output" <<'PYTHON'
from pathlib import Path
import sys
for path in Path(sys.argv[1]).rglob('*'):
    if path.is_file():
        path.write_text('\n'.join(line.rstrip() for line in path.read_text().splitlines()).rstrip() + '\n')
PYTHON
pairs=(
    'swift/AlbumWinnowRust.swift|Packages/AlbumWinnowRust/Sources/AlbumWinnowRust/AlbumWinnowRust.swift'
    'swift/AlbumWinnowRustFFI.h|Packages/AlbumWinnowRust/Headers/AlbumWinnowRustFFI.h'
    'swift/AlbumWinnowRustFFI.modulemap|Packages/AlbumWinnowRust/Headers/module.modulemap'
    'kotlin/org/albumwinnow/core/albumwinnow_ffi.kt|Tests/AndroidCoreSmoke/core/src/main/kotlin/org/albumwinnow/core/albumwinnow_ffi.kt'
)
for pair in "${pairs[@]}"; do
    source_file="$output/${pair%%|*}"
    destination="${pair#*|}"
    if [[ "${1:-}" == --check ]]; then
        cmp "$source_file" "$destination"
    else
        cp "$source_file" "$destination"
    fi
done
