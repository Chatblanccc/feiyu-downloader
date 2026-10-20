#!/usr/bin/env python3
"""Upload verified assets to a new draft GitHub Release; never publishes it."""
import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'Chatblanccc/feiyu-downloader'


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def safe_asset_name(name):
    return (isinstance(name, str) and bool(name) and Path(name).name == name
            and not name.startswith('.') and '\\' not in name
            and not any(ord(character) < 32 or ord(character) == 127 for character in name))


def validate_manifest(manifest):
    version = manifest.get('version')
    if (manifest.get('repository') != REPOSITORY or not isinstance(version, str)
            or not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version)
            or manifest.get('tag') != 'v' + version):
        raise ValueError('Unexpected release repository, version or tag')
    platforms = manifest.get('platforms', ['macos', 'windows'])
    if (not isinstance(platforms, list) or not platforms
            or any(not isinstance(platform, str) or platform not in {'macos', 'windows'} for platform in platforms)
            or len(platforms) != len(set(platforms))):
        raise ValueError('Invalid release platform list')
    if platforms == ['macos'] and (manifest.get('prerelease') is not True or manifest.get('makeLatest') is not False):
        raise ValueError('macOS-only releases must be prereleases and must not replace Latest')
    names = manifest.get('assets', [])
    if (not isinstance(names, list) or not names or any(not safe_asset_name(name) for name in names)
            or len(names) != len(set(names))):
        raise ValueError('Invalid release asset names')
    sha = manifest.get('sourceCommit')
    if not isinstance(sha, str) or not re.fullmatch(r'[a-f0-9]{40}', sha):
        raise ValueError('Invalid source commit')
    return platforms


def validate_source_versions(manifest, platforms):
    sources = {'macos': 'MacDownloader/Release.json', 'windows': 'WindowsDownloader/package.json'}
    for platform in platforms:
        source = sources[platform]
        record = json.loads(subprocess.check_output(['git', 'show', manifest['sourceCommit'] + ':' + source], cwd=ROOT, text=True))
        if record.get('version') != manifest['version']:
            raise ValueError('Release version does not belong to its source commit: ' + platform)


def release_command(manifest, directory, platforms):
    policy = ['--prerelease', '--latest=false'] if platforms == ['macos'] else []
    return ['gh', 'release', 'create', manifest['tag'], '--repo', REPOSITORY,
            '--target', manifest['sourceCommit'], '--draft', *policy,
            '--title', ('飞羽下载 macOS ' if platforms == ['macos'] else '飞羽下载 ') + manifest['version'],
            '--notes-file', str(directory / 'RELEASE_NOTES.md'),
            *[str(directory / name) for name in manifest['assets']]]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args(argv)
    directory = args.directory.resolve()
    manifest = json.loads((directory / 'release-assets.json').read_text())
    platforms = validate_manifest(manifest)
    names = manifest['assets']
    checksums = {}
    for line in (directory / 'SHA256SUMS.txt').read_text().splitlines():
        value, name = line.split('  ', 1)
        if not re.fullmatch(r'[a-f0-9]{64}', value) or not safe_asset_name(name) or name in checksums:
            raise ValueError('Invalid release checksum list')
        checksums[name] = value
    if set(checksums) != set(names) - {'SHA256SUMS.txt'}:
        raise ValueError('Release checksum inventory mismatch')
    for name in names:
        file = directory / name
        if not file.is_file() or file.is_symlink() or (name in checksums and file_hash(file) != checksums[name]):
            raise ValueError('Release asset missing or changed: ' + name)
    sha = manifest['sourceCommit']
    subprocess.run(['git', 'cat-file', '-e', sha + '^{commit}'], cwd=ROOT, check=True)
    validate_source_versions(manifest, platforms)
    subprocess.run(release_command(manifest, directory, platforms), cwd=ROOT, check=True)
    print('Draft release uploaded. Installed clients cannot see drafts.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
