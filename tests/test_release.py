import base64
import importlib.util
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

spec = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[1] / 'scripts/prepare-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseChecks(unittest.TestCase):
    def test_platform_versions_cannot_diverge(self):
        self.assertEqual(release.release_version({'version': '0.4.0'}, {'version': '0.4.0'}), '0.4.0')
        for mac, win in [('0.4.0', '0.3.2'), ('0.4.0-beta.1', '0.4.0-beta.1'), ('01.4.0', '01.4.0')]:
            with self.assertRaises(ValueError):
                release.release_version({'version': mac}, {'version': win})

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
