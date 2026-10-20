import base64
import contextlib
import importlib.util
import io
import json
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[1] / 'scripts/prepare-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
stage_spec = importlib.util.spec_from_file_location('stage_release', Path(__file__).resolve().parents[1] / 'scripts/stage-release.py')
stage = importlib.util.module_from_spec(stage_spec)
stage_spec.loader.exec_module(stage)


class ReleaseChecks(unittest.TestCase):
    def test_platform_versions_cannot_diverge(self):
        self.assertEqual(release.release_version({'version': '0.4.0'}, {'version': '0.4.0'}), '0.4.0')
        for mac, win in [('0.4.0', '0.3.2'), ('0.4.0-beta.1', '0.4.0-beta.1'), ('01.4.0', '01.4.0')]:
            with self.assertRaises(ValueError):
                release.release_version({'version': mac}, {'version': win})

    def test_version_divergence_requires_explicit_mac_only(self):
        with self.assertRaisesRegex(ValueError, 'Both platforms'):
            release.release_version({'version': '0.5.2'}, {'version': '0.4.1'})
        self.assertEqual(release.release_version({'version': '0.5.2'}, {'version': '0.4.1'}, mac_only=True), '0.5.2')
        self.assertEqual(release.release_version({'version': '0.5.2'}, mac_only=True), '0.5.2')
        with self.assertRaises(ValueError):
            release.release_version({'version': '0.5.2-beta.1'}, mac_only=True)

    def test_windows_parameter_is_required_by_default_and_sources_always_required(self):
        arguments = ['--mac-app', '/tmp/app', '--sparkle-tools', '/tmp/tools',
                     '--notes', '/tmp/notes', '--third-party-source', '/tmp/ffmpeg.tar.xz']
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
            release.parse_arguments(arguments)
        self.assertEqual(failure.exception.code, 2)
        self.assertTrue(release.parse_arguments([*arguments, '--mac-only']).mac_only)
        self.assertFalse(release.parse_arguments([*arguments, '--windows-dir', '/tmp/win']).mac_only)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            release.parse_arguments(arguments[:-2] + ['--mac-only'])

    def test_extra_assets_reject_symlinks_unsafe_names_and_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            asset = root / 'accepted.dmg'
            asset.write_bytes(b'accepted installer')
            release.validate_extra_assets([asset], {'appcast.xml'})
            for sources, reserved in [([asset, asset], set()), ([asset], {'accepted.dmg'})]:
                with self.assertRaisesRegex(ValueError, 'Duplicate'):
                    release.validate_extra_assets(sources, reserved)
            alias = root / 'alias.dmg'
            alias.symlink_to(asset)
            for invalid in (alias, root, root / 'missing.zip'):
                with self.assertRaisesRegex(ValueError, 'regular release asset'):
                    release.validate_extra_assets([invalid], set())
            unsafe = root / 'bad\nname.zip'
            unsafe.write_bytes(b'unsafe')
            with self.assertRaises(ValueError):
                release.validate_extra_assets([unsafe], set())
            for name in ('../escape.zip', '/absolute.zip', r'nested\escape.zip', '.hidden', 'bad\rname'):
                self.assertFalse(release.safe_asset_name(name))
                self.assertFalse(stage.safe_asset_name(name))

    def test_nonempty_output_never_overwrites_a_signed_asset(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / 'release'
            release.prepare_destination(destination)
            signed = destination / 'appcast.xml'
            signed.write_bytes(b'signed bytes')
            with self.assertRaisesRegex(ValueError, 'must be empty'):
                release.prepare_destination(destination)
            self.assertEqual(signed.read_bytes(), b'signed bytes')
            alias = root / 'alias'
            alias.symlink_to(destination, target_is_directory=True)
            with self.assertRaises(ValueError):
                release.prepare_destination(alias)

    def manifest(self, **changes):
        manifest = {'repository': stage.REPOSITORY, 'version': '0.5.2', 'tag': 'v0.5.2',
                    'sourceCommit': 'a' * 40, 'assets': ['RELEASE_NOTES.md', 'SHA256SUMS.txt']}
        manifest.update(changes)
        return manifest

    def test_stage_platform_whitelist_and_tag_must_match_version(self):
        self.assertEqual(stage.validate_manifest(self.manifest()), ['macos', 'windows'])
        valid_mac = self.manifest(platforms=['macos'], prerelease=True, makeLatest=False)
        self.assertEqual(stage.validate_manifest(valid_mac), ['macos'])
        for invalid in ([], ['linux'], ['macos', 'linux'], ['macos', 'macos'], 'macos', None, [{}]):
            with self.subTest(platforms=invalid), self.assertRaises(ValueError):
                stage.validate_manifest(self.manifest(platforms=invalid))
        for invalid in ('v0.5.1', '0.5.2', 'v0.5.2/escape', '../v0.5.2'):
            with self.subTest(tag=invalid), self.assertRaises(ValueError):
                stage.validate_manifest(self.manifest(tag=invalid))
        for changes in ({'prerelease': False, 'makeLatest': False}, {'prerelease': True, 'makeLatest': True}, {}):
            with self.subTest(policy=changes), self.assertRaisesRegex(ValueError, 'must be prereleases'):
                stage.validate_manifest(self.manifest(platforms=['macos'], **changes))
        for names in (['../escape.zip'], ['.hidden'], ['same', 'same'], [{}], 'file.zip'):
            with self.subTest(assets=names), self.assertRaises(ValueError):
                stage.validate_manifest(self.manifest(assets=names))

    def test_stage_checks_only_declared_source_versions_and_preserves_legacy_checks(self):
        manifest = self.manifest(platforms=['macos'], prerelease=True, makeLatest=False)
        def version_at_commit(command, **_):
            version = '0.5.2' if command[-1].endswith('MacDownloader/Release.json') else '0.4.1'
            return json.dumps({'version': version})
        with mock.patch.object(stage.subprocess, 'check_output', side_effect=version_at_commit) as checked:
            stage.validate_source_versions(manifest, stage.validate_manifest(manifest))
            self.assertEqual(checked.call_count, 1)
            self.assertTrue(checked.call_args.args[0][-1].endswith('MacDownloader/Release.json'))
        legacy = self.manifest()
        with mock.patch.object(stage.subprocess, 'check_output', side_effect=version_at_commit) as checked:
            with self.assertRaisesRegex(ValueError, 'windows'):
                stage.validate_source_versions(legacy, stage.validate_manifest(legacy))
            self.assertEqual(checked.call_count, 2)

    def test_mac_only_prepare_and_draft_stage_keep_windows_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'MacDownloader').mkdir()
            (root / 'MacDownloader/Release.json').write_text(json.dumps({'version': '0.5.2', 'build': '14'}))
            (root / 'updates/macos').mkdir(parents=True)
            public_key = 'test-public-key'
            (root / 'updates/macos/public-key.txt').write_text(public_key)
            app = root / 'accepted.app'
            (app / 'Contents').mkdir(parents=True)
            info = {'CFBundleIdentifier': 'io.feather.videodownloader', 'CFBundleShortVersionString': '0.5.2',
                    'CFBundleVersion': '14', 'SUPublicEDKey': public_key,
                    'SUVerifyUpdateBeforeExtraction': True, 'SURequireSignedFeed': True}
            with (app / 'Contents/Info.plist').open('wb') as stream:
                plistlib.dump(info, stream)
            notes = root / 'notes.md'
            notes.write_text('Mac-only update; Windows remains 0.4.1.')
            upstream = root / 'ffmpeg.tar.xz'
            upstream.write_bytes(b'corresponding source fixture')
            extra = [root / 'accepted.dmg', root / 'matching-Source.zip']
            for asset in extra:
                asset.write_bytes(b'accepted extra fixture')
            output = root / 'prepared'
            signature = base64.b64encode(bytes(64)).decode()
            def local_output(command, **_):
                if command[:2] == ['git', 'status']:
                    return ''
                if command[:2] == ['git', 'rev-parse']:
                    return 'a' * 40
                if command[0] == 'node':
                    return public_key
                if '-p' in command:
                    return signature
                self.fail('Unexpected helper: ' + repr(command))
            def local_run(command, **_):
                if command[0] == 'ditto':
                    Path(command[-1]).write_bytes(b'mac update archive fixture')
                self.assertNotEqual(command[0], 'gh')
            arguments = ['--mac-only', '--mac-app', str(app), '--sparkle-tools', str(root / 'sign-tools'),
                         '--key-file', str(root / 'dummy-seed'), '--notes', str(notes), '--output', str(output),
                         '--third-party-source', str(upstream)]
            for asset in extra:
                arguments += ['--extra-asset', str(asset)]
            with mock.patch.object(release, 'ROOT', root), mock.patch.object(release.subprocess, 'check_output', side_effect=local_output), \
                    mock.patch.object(release.subprocess, 'run', side_effect=local_run) as helpers, contextlib.redirect_stdout(io.StringIO()):
                release.main(arguments)
            manifest = json.loads((output / 'release-assets.json').read_text())
            self.assertIn('测试版本', ET.fromstring((output / 'appcast.xml').read_bytes()).find('channel/description').text)
            self.assertEqual(manifest['platforms'], ['macos'])
            self.assertTrue(manifest['prerelease'])
            self.assertFalse(manifest['makeLatest'])
            self.assertEqual(manifest['sourceCommit'], 'a' * 40)
            self.assertFalse((root / 'WindowsDownloader').exists())
            self.assertFalse(any('Windows' in asset or asset == 'latest.yml' for asset in manifest['assets']))
            for asset in extra:
                self.assertEqual((output / asset.name).read_bytes(), asset.read_bytes())
            verification_calls = [call.args[0] for call in helpers.call_args_list if '--verify' in call.args[0]]
            self.assertEqual(len(verification_calls), 3)  # App signature, complete signed feed, update archive.
            with mock.patch.object(stage, 'ROOT', root), mock.patch.object(stage.subprocess, 'check_output', return_value='{"version":"0.5.2"}') as checked, \
                    mock.patch.object(stage.subprocess, 'run') as staged, contextlib.redirect_stdout(io.StringIO()):
                stage.main([str(output)])
            self.assertEqual(checked.call_count, 1)
            command = staged.call_args.args[0]
            self.assertEqual(command[:3], ['gh', 'release', 'create'])
            for flag in ('--draft', '--prerelease', '--latest=false'):
                self.assertIn(flag, command)
            (output / extra[0].name).write_bytes(b'tampered extra')
            with mock.patch.object(stage.subprocess, 'run') as rejected:
                with self.assertRaisesRegex(ValueError, 'missing or changed'):
                    stage.main([str(output)])
                rejected.assert_not_called()

    def test_corrupted_or_wrong_windows_payload_cannot_be_staged(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'FeiyuDownload-0.4.0-Windows-x64-Setup.exe'
            file.write_bytes(b'MZtest installer')
            checksum = base64.b64encode(release.digest(file, 'sha512')).decode()
            entry = {'url': file.name, 'sha512': checksum, 'size': file.stat().st_size}
            metadata = {'version': '0.4.0', 'files': [entry]}
            self.assertEqual(release.validate_windows_metadata(metadata, directory, '0.4.0'), file)
            file.write_bytes(b'MZtampered payload')
            with self.assertRaisesRegex(ValueError, 'SHA512'):
                release.validate_windows_metadata(metadata, directory, '0.4.0')
            entry['url'] = '../outside.exe'
            with self.assertRaisesRegex(ValueError, 'exactly'):
                release.validate_windows_metadata(metadata, directory, '0.4.0')

    def test_generated_feed_is_platform_specific_and_escapes_release_notes(self):
        signature = base64.b64encode(bytes(64)).decode()
        tree = ET.fromstring(release.appcast('0.4.0', '9', 'FeiyuDownload-0.4.0-macOS-arm64.zip', 123, signature, 'Fix <video> & download'))
        item = tree.find('channel/item')
        self.assertEqual(item.find('description').text, 'Fix <video> & download')
        self.assertEqual(item.find('{%s}version' % release.SPARKLE).text, '9')
        enclosure = item.find('enclosure')
        self.assertIn('/releases/download/v0.4.0/', enclosure.get('url'))
        self.assertEqual(enclosure.get('{%s}edSignature' % release.SPARKLE), signature)
        self.assertEqual(enclosure.get('{%s}os' % release.SPARKLE), 'macos')
        with self.assertRaises(ValueError):
            release.appcast('0.4.0', '9', 'app.zip', 123, 'unsigned', '')


if __name__ == '__main__':
    unittest.main()
