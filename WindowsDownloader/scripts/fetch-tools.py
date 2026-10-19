#!/usr/bin/env python3
"""Download fixed upstream Windows tools, verify published SHA256, retain provenance."""
from pathlib import Path
import urllib.request,json,hashlib,zipfile,subprocess,shutil,concurrent.futures
ROOT=Path(__file__).resolve().parents[1]; DEST=ROOT/'vendor/win-x64'; CACHE=ROOT.parent/'work/windows-downloads';DEST.mkdir(parents=True,exist_ok=True);CACHE.mkdir(parents=True,exist_ok=True)

def fetch(url,target,expected=None):
    if target.exists() and (not expected or hashlib.sha256(target.read_bytes()).hexdigest()==expected):return
    part=target.with_suffix(target.suffix+'.part')
    subprocess.run(['curl','--fail','-L','--retry','4','--retry-all-errors','--connect-timeout','20','--max-time','600','-o',str(part),url],check=True,stdout=subprocess.DEVNULL)
    if expected and hashlib.sha256(part.read_bytes()).hexdigest()!=expected:raise ValueError('SHA256 mismatch: '+target.name)
    part.replace(target)
def checksum(url,name):
    p=CACHE/(name+'.sums');fetch(url,p)
    for line in p.read_text().splitlines():
        fields=line.split()
        if len(fields)>=2 and fields[-1].lstrip('*').strip()==name:return fields[0]
    match=__import__('re').search(r'Hash\s*:\s*([A-Fa-f0-9]{64})',p.read_text())
    if match:return match.group(1).lower()
    raise ValueError('Missing published checksum: '+name)
def tool(name,url,sha,extract=None):
    p=CACHE/name;fetch(url,p,sha)
    if extract:
        with zipfile.ZipFile(p) as z:
            for item in z.infolist():
                path=Path(item.filename)
                if path.is_absolute() or '..' in path.parts:raise ValueError('Unsafe archive')
                if item.is_dir():continue
                if extract=='ffmpeg' and path.suffix.lower() not in {'.dll','.exe','.txt','.md'}:continue
                if extract=='ffmpeg' and path.suffix.lower()=='.exe' and path.name not in ['ffmpeg.exe','ffprobe.exe']:continue
                if extract=='whisper' and path.suffix.lower() not in {'.dll','.exe','.txt','.md'}:continue
                if extract=='whisper' and path.suffix.lower()=='.exe' and path.name!='whisper-cli.exe':continue
                out=DEST/(('whisper/'+path.name) if extract=='whisper' else path.name)
                out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(z.read(item))
    else:shutil.copy2(p,DEST/name)
    return {'archive':name,'url':url,'sha256':sha}

yt='https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/'
deno='https://github.com/denoland/deno/releases/download/v2.9.7/'
entries=[('yt-dlp.exe',yt+'yt-dlp.exe',checksum(yt+'SHA2-256SUMS','yt-dlp.exe'),None),
('deno-x86_64-pc-windows-msvc.zip',deno+'deno-x86_64-pc-windows-msvc.zip',checksum(deno+'deno-x86_64-pc-windows-msvc.zip.sha256sum','deno-x86_64-pc-windows-msvc.zip'),'deno'),
('ffmpeg-n9.0-latest-win64-lgpl-shared-9.0.zip','https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n9.0-latest-win64-lgpl-shared-9.0.zip','11afb4cc03bd4c5ab123dfe396b31aa432bb227cfae0047a56ed632c17c59e0f','ffmpeg'),
('whisper-bin-x64.zip','https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-bin-x64.zip','6ba69e3482d7826214f90a6a9c84ca07782aec1e1d0c6a7c30c994fd5d816ccb','whisper')]
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:sources=list(pool.map(lambda x:tool(*x),entries))
manifest={'platform':'win32-x64','sources':sources,'files':[{'path':str(p.relative_to(DEST)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(DEST.rglob('*')) if p.is_file()]}
(DEST/'tools-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print('Verified Windows tools ready')
