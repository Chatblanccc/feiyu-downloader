#!/usr/bin/env python3
"""Build the native app and a drag-to-Applications DMG without global installs."""
from pathlib import Path
import base64
import hashlib
import json
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "MacDownloader"
VENDOR = ROOT / "work" / "vendor"
REPAIR = VENDOR / "video-repair"
OUTPUT = ROOT / "outputs"
APP = OUTPUT / "飞羽下载.app"
RELEASE = json.loads((PROJECT / "Release.json").read_text())
VERSION = RELEASE["version"]
UPDATE_FEED = "https://raw.githubusercontent.com/Chatblanccc/feiyu-downloader/main/updates/macos/appcast.xml"

def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

def source_files():
    return [path for path in sorted(PROJECT.rglob("*")) if path.is_file() and
            not any(part in {".build", ".swiftpm", "Validation", "__pycache__", ".DS_Store"}
                    for part in path.relative_to(PROJECT).parts)]

def source_hashes():
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in source_files()}

def verify_repair_runtime():
    manifest_path = REPAIR / "manifest.json"
    if not manifest_path.is_file():
        raise SystemExit("Missing offline AI runtime; run scripts/fetch-video-repair.py first")
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("offline") is not True or manifest.get("architecture") != "arm64":
        raise SystemExit("AI runtime must be an offline arm64 build")
    for item in manifest["files"]:
        path = REPAIR / item["path"]
        if REPAIR.resolve() not in path.resolve().parents or not path.is_file():
            raise SystemExit("Invalid AI runtime file: " + item["path"])
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise SystemExit("AI runtime checksum changed: " + item["path"])
    for source in (PROJECT / "VideoRepairWorker").glob("*.py"):
        if (REPAIR / source.name).read_bytes() != source.read_bytes():
            raise SystemExit("AI worker source changed; refresh runtime before packaging: " + source.name)
    return manifest

def sign_repair_runtime(directory):
    # Python extension modules and their dynamic libraries are nested executable
    # code. Sign every real Mach-O file before sealing the enclosing application.
    magic = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
             b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    files = []
    for path in directory.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) in magic:
                files.append(path)
    for path in sorted(files, key=lambda p: (-len(p.parts), str(p))):
        run("codesign", "--force", "--sign", "-", "--timestamp=none", path,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    manifest_path = directory / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["localSigning"] = "ad-hoc; not Developer ID signed or notarized"
    manifest["packagedMachOFiles"] = [{"path": str(path.relative_to(directory)),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bytes": path.stat().st_size} for path in files]
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")

def main():
    verify_repair_runtime()
    before_build = source_hashes()
    public_key_path = ROOT / "updates" / "macos" / "public-key.txt"
    if not public_key_path.is_file():
        raise SystemExit("Missing Sparkle public key: " + str(public_key_path))
    public_key = public_key_path.read_text().strip()
    try:
        if len(base64.b64decode(public_key, validate=True)) != 32:
            raise ValueError("Ed25519 public keys must contain 32 bytes")
    except ValueError as error:
        raise SystemExit("Invalid Sparkle public key: " + str(error))
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
    if source_hashes() != before_build:
        raise SystemExit("Mac sources changed while compiling; rebuild the current candidate")
    snapshot = ROOT / "work" / "validation" / ("v" + VERSION) / "source-snapshot"
    if snapshot.exists():
        shutil.rmtree(snapshot)
    for source in source_files():
        target = snapshot / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    shutil.copy2(ROOT / "LICENSE", snapshot / "LICENSE")
    if source_hashes() != before_build:
        raise SystemExit("Mac sources changed while freezing their matching source delivery")
    bin_path = Path(subprocess.check_output(["swift", "build", "-c", "release", "--arch", "arm64", "--show-bin-path"], cwd=PROJECT, text=True).strip())
    if APP.exists():
        shutil.rmtree(APP)
    contents = APP / "Contents"
    resources = contents / "Resources"
    tools = resources / "tools"
    (contents / "MacOS").mkdir(parents=True)
    tools.mkdir(parents=True)
    shutil.copy2(bin_path / "FeatherApp", contents / "MacOS" / "FeatherApp")
    frameworks = list((PROJECT / ".build" / "artifacts").glob("**/macos-*/Sparkle.framework"))
    if len(frameworks) != 1:
        raise SystemExit("Expected exactly one Sparkle macOS framework from the pinned Swift package")
    sparkle = contents / "Frameworks" / "Sparkle.framework"
    sparkle.parent.mkdir()
    # Sparkle's versioned framework and helper bundles require their symlinks
    # and executable permissions. Preserve the vendor's nested code signatures.
    shutil.copytree(frameworks[0], sparkle, symlinks=True)
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", sparkle)
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
    shutil.copy2(PROJECT / "Resources" / "BrandIcon.png", resources / "BrandIcon.png")
    shutil.copytree(VENDOR / "licenses", resources / "Licenses")
    sparkle_license = PROJECT / ".build" / "artifacts" / "sparkle" / "Sparkle" / "LICENSE"
    if not sparkle_license.is_file():
        raise SystemExit("Missing Sparkle license in the verified Swift package artifact")
    shutil.copy2(sparkle_license, resources / "Licenses" / "Sparkle-LICENSE.txt")
    shutil.copy2(VENDOR / "tools-manifest.json", resources / "tools-manifest.json")
    shutil.copytree(REPAIR, resources / "VideoRepair", symlinks=True,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo"))
    sign_repair_runtime(resources / "VideoRepair")
    # Local validation reports can contain private source URLs and do not describe
    # this release. Keep them outside the distributable application bundle.
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
        "NSPrincipalClass": "NSApplication",
        "SUFeedURL": UPDATE_FEED,
        "SUPublicEDKey": public_key,
        "SUEnableAutomaticChecks": False,
        "SUAutomaticallyUpdate": False,
        "SUAllowsAutomaticUpdates": False,
        "SUSendProfileInfo": False,
        "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True
    }
    with (contents / "Info.plist").open("wb") as file:
        plistlib.dump(info, file)
    # Sign our tools first, preserve Sparkle's upstream helper signatures, then
    # seal the app. No Hardened Runtime/Developer ID is assumed for local builds.
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
    (resources / "source-manifest.json").write_text(json.dumps({"version": VERSION,
        "build": RELEASE["build"], "files": before_build}, ensure_ascii=False, indent=2) + "\n")
    run("codesign", "--force", "--sign", "-", "--timestamp=none", APP)
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", APP)
    print("APP_READY", APP, flush=True)

if __name__ == "__main__":
    main()
