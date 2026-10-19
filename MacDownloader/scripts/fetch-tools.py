#!/usr/bin/env python3
"""Fetch pinned upstream tools into the workspace; never installs globally."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / "work" / "vendor"
LICENSES = DEST / "licenses"
VERSIONS = {"yt-dlp": "2026.08.19", "deno": "v2.9.7"}
BASES = {
    "yt-dlp": "https://github.com/yt-dlp/yt-dlp/releases/download/" + VERSIONS["yt-dlp"] + "/",
    "deno": "https://github.com/denoland/deno/releases/download/" + VERSIONS["deno"] + "/",
}
EXPECTED_SIZES = {}

def fetch(url, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    expected_size = EXPECTED_SIZES.get(url)
    if path.exists() and path.stat().st_size > 0 and (expected_size is None or path.stat().st_size == expected_size):
        return path
    temporary = path.with_name(path.name + ".download")
    if path.exists() and expected_size and 0 < path.stat().st_size < expected_size:
        path.replace(temporary)
    for attempt in range(3):
        try:
            args = ["curl", "--fail", "--location", "--silent", "--show-error", "--connect-timeout", "20", "--max-time", "240", "--retry", "2"]
            if expected_size and temporary.exists() and 0 < temporary.stat().st_size < expected_size:
                args += ["--continue-at", "-"]
            args += [url, "--output", str(temporary)]
            subprocess.run(args, check=True)
            if temporary.stat().st_size == 0:
                raise RuntimeError("Empty upstream response for " + path.name)
            if expected_size and temporary.stat().st_size != expected_size:
                raise RuntimeError("Incomplete upstream response for " + path.name)
            temporary.replace(path)
            print("Fetched", path.name, path.stat().st_size, flush=True)
            return path
        except Exception:
            if attempt == 2:
                raise
            time.sleep(1 + attempt)

def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

def main():
    DEST.mkdir(parents=True, exist_ok=True)
    for name, repository in [("yt-dlp", "yt-dlp/yt-dlp"), ("deno", "denoland/deno")]:
        metadata_path = DEST / (name + "-release.json")
        if not metadata_path.exists():
            fetch("https://api.github.com/repos/" + repository + "/releases/tags/" + VERSIONS[name], metadata_path)
        metadata = json.loads(metadata_path.read_text())
        if metadata["tag_name"] != VERSIONS[name]:
            raise RuntimeError("Unexpected cached tool version: " + name)
        EXPECTED_SIZES.update({a["browser_download_url"]: a["size"] for a in metadata["assets"]})
    downloads = [
        (BASES["yt-dlp"] + "yt-dlp_macos", DEST / "yt-dlp"),
        (BASES["yt-dlp"] + "SHA2-256SUMS", DEST / "yt-dlp-SHA2-256SUMS"),
        (BASES["deno"] + "deno-aarch64-apple-darwin.zip", DEST / "deno.zip"),
        (BASES["deno"] + "deno-aarch64-apple-darwin.zip.sha256sum", DEST / "deno-zip.sha256sum"),
        ("https://raw.githubusercontent.com/yt-dlp/yt-dlp/" + VERSIONS["yt-dlp"] + "/LICENSE", LICENSES / "yt-dlp-LICENSE.txt"),
        ("https://raw.githubusercontent.com/yt-dlp/yt-dlp/" + VERSIONS["yt-dlp"] + "/THIRD_PARTY_LICENSES.txt", LICENSES / "yt-dlp-THIRD-PARTY.txt"),
        ("https://raw.githubusercontent.com/denoland/deno/" + VERSIONS["deno"] + "/LICENSE.md", LICENSES / "deno-LICENSE.txt"),
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        futures = [pool.submit(fetch, url, path) for url, path in downloads]
        for result in concurrent.futures.as_completed(futures):
            result.result()
    expected = dict(line.split(maxsplit=1)[::-1] for line in (DEST / "yt-dlp-SHA2-256SUMS").read_text().splitlines())
    if sha(DEST / "yt-dlp") != expected["yt-dlp_macos"]:
        raise RuntimeError("yt-dlp checksum mismatch")
    expected_deno = (DEST / "deno-zip.sha256sum").read_text().split()[0]
    if sha(DEST / "deno.zip") != expected_deno:
        raise RuntimeError("Deno checksum mismatch")
    with zipfile.ZipFile(DEST / "deno.zip") as archive:
        with archive.open("deno") as source, (DEST / "deno").open("wb") as output:
            shutil.copyfileobj(source, output)
    manifest = {"architecture": "arm64", "versions": VERSIONS, "files": [], "sources": [url for url, _ in downloads]}
    for name in ["yt-dlp", "deno"]:
        path = DEST / name
        path.chmod(0o755)
        manifest["files"].append({"name": name, "bytes": path.stat().st_size, "sha256": sha(path)})
    (DEST / "tools-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Tools ready", flush=True)

if __name__ == "__main__":
    main()
