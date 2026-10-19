#!/usr/bin/env python3
"""Build the native app and a drag-to-Applications DMG without global installs."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "MacDownloader"
VENDOR = ROOT / "work" / "vendor"
OUTPUT = ROOT / "outputs"
APP = OUTPUT / "飞羽下载.app"
RELEASE = json.loads((PROJECT / "Release.json").read_text())
VERSION = RELEASE["version"]
SUBTITLE_RELEASE = tuple(int(part) for part in VERSION.split(".")[:2]) >= (0, 2)

def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    shutil.copy2(PROJECT / "Resources" / "使用说明.txt", OUTPUT / "使用说明.txt")
    for name in ["yt-dlp", "ffmpeg", "ffprobe", "deno"]:
        if not (VENDOR / name).is_file():
            raise SystemExit("Missing verified tool: " + name + "; run scripts/fetch-tools.py first")
    manifest = json.loads((VENDOR / "tools-manifest.json").read_text())
    if "--disable-nonfree" not in manifest.get("ffmpegConfiguration", []) or "--disable-gpl" not in manifest.get("ffmpegConfiguration", []):
        raise SystemExit("Build the redistributable FFmpeg tools with scripts/build-ffmpeg.py first")
    for entry in manifest["files"]:
        if hashlib.sha256((VENDOR / entry["name"]).read_bytes()).hexdigest() != entry["sha256"]:
            raise SystemExit("Tool checksum changed: " + entry["name"])
    run("swift", "build", "-c", "release", "--arch", "arm64", cwd=PROJECT)
    bin_path = Path(subprocess.check_output(["swift", "build", "-c", "release", "--arch", "arm64", "--show-bin-path"], cwd=PROJECT, text=True).strip())
    if APP.exists():
        shutil.rmtree(APP)
    contents = APP / "Contents"
    resources = contents / "Resources"
    tools = resources / "tools"
    (contents / "MacOS").mkdir(parents=True)
    tools.mkdir(parents=True)
    shutil.copy2(bin_path / "FeatherApp", contents / "MacOS" / "FeatherApp")
    # This CLT/SwiftPM combination labels LC_BUILD_VERSION.sdk as the minimum
    # deployment version. Record the actual installed SDK while retaining minOS 13.
    sdk_version = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
    app_binary = contents / "MacOS" / "FeatherApp"
    corrected_binary = app_binary.with_suffix(".sdk-corrected")
    run("xcrun", "vtool", "-set-build-version", "macos", "13.0", sdk_version, "-replace", "-output", corrected_binary, app_binary)
    corrected_binary.replace(app_binary)
    app_binary.chmod(0o755)
    for name in ["yt-dlp", "ffmpeg", "ffprobe", "deno"]:
        shutil.copy2(VENDOR / name, tools / name)
        (tools / name).chmod(0o755)
    shutil.copytree(VENDOR / "licenses", resources / "Licenses")
    shutil.copy2(VENDOR / "tools-manifest.json", resources / "tools-manifest.json")
    report_names = ["platform-results.json", "resource-results.json"] + (["subtitle-results.json"] if SUBTITLE_RELEASE else [])
    for name in report_names:
        if (PROJECT / "Validation" / name).exists():
            shutil.copy2(PROJECT / "Validation" / name, resources / name)
    iconset = ROOT / "work" / "Feather.iconset"
    run("swift", PROJECT / "scripts" / "make-icon.swift", iconset)
    run("iconutil", "-c", "icns", iconset, "-o", resources / "Feather.icns")
    info = {
        "CFBundleIdentifier": "io.feather.videodownloader",
        "CFBundleName": "飞羽下载",
        "CFBundleDisplayName": "飞羽下载",
        "CFBundleExecutable": "FeatherApp",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": VERSION,
        "CFBundleVersion": RELEASE["build"],
        "CFBundleIconFile": "Feather",
        "CFBundleDevelopmentRegion": "zh-Hans",
        "CFBundleLocalizations": ["zh-Hans", "en"],
        "LSMinimumSystemVersion": "13.0",
        "LSApplicationCategoryType": "public.app-category.video",
        "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": "飞羽下载 · 2026",
        "NSPrincipalClass": "NSApplication"
    }
    with (contents / "Info.plist").open("wb") as file:
        plistlib.dump(info, file)
    # Sign tools first, then seal the containing app. No Developer ID is assumed.
    for name in ["yt-dlp", "ffmpeg", "ffprobe", "deno"]:
        run("codesign", "--force", "--sign", "-", "--timestamp=none", tools / name)
    manifest["packagedFilesAfterLocalSigning"] = [
        {"name": name, "sha256": hashlib.sha256((tools / name).read_bytes()).hexdigest(), "bytes": (tools / name).stat().st_size}
        for name in ["yt-dlp", "ffmpeg", "ffprobe", "deno"]
    ]
    manifest["signing"] = "ad-hoc local signing; not Apple notarized"
    manifest["appMinimumOS"] = "13.0"
    manifest["appLinkedSDK"] = sdk_version
    (resources / "tools-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    run("codesign", "--force", "--sign", "-", "--timestamp=none", APP)
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", APP)
    print("APP_READY", APP, flush=True)

if __name__ == "__main__":
    main()
