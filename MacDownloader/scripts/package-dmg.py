#!/usr/bin/env python3
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess
from release_evidence import app_identity, matches_identity

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "outputs"
STAGE = ROOT / "work" / "dmg-staging"
RELEASE = json.loads((ROOT / "MacDownloader" / "Release.json").read_text())
VERSION = RELEASE["version"]
SUBTITLE_RELEASE = tuple(int(part) for part in VERSION.split(".")[:2]) >= (0, 2)
AI_RELEASE = tuple(int(part) for part in VERSION.split(".")[:2]) >= (0, 5)
DMG = OUTPUT / ("飞羽下载-" + VERSION + "-AppleSilicon.dmg")

def verify_ai_release(app):
    validation = ROOT / "work" / "validation" / ("v" + VERSION)
    core = json.loads((validation / "core-regression.json").read_text())
    repair = json.loads((validation / "ai-repair-acceptance.json").read_text())
    gui = json.loads((validation / "final-gui" / "acceptance.json").read_text())
    if core.get("passed") is not True or core.get("testCount", 0) < 40:
        raise SystemExit("AI release requires current core regression checks")
    required = ["realVideoBoth", "enhancementOnly", "localRepairOnly", "cancellation",
                "fullDecode", "sourceUnchanged", "audioAndDuration", "automaticMultipleRegions"]
    if repair.get("passed") is not True or any(repair.get("checks", {}).get(k) is not True for k in required):
        raise SystemExit("Current real-video AI acceptance is incomplete")
    if gui.get("passed") is not True or not gui.get("statePersistence"):
        raise SystemExit("Current AI GUI/relaunch acceptance is incomplete")
    with (app / "Contents" / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    identity = app_identity(app)
    for report in [repair, gui]:
        build = report.get("app", {})
        if build.get("version") != VERSION or str(build.get("build")) != str(RELEASE["build"]) or not matches_identity(build, identity):
            raise SystemExit("AI acceptance does not match the packaged app binary")
    for source_name, delivery_name in [("ai-repair-acceptance.json", "AI视频修复验收.json"),
                                       ("core-regression.json", "核心回归验收.json")]:
        source = validation / source_name
        if (app / "Contents" / "Resources" / source_name).read_bytes() != source.read_bytes() or (OUTPUT / delivery_name).read_bytes() != source.read_bytes():
            raise SystemExit("Finalize current AI acceptance before packaging")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)

def verify_subtitle_release(app):
    validation = ROOT / "work" / "validation" / ("v" + VERSION)
    core = json.loads((validation / "core-regression.json").read_text())
    if core.get("passed") is not True or core.get("testCount", 0) < 35:
        raise SystemExit("The current release requires at least 35 passing core regressions")
    gui = json.loads((validation / "final-gui" / "acceptance.json").read_text())
    gui_app = gui.get("app", {})
    if gui.get("passed") is not True or gui_app.get("version") != VERSION or str(gui_app.get("build")) != str(RELEASE["build"]):
        raise SystemExit("Final GUI acceptance did not pass for this release/build")
    if "observations" not in gui or "statePersistence" not in gui:
        raise SystemExit("Final GUI acceptance is missing observations or state persistence evidence")
    subtitle = ROOT / "MacDownloader" / "Validation" / "subtitle-results.json"
    if json.loads(subtitle.read_text()).get("passed") is not True:
        raise SystemExit("Subtitle acceptance did not pass")
    with (app / "Contents" / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if info.get("CFBundleShortVersionString") != VERSION or str(info.get("CFBundleVersion")) != str(RELEASE["build"]):
        raise SystemExit("The built app belongs to a different release/build")
    # Finalization must copy current reports into both the app and the delivery.
    for resource_name, delivery_name in [("subtitle-results.json", "字幕功能验收.json"),
                                         ("resource-results.json", "资源修复验收.json"),
                                         ("platform-results.json", "平台实测结果.json")]:
        source = ROOT / "MacDownloader" / "Validation" / resource_name
        bundled = app / "Contents" / "Resources" / resource_name
        delivered = OUTPUT / delivery_name
        if not bundled.is_file() or not delivered.is_file() or source.read_bytes() != bundled.read_bytes() or source.read_bytes() != delivered.read_bytes():
            raise SystemExit("Finalize current acceptance reports before packaging: " + resource_name)

def main():
    app = OUTPUT / "飞羽下载.app"
    if not app.exists():
        raise SystemExit("Build and verify the app first")
    if AI_RELEASE:
        verify_ai_release(app)
    elif SUBTITLE_RELEASE:
        verify_subtitle_release(app)
    if STAGE.exists():
        shutil.rmtree(STAGE)
    STAGE.mkdir(parents=True)
    subprocess.run(["ditto", str(app), str(STAGE / app.name)], check=True)
    (STAGE / "Applications").symlink_to("/Applications", target_is_directory=True)
    documents = (["使用说明.txt", "AI视频修复验收.json", "核心回归验收.json"] if AI_RELEASE else
                 ["使用说明.txt", "平台实测结果.json", "资源修复验收.json"] + (["字幕功能验收.json"] if SUBTITLE_RELEASE else []))
    for name in documents:
        if (OUTPUT / name).exists():
            shutil.copy2(OUTPUT / name, STAGE / name)
    if DMG.exists():
        DMG.unlink()
    subprocess.run(["hdiutil", "create", "-volname", "飞羽下载", "-srcfolder", str(STAGE), "-format", "UDZO", "-ov", str(DMG)], check=True)
    subprocess.run(["hdiutil", "verify", str(DMG)], check=True)
    checksums = []
    source_name = "飞羽下载-" + VERSION + "-源代码.zip" if AI_RELEASE else "飞羽下载-源代码.zip"
    for path in [DMG, OUTPUT / source_name]:
        if path.exists():
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            checksums.append(digest.hexdigest() + "  " + path.name)
    (OUTPUT / "SHA256SUMS.txt").write_text("\n".join(checksums) + "\n")
    print("DMG_READY", DMG)

if __name__ == "__main__":
    main()
