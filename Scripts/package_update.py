#!/usr/bin/env python3
"""Package a built Memozia.app and sign its Sparkle update using Keychain."""
import argparse
import base64
import hashlib
import pathlib
import plistlib
import subprocess
import xml.etree.ElementTree as ET

from verify_update_signature import verify

ROOT = pathlib.Path(__file__).resolve().parent.parent
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
REPO = 'oceanix-pr/Memozia'
FEED = f'https://raw.githubusercontent.com/{REPO}/updates/stable/appcast.xml'
ACCOUNT = 'com.oceanix.Memozia.sparkle'


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--sparkle-bin', type=pathlib.Path, required=True)
    parser.add_argument('--unnotarized-test', action='store_true',
                        help='Explicitly allow the existing ad-hoc preview distribution')
    args = parser.parse_args()
    # Never mutate the original build. An existing output directory is an error.
    args.output.mkdir(parents=True, exist_ok=False)
    stage = args.output / 'stage'
    stage.mkdir()
    app = stage / 'Memozia.app'
    run('ditto', args.app, app)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    assert info['CFBundleIdentifier'] == 'app.memozia'
    assert info['SUFeedURL'] == FEED
    public_key = base64.b64decode(info['SUPublicEDKey'], validate=True)
    assert len(public_key) == 32
    assert info['SUEnableAutomaticChecks'] is True
    assert info['SUAllowsAutomaticUpdates'] is False
    assert info['SUAutomaticallyUpdate'] is False
    assert info['SUEnableSystemProfiling'] is False
    assert subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/Memozia')],
                                   text=True).strip() == 'arm64'
    unnotarized = info.get('MemoziaUnnotarizedBuild') in (True, 'YES')
    assert unnotarized == args.unnotarized_test, 'Distribution marker mismatch'
    if args.unnotarized_test:
        # Same per-app exception used by existing Memozia previews. Keep runtime
        # protection; no global security setting or user entitlement is changed.
        for framework in sorted((app / 'Contents/Frameworks').glob('*.framework')):
            run('codesign', '--force', '--deep', '--sign', '-', '--options',
                'runtime', '--timestamp=none', framework)
        run('codesign', '--force', '--sign', '-', '--options', 'runtime',
            '--timestamp=none', app / 'Contents/Helpers/memozia-mcp')
        entitlements = plistlib.loads((ROOT / 'Memozia/Resources/Memozia.entitlements').read_bytes())
        entitlements['com.apple.security.cs.disable-library-validation'] = True
        entitlements.pop('com.apple.security.get-task-allow', None)
        ent_file = args.output / 'adhoc.entitlements'
        ent_file.write_bytes(plistlib.dumps(entitlements))
        run('codesign', '--force', '--sign', '-', '--options', 'runtime',
            '--timestamp=none', '--entitlements', ent_file, app)
    else:
        run('xcrun', 'stapler', 'validate', app)
        run('spctl', '--assess', '--type', 'execute', app)
    run('codesign', '--verify', '--deep', '--strict', app)
    for binary in (app / 'Contents/Frameworks').rglob('SherpaOnnxC'):
        if binary.is_file():
            assert '@rpath/libonnxruntime.dylib' not in subprocess.check_output(
                ['otool', '-L', str(binary)], text=True)
    updates = args.output / 'updates'
    updates.mkdir()
    archive = updates / f'Memozia-v{version}-{build}-arm64.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
    notes = ROOT / f'docs/releases/{version}.md'
    archive.with_suffix('.md').write_bytes(notes.read_bytes())
    run(args.sparkle_bin / 'generate_appcast', '--account', ACCOUNT,
        '--maximum-deltas', '0', '--download-url-prefix',
        f'https://github.com/{REPO}/releases/download/v{version}/',
        '--embed-release-notes', updates)
    feed = updates / 'appcast.xml'
    item = ET.parse(feed).find('channel/item')
    assert item is not None and item.findtext(NS + 'version') == build
    assert item.findtext(NS + 'shortVersionString') == version
    enclosure = item.find('enclosure')
    assert enclosure is not None
    assert enclosure.get('url') == f'https://github.com/{REPO}/releases/download/v{version}/{archive.name}'
    assert int(enclosure.get('length')) == archive.stat().st_size
    verify(public_key, base64.b64decode(enclosure.get(NS + 'edSignature'), validate=True), archive.read_bytes())
    (updates / 'SHA256SUMS').write_text(''.join(
        f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in [archive, feed]))
    print(f'Verified update package: {updates}')


if __name__ == '__main__':
    main()
