"""Identify executable code and AI assets independently of report re-signing."""
from pathlib import Path
import hashlib
import plistlib
import shutil
import subprocess
import tempfile

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def app_identity(app):
    app = Path(app)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable = app / 'Contents/MacOS/FeatherApp'
    # Embedding acceptance reports changes the app's resource seal and therefore
    # its executable signature. Strip a temporary copy to hash all actual code
    # and constant data without creating a self-referential signed report.
    with tempfile.TemporaryDirectory(prefix='feiyu-code-proof-') as temp:
        binary = Path(temp) / 'FeatherApp'
        shutil.copy2(executable, binary)
        subprocess.run(['codesign','--remove-signature',str(binary)],check=True,capture_output=True)
        code_hash = sha(binary)
    return {'version':info['CFBundleShortVersionString'], 'build':str(info['CFBundleVersion']),
            'bundleIdentifier':info['CFBundleIdentifier'], 'unsignedBinarySHA256':code_hash,
            'binarySHA256AtObservation':sha(executable),
            'runtimeManifestSHA256':sha(app / 'Contents/Resources/VideoRepair/manifest.json'),
            'toolsManifestSHA256':sha(app / 'Contents/Resources/tools-manifest.json'),
            'sourceManifestSHA256':sha(app / 'Contents/Resources/source-manifest.json')}

def matches_identity(recorded, actual):
    return all(recorded.get(key)==actual.get(key) for key in
               ['version','build','unsignedBinarySHA256','runtimeManifestSHA256','toolsManifestSHA256','sourceManifestSHA256'])
