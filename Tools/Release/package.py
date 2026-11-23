#!/usr/bin/env python3
"""Package previously built release products; never overwrites a release."""
import argparse
import re

def version(value):
    if not re.fullmatch(r'1\.[0-9]+\.[0-9]+', value):
        raise argparse.ArgumentTypeError('Expected a v1 release number, e.g. 1.7.0')
    return value

def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version', type=version)
    parser.add_argument('mac_build')
    parser.add_argument('ios_build')
    return parser.parse_args(argv)

def main():
    from pathlib import Path
    import hashlib, json, plistlib, shutil, subprocess
    
    args = arguments()
    version, mac_build, ios_build = args.version, args.mac_build, args.ios_build
    repo = Path(__file__).resolve().parents[2]
    assert Path.cwd().resolve() == repo, 'Run from the repository root'
    release = repo / '.local' / 'App' / ('v' + version)
    assert not release.exists(), 'Do not overwrite a completed release'
    assert not subprocess.check_output(['git','status','--porcelain']).strip(), 'Source tree must be clean'
    commit = subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip()
    tree = subprocess.check_output(['git','rev-parse','HEAD^{tree}'], text=True).strip()
    mac = Path(mac_build) / 'Build/Products/Release/AlbumWinnow.app'
    ios = Path(ios_build) / 'Build/Products/Release-iphoneos/AlbumWinnow.app'
    with (mac / 'Contents/Info.plist').open('rb') as f: mac_info = plistlib.load(f)
    with (ios / 'Info.plist').open('rb') as f: ios_info = plistlib.load(f)
    assert mac_info['CFBundleShortVersionString'] == ios_info['CFBundleShortVersionString'] == version
    assert mac_info['LSMinimumSystemVersion'] == '26.0'
    assert set(ios_info['UIDeviceFamily']) == {1, 2}
    assert ios_info['MinimumOSVersion'] == '26.0'
    assert ios_info['CFBundleSupportedPlatforms'] == ['iPhoneOS']
    assert not (ios / '_CodeSignature').exists(), 'IPA should be explicitly unsigned'
    release.mkdir(parents=True)
    subprocess.run(['ditto', str(mac), str(release / 'AlbumWinnow.app')], check=True)
    subprocess.run(['codesign','--force','--deep','--sign','-','--entitlements','Apps/macOS/AlbumWinnow.entitlements',str(release / 'AlbumWinnow.app')], check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(release / 'AlbumWinnow.app')], check=True)
    architectures = subprocess.check_output(['lipo','-archs', str(release / 'AlbumWinnow.app/Contents/MacOS/AlbumWinnow')], text=True).strip()
    assert set(architectures.split()) == {'arm64','x86_64'}
    mac_zip = release / f'AlbumWinnow-v{version}-macOS-universal.zip'
    subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',str(release / 'AlbumWinnow.app'),str(mac_zip)], check=True)
    staging = repo / '.local' / ('package-v' + version)
    payload = staging / 'Payload'
    payload.mkdir(parents=True, exist_ok=False)
    subprocess.run(['ditto',str(ios), str(payload / 'AlbumWinnow.app')],check=True)
    ipa = release / f'AlbumWinnow-v{version}-unsigned.ipa'
    subprocess.run(['ditto','-c','-k','--keepParent',str(payload),str(ipa)],check=True)
    shutil.rmtree(staging)
    checksums = {}
    for file in [mac_zip, ipa]:
        checksums[file.name] = hashlib.sha256(file.read_bytes()).hexdigest()
    (release / 'SHA256SUMS').write_text(''.join(f'{value}  {name}\n' for name,value in checksums.items()))
    manifest = {}
    for file in sorted((release / 'AlbumWinnow.app').rglob('*')):
        if file.is_file(): manifest[str(file.relative_to(release))] = hashlib.sha256(file.read_bytes()).hexdigest()
    (release / 'APP-SHA256.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (release / 'BUILD-INFO.txt').write_text(f'AlbumWinnow v{version}\nSource commit: {commit}\nSource tree: {tree}\nmacOS: universal {architectures}; minimum macOS 26.0; ad hoc signature, not notarized\niOS/iPadOS: arm64; minimum 26.0; unsigned IPA, signing required\n'+subprocess.check_output(['xcodebuild','-version'],text=True))
    print(json.dumps({'version':version,'commit':commit,'artifacts':checksums},indent=2))

if __name__ == "__main__":
    main()
