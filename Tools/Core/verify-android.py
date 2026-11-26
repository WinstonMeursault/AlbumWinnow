"""Verify every ELF library in a smoke APK and its 16 KB ZIP alignment."""
import argparse
from pathlib import Path
import struct
import subprocess
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('apk', type=Path)
parser.add_argument('--zipalign', required=True, type=Path)
args = parser.parse_args()
required = {'arm64-v8a', 'x86_64'}
machines = {'arm64-v8a': 183, 'x86_64': 62}
seen = set()
with zipfile.ZipFile(args.apk) as archive:
    root = Path(__file__).resolve().parents[2]
    licenses = [root / 'LICENSE', root / 'THIRD-PARTY-NOTICES.txt']
    licenses += sorted((root / 'Tests/AndroidCoreSmoke/licenses').glob('*.txt'))
    for license_path in licenses:
        if archive.read('assets/licenses/' + license_path.name) != license_path.read_bytes():
            raise SystemExit(f'{license_path.name}: APK license differs from reviewed source')
    print(f'APK contains {len(licenses)} exact license/notice resources')
    names = sorted(n for n in archive.namelist() if n.startswith('lib/') and n.endswith('.so'))
    if not names:
        raise SystemExit('APK contains no native libraries')
    for name in names:
        data = archive.read(name)
        if data[:6] != b'\x7fELF\x02\x01':
            raise SystemExit(f'{name}: expected little-endian ELF64')
        abi = name.split('/')[1]
        if abi not in machines or struct.unpack_from('<H', data, 18)[0] != machines[abi]:
            raise SystemExit(f'{name}: ELF machine does not match ABI directory')
        phoff = struct.unpack_from('<Q', data, 32)[0]
        phsize, phcount = struct.unpack_from('<HH', data, 54)
        loads = 0
        for i in range(phcount):
            fields = struct.unpack_from('<IIQQQQQQ', data, phoff + i * phsize)
            kind, _, offset, virtual, _, _, _, alignment = fields
            if kind != 1:
                continue
            loads += 1
            if alignment < 16384 or offset % 16384 != virtual % 16384:
                raise SystemExit(f'{name}: LOAD segment not 16 KB compatible')
        if loads == 0:
            raise SystemExit(f'{name}: no LOAD segments')
        if name.endswith('/libalbumwinnow_ffi.so'):
            seen.add(name.split('/')[1])
        print(f'{name}: {loads} LOAD segments compatible with 16 KB pages')
if not required <= seen:
    raise SystemExit(f'Missing core ABIs: {sorted(required - seen)}')
subprocess.run([str(args.zipalign), '-c', '-P', '16', '-v', '4', str(args.apk)], check=True)
