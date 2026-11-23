#!/usr/bin/env python3
"""Atomically publish and verify a packaged IPA using the existing IPAes container."""
import argparse
import re
from urllib.parse import urlparse

def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version')
    parser.add_argument('--host', required=True)
    parser.add_argument('--upload-directory', required=True)
    parser.add_argument('--repository-url', required=True)
    args = parser.parse_args(argv)
    if not re.fullmatch(r'1\.[0-9]+\.[0-9]+', args.version):
        parser.error('Invalid release version')
    if not re.fullmatch(r'[A-Za-z0-9_.@-]+', args.host) or args.host.startswith('-'):
        parser.error('Invalid SSH host')
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', args.upload_directory) or '..' in args.upload_directory.split('/'):
        parser.error('Invalid upload directory')
    url = urlparse(args.repository_url)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
        parser.error('Repository URL must be a plain HTTPS URL')
    return args

def main():
    from pathlib import Path
    import hashlib, json, shlex, subprocess, time, urllib.request
    from textwrap import dedent
    
    args = arguments()
    version = args.version
    release = Path('.local/App') / ('v' + version)
    ipa = release / f'AlbumWinnow-v{version}-unsigned.ipa'
    notes = Path('.local/docs') / f'v{version}-release-notes.md'
    raw_notes = notes.read_text()
    sha = hashlib.sha256(ipa.read_bytes()).hexdigest()
    assert f'{sha}  {ipa.name}' in (release / 'SHA256SUMS').read_text().splitlines(), 'Local release checksum mismatch'
    filename = f'AlbumWinnow-v{version}.ipa'
    temporary = f'.{filename}.{sha[:12]}.upload'
    subprocess.run(['scp',str(ipa),args.host + ':' + shlex.quote(args.upload_directory.rstrip('/') + '/' + temporary)],check=True)
    highlights = ['未签名 IPA，需自行签名安装', 'AlbumWinnow v' + version] + [paragraph.split('。')[0] for paragraph in raw_notes.split('\n\n')[1:] if paragraph and not paragraph[0].isascii()][:4]
    metadata = dict(version=version, filename=filename, temporary=temporary, sha=sha, notes=raw_notes, highlights=highlights)
    program = '''
    from pathlib import Path
    import fcntl, hashlib, json, os, scanner, ipa_descriptions
    m = json.loads(PAYLOAD)
    src = Path('/data/ipa') / m['temporary']
    dst = Path('/data/ipa/AlbumWinnow') / m['filename']
    assert hashlib.sha256(src.read_bytes()).hexdigest() == m['sha'], 'Upload hash mismatch'
    dst.parent.mkdir(exist_ok=True)
    with scanner.SCAN_LOCK.open('a+') as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if dst.exists():
            assert hashlib.sha256(dst.read_bytes()).hexdigest() == m['sha'], 'Existing release differs'
            src.unlink()
        else:
            os.rename(src, dst)
        ipa_descriptions.set_manual(m['filename'], m['highlights'], m['notes'])
    scanner.scan()
    print('VERIFIED_SHA256=' + hashlib.sha256(dst.read_bytes()).hexdigest())
    '''.replace('PAYLOAD',repr(json.dumps(metadata,ensure_ascii=False)))
    program = dedent(program)
    command = 'docker exec -w /app ipaes python3 -c ' + shlex.quote(program)
    result = subprocess.run(['ssh',args.host,command],check=True,text=True,capture_output=True)
    (release / 'IPAES-PUBLISH.log').write_text(result.stdout+result.stderr)
    assert 'VERIFIED_SHA256='+sha in result.stdout
    
    def fetch(url):
        request = urllib.request.Request(url,headers={'User-Agent':'AlbumWinnow-release-verification/1.0','Cache-Control':'no-cache'})
        with urllib.request.urlopen(request,timeout=60) as response:
            return response.read()
    
    repo_url = args.repository_url.rstrip('/') + '/'
    for attempt in range(6):
        try:
            raw_repo = fetch(repo_url + '?verify=' + sha[:12])
            repository = json.loads(raw_repo)
            app = next(app for app in repository['apps'] if app['bundleIdentifier']=='io.github.winstonmeursault.albumwinnow')
            versions = app['versions']
            assert versions and len({item['version'] for item in versions}) == len(versions), 'Duplicate or empty versions array'
            assert all(item.get('downloadURL') for item in versions), 'Missing version download URL'
            assert versions[0]['version'] == version
            published = next(item for item in versions if item['version']==version)
            assert published['minOSVersion']=='26.0'
            assert published['size']==ipa.stat().st_size
            actual_ipa = fetch(published['downloadURL'] + '?verify=' + sha[:12])
            assert hashlib.sha256(actual_ipa).hexdigest()==sha, 'Downloaded IPA hash mismatch'
            icon = fetch(app['iconURL'])
            assert icon.startswith(b'\x89PNG\r\n\x1a\n') and len(icon)>1000 and icon[12:16] == b'IHDR', 'Icon is not a valid PNG payload'
            assert int.from_bytes(icon[16:20], 'big') > 0 and int.from_bytes(icon[20:24], 'big') > 0
            (release/'IPAES-REPO.json').write_bytes(raw_repo)
            (release/'IPAES-ICON.png').write_bytes(icon)
            verification = dict(version=version,downloadURL=published['downloadURL'],sha256=sha,
                versions=[item['version'] for item in versions],iconURL=app['iconURL'],iconSHA256=hashlib.sha256(icon).hexdigest())
            (release/'IPAES-VERIFIED.json').write_text(json.dumps(verification,indent=2,ensure_ascii=False)+'\n')
            print(json.dumps(verification,indent=2,ensure_ascii=False))
            break
        except Exception:
            if attempt == 5: raise
            time.sleep(5)

if __name__ == "__main__":
    main()
