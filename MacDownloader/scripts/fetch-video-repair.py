#!/usr/bin/env python3
"""Build an offline Apple Silicon repair runtime without a global Python install.

Downloads are pinned, resumable and checksum checked. Runtime files are described
by manifest.json before the app builder signs/re-hashes its embedded Mach-O code.
The application never downloads models at launch and never uploads input media.
"""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'MacDownloader' / 'VideoRepairWorker'
SPIKE = ROOT / 'work' / 'video-restoration-spike'
CACHE = SPIKE / 'cache'
RUNTIME = ROOT / 'work' / 'vendor' / 'video-repair'
PYTHON_URL = 'https://github.com/astral-sh/python-build-standalone/releases/download/20241016/cpython-3.11.10%2B20241016-aarch64-apple-darwin-install_only.tar.gz'
PYTHON_SHA256 = '5a69382da99c4620690643517ca1f1f53772331b347e75f536088c42a4cf6620'
LAMA_URL = 'https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt'
# Checksum published in the official IOPaint model loader, not an arbitrary mirror.
LAMA_MD5 = 'e3aa4aaa15225a33ec84f9f4bc47e500'
LAMA_SHA256 = '344c77bbcb158f17dd143070d1e789f38a66c04202311ae3a258ef66667a9ea9'
SRVGG_URL = 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth'
SRVGG_SHA256 = '8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292'
SRVGG_ARCH_SOURCE = 'https://github.com/xinntao/Real-ESRGAN/blob/master/realesrgan/archs/srvgg_arch.py'

def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)

def digest(path, algorithm='sha256'):
    d = hashlib.new(algorithm)
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            d.update(block)
    return d.hexdigest()

def download(url, path, expected=None, algorithm='sha256'):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and expected and digest(path, algorithm) == expected:
        return
    partial = path.with_suffix(path.suffix+'.partial')
    run('curl','--fail','--location','--continue-at','-','--retry','3','--output',partial,url)
    if expected and digest(partial, algorithm) != expected:
        raise SystemExit('Checksum mismatch: '+path.name)
    partial.replace(path)

def safe_python_extract(archive):
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            target = (RUNTIME/member.name).resolve()
            if target != RUNTIME and RUNTIME not in target.parents:
                raise SystemExit('Unsafe Python archive path')
            if member.issym():
                link = (target.parent/member.linkname).resolve()
                if RUNTIME not in link.parents:
                    raise SystemExit('Unsafe Python archive symlink')
        tar.extractall(RUNTIME)

def setup_downloads():
    CACHE.mkdir(parents=True, exist_ok=True)
    RUNTIME.mkdir(parents=True, exist_ok=True)
    archive = CACHE/'python-arm64.tar.gz'
    # Reuse the compatibility-spike artifacts only after checking the same pin.
    previous = RUNTIME/'cache'/'python-arm64-new.tar.gz'
    if previous.is_file() and not archive.exists() and digest(previous)==PYTHON_SHA256:
        shutil.copy2(previous,archive)
    if not (RUNTIME/'python'/'bin'/'python3').is_file():
        download(PYTHON_URL,archive,PYTHON_SHA256)
        safe_python_extract(archive)
    lama=RUNTIME/'models'/'big-lama.pt'
    download(LAMA_URL,lama,LAMA_SHA256)
    if digest(lama,'md5') != LAMA_MD5:
        raise SystemExit('LaMa official MD5 mismatch')
    ensure_srvgg()
    python=RUNTIME/'python'/'bin'/'python3'
    run(python,'-m','pip','install','--no-compile','--disable-pip-version-check','-r',SOURCE/'requirements.txt')
    run(python,'-B','-c','import torch,cv2,numpy; print(torch.__version__,cv2.__version__,numpy.__version__)')

def ensure_srvgg():
    target=RUNTIME/'models'/'realesr-general-x4v3.pth'
    target.parent.mkdir(parents=True,exist_ok=True)
    cached=SPIKE/'srvgg'/'realesr-general-x4v3.pth'
    if cached.is_file() and digest(cached)==SRVGG_SHA256 and not target.exists():
        shutil.copy2(cached,target)
    download(SRVGG_URL,target,SRVGG_SHA256)

def assemble():
    ensure_srvgg()
    for name in ['worker.py','detector.py','srvgg_arch.py','requirements.txt','README.md']:
        shutil.copy2(SOURCE/name,RUNTIME/name)
    licenses=RUNTIME/'licenses'
    licenses.mkdir(exist_ok=True)
    for name,url in [
        ('LaMa-Apache-2.0.txt','https://raw.githubusercontent.com/advimman/lama/main/LICENSE'),
        ('IOPaint-Apache-2.0.txt','https://raw.githubusercontent.com/Sanster/IOPaint/main/LICENSE'),
        ('Real-ESRGAN-BSD-3-Clause.txt','https://raw.githubusercontent.com/xinntao/Real-ESRGAN/master/LICENSE'),
    ]:
        target=licenses/name
        if not target.exists():
            download(url,target)
    # Legacy GPU executable/model archives remain in work/spike, outside the app.
    if (RUNTIME/'realesrgan').exists():
        shutil.rmtree(RUNTIME/'realesrgan')
    (licenses/'Real-ESRGAN-NCNN-MIT.txt').unlink(missing_ok=True)
    shutil.copy2(RUNTIME/'python'/'lib'/'python3.11'/'LICENSE.txt',licenses/'Python-LICENSE.txt')
    (licenses/'THIRD-PARTY-NOTICES.txt').write_text(
        'Feather video repair runtime\n\n'
        'LaMa: https://github.com/advimman/lama (Apache-2.0), TorchScript weights\n'
        'distributed by https://github.com/Sanster/models/releases/tag/add_big_lama .\n'
        'IOPaint: https://github.com/Sanster/IOPaint (Apache-2.0), inference interface reference.\n'
        'Real-ESRGAN: https://github.com/xinntao/Real-ESRGAN (BSD-3-Clause).\n'
        'Official SRVGGNetCompact architecture and general-x4v3 weights use BSD-3-Clause.\n'
        'Architecture adaptation removes only the BasicSR registry import/decorator.\n'
        'Python standalone: https://github.com/astral-sh/python-build-standalone .\n'
        'PyTorch, NumPy, OpenCV and Python dependency licenses are retained in\n'
        'python/lib/python3.11/site-packages/*-info and package license folders.\n\n'
        'Feather adaptation: automatic local pixel-grid detection, bounded streaming\n'
        'video pipeline, original-colour-constrained inpainting, NDJSON progress and\n'
        'cancellation. The model weights are unmodified. SRVGG is resident on MPS,\n'
        'with complete-tile CPU retry on MPS failure, tile256 and 34-pixel context.\n'
        'The detector and wrapper are newly authored; no DeepMosaics code or model\n'
        'is bundled. AI output is a conjectured reconstruction, not original detail.\n')
    # Keep source and licenses, but avoid shipping build caches and bytecode.
    for path in sorted(RUNTIME.rglob('__pycache__'),reverse=True):
        shutil.rmtree(path)
    for path in RUNTIME.rglob('*.pyc'):
        path.unlink()
    if (RUNTIME/'cache').exists():
        shutil.rmtree(RUNTIME/'cache')
    files=[]
    for path in sorted(RUNTIME.rglob('*')):
        if path.is_file() and not path.is_symlink() and path.name!='manifest.json':
            files.append({'path':str(path.relative_to(RUNTIME)),'sha256':digest(path),'bytes':path.stat().st_size})
    manifest={'schemaVersion':1,'offline':True,'architecture':'arm64','pythonVersion':'3.11.10',
        'engines':[
            {'name':'LaMa','version':'big-lama TorchScript','source':LAMA_URL,'license':'Apache-2.0','md5':LAMA_MD5},
            {'name':'Real-ESRGAN general x4v3','version':'0.2.5.0','source':SRVGG_URL,'sha256':SRVGG_SHA256,'architectureSource':SRVGG_ARCH_SOURCE,'license':'BSD-3-Clause'},
            {'name':'Python standalone','version':'3.11.10+20241016','source':PYTHON_URL,'license':'PSF and bundled dependencies'},
        ],'files':files}
    (RUNTIME/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    print('VIDEO_REPAIR_READY',RUNTIME,flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assemble-only',action='store_true',help='Use the already downloaded and installed runtime')
    opts=parser.parse_args()
    if not opts.assemble_only:setup_downloads()
    assemble()
