#!/usr/bin/env python3
"""Build the required FFmpeg tools from official source, with LGPL-only options."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
VERSION = "9.0.2"
WORK = ROOT / "work" / "ffmpeg-build"
SOURCE = WORK / ("ffmpeg-" + VERSION)
ARCHIVE = WORK / ("ffmpeg-" + VERSION + ".tar.xz")
VENDOR = ROOT / "work" / "vendor"
CONFIGURE = [
    "--arch=arm64", "--cc=/usr/bin/clang", "--extra-cflags=-mmacosx-version-min=13.0", "--extra-ldflags=-mmacosx-version-min=13.0",
    "--disable-shared", "--enable-static", "--disable-autodetect", "--disable-doc", "--disable-debug", "--disable-ffplay",
    "--disable-gpl", "--disable-nonfree", "--disable-version3", "--disable-everything", "--enable-ffmpeg", "--enable-ffprobe",
    "--enable-network", "--enable-securetransport", "--enable-videotoolbox", "--enable-protocol=file,http,https,tcp,tls,crypto,pipe,data",
    "--enable-demuxer=mov,matroska,webm_dash_manifest,mp3,aac,flac,ogg,wav,mpegts,hls,concat,srt,rawvideo,image2,image2pipe",
    "--enable-muxer=mp4,mov,matroska,mp3,adts,ipod,null,flac,ogg,wav,rawvideo,image2,image2pipe",
    "--enable-parser=aac,h264,hevc,av1,vp8,vp9,opus,vorbis,flac,mpegaudio",
    "--enable-decoder=aac,h264,hevc,av1,vp8,vp9,opus,vorbis,mp3,flac,pcm_s16le,alac,subrip,movtext,rawvideo,png,mjpeg,mpeg4",
    "--enable-encoder=aac,pcm_s16le,flac,wrapped_avframe,movtext,rawvideo,png,h264_videotoolbox",
    "--enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,av1_metadata,vp9_superframe",
    "--enable-filter=aresample,anull,null,format,scale,trim,atrim,asetpts,setpts,fps"
]

def run(*arguments, **kwargs):
    subprocess.run([str(a) for a in arguments], check=True, **kwargs)

def main():
    WORK.mkdir(parents=True, exist_ok=True)
    url = "https://ffmpeg.org/releases/" + ARCHIVE.name
    if not ARCHIVE.exists():
        run("curl", "--fail", "--location", "--retry", "3", "--connect-timeout", "20", "--max-time", "300", url, "-o", ARCHIVE)
    if not SOURCE.exists():
        run("tar", "-xf", ARCHIVE, "-C", WORK)
    configuration_record = WORK / "configuration.json"
    recorded_configuration = json.loads(configuration_record.read_text()) if configuration_record.exists() else None
    if not (SOURCE / "config.h").exists() or recorded_configuration != CONFIGURE:
        with (WORK / "configure.log").open("w") as log:
            run(SOURCE / "configure", *CONFIGURE, cwd=SOURCE, stdout=log, stderr=subprocess.STDOUT)
        configuration_record.write_text(json.dumps(CONFIGURE, indent=2) + "\n")
    with (WORK / "make.log").open("w") as log:
        run("make", "-j", min(os.cpu_count() or 4, 8), "ffmpeg", "ffprobe", cwd=SOURCE, stdout=log, stderr=subprocess.STDOUT)
    for name in ["ffmpeg", "ffprobe"]:
        shutil.copy2(SOURCE / name, VENDOR / name)
        run("strip", "-x", VENDOR / name)
        (VENDOR / name).chmod(0o755)
    licenses = VENDOR / "licenses"
    for name in ["LICENSE.md", "COPYING.LGPLv2.1", "COPYING.LGPLv3"]:
        if (SOURCE / name).exists():
            shutil.copy2(SOURCE / name, licenses / ("ffmpeg-" + name))
    (licenses / "ffmpeg-BUILD.txt").write_text("Official source: " + url + "\nSource SHA-256: " + hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() + "\nUnmodified FFmpeg source. Local configuration (one argument per line):\n" + "\n".join(CONFIGURE) + "\nBuilt with Apple Command Line Tools. No external codec libraries.\n")
    (licenses / "ffmpeg-LICENSE.txt").write_text((SOURCE / "COPYING.LGPLv2.1").read_text())
    manifest_path = VENDOR / "tools-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["versions"].pop("ffmpeg-static", None)
    manifest["versions"]["ffmpeg"] = VERSION + " (locally built LGPL-only)"
    manifest["sources"] = [u for u in manifest["sources"] if "eugeneware" not in u]
    if url not in manifest["sources"]:
        manifest["sources"].append(url)
    manifest["ffmpegConfiguration"] = CONFIGURE
    manifest["ffmpegSourceSHA256"] = hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()
    manifest["files"] = [e for e in manifest["files"] if e["name"] not in ["ffmpeg", "ffprobe"]]
    for name in ["ffmpeg", "ffprobe"]:
        binary = VENDOR / name
        manifest["files"].append({"name": name, "bytes": binary.stat().st_size, "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()})
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print("LGPL-only FFmpeg ready", flush=True)

if __name__ == "__main__":
    main()
