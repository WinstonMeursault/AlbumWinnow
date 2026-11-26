#!/usr/bin/env python3
"""Prepare a disposable instrumented benchmark; never edit production bindings.

Usage: python3 Tests/Performance/prepare_ffi_probe.py OUTPUT_DIRECTORY
Build OUTPUT_DIRECTORY/Tests/Performance in Release and run ScanBenchmark normally.
Its timings include instrumentation overhead and must not be used for speed gates.
Counts include runtime wrapper calls (including allocation/free), excluding direct
initialization checks. Bytes count serialized buffer payloads in both directions,
including native callbacks, not scalar arguments or every internal memory copy.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=False)
for relative in ['Packages/AlbumWinnowRust', 'Packages/AlbumWinnowApple', 'Tests/Performance']:
    shutil.copytree(root / relative, output / relative, ignore=shutil.ignore_patterns('.build', '__pycache__'))
(output / '.local').mkdir()
(output / '.local/core').symlink_to(root / '.local/core', target_is_directory=True)
binding = output / 'Packages/AlbumWinnowRust/Sources/AlbumWinnowRust/AlbumWinnowRust.swift'
source = binding.read_text()
changes = {
    'import Foundation': 'import Foundation\nimport os',
    '    init(bytes: [UInt8]) {': '    init(bytes: [UInt8]) {\n        recordFFIProbe(1, UInt64(bytes.count))',
    '    init(rustBuffer: RustBuffer) {': '    init(rustBuffer: RustBuffer) {\n        recordFFIProbe(2, UInt64(rustBuffer.len))',
    '    uniffiEnsureAlbumwinnowFfiInitialized()\n    var callStatus':
        '    recordFFIProbe(0, 1)\n    uniffiEnsureAlbumwinnowFfiInitialized()\n    var callStatus',
}
for before, after in changes.items():
    if source.count(before) != 1:
        raise SystemExit('Generated runtime changed; review probe anchor: ' + before)
    source = source.replace(before, after)
source += '''
private let ffiProbeCounters = OSAllocatedUnfairLock(initialState: [UInt64](repeating: 0, count: 3))
private func recordFFIProbe(_ index: Int, _ amount: UInt64) {
    ffiProbeCounters.withLock { $0[index] += amount }
}
public func ffiProbeSnapshot() -> [String: UInt64] {
    ffiProbeCounters.withLock {
        ["wrapper_calls": $0[0], "swift_to_rust_buffer_bytes": $0[1], "rust_to_swift_buffer_bytes": $0[2]]
    }
}
'''
binding.write_text(source)
benchmark = output / 'Tests/Performance/Sources/ScanBenchmark/main.swift'
source = benchmark.read_text()
anchor = 'var metrics = [[String: Any]]()'
if source.count(anchor) != 1:
    raise SystemExit('Benchmark changed; review metrics anchor')
source = source.replace(anchor, anchor + '\n        var priorFFIProbe = ffiProbeSnapshot()')
anchor = '            metrics.append(entry)'
if source.count(anchor) != 1:
    raise SystemExit('Benchmark changed; review record anchor')
source = source.replace(anchor, '''            var measured = entry
            let snapshot = ffiProbeSnapshot()
            measured["ffi_probe_delta"] = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.key, $0.value - (priorFFIProbe[$0.key] ?? 0)) })
            priorFFIProbe = snapshot
            metrics.append(measured)''')
benchmark.write_text(source)
(output / 'probe-provenance.json').write_text(json.dumps({
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    'method': __doc__, 'production_sources_modified': False,
}, indent=2) + '\n')
print(output / 'Tests/Performance')
