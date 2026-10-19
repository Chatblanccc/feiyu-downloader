#!/usr/bin/env python3
"""Fetch fixed upstream artifacts, verify hashes, patch WebP and audit every ELF.

No global installation or app-time component downloads. Python 3.9+, curl required.
"""
from pathlib import Path
import argparse, hashlib, io, json, os, posixpath, stat, struct, subprocess, tarfile, zipfile

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = {
    "library.aar": ("https://repo.maven.apache.org/maven2/io/github/junkfood02/youtubedl-android/library/0.18.1/library-0.18.1.aar", "579b5fb480892b1abc2b218c2089699d52759cc8d7ba256bf876453f0365faef"),
    "ffmpeg.aar": ("https://repo.maven.apache.org/maven2/io/github/junkfood02/youtubedl-android/ffmpeg/0.18.1/ffmpeg-0.18.1.aar", "0a87ffa6cf912b0fe76c1a99b9107f543ee2f247935fae2c71f0822eb7bc5f49"),
    "webp.deb": ("https://packages.termux.dev/apt/termux-main/pool/main/libw/libwebp/libwebp_1.6.0.0.0.1%2Breally1.6.0_aarch64.deb", "8ba7fcfadd1a9957a7632c6407d6ef3e41d34dbd96a41769b245592ed4559045"),
    "yt-dlp": ("https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp", "1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6"),
}
def digest(data): return hashlib.sha256(data).hexdigest()
def fetch(name, cache):
    url, expected = ARTIFACTS[name]
    path = cache / name
    if not path.exists() or digest(path.read_bytes()) != expected:
        temporary = path.with_suffix(path.suffix + ".part")
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3", "--retry-all-errors", "--max-time", "300", "-o", str(temporary), url], check=True)
        assert digest(temporary.read_bytes()) == expected, "Checksum mismatch: " + name
        temporary.replace(path)
    print("verified", name, flush=True)
    return path.read_bytes()
def deb_libraries(data):
    assert data.startswith(b"!<arch>\n")
    offset = 8
    while offset < len(data):
        header = data[offset:offset+60]
        name = header[:16].decode().strip().rstrip("/"); size = int(header[48:58])
        content = data[offset+60:offset+60+size]; offset += 60 + size + size % 2
        if name.startswith("data.tar"):
            with tarfile.open(fileobj=io.BytesIO(content), mode="r:*") as archive:
                names = {"libsharpyuv.so", "libwebp.so", "libwebpdecoder.so", "libwebpdemux.so", "libwebpmux.so"}
                return {Path(m.name).name: archive.extractfile(m).read() for m in archive.getmembers() if m.isfile() and Path(m.name).name in names and "/lib/" in m.name}
    raise ValueError("No library payload")
def elf_report(name, data):
    if data[:4] != b"\x7fELF": return None
    assert data[4] == 2 and data[5] == 1, "Expected ARM64 ELF: " + name
    offset = struct.unpack_from("<Q", data, 32)[0]
    size, count = struct.unpack_from("<HH", data, 54)
    loads = [struct.unpack_from("<IIQQQQQQ", data, offset+i*size) for i in range(count) if struct.unpack_from("<I", data, offset+i*size)[0] == 1]
    compatible = all(p[7] >= 16384 and p[2] % 16384 == p[3] % 16384 for p in loads)
    return {"name": name, "sha256": digest(data), "loadAlignments": [p[7] for p in loads], "compatible16KB": compatible}
def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--cache", type=Path, default=ROOT.parent / "work/android-toolchain")
    args = parser.parse_args(); args.cache.mkdir(parents=True, exist_ok=True)
    native = ROOT / "app/src/main/jniLibs/arm64-v8a"; native.mkdir(parents=True, exist_ok=True)
    assets = ROOT / "app/src/main/assets/runtime"; assets.mkdir(parents=True, exist_ok=True)
    replacements = deb_libraries(fetch("webp.deb", args.cache)); assert len(replacements) == 5
    for artifact in ["library.aar", "ffmpeg.aar"]:
        with zipfile.ZipFile(io.BytesIO(fetch(artifact, args.cache))) as archive:
            for item in archive.infolist():
                if item.is_dir() or not item.filename.startswith("jni/arm64-v8a/"): continue
                data = archive.read(item)
                if item.filename.endswith("libffmpeg.zip.so"):
                    result = io.BytesIO()
                    with zipfile.ZipFile(io.BytesIO(data)) as source, zipfile.ZipFile(result,"w",zipfile.ZIP_DEFLATED) as target:
                        for entry in source.infolist():
                            target.writestr(entry, replacements.get(Path(entry.filename).name, source.read(entry)))
                    data = result.getvalue()
                (native / Path(item.filename).name).write_bytes(data)
    (assets / "yt-dlp").write_bytes(fetch("yt-dlp", args.cache))
    report = []; symlinks = {}
    for path in sorted(native.iterdir()):
        data = path.read_bytes()
        if zipfile.is_zipfile(io.BytesIO(data)):
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                component="python" if path.name=="libpython.zip.so" else "ffmpeg"
                symlinks[component]={}
                for item in archive.infolist():
                    if not item.is_dir():
                        if stat.S_ISLNK(item.external_attr >> 16):
                            link=archive.read(item).decode()
                            prefix="/data/data/com.termux/files/"
                            target=link[len(prefix):] if link.startswith(prefix) else posixpath.normpath(posixpath.join(posixpath.dirname(item.filename),link))
                            assert not target.startswith(("/","../")) and "\x00" not in target, "Unsafe runtime link"
                            symlinks[component][item.filename]=target
                        entry = elf_report(path.name + "/" + item.filename, archive.read(item))
                        if entry: report.append(entry)
        else:
            entry = elf_report(path.name, data)
            if entry: report.append(entry)
    assert report and all(x["compatible16KB"] for x in report), "Unaligned ELF payload remains"
    manifest = {"runtime": "0.18.1-feiyu.3", "ytDlpVersion": "2026.08.19", "ytDlpSha256": ARTIFACTS["yt-dlp"][1], "symlinks":symlinks,
                "files": {p.name: digest(p.read_bytes()) for p in sorted(native.iterdir())},
                "upstream": {k: {"url": v[0], "sha256": v[1]} for k,v in ARTIFACTS.items()}, "elfAudit": report}
    (assets / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (ROOT / "runtime-lock.json").write_text(json.dumps({k:v for k,v in manifest.items() if k!="elfAudit"}, indent=2) + "\n")
    print("Runtime ready; all", len(report), "ELF files pass 4 KB / 16 KB layout checks.")
if __name__ == "__main__": main()
