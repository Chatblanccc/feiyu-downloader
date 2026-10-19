#!/usr/bin/env python3
"""Seal observed current AI acceptance and a reproducible source delivery."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess
import zipfile
from release_evidence import app_identity, matches_identity

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "MacDownloader"
OUTPUT = ROOT / "outputs"
RELEASE = json.loads((PROJECT / "Release.json").read_text())
VALIDATION = ROOT / "work" / "validation" / ("v" + RELEASE["version"])
APP = OUTPUT / "飞羽下载.app"

def main():
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    identity = app_identity(APP)
    for name in ["ai-repair-acceptance.json", "final-gui/acceptance.json"]:
        report = json.loads((VALIDATION / name).read_text())
        current = report.get("app", {})
        if report.get("passed") is not True or not matches_identity(current, identity) or current.get("version") != RELEASE["version"] or str(current.get("build")) != str(RELEASE["build"]):
            raise SystemExit("Incomplete or stale observed acceptance: " + name)
    if info["CFBundleShortVersionString"] != RELEASE["version"] or str(info["CFBundleVersion"]) != str(RELEASE["build"]):
        raise SystemExit("App belongs to a different release")
    for source, delivered in [("ai-repair-acceptance.json", "AI视频修复验收.json"), ("core-regression.json", "核心回归验收.json")]:
        shutil.copy2(VALIDATION / source, APP / "Contents/Resources" / source)
        shutil.copy2(VALIDATION / source, OUTPUT / delivered)
    subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(APP)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(APP)], check=True)
    target = OUTPUT / ("飞羽下载-" + RELEASE["version"] + "-源代码.zip")
    snapshot = VALIDATION / "source-snapshot"
    source_manifest = json.loads((APP / "Contents/Resources/source-manifest.json").read_text())
    for name, expected in source_manifest["files"].items():
        if hashlib.sha256((snapshot / name).read_bytes()).hexdigest() != expected:
            raise SystemExit("Frozen build source does not match: " + name)
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(snapshot.rglob("*")):
            if path.is_file(): archive.write(path, path.relative_to(snapshot))
        archive.write(APP / "Contents/Resources/source-manifest.json", "source-manifest.json")
        for directory, prefix in [(ROOT / "work/vendor/licenses", "ThirdPartyNotices"),
                                  (ROOT / "work/vendor/video-repair/licenses", "ThirdPartyNotices/VideoRepair")]:
            for path in sorted(directory.rglob("*")):
                if path.is_file(): archive.write(path, str(Path(prefix) / path.relative_to(directory)))
        for source, prefix in [(ROOT / "work/vendor/tools-manifest.json", "ThirdPartyNotices"),
                               (ROOT / "work/vendor/video-repair/manifest.json", "ThirdPartyNotices/VideoRepair"),
                               (ROOT / "work/ffmpeg-build/ffmpeg-9.0.2.tar.xz", "ThirdPartySources")]:
            archive.write(source, str(Path(prefix) / source.name))
    print("SOURCE_READY", target)

if __name__ == "__main__":
    main()
