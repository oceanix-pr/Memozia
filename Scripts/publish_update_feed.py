#!/usr/bin/env python3
"""Verify public Release assets, then advance the independent stable feed."""
import argparse
import base64
import hashlib
import io
import json
import pathlib
import plistlib
import re
import subprocess
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

from verify_update_signature import verify

REPO = 'oceanix-pr/Memozia'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
FEED_PATH = 'stable/appcast.xml'
FEED_URL = f'https://raw.githubusercontent.com/{REPO}/updates/{FEED_PATH}'
ROOT = pathlib.Path(__file__).resolve().parent.parent


def gh(*args, payload=None):
    command = ['gh', *args]
    if payload is not None:
        command += ['--input', '-']
    return json.loads(subprocess.check_output(command, input=json.dumps(payload).encode()
                                             if payload is not None else None))


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tag')
    parser.add_argument('--verified-archive', type=pathlib.Path,
                        help='Reuse the actual downloaded draft ZIP, checking the public asset digest and range')
    parser.add_argument('--publish', action='store_true', help='Advance updates branch after verification')
    args = parser.parse_args()
    assert re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', args.tag)
    release = gh('api', f'repos/{REPO}/releases/tags/{args.tag}')
    assert not release['draft'], 'Publish Release before updating feed'
    asset_records = {a['name']: a for a in release['assets']}
    assets = {name: a['browser_download_url'] for name, a in asset_records.items()}
    feed = fetch(assets['appcast.xml'])
    checksums = dict(line.split()[::-1] for line in fetch(assets['SHA256SUMS']).decode().splitlines())
    assert hashlib.sha256(feed).hexdigest() == checksums['appcast.xml']
    item = ET.fromstring(feed).find('channel/item')
    assert item is not None and item.findtext(NS + 'shortVersionString') == args.tag[1:]
    build = int(item.findtext(NS + 'version'))
    enclosure = item.find('enclosure')
    assert enclosure is not None
    archive_name = f'Memozia-{args.tag}-{build}-arm64.zip'
    assert enclosure.get('url') == assets[archive_name]
    if args.verified_archive:
        archive = args.verified_archive.read_bytes()
        digest = hashlib.sha256(archive).hexdigest()
        assert asset_records[archive_name].get('digest') == 'sha256:' + digest
        request = urllib.request.Request(assets[archive_name], headers={'Range': 'bytes=0-1023'})
        with urllib.request.urlopen(request, timeout=120) as response:
            assert response.read(1024) == archive[:1024]
            total = (response.headers.get('Content-Range') or '').rsplit('/', 1)[-1]
            if not total:
                total = response.headers.get('Content-Length')
            assert int(total) == len(archive)
    else:
        archive = fetch(assets[archive_name])
    assert len(archive) == int(enclosure.get('length'))
    assert hashlib.sha256(archive).hexdigest() == checksums[archive_name]
    config = (ROOT / 'project.yml').read_text()
    key = re.search(r'MEMOZIA_UPDATE_PUBLIC_KEY: "([^"]+)"', config)[1]
    verify(base64.b64decode(key, validate=True),
           base64.b64decode(enclosure.get(NS + 'edSignature'), validate=True), archive)
    with zipfile.ZipFile(io.BytesIO(archive)) as z:
        assert z.testzip() is None
        info = plistlib.loads(z.read('Memozia.app/Contents/Info.plist'))
    assert info['CFBundleIdentifier'] == 'app.memozia'
    assert info['CFBundleShortVersionString'] == args.tag[1:] and int(info['CFBundleVersion']) == build
    assert info['SUPublicEDKey'] == key and info['SUFeedURL'] == FEED_URL
    branches = gh('api', f'repos/{REPO}/branches?per_page=100')
    exists = any(b['name'] == 'updates' for b in branches)
    old_sha = None
    if exists:
        # Only an explicit 404 means absent. Network/permission/parse errors fail closed.
        result = subprocess.run(['gh', 'api', f'repos/{REPO}/contents/{FEED_PATH}?ref=updates'],
                                capture_output=True)
        if result.returncode == 0:
            old = json.loads(result.stdout)
            old_feed = ET.fromstring(base64.b64decode(old['content']))
            old_build = int(old_feed.findtext('channel/item/' + NS + 'version'))
            if old_build == build and base64.b64decode(old['content']) == feed:
                print(f'Stable feed already matches {args.tag} ({build})')
                return
            assert build > old_build, 'Refusing to replace or downgrade an existing update'
            old_sha = old['sha']
        elif 'HTTP 404' not in result.stderr.decode():
            raise RuntimeError('Cannot read existing feed: ' + result.stderr.decode())
    print(f'Public ZIP, checksum, signature and bundle metadata verified: {args.tag} ({build})')
    if not args.publish:
        return
    if not exists:
        base = gh('api', f'repos/{REPO}/git/ref/heads/main')['object']['sha']
        gh('api', f'repos/{REPO}/git/refs', '--method', 'POST',
           payload={'ref': 'refs/heads/updates', 'sha': base})
    payload = {'message': f'Publish verified stable update {args.tag} ({build})',
               'content': base64.b64encode(feed).decode(), 'branch': 'updates'}
    if old_sha:
        payload['sha'] = old_sha
    gh('api', f'repos/{REPO}/contents/{FEED_PATH}', '--method', 'PUT', payload=payload)
    # Fetch uncached anonymously; a public URL must serve exactly the verified bytes.
    assert fetch(FEED_URL + '?build=' + str(build)) == feed
    print(f'Stable feed published: {FEED_URL}')


if __name__ == '__main__':
    main()
