import contextlib
import importlib.util
import io
import hashlib
import os
import shlex
import subprocess
import tempfile
from unittest import mock
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'Tools/Release' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

class ReleaseArgumentsTests(unittest.TestCase):
    def test_publish_rejects_invalid_or_shell_interpretable_inputs_without_uploading(self):
        publish = module('publish_ipaes')
        base = ['2.0.0', '--host', 'test-host', '--upload-directory', '/opt/ipaes/ipa', '--repository-url', 'https://example.test/']
        self.assertEqual(publish.arguments(base).version, '2.0.0')
        for index, bad in [(0, '1.7.0'), (0, '2.0.0-rc.1'), (0, '../../bad'), (2, '-x'), (2, 'host;echo'), (4, '/tmp/../ipa'), (4, '/tmp/$(id)'), (6, 'http://example.test/'), (6, 'https://user:secret@example.test/')]:
            args = base.copy(); args[index] = bad
            with self.subTest(bad=bad), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                publish.arguments(args)
    def test_package_rejects_non_release_versions(self):
        package = module('package')
        for version in ['2.0.0', '2.0.1']:
            self.assertEqual(package.arguments([version, 'mac', 'ios']).version, version)
        for version in ['1.7.0', '2.0.0-rc.1', '../bad']:
            with self.subTest(version=version), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                package.arguments([version, 'mac', 'ios'])

    def test_actual_remote_payload_compiles_with_unicode_quotes_and_newlines(self):
        publish = module('publish_ipaes')
        class Captured(Exception): pass
        def capture(arguments, **kwargs):
            if arguments[0] == 'ssh':
                remote = shlex.split(arguments[2])
                self.assertEqual(remote[:7], ['docker', 'exec', '-w', '/app', 'ipaes', 'python3', '-c'])
                compile(remote[7], '<IPAes publication payload>', 'exec')
                raise Captured()
            self.assertEqual(arguments[0], 'scp')
            return subprocess.CompletedProcess(arguments, 0)
        original = Path.cwd()
        (ROOT / '.local').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / '.local') as temporary:
            try:
                os.chdir(temporary)
                release = Path('.local/App/v2.0.0'); release.mkdir(parents=True)
                ipa = release / 'AlbumWinnow-v2.0.0-unsigned.ipa'; ipa.write_bytes(b'test IPA')
                (release / 'SHA256SUMS').write_text(hashlib.sha256(ipa.read_bytes()).hexdigest() + '  ' + ipa.name + '\n')
                notes = Path('.local/docs'); notes.mkdir(parents=True)
                (notes / 'v2.0.0-release-notes.md').write_text("# Release\n\n中文 'quotes' \"double\"\nLiteral $(command) and `text`.")
                args = ['publish', '2.0.0', '--host', 'test-host', '--upload-directory', '/opt/ipaes/ipa', '--repository-url', 'https://example.test/']
                with mock.patch('sys.argv', args), mock.patch('subprocess.run', side_effect=capture), self.assertRaises(Captured):
                    publish.main()
            finally:
                os.chdir(original)
