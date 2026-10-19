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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    directory = args.directory.resolve()
    manifest = json.loads((directory / 'release-assets.json').read_text())
    if manifest.get('repository') != REPOSITORY or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', manifest.get('tag', '')):
        raise ValueError('Unexpected release repository or tag')
    names = manifest.get('assets', [])
    if not names or len(names) != len(set(names)) or any(not isinstance(name, str) or Path(name).name != name or name.startswith('.') for name in names):
        raise ValueError('Invalid release asset names')
    checksums = {}
    for line in (directory / 'SHA256SUMS.txt').read_text().splitlines():
        value, name = line.split('  ', 1)
        if not re.fullmatch(r'[a-f0-9]{64}', value) or Path(name).name != name or name in checksums:
            raise ValueError('Invalid release checksum list')
        checksums[name] = value
    if set(checksums) != set(names) - {'SHA256SUMS.txt'}:
        raise ValueError('Release checksum inventory mismatch')
    for name in names:
        file = directory / name
        if not file.is_file() or file.is_symlink() or (name in checksums and file_hash(file) != checksums[name]):
            raise ValueError('Release asset missing or changed: ' + name)
    sha = manifest['sourceCommit']
    if not re.fullmatch(r'[a-f0-9]{40}', sha):
        raise ValueError('Invalid source commit')
    subprocess.run(['git', 'cat-file', '-e', sha + '^{commit}'], cwd=ROOT, check=True)
    for source in ('MacDownloader/Release.json', 'WindowsDownloader/package.json'):
        record = json.loads(subprocess.check_output(['git', 'show', sha + ':' + source], cwd=ROOT, text=True))
        if record.get('version') != manifest['version']:
            raise ValueError('Release version does not belong to its source commit')
    subprocess.run(['gh', 'release', 'create', manifest['tag'], '--repo', REPOSITORY,
                    '--target', sha, '--draft', '--title', '飞羽下载 ' + manifest['version'],
                    '--notes-file', str(directory / 'RELEASE_NOTES.md'),
                    *[str(directory / name) for name in names]], cwd=ROOT, check=True)
    print('Draft release uploaded. Installed clients cannot see drafts.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
