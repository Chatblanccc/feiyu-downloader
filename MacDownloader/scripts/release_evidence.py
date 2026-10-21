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
    resources = app / 'Contents/Resources'
    embedded = resources / 'VideoRepair/manifest.json'
    if embedded.is_file():
        runtime_hash = sha(embedded)
    else:
        # On-demand releases identify the exact installer, pins and licenses.
        # Installed model content is separately attested by the component receipt.
        digest = hashlib.sha256()
        for path in sorted((resources / 'AIComponents').rglob('*')):
            if path.is_file() and '__pycache__' not in path.parts:
                digest.update(str(path.relative_to(resources)).encode('utf-8') + b'\0')
                digest.update(path.read_bytes())
        runtime_hash = digest.hexdigest()
    return {'version':info['CFBundleShortVersionString'], 'build':str(info['CFBundleVersion']),
            'bundleIdentifier':info['CFBundleIdentifier'], 'unsignedBinarySHA256':code_hash,
            'binarySHA256AtObservation':sha(executable),
            'runtimeManifestSHA256':runtime_hash,
            'toolsManifestSHA256':sha(app / 'Contents/Resources/tools-manifest.json'),
            'sourceManifestSHA256':sha(app / 'Contents/Resources/source-manifest.json')}

def matches_identity(recorded, actual):
    return all(recorded.get(key)==actual.get(key) for key in
               ['version','build','unsignedBinarySHA256','runtimeManifestSHA256','toolsManifestSHA256','sourceManifestSHA256'])
