#!/usr/bin/env python3
"""Prepare verified GitHub release assets. Does not upload or publish anything."""
import argparse
import base64
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'Chatblanccc/feiyu-downloader'
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def digest(path, algorithm='sha256'):
    hasher = hashlib.new(algorithm)
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(chunk)
    return hasher.digest()


def release_version(mac_release, windows_package=None, *, mac_only=False):
    version = mac_release.get('version')
    if not isinstance(version, str) or not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('Stable release version must be X.Y.Z')
    if not mac_only and (windows_package is None or windows_package.get('version') != version):
        raise ValueError('Both platforms must share the release version')
    return version


def safe_asset_name(name):
    return (isinstance(name, str) and bool(name) and Path(name).name == name
            and not name.startswith('.') and '\\' not in name
            and not any(ord(character) < 32 or ord(character) == 127 for character in name))


def validate_extra_assets(sources, reserved_names):
    names = set(reserved_names)
    for source in sources:
        if not source.is_file() or source.is_symlink() or not safe_asset_name(source.name):
            raise ValueError('Expected regular release asset with a safe file name: ' + str(source))
        if source.name in names:
            raise ValueError('Duplicate release asset name: ' + source.name)
        names.add(source.name)


def prepare_destination(destination):
    if destination.is_symlink() or (destination.exists() and (not destination.is_dir() or any(destination.iterdir()))):
        raise ValueError('Release output directory must be empty; use a new folder without signed assets')
    destination.mkdir(parents=True, exist_ok=True)


def validate_windows_metadata(metadata, directory, version):
    expected = f'FeiyuDownload-{version}-Windows-x64-Setup.exe'
    if metadata.get('version') != version:
        raise ValueError('Windows update metadata version mismatch')
    files = metadata.get('files')
    if not isinstance(files, list) or len(files) != 1 or files[0].get('url') != expected:
        raise ValueError('Windows update metadata must name exactly the full installer')
    file = Path(directory) / expected
    if not file.is_file() or file.is_symlink():
        raise ValueError('Missing regular Windows installer')
    with file.open('rb') as stream:
        if stream.read(2) != b'MZ':
            raise ValueError('Windows installer is not a PE executable')
    expected_hash = base64.b64encode(digest(file, 'sha512')).decode()
    if files[0].get('sha512') != expected_hash or files[0].get('size') != file.stat().st_size:
        raise ValueError('Windows installer SHA512 or byte size mismatch')
    if metadata.get('path', expected) != expected or metadata.get('sha512', expected_hash) != expected_hash:
        raise ValueError('Legacy Windows metadata disagrees with files entry')
    return file


def appcast(version, build, filename, length, signature, notes, minimum_os='13.0'):
    if not re.fullmatch(r'[A-Za-z0-9+/]{86}==', signature):
        raise ValueError('Expected Ed25519 archive signature')
    tree = ET.Element('rss', version='2.0')
    channel = ET.SubElement(tree, 'channel')
    ET.SubElement(channel, 'title').text = '飞羽下载 macOS 更新'
    ET.SubElement(channel, 'link').text = f'https://github.com/{REPOSITORY}/releases'
    ET.SubElement(channel, 'description').text = '用户主动检查的稳定版本更新'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'飞羽下载 {version}'
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = str(build)
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = minimum_os
    ET.SubElement(item, 'description').text = notes
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/{REPOSITORY}/releases/download/v{version}/{quote(filename)}',
        'length': str(length), 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}edSignature': signature,
        f'{{{SPARKLE}}}os': 'macos',
    })
    ET.indent(tree, space='  ')
    return ET.tostring(tree, encoding='utf-8', xml_declaration=True) + b'\n'


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mac-app', type=Path, required=True)
    parser.add_argument('--windows-dir', type=Path)
    parser.add_argument('--mac-only', action='store_true', help='Prepare a macOS-only prerelease without replacing Windows Latest')
    parser.add_argument('--sparkle-tools', type=Path, required=True, help='Sparkle distribution bin directory')
    parser.add_argument('--key-file', type=Path, default=Path.home() / 'Library/Application Support/FeiyuRelease/keys/macos-ed25519.seed')
    parser.add_argument('--notes', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--third-party-source', type=Path, action='append', default=[], required=True, help='Corresponding upstream source archive; repeat for each bundled FFmpeg build')
    parser.add_argument('--extra-asset', type=Path, action='append', default=[], help='Accepted DMG, matching source ZIP or evidence; repeat for each file')
    args = parser.parse_args(argv)
    if not args.mac_only and args.windows_dir is None:
        parser.error('--windows-dir is required unless --mac-only is set')
    return args


def main(argv=None):
    args = parse_arguments(argv)
    dirty = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all'], cwd=ROOT, text=True)
    if dirty.strip():
        raise ValueError('Commit all release source and metadata before preparing installers for publication')
    source_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    release = json.loads((ROOT / 'MacDownloader/Release.json').read_text())
    package = None if args.mac_only else json.loads((ROOT / 'WindowsDownloader/package.json').read_text())
    version = release_version(release, package, mac_only=args.mac_only)
    destination = args.output or ROOT / 'outputs/releases' / ('v' + version)
    reserved = {'appcast.xml', 'RELEASE_NOTES.md', 'SHA256SUMS.txt', 'release-assets.json',
                f'FeiyuDownload-{version}-macOS-arm64.zip'}
    if not args.mac_only:
        reserved.update({'latest.yml', f'FeiyuDownload-{version}-Windows-x64-Setup.exe',
                         f'FeiyuDownload-{version}-Windows-x64-Setup.exe.blockmap'})
    validate_extra_assets([*args.third_party_source, *args.extra_asset], reserved)
    for source in args.third_party_source:
        if source.suffix not in {'.xz', '.gz', '.zip'}:
            raise ValueError('Expected regular upstream source archive')
    prepare_destination(destination)
    with (args.mac_app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'io.feather.videodownloader' or info.get('CFBundleShortVersionString') != version or str(info.get('CFBundleVersion')) != str(release['build']):
        raise ValueError('Built Mac app identity/version mismatch')
    if info.get('SUPublicEDKey') != (ROOT / 'updates/macos/public-key.txt').read_text().strip():
        raise ValueError('Built Mac app trusts a different release key')
    if info.get('SUVerifyUpdateBeforeExtraction') is not True or info.get('SURequireSignedFeed') is not True:
        raise ValueError('Built Mac app does not require signed updates/feed')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.mac_app)], check=True)
    installer = yaml_file = None
    if not args.mac_only:
        yaml_file = args.windows_dir / 'latest.yml'
        js = "const fs=require('fs'),yaml=require('js-yaml');process.stdout.write(JSON.stringify(yaml.load(fs.readFileSync(process.argv[1],'utf8'))))"
        metadata = json.loads(subprocess.check_output(['node', '-e', js, str(yaml_file.resolve())], cwd=ROOT / 'WindowsDownloader', text=True))
        installer = validate_windows_metadata(metadata, args.windows_dir, version)
    mac_zip = destination / f'FeiyuDownload-{version}-macOS-arm64.zip'
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(args.mac_app), str(mac_zip)], check=True)
    # Sparkle's current file format is a base64 encoded 32-byte Ed25519 seed.
    # Derive only its public key; never print or copy the private seed.
    key_js = "const fs=require('fs'),c=require('crypto');const seed=Buffer.from(fs.readFileSync(process.argv[1],'utf8').trim(),'base64');if(seed.length!==32)throw new Error('Expected a 32-byte Sparkle seed');const key=c.createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),seed]),format:'der',type:'pkcs8'});process.stdout.write(c.createPublicKey(key).export({format:'der',type:'spki'}).subarray(-32).toString('base64'))"
    key_public = subprocess.check_output(['node', '-e', key_js, str(args.key_file)], text=True).strip()
    if key_public != info['SUPublicEDKey']:
        raise ValueError('Release private key does not match the public key embedded in the app')
    signer = (args.sparkle_tools / 'sign_update').resolve()
    signature = subprocess.check_output([str(signer), '--ed-key-file', str(args.key_file), '-p', str(mac_zip)], text=True).strip()
    feed = destination / 'appcast.xml'
    feed.write_bytes(appcast(version, release['build'], mac_zip.name, mac_zip.stat().st_size, signature, args.notes.read_text(), info.get('LSMinimumSystemVersion', '13.0')))
    subprocess.run([str(signer), '--ed-key-file', str(args.key_file), str(feed)], check=True)
    subprocess.run([str(signer), '--verify', '--ed-key-file', str(args.key_file), str(feed)], check=True)
    # Archive signature and signed feed must correspond to the same private key.
    subprocess.run([str(signer), '--verify', '--ed-key-file', str(args.key_file), str(mac_zip), signature], check=True)
    assets = [mac_zip, feed]
    for source in [*args.third_party_source, *args.extra_asset]:
        target = destination / source.name
        if target.exists():
            raise ValueError('Duplicate release asset name: ' + target.name)
        shutil.copy2(source, target)
        assets.append(target)
    if not args.mac_only:
        for source in (installer, yaml_file):
            target = destination / source.name
            shutil.copy2(source, target)
            assets.append(target)
        blockmap = installer.with_suffix(installer.suffix + '.blockmap')
        if blockmap.is_file():
            target = destination / blockmap.name
            shutil.copy2(blockmap, target)
            assets.append(target)
    notes = destination / 'RELEASE_NOTES.md'
    shutil.copy2(args.notes, notes)
    assets.append(notes)
    sums = destination / 'SHA256SUMS.txt'
    sums.write_text(''.join(f'{digest(file).hex()}  {file.name}\n' for file in assets))
    assets.append(sums)
    manifest = {'version': version, 'tag': 'v' + version, 'repository': REPOSITORY,
                'sourceCommit': source_commit,
                'platforms': ['macos'] if args.mac_only else ['macos', 'windows'],
                'prerelease': args.mac_only, 'makeLatest': not args.mac_only,
                'assets': [file.name for file in assets],
                'signing': {'macArchiveAndFeed': 'Ed25519', 'macDeveloperID': bool(info.get('FeiyuDeveloperIDSigned', False))}}
    if not args.mac_only:
        manifest['signing']['windowsAuthenticode'] = 'not established by this script; verify separately'
    (destination / 'release-assets.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(f'Ready: {destination} ({len(assets)} assets). No upload or publication performed.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
