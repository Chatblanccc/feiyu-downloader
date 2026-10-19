#!/usr/bin/env python3
"""Generate a compact, credential-free acceptance report and source delivery."""
from pathlib import Path
import json
import plistlib
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "outputs"
PROJECT = ROOT / "MacDownloader"
RELEASE = json.loads((PROJECT / "Release.json").read_text())
VALIDATION = ROOT / "work" / "validation" / ("v" + RELEASE["version"])
SUBTITLE_RELEASE = tuple(int(part) for part in RELEASE["version"].split(".")[:2]) >= (0, 2)

def require_current_gui():
    gui = json.loads((VALIDATION / "final-gui" / "acceptance.json").read_text())
    if gui.get("passed") is not True:
        raise SystemExit("Final GUI acceptance did not pass")
    if SUBTITLE_RELEASE:
        app = gui.get("app", {})
        if app.get("version") != RELEASE["version"] or str(app.get("build")) != str(RELEASE["build"]):
            raise SystemExit("Final GUI acceptance belongs to a different release/build")
        if "observations" not in gui or "statePersistence" not in gui:
            raise SystemExit("Final GUI acceptance is missing observations or state persistence evidence")
    return gui

def main():
    core_regression = json.loads((VALIDATION / "core-regression.json").read_text())
    if core_regression.get("passed") is not True:
        raise SystemExit("Core resource regressions did not pass")
    if SUBTITLE_RELEASE and core_regression.get("testCount", 0) < 35:
        raise SystemExit("The current release requires at least 35 passing core regressions")
    gui = require_current_gui()
    subtitle_report = None
    if SUBTITLE_RELEASE:
        subtitle_report = json.loads((PROJECT / "Validation" / "subtitle-results.json").read_text())
        if subtitle_report.get("passed") is not True:
            raise SystemExit("Subtitle acceptance did not pass")
        resource_report = json.loads((PROJECT / "Validation" / "resource-results.json").read_text())
        if resource_report.get("版本", resource_report.get("version")) != RELEASE["version"]:
            raise SystemExit("Resource acceptance belongs to a different release")
        app_info_path = OUTPUT / "飞羽下载.app" / "Contents" / "Info.plist"
        with app_info_path.open("rb") as file:
            app_info = plistlib.load(file)
        if app_info.get("CFBundleShortVersionString") != RELEASE["version"] or str(app_info.get("CFBundleVersion")) != str(RELEASE["build"]):
            raise SystemExit("The built app belongs to a different release/build")
    baseline = ROOT / "work" / "validation" / "v0.1.1" if SUBTITLE_RELEASE else VALIDATION
    rows = []
    for name, label in [("douyin", "抖音"), ("bilibili", "B站"), ("kuaishou", "快手"), ("youtube", "YouTube"), ("audio", "仅音频 M4A")]:
        record = json.loads((baseline / ("packaged_" + name + ".json")).read_text())
        app = record.get("appResult", {})
        if not record.get("passed"):
            raise SystemExit("Acceptance not passed: " + label)
        if SUBTITLE_RELEASE and (record.get("version") != "0.1.1" or record.get("exitCode") != 0
                                 or record.get("probeExitCode") != 0 or record.get("decodeExitCode") != 0
                                 or app.get("success") is not True or app.get("stage") != "downloaded"):
            raise SystemExit("Historical complete-download baseline is invalid: " + label)
        rows.append({
            "平台": label, "结果": "历史基线通过" if SUBTITLE_RELEASE else "通过",
            "范围": "继承 0.1.1 (2) 的实际完整下载及全片解码记录；" + RELEASE["version"] + " 本轮未重新下载这个平台样本" if SUBTITLE_RELEASE else "候选安装包实际完整下载并全片解码；最终构建另见界面及资源回归报告",
            "完整下载验证构建": "0.1.1 (2)",
            "来源": app.get("sourceURL"), "标题": app.get("title"), "文件名": Path(app["file"]).name,
            "字节数": app.get("bytes"), "媒体信息": record.get("media"),
            "下载退出码": record.get("exitCode"), "媒体探测退出码": record.get("probeExitCode"), "完整解码退出码": record.get("decodeExitCode"),
            "已有浏览器凭据": "未读取", "用时秒": record.get("elapsedSeconds")
        })
    report = {
        "应用": "飞羽下载", "版本": RELEASE["version"], "构建": RELEASE["build"], "验证日期": RELEASE["date"], "时区": "Asia/Shanghai",
        "构建架构": "Apple Silicon arm64", "构建最低系统": "macOS 13", "实际验证系统": "macOS 26.6.2",
        "平台实测": rows,
        "未计入成功的平台": [
            {"平台": "TikTok", "状态": "已接入通用引擎，当前匿名测试受 IP 访问限制；未验证成功"},
            {"平台": "小红书", "状态": "已接入通用引擎，匿名样本返回不可浏览或登录页；未验证成功"},
            {"平台": "Vimeo", "状态": "测试样本需要登录；未验证成功"}
        ],
        "最终图形界面验收": ({"通过": gui["passed"], "版本": gui["app"]["version"], "构建": gui["app"]["build"], "本轮观察": gui["observations"], "重启持久化": gui["statePersistence"]} if SUBTITLE_RELEASE else {"通过": gui["passed"], "版本": gui["app"]["version"], "构建": gui["app"]["build"], "已存在文件恢复完成": gui["observations"]["existingFileRecoveredToCompleted"], "实际传输中取消": gui["observations"]["cancellationDuringActualTransfer"], "取消后续传完成": gui["observations"]["sameTestRecordRetriedAndResumed"], "失败预览按时停止": gui["observations"]["invalidPreviewAutomaticallyEnded"], "清理后重启持久化": gui["statePersistence"]}),
        "核心回归": {"通过数": core_regression["testCount"], "方式": "同一测试源码的 FEATHER_STANDALONE 断言入口；主机仅有 CLT，缺少 XCTest", "用时秒": core_regression["elapsedSeconds"], "实际执行结果": "通过；详见资源修复验收报告"},
        "抖音浏览器隔离": {"系统WebKit": True, "临时非持久会话": True, "固定目标作品ID": True, "禁止外部应用协议": True, "禁止新窗口": True, "取消清理已实测": True},
        "签名": "本地 ad-hoc 签名，codesign --verify --deep --strict 通过；无 Apple Developer ID 与公证",
        "范围边界": ("平台完整下载结果是 0.1.1 (2) 的历史基线，" + RELEASE["version"] + " 本轮未重下上述五条样本；本轮结果仅包含当前核心回归、图形界面和字幕功能验收，不能视为当前版本的平台网络下载实测。" if SUBTITLE_RELEASE else "上述结果只说明指定公开样本在本轮环境中成功，不能保证平台全部内容、所有账号、网络和后续页面版本均可下载。")
    }
    if SUBTITLE_RELEASE:
        report["平台实测来源"] = {"性质": "继承历史基线", "实际完整下载版本": "0.1.1", "实际完整下载构建": "2", "本轮平台样本重新下载": False}
        report["字幕功能验收"] = {"通过": subtitle_report["passed"], "报告": "字幕功能验收.json", "最低系统": "macOS 26"}
        for row in report["未计入成功的平台"]:
            row["范围"] = "0.1.1 历史测试记录；" + RELEASE["version"] + " 本轮未重测"
        diagnosis_path = VALIDATION / "x-diagnosis-summary.json"
        if diagnosis_path.exists():
            diagnosis = json.loads(diagnosis_path.read_text())
            if diagnosis.get("passed") is not True:
                raise SystemExit("Current X visibility diagnosis did not pass")
            report["本轮X访问诊断"] = {
                "匿名接口": "受内容可见性过滤，未获得可下载媒体；不能直接判断删除、私密或地区限制",
                "显式授权Chrome": "同一原链接在实际下载引擎中成功解析媒体信息",
                "自动读取登录凭据": False,
                "范围": "自动诊断只请求媒体信息，没有下载或播放媒体；用户自行重试的结果另见界面验收。",
                "旧错误迁移": "仅更新失败X任务的旧通用错误说明，保留其它字段，不自动重试"
            }
    data = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    (OUTPUT / "平台实测结果.json").write_text(data)
    (PROJECT / "Validation" / "platform-results.json").write_text(data)
    app = OUTPUT / "飞羽下载.app"
    shutil.copy2(PROJECT / "Validation" / "platform-results.json", app / "Contents" / "Resources" / "platform-results.json")
    shutil.copy2(PROJECT / "Validation" / "resource-results.json", app / "Contents" / "Resources" / "resource-results.json")
    shutil.copy2(PROJECT / "Validation" / "resource-results.json", OUTPUT / "资源修复验收.json")
    if SUBTITLE_RELEASE:
        shutil.copy2(PROJECT / "Validation" / "subtitle-results.json", app / "Contents" / "Resources" / "subtitle-results.json")
        shutil.copy2(PROJECT / "Validation" / "subtitle-results.json", OUTPUT / "字幕功能验收.json")
    subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    source_zip = OUTPUT / "飞羽下载-源代码.zip"
    with zipfile.ZipFile(source_zip, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(PROJECT.rglob("*")):
            if path.is_file() and not any(part in [".build", "__pycache__", ".DS_Store"] for part in path.parts):
                archive.write(path, path.relative_to(ROOT))
        for path in sorted((ROOT / "work" / "vendor" / "licenses").iterdir()):
            if path.is_file():
                archive.write(path, "ThirdPartyNotices/" + path.name)
        archive.write(ROOT / "work" / "vendor" / "tools-manifest.json", "ThirdPartyNotices/tools-manifest.json")
        ffmpeg_source = ROOT / "work" / "ffmpeg-build" / "ffmpeg-9.0.2.tar.xz"
        archive.write(ffmpeg_source, "ThirdPartySources/" + ffmpeg_source.name, compress_type=zipfile.ZIP_STORED)
    print("Report and source delivery ready")

if __name__ == "__main__":
    main()
