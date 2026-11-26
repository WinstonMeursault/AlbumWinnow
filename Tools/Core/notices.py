#!/usr/bin/env python3
"""Regenerate notices from locked supported-target Cargo trees and package license files."""
import argparse
import hashlib
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SUPPLEMENTAL = ROOT / 'Tools/Core/licenses'


def cargo(*arguments):
    environment = os.environ.copy()
    environment['PATH'] = str(Path.home() / '.cargo/bin') + os.pathsep + environment['PATH']
    environment['CARGO_NET_OFFLINE'] = 'true'
    return subprocess.check_output(['cargo', *arguments], cwd=ROOT, env=environment, text=True)


def license_texts(package):
    directory = Path(package['manifest_path']).parent
    expression = package['license']
    if expression == 'MPL-2.0':
        return [('MPL-2.0', (SUPPLEMENTAL / 'MPL-2.0.txt').read_text())]
    if package['name'] == 'siphasher' and expression == 'MIT/Apache-2.0':
        mit = (SUPPLEMENTAL / 'MIT.txt').read_text().replace('Copyright (c) <year> <copyright holders>\n\n', '')
        return [('MIT', (directory / 'COPYING').read_text() + '\n' + mit)]
    if expression in {'CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception', 'CC0-1.0 OR MIT-0 OR Apache-2.0'}:
        choices = [('CC0-1.0', ['LICENSE_CC0', 'LICENSE-CC0'])]
    elif expression in {'MIT', 'MIT OR Apache-2.0', 'Apache-2.0 OR MIT', 'MIT/Apache-2.0', 'Unlicense OR MIT',
                        'Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT',
                        '(MIT OR Apache-2.0) AND Unicode-3.0'}:
        choices = [('MIT', ['LICENSE-MIT', 'LICENSE', 'LICENSE.md'])]
        if 'AND Unicode-3.0' in expression:
            choices.append(('Unicode-3.0', ['LICENSE-UNICODE']))
    elif expression in ('BSD-2-Clause', 'Zlib'):
        choices = [(expression, ['LICENSE'])]
    else:
        raise ValueError(f"Review new license expression: {package['name']} {expression}")
    result = []
    for identifier, names in choices:
        path = next((directory / name for name in names if (directory / name).is_file()), None)
        if path is None:
            raise ValueError(f"Missing {identifier} license text: {package['name']}")
        result.append((identifier, path.read_text()))
    return result


def standard_library_notices():
    environment = os.environ.copy()
    environment['PATH'] = str(Path.home() / '.cargo/bin') + os.pathsep + environment['PATH']
    sysroot = Path(subprocess.check_output(['rustc', '--print', 'sysroot'], cwd=ROOT, env=environment, text=True).strip())
    directory = sysroot / 'share/doc/rust'
    source = (directory / 'COPYRIGHT-library.html').read_text()

    class RuntimeNotices(HTMLParser):
        def __init__(self):
            super().__init__()
            self.parts = []
            self.pre = None
            self.bodies = {}

        def handle_starttag(self, tag, attributes):
            if tag == 'pre':
                self.pre = []
            elif tag in {'p', 'div', 'li', 'h1', 'h2', 'h3'}:
                self.parts.append('\n')

        def handle_endtag(self, tag):
            if tag == 'pre':
                body = ''.join(self.pre).strip()
                self.pre = None
                self.bodies.setdefault(body, len(self.bodies) + 1)
                self.parts.append(f'\nRust runtime license text {self.bodies[body]}\n')
            elif tag in {'p', 'div', 'li', 'h1', 'h2', 'h3'}:
                self.parts.append('\n')

        def handle_data(self, data):
            (self.pre if self.pre is not None else self.parts).append(data)

    parser = RuntimeNotices()
    parser.feed(source)
    if not parser.bodies or parser.pre is not None:
        raise ValueError('Unrecognized Rust standard-library notice layout')
    context = '\n'.join(line.strip() for line in ''.join(parser.parts).splitlines() if line.strip())
    sections = ['Rust 1.100.0 standard-library distribution notices (all platforms)\n'
                'Source: rust-docs COPYRIGHT-library.html; identical license bodies are referenced once.\n'
                'https://github.com/rust-lang/rust/tree/1.100.0\n\n' + context]
    for body, index in parser.bodies.items():
        sections.append(f'Rust runtime license text {index}\n\n{body}')
    # These cover the top-level and in-tree exceptions named by COPYRIGHT-library.
    for name in ['MIT', 'Apache-2.0', 'Unicode-3.0', 'BSD-2-Clause']:
        sections.append(f'Rust in-tree license: {name}\n\n' + (directory / 'licenses' / (name + '.txt')).read_text().strip())
    return '\n\n'.join(sections)


def generate():
    metadata = json.loads(cargo('metadata', '--locked', '--format-version', '1'))
    packages = {(p['name'], p['version']): p for p in metadata['packages']}
    target_list = re.search(r'^targets\s*=\s*(\[[^\]]*\])', (ROOT / 'rust-toolchain.toml').read_text(), re.MULTILINE)
    targets = json.loads(target_list.group(1))
    selected = set()
    for target in targets:
        tree = cargo('tree', '-p', 'albumwinnow-ffi', '--locked', '--target', target,
                     '--edges', 'normal', '--prefix', 'none', '--format', '{p}')
        for line in tree.splitlines():
            match = re.match(r'([\w-]+) v([^ (]+)', line)
            if match and packages[match.groups()]['source']:
                selected.add(match.groups())
    # The generated Swift/Kotlin runtime includes code from these MPL templates.
    selected.add(('uniffi_bindgen', '0.29.4'))
    lock_hash = hashlib.sha256((ROOT / 'Cargo.lock').read_bytes()).hexdigest()
    sections = [f'''AlbumWinnow Third-Party Notices

Generated by Tools/Core/notices.py from the locked normal dependency trees for
supported Apple/Android targets, plus UniFFI binding-generator templates.
Some listed components run during compilation. License texts and attributions
below identify the license alternative included with this distribution.
Cargo.lock SHA-256: {lock_hash}

UniFFI source and generator templates (MPL-2.0):
https://github.com/mozilla/uniffi-rs/tree/00cd7e313cf73c78637161831ff17f8f53f7b824
Generated bindings are included in the AlbumWinnow source for this version.
''']
    license_bodies = {}
    for key in sorted(selected):
        package = packages[key]
        texts = license_texts(package)
        section = [f"{package['name']} {package['version']} — {package['license']}",
                   f"https://crates.io/crates/{package['name']}/{package['version']}"]
        for identifier, text in texts:
            text = text.rstrip()
            if text not in license_bodies:
                license_bodies[text] = (len(license_bodies) + 1, identifier)
            section.append(f'Included license: {identifier} (text {license_bodies[text][0]})')
        sections.append('\n'.join(section))
    for text, (index, identifier) in license_bodies.items():
        sections.append(f'License text {index}: {identifier}\n\n{text}')
    sqlite = next(p for p in packages.values() if p['name'] == 'libsqlite3-sys')
    header = (Path(sqlite['manifest_path']).parent / 'sqlite3/sqlite3.h').read_text()
    version = re.search(r'#define SQLITE_VERSION\s+"([^"]+)"', header).group(1)
    blessing = re.search(r'The author disclaims.*?May you share freely, never taking more than you give\.', header, re.DOTALL).group()
    sections.append(f'SQLite {version} — public domain\nhttps://sqlite.org/copyright.html\n\n{blessing}\n')
    sections.append(standard_library_notices())
    combined = ('\n\n' + '-' * 64 + '\n\n').join(sections)
    return '\n'.join(line.rstrip() for line in combined.splitlines()).rstrip() + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    generated = generate()
    output = ROOT / 'THIRD-PARTY-NOTICES.txt'
    if args.check:
        if output.read_text() != generated:
            raise SystemExit('Third-party notices differ; run python3 Tools/Core/notices.py')
    else:
        output.write_text(generated)
    print(f'Notices {"checked" if args.check else "generated"}: {len(generated.encode())} bytes')


if __name__ == '__main__':
    main()
