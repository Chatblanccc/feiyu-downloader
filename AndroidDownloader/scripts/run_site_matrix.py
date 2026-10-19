#!/usr/bin/env python3
"""Serial Android real-download acceptance; a skipped test never counts as a pass.

The target APK and its same-signature androidTest APK must already be installed.
No application install, proxy change, login, or emulator startup is performed here.
Do not run other instrumentation sessions on the selected device during this run.
"""

import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
APP = "io.feather.videodownloader.android"
TEST = APP + ".test/androidx.test.runner.AndroidJUnitRunner"
METHOD = APP + ".DownloadFlowInstrumentedTest#realSiteDownloadWhenUrlSupplied"
LABELS = {"douyin": "抖音", "kuaishou": "快手", "bilibili": "B站", "youtube": "YouTube", "x": "X", "tiktok": "TikTok"}


def timestamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_json(path, value):
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temp.replace(path)


def validate_result(output, logcat, marker, site):
    """Require JUnit completion plus a real downloaded A/V artifact receipt."""
    if not re.search(r"\bOK\s*\(1 test\)", output):
        return None, "Instrumentation did not report exactly one successful test"
    if re.search(r"FAILURES!!!|INSTRUMENTATION_FAILED|Process crashed|shortMsg=", output):
        return None, "Instrumentation reported failure or crash"
    # sendStatus stream output belongs to this invocation and avoids logcat's
    # per-entry truncation. Fall back only to uniquely marked current logcat.
    current = output if "FEIYU_SITE_RESULT " in output else logcat.split(marker, 1)[1] if marker in logcat else ""
    receipts = []
    for line in current.splitlines():
        if "FEIYU_SITE_RESULT " in line:
            try:
                receipts.append(json.loads(line.split("FEIYU_SITE_RESULT ", 1)[1]))
            except json.JSONDecodeError:
                return None, "Downloaded-file receipt is truncated or invalid JSON"
    if len(receipts) != 1:
        return None, f"Expected one downloaded-file receipt, received {len(receipts)} (a skipped test is not a pass)"
    receipt = receipts[0]
    if receipt.get("site") != LABELS[site]:
        return None, "Downloaded-file receipt site does not match selected fixture"
    try:
        duration = float(receipt.get("duration", receipt.get("media", {}).get("format", {}).get("duration", 0)))
        streams = receipt.get("streams", receipt.get("media", {}).get("streams", []))
        codecs = {stream.get("codec_type") if isinstance(stream, dict) else stream for stream in streams}
        valid = (receipt["bytes"] > 0 and duration > 0 and {"audio", "video"} <= codecs
                 and bool(receipt.get("id")) and re.fullmatch(r"[a-f0-9]{64}", receipt.get("sha256", ""))
                 and receipt.get("uri", "").startswith("content://") and receipt.get("decodedSamples", 0) >= 3)
    except (KeyError, TypeError, ValueError):
        valid = False
    if not valid:
        return None, "Receipt does not prove a distinct downloaded video, SHA256, saved media URI, duration, video/audio, and three decoded samples"
    return receipt, None


def run_fixture(adb, fixture, output_dir, timeout):
    name = fixture["id"]
    row = {"fixtureId": name, "site": fixture["site"], "url": fixture["url"], "quality": fixture.get("quality", "BEST"), "startedAt": timestamp(), "status": "running"}
    marker = "FEIYU_MATRIX_START_" + uuid.uuid4().hex
    attempt_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:8]
    attempt_dir = output_dir / name / attempt_id
    attempt_dir.mkdir(parents=True)
    row["attemptId"] = attempt_id
    instrument_path = attempt_dir / "instrument.log"
    logcat_path = attempt_dir / "logcat.log"
    start = time.monotonic()
    # Do not clear the device's log buffer. A unique in-stream marker separates
    # the current invocation from old System.out receipts in that buffer.
    with logcat_path.open("w") as logcat_file:
        logger = subprocess.Popen(adb + ["logcat", "-v", "raw", "-T", "1", "System.out:I", "FeiyuMatrix:I", "*:S"], stdout=logcat_file, stderr=subprocess.STDOUT)
        try:
            subprocess.run(adb + ["shell", "log", "-p", "i", "-t", "FeiyuMatrix", marker], check=True, timeout=15, capture_output=True)
            # `adb shell` reconstructs its remote argv; quote the URL as a remote
            # shell argument so authorId and other '&' query parameters survive.
            remote = shlex.join(["am", "instrument", "-w", "-e", "class", METHOD, "-e", "retainMedia", "true", "-e", "quality", row["quality"], "-e", "siteUrl", fixture["url"], TEST])
            try:
                process = subprocess.run(adb + ["shell", remote], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
                output = process.stdout
                row["returnCode"] = process.returncode
            except subprocess.TimeoutExpired as exc:
                output = exc.stdout or b""
                if isinstance(output, bytes):
                    output = output.decode("utf-8", errors="replace")
                row["status"] = "timed_out"
                row["error"] = f"Exceeded {timeout} seconds; target and test package force-stopped"
                for package in (APP + ".test", APP):
                    subprocess.run(adb + ["shell", "am", "force-stop", package], timeout=15, capture_output=True)
            instrument_path.write_text(output)
            # Flush logger output after am instrument has exited.
            time.sleep(0.3)
        finally:
            logger.terminate()
            try:
                logger.wait(timeout=5)
            except subprocess.TimeoutExpired:
                logger.kill()
                logger.wait()
    row.update({"finishedAt": timestamp(), "seconds": round(time.monotonic() - start, 2), "instrumentLog": str(instrument_path.relative_to(output_dir)), "logcatLog": str(logcat_path.relative_to(output_dir))})
    if row["status"] != "timed_out":
        receipt, error = validate_result(output, logcat_path.read_text(errors="replace"), marker, fixture["site"])
        if receipt and (receipt.get("source") != fixture["url"] or receipt.get("quality") != row["quality"]):
            error = "Receipt source or quality does not match this exact invocation"
        if row["returnCode"] != 0:
            error = f"adb/instrument exit code {row['returnCode']}"
        row["status"] = "passed" if error is None else "failed"
        if error:
            row["error"] = error
        else:
            row["downloadedFile"] = receipt
    write_json(attempt_dir / "result.json", row)
    return row


def summarize(state):
    state["passed"] = sum(result["status"] == "passed" for result in state["results"])
    state["distinctVideoIds"] = {site: sorted({str(result["downloadedFile"]["id"]) for result in state["results"] if result["site"] == site and result["status"] == "passed"}) for site in LABELS}
    state["sixSitesTwoDistinctVideosPassed"] = all(len(ids) >= 2 for ids in state["distinctVideoIds"].values())
    expected = {site: min(2, sum(result["site"] == site for result in state["results"])) for site in LABELS}
    state["selectedFixtureCoveragePassed"] = (state["passed"] == len(state["results"])
                                               and all(len(state["distinctVideoIds"][site]) >= count for site, count in expected.items()))
    state["finishedAt"] = timestamp()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="Explicit ADB device serial")
    parser.add_argument("--adb", type=Path, default=ROOT / "work/android-toolchain/sdk/platform-tools/adb")
    parser.add_argument("--fixtures", type=Path, default=ROOT / "AndroidDownloader/docs/site-fixtures.json")
    parser.add_argument("--output", type=Path, default=ROOT / "work/android-toolchain/site-matrix")
    parser.add_argument("--site", action="append", choices=LABELS, help="Repeat to select sites")
    parser.add_argument("--id", action="append", help="Repeat to select fixture IDs")
    parser.add_argument("--timeout", type=int, default=300, help="Hard timeout per full download, maximum 300 seconds")
    parser.add_argument("--quality", choices=["BEST", "P1080", "P720"], help="Override fixture video quality")
    parser.add_argument("--resume", action="store_true", help="Reuse only receipts for identical URL, quality, and installed APK fingerprint")
    parser.add_argument("--retry-failed", type=int, default=0, help="Explicit retry count after a failed attempt; all attempts are retained")
    parser.add_argument("--list", action="store_true", help="Print fixtures without using ADB")
    args = parser.parse_args()
    if not 1 <= args.timeout <= 300 or not 0 <= args.retry_failed <= 3:
        parser.error("Timeout must be 1..300 seconds and explicit retries must be 0..3")
    data = json.loads(args.fixtures.read_text())
    fixtures = [dict(f) for f in data["fixtures"] if (not args.site or f["site"] in args.site) and (not args.id or f["id"] in args.id)]
    if not fixtures or len({f["id"] for f in fixtures}) != len(fixtures):
        parser.error("No fixtures selected, or fixture IDs are duplicated")
    for fixture in fixtures:
        if args.quality:
            fixture["quality"] = args.quality
        if not re.fullmatch(r"[a-z0-9-]+", fixture["id"]):
            parser.error("Fixture IDs must use lowercase letters, digits, and hyphens")
        if fixture["site"] not in LABELS or not fixture["url"].startswith("https://"):
            parser.error("Only known sites and explicit HTTPS public-video fixtures are accepted")
    if args.list:
        print(json.dumps(fixtures, ensure_ascii=False, indent=2))
        return 0
    args.output.mkdir(parents=True, exist_ok=True)
    lock_path = args.output.parent / ("site-matrix-" + re.sub(r"[^a-zA-Z0-9_-]", "_", args.serial) + ".lock")
    with lock_path.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("Another matrix runner already owns this device")
        lock.write(str(os.getpid()))
        lock.flush()
        adb = [str(args.adb), "-s", args.serial]
        subprocess.run(adb + ["get-state"], check=True, timeout=15, capture_output=True)
        package = subprocess.run(adb + ["shell", "dumpsys", "package", APP], check=True, text=True, capture_output=True, timeout=15).stdout
        # lastUpdateTime changes for install -r even if versionCode is unchanged.
        fingerprint = "\n".join(line.strip() for line in package.splitlines() if re.search(r"versionCode=|versionName=|lastUpdateTime=", line))
        if not fingerprint:
            parser.error("Target package is not installed")
        state = {"startedAt": timestamp(), "device": args.serial, "installedPackage": fingerprint, "fixturesFile": str(args.fixtures), "results": [], "attempts": []}
        for fixture in fixtures:
            previous_path = args.output / (fixture["id"] + ".result.json")
            previous = json.loads(previous_path.read_text()) if args.resume and previous_path.exists() else {}
            if (previous.get("status") == "passed" and previous.get("url") == fixture["url"] and previous.get("quality") == fixture.get("quality", "BEST") and previous.get("installedPackage") == fingerprint):
                row = previous
            else:
                print(f"Running {fixture['id']} ({fixture['site']}, {fixture.get('quality', 'BEST')})", flush=True)
                for attempt in range(args.retry_failed + 1):
                    row = run_fixture(adb, fixture, args.output, args.timeout)
                    row["installedPackage"] = fingerprint
                    state["attempts"].append(row)
                    write_json(args.output / fixture["id"] / row["attemptId"] / "result.json", row)
                    if row["status"] == "passed":
                        break
                    print(f"  attempt {attempt + 1} {row['status']}: {row.get('error', '')}", flush=True)
                write_json(previous_path, row)
            state["results"].append(row)
            summarize(state)
            write_json(args.output / "matrix.json", state)
            print(f"  {row['status']}: {row.get('error', str(row.get('downloadedFile', {}).get('bytes', 0)) + ' bytes')}", flush=True)
        return 0 if state["selectedFixtureCoveragePassed"] else 1


if __name__ == "__main__":
    sys.exit(main())
