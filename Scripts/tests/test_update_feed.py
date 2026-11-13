"""Offline checks for the public feed's trust and rollback boundaries."""
import base64
import hashlib
import importlib.util
import io
import pathlib
import plistlib
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))
from verify_update_signature import openssl

spec = importlib.util.spec_from_file_location('feed', pathlib.Path(__file__).parents[1] / 'publish_update_feed.py')
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


class UpdateFeedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        private = self.root / 'test-only-key.pem'
        subprocess.run([openssl(), 'genpkey', '-algorithm', 'ED25519', '-out', str(private)], check=True)
        public = subprocess.check_output([openssl(), 'pkey', '-in', str(private), '-pubout', '-outform', 'DER'])[-32:]
        key = base64.b64encode(public).decode()
        (self.root / 'project.yml').write_text(f'MEMOZIA_UPDATE_PUBLIC_KEY: "{key}"')
        out = io.BytesIO()
        info = dict(CFBundleIdentifier='app.memozia', CFBundleVersion='155',
                    CFBundleShortVersionString='9.7.0', SUPublicEDKey=key, SUFeedURL=feed.FEED_URL)
        with zipfile.ZipFile(out, 'w') as z:
            z.writestr('Memozia.app/Contents/Info.plist', plistlib.dumps(info))
        self.archive = out.getvalue()
        self.name = 'Memozia-v9.7.0-155-arm64.zip'
        self.url = f'https://github.com/{feed.REPO}/releases/download/v9.7.0/{self.name}'
        (self.root / 'archive').write_bytes(self.archive)
        sig = base64.b64encode(subprocess.check_output([openssl(), 'pkeyutl', '-sign', '-rawin',
            '-inkey', str(private), '-in', str(self.root / 'archive')])).decode()
        self.xml = (f'<rss xmlns:sparkle="{feed.NS[1:-1]}"><channel><item>'
                    '<sparkle:version>155</sparkle:version><sparkle:shortVersionString>9.7.0</sparkle:shortVersionString>'
                    f'<enclosure url="{self.url}" length="{len(self.archive)}" sparkle:edSignature="{sig}"/>'
                    '</item></channel></rss>').encode()
        self.draft = False
        self.old = None
        self.calls = []

    def gh(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        if '/releases/tags/' in args[1]:
            return {'draft': self.draft, 'assets': [
                {'name': n, 'browser_download_url': u} for n, u in [
                    (self.name, self.url), ('appcast.xml', 'https://example.com/feed'),
                    ('SHA256SUMS', 'https://example.com/sums')]]}
        if '/branches?' in args[1]:
            return [{'name': 'updates'}] if self.old else []
        raise AssertionError('Unexpected mutation or API request')

    def fetch(self, url):
        if url == self.url:
            return self.archive
        if url.endswith('/feed'):
            return self.xml
        if url.endswith('/sums'):
            return (f'{hashlib.sha256(self.archive).hexdigest()}  {self.name}\n'
                    f'{hashlib.sha256(self.xml).hexdigest()}  appcast.xml\n').encode()
        raise AssertionError(url)

    def invoke(self):
        with patch.object(feed, 'ROOT', self.root), patch.object(feed, 'gh', self.gh), \
                patch.object(feed, 'fetch', self.fetch), patch('sys.argv', ['feed', 'v9.7.0']):
            feed.main()

    def test_verified_release_is_read_only_by_default(self):
        self.invoke()
        self.assertEqual(len(self.calls), 2)

    def test_draft_cannot_reach_stable_feed(self):
        self.draft = True
        with self.assertRaises(AssertionError):
            self.invoke()

    def test_checksum_cannot_substitute_for_signature(self):
        # Checksums match the tampered bytes, but the trusted key rejects them.
        self.archive += b'tampered'
        self.xml = self.xml.replace(f'length="{len(self.archive)-8}"'.encode(),
                                    f'length="{len(self.archive)}"'.encode())
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()

    def test_wrong_embedded_public_key_is_rejected(self):
        (self.root / 'project.yml').write_text('MEMOZIA_UPDATE_PUBLIC_KEY: "' + base64.b64encode(b'x'*32).decode() + '"')
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()

    def test_stable_build_cannot_roll_back(self):
        self.old = True
        old_xml = self.xml.replace(b'<sparkle:version>155', b'<sparkle:version>156')
        import json
        import subprocess
        result = subprocess.CompletedProcess([], 0, json.dumps({
            'content': base64.b64encode(old_xml).decode(), 'sha': 'old-sha'}).encode(), b'')
        real_run = subprocess.run
        def run(command, **kwargs):
            return result if command[0] == 'gh' else real_run(command, **kwargs)
        with patch.object(feed.subprocess, 'run', side_effect=run):
            with self.assertRaisesRegex(AssertionError, 'downgrade'):
                self.invoke()


if __name__ == '__main__':
    unittest.main()
