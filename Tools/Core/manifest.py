"""Record the exact inputs used for local native artifacts."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
paths = [root / 'Cargo.toml', root / 'Cargo.lock', root / 'rust-toolchain.toml']
paths += sorted((root / 'Core').rglob('*.rs'))
paths += sorted((root / 'Core').rglob('*.toml'))
paths += [root / 'Tools/Core' / name for name in ['build-apple.sh', 'build-android.sh', 'generate-bindings.sh', 'manifest.py']]
bindings = sorted((root / 'Packages/AlbumWinnowRust/Sources').rglob('*.swift')) + sorted((root / 'Packages/AlbumWinnowRust/Headers').glob('*'))
bindings += [root / 'Tests/AndroidCoreSmoke/core/src/main/kotlin/org/albumwinnow/core/albumwinnow_ffi.kt']

def digest(files):
    result = hashlib.sha256()
    for path in files:
        result.update(str(path.relative_to(root)).encode())
        result.update(b'\0')
        result.update(path.read_bytes())
    return result.hexdigest()

def artifacts(directory):
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(directory.rglob('*')) if p.is_file()}

if sys.argv[1] == '--check-apple':
    try:
        directory = root / '.local/core'
        previous = json.loads((directory / 'apple-manifest.json').read_text())
        current = (previous['profile'] == sys.argv[2] and previous['targets'] == sys.argv[3:]
                   and previous['source_sha256'] == digest(paths) and previous['bindings_sha256'] == digest(bindings)
                   and previous['rust'] == subprocess.check_output(['rustc', '--version'], text=True).strip()
                   and previous['xcode'] == subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
                   and previous['artifacts'] == artifacts(directory / 'AlbumWinnowRustFFI.xcframework')
                   and bool(previous['artifacts']))
    except (OSError, ValueError, KeyError, TypeError):
        current = False
    sys.exit(0 if current else 1)

result = {
    'profile': sys.argv[1],
    'targets': sys.argv[3:],
    'rust': subprocess.check_output(['rustc', '--version'], text=True).strip(),
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    'source_sha256': digest(paths),
    'bindings_sha256': digest(bindings),
    'dependencies': json.loads(subprocess.check_output(['cargo', 'metadata', '--locked', '--format-version', '1'], cwd=root, text=True))['packages'],
}
if sys.platform == 'darwin':
    result['xcode'] = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
# Package IDs and versions are enough; avoid absolute build-machine paths.
result['dependencies'] = [{'name': p['name'], 'version': p['version'], 'license': p['license']} for p in result['dependencies']]
output = Path(sys.argv[2])
artifact_root = output.parent / ('jniLibs' if output.name == 'manifest.json' else 'AlbumWinnowRustFFI.xcframework')
result['artifacts'] = artifacts(artifact_root)
output.write_text(json.dumps(result, indent=2) + '\n')
