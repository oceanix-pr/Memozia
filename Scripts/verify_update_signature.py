"""Verify Ed25519 with an independent OpenSSL implementation; no private keys."""
import os
import pathlib
import shutil
import subprocess
import tempfile


def openssl():
    candidate = os.environ.get('OPENSSL')
    if not candidate:
        candidate = '/opt/homebrew/bin/openssl' if pathlib.Path('/opt/homebrew/bin/openssl').exists() else shutil.which('openssl')
    if not candidate:
        raise RuntimeError('OpenSSL 3+ is required for independent Ed25519 verification')
    version = subprocess.check_output([candidate, 'version'], text=True)
    if not version.startswith('OpenSSL '):
        raise RuntimeError('Set OPENSSL to OpenSSL 3+ (system LibreSSL cannot verify Ed25519)')
    return candidate


def verify(public_key, signature, data):
    assert len(public_key) == 32 and len(signature) == 64
    with tempfile.TemporaryDirectory(prefix='memozia-verify-') as directory:
        root = pathlib.Path(directory)
        # RFC 8410 SubjectPublicKeyInfo for the public Ed25519 key.
        (root / 'public.der').write_bytes(bytes.fromhex('302a300506032b6570032100') + public_key)
        (root / 'signature').write_bytes(signature)
        (root / 'archive').write_bytes(data)
        subprocess.run([openssl(), 'pkeyutl', '-verify', '-rawin', '-pubin', '-keyform', 'DER',
                        '-inkey', str(root / 'public.der'), '-sigfile', str(root / 'signature'),
                        '-in', str(root / 'archive')], check=True, capture_output=True)
