#!/usr/bin/env python3
"""Resolve the evaluated SeedVR2 environment into immutable, offline-install pins.

This is a maintainer tool, never an application startup step. It uses official
PyPI JSON and immutable GitHub/Hugging Face revisions, keeps downloaded artifacts
outside the app, and does not execute a model or upload media.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path, PurePosixPath
import runpy
import shutil
import subprocess
import tarfile

from packaging.tags import compatible_tags, cpython_tags, mac_platforms
from packaging.utils import parse_wheel_filename

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "MacDownloader/Resources/AIComponents"
EVALUATION = ROOT / "work/seedvr2-evaluation"
PYTHON = {
    "id": "python", "kind": "python",
    "filename": "cpython-3.11.16+20260901-aarch64-apple-darwin-install_only.tar.gz",
    "url": "https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.11.16%2B20260901-aarch64-apple-darwin-install_only.tar.gz",
    "sha256": "50424fa409e8ae84b82a3052522f64695b47dff2158b70bb7358e0ebd6c085c9",
    "bytes": 27087450, "version": "3.11.16+20260901",
    "sourceCommit": "4bb01f09aaf362c71e891be4a41cb6d6ddf830b3",
    "license": "PSF-2.0 and bundled dependency licenses",
}
UPSTREAM_COMMIT = "4490bd1f482e026674543386bb2a4d176da245b9"
MODEL_COMMIT = "09ced71023636e9bc8cdf9cdecfb2625d1e691e8"
MODELS = [
    ("seedvr2_ema_3b_fp16.safetensors", 6783018808,
     "2fd0e03a3dad24e07086750360727ca437de4ecd456f769856e960ae93e2b304"),
    ("ema_vae_fp16.safetensors", 501324814,
     "20678548f420d98d26f11442d3528f8b8c94e57ee046ef93dbb7633da8612ca1"),
]


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def fetch_json(url: str) -> dict:
    data = subprocess.check_output(["/usr/bin/curl", "--fail", "--location", "--silent",
                                    "--show-error", "--retry", "3", "--max-time", "120", url])
    return json.loads(data)


def download(item: dict, directory: Path) -> Path:
    path = directory / item["filename"]
    if path.is_file() and path.stat().st_size == item.get("bytes", path.stat().st_size):
        if not item.get("sha256") or digest(path) == item["sha256"]:
            return path
    partial = path.with_name(path.name + ".partial")
    subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                    "--retry", "3", "--max-time", "600", "--output", str(partial), item["url"]], check=True)
    if item.get("bytes") and partial.stat().st_size != item["bytes"]:
        raise ValueError("Download size mismatch: " + path.name)
    if item.get("sha256") and digest(partial) != item["sha256"]:
        raise ValueError("Download SHA mismatch: " + path.name)
    partial.replace(path)
    return path


def audit_archive(path: Path, expected_root: str) -> dict:
    """Audit every path/link, including symlink ancestor traversal and hardlinks."""
    def normalized(value: str, base: PurePosixPath = PurePosixPath()) -> PurePosixPath:
        candidate = PurePosixPath(value)
        if candidate.is_absolute() or "\\" in value:
            raise ValueError("Absolute or Windows archive path: " + value)
        parts: list[str] = list(base.parts)
        for part in candidate.parts:
            if part in ("", "."):
                continue
            if part == "..":
                if not parts:
                    raise ValueError("Archive path escapes root: " + value)
                parts.pop()
            else:
                parts.append(part)
        result = PurePosixPath(*parts)
        if not result.parts or result.parts[0] != expected_root:
            raise ValueError("Unexpected archive root: " + value)
        return result

    links: dict[PurePosixPath, PurePosixPath] = {}
    members: set[PurePosixPath] = set()
    symlinks = hardlinks = regular = 0
    with tarfile.open(path, "r:gz") as archive:
        entries = archive.getmembers()
        for member in entries:
            name = normalized(member.name)
            if name in members:
                raise ValueError("Duplicate archive entry: " + member.name)
            members.add(name)
            if member.issym() or member.islnk():
                target = normalized(member.linkname, name.parent if member.issym() else PurePosixPath())
                links[name] = target
                symlinks += member.issym()
                hardlinks += member.islnk()
            elif member.isfile():
                regular += 1
            elif not member.isdir():
                raise ValueError("Special archive entry: " + member.name)
        for member in entries:
            name = normalized(member.name)
            for ancestor in name.parents:
                if ancestor in links:
                    raise ValueError("Archive writes through link: " + member.name)
        for start, target in links.items():
            visited = {start}
            while target in links:
                if target in visited:
                    raise ValueError("Archive link cycle: " + str(start))
                visited.add(target)
                target = links[target]
            if target not in members:
                raise ValueError("Dangling archive link: " + str(start))
    return {"status": "passed", "root": expected_root,
            "regularFiles": regular, "symbolicLinks": symlinks, "hardLinks": hardlinks,
            "checks": ["relative-root-contained-paths", "no-special-files", "no-duplicate-entries",
                       "root-contained-link-targets", "no-link-ancestor-writes", "no-link-cycles-or-dangling-links"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--downloads", type=Path, default=EVALUATION / "component-runtime/downloads")
    parser.add_argument("--requirements", type=Path, default=EVALUATION / "requirements-resolved.txt")
    parser.add_argument("--download-wheels", action="store_true")
    parser.add_argument("--profile", choices=("seedvr2", "realesrgan"), default="seedvr2")
    args = parser.parse_args()
    args.downloads.mkdir(parents=True, exist_ok=True)
    RESOURCES.mkdir(parents=True, exist_ok=True)
    legacy = args.profile == "realesrgan"
    platforms = list(mac_platforms(version=(13 if legacy else 14, 0), arch="arm64"))
    tags = list(cpython_tags((3, 11), abis=["cp311"], platforms=platforms))
    tags += list(compatible_tags((3, 11), interpreter="cp311", platforms=platforms))
    rank = {tag: index for index, tag in enumerate(tags)}
    requirement_source = ROOT / "MacDownloader/VideoRepairWorker/requirements.txt" if legacy else args.requirements
    requirements = [line.strip().split("==") for line in requirement_source.read_text().splitlines()
                    if line.strip() and not line.startswith("#")]
    # Match the evaluated environment, including its package installer tooling.
    requirements += [["pip", "24.1.2" if legacy else "24.0"], ["setuptools", "70.3.0" if legacy else "79.0.1"]]

    def resolve(pair: list[str]) -> dict:
        name, version = pair
        metadata = fetch_json(f"https://pypi.org/pypi/{name}/{version}/json")
        choices = []
        for item in metadata["urls"]:
            if item["packagetype"] != "bdist_wheel" or item.get("yanked"):
                continue
            _, _, _, wheel_tags = parse_wheel_filename(item["filename"])
            candidates = [rank[tag] for tag in wheel_tags if tag in rank]
            if candidates:
                choices.append((min(candidates), item["filename"], item))
        if not choices:
            raise ValueError(f"No supported macOS arm64 CPython311 wheel: {name}=={version}")
        item = min(choices)[2]
        info = metadata["info"]
        license_value = info.get("license_expression") or info.get("license") or "See wheel dist-info licenses"
        if len(license_value) > 160:
            license_value = "See wheel dist-info licenses"
        return {"id": "wheel-" + name.lower().replace("_", "-"), "kind": "wheel",
                "name": name, "version": version, "filename": item["filename"],
                "url": item["url"], "sha256": item["digests"]["sha256"], "bytes": item["size"],
                "metadataURL": f"https://pypi.org/pypi/{name}/{version}/json",
                "license": license_value}

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        wheels = sorted(pool.map(resolve, requirements), key=lambda item: item["name"].lower())
    python_pin = dict(PYTHON)
    if legacy:
        reference = runpy.run_path(str(ROOT / "MacDownloader/scripts/fetch-video-repair.py"), run_name="catalog_reference")
        python_pin.update(filename="cpython-3.11.10+20241016-aarch64-apple-darwin-install_only.tar.gz",
                          url=reference["PYTHON_URL"], sha256=reference["PYTHON_SHA256"], version="3.11.10+20241016")
        del python_pin["bytes"]
        release = fetch_json("https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/20241016")
        asset = next(item for item in release["assets"] if item["name"] == python_pin["filename"])
        python_pin.update(bytes=asset["size"], sourceCommit="78e57bd18b48c357904b47a6ae6999ebb255c578")
    python_path = download(python_pin, args.downloads)
    python = dict(python_pin, archiveAudit=audit_archive(python_path, "python"))
    source = {"id": "source", "kind": "source", "filename": "seedvr2-" + UPSTREAM_COMMIT + ".tar.gz",
              "url": "https://codeload.github.com/numz/ComfyUI-SeedVR2_VideoUpscaler/tar.gz/" + UPSTREAM_COMMIT,
              "bytes": 4776791, "sha256": "73ebee9da0bfa6876613e23a5f898ebd72ea938eb1d26d9322063172bfb788be",
              "sourceCommit": UPSTREAM_COMMIT, "license": "Apache-2.0"}
    if not legacy:
        source_path = download(source, args.downloads)
        source.update(bytes=source_path.stat().st_size, sha256=digest(source_path))
        source["archiveRoot"] = "ComfyUI-SeedVR2_VideoUpscaler-" + UPSTREAM_COMMIT
        source["archiveAudit"] = audit_archive(source_path, source["archiveRoot"])
    models = [{"id": "model-dit" if index == 0 else "model-vae", "kind": "model", "filename": name,
               "url": f"https://huggingface.co/numz/SeedVR2_comfyUI/resolve/{MODEL_COMMIT}/{name}",
               "bytes": size, "sha256": sha, "sourceCommit": MODEL_COMMIT, "license": "Apache-2.0",
               "licenseSource": f"https://huggingface.co/numz/SeedVR2_comfyUI/blob/{MODEL_COMMIT}/README.md"}
              for index, (name, size, sha) in enumerate(MODELS)]
    if legacy:
        model_pins = [("big-lama.pt", reference["LAMA_URL"], reference["LAMA_SHA256"], "Apache-2.0"),
                      ("realesr-general-x4v3.pth", reference["SRVGG_URL"], reference["SRVGG_SHA256"], "BSD-3-Clause")]
        model_pins += [(name, url, sha, "BSD-3-Clause") for name, (url, sha) in reference["RRDB_MODELS"].items()]
        models = []
        for name, url, sha, license_id in model_pins:
            cached = ROOT / "work/vendor/video-repair/models" / name
            if not cached.is_file() or digest(cached) != sha:
                raise ValueError("Accepted legacy model is absent or changed: " + name)
            models.append({"id": "model-" + name.split(".")[0].lower(), "kind": "model", "filename": name,
                           "url": url, "sha256": sha, "bytes": cached.stat().st_size, "license": license_id})
    downloads = [python] + ([] if legacy else [source]) + wheels + models
    license_directory = RESOURCES / "licenses"
    license_directory.mkdir(exist_ok=True)
    if legacy:
        license_names = ["LaMa-Apache-2.0.txt", "Real-ESRGAN-BSD-3-Clause.txt", "BasicSR-Apache-2.0.txt", "IOPaint-Apache-2.0.txt"]
        for name in license_names:
            shutil.copy2(ROOT / "work/vendor/video-repair/licenses" / name, license_directory / name)
    else:
        license_names = ["SeedVR2-Apache-2.0.txt"]
        with tarfile.open(source_path, "r:gz") as archive:
            (license_directory / license_names[0]).write_bytes(archive.extractfile(source["archiveRoot"] + "/LICENSE").read())
    runtime_size = sum(item["bytes"] for item in downloads if item["kind"] != "model")
    model_size = sum(item["bytes"] for item in models)
    locked = "# macOS arm64, CPython3.11. Evaluated environment; generated by build-ai-catalog.py\n"
    locked += "\n".join(f'{item["name"]}=={item["version"]} --hash=sha256:{item["sha256"]}' for item in wheels) + "\n"
    requirements_name = "locked-requirements-realesrgan.txt" if legacy else "locked-requirements.txt"
    catalog_name = "catalog-realesrgan.json" if legacy else "catalog.json"
    (RESOURCES / requirements_name).write_text(locked)
    catalog = {"schemaVersion": 1, "id": "realesrgan-lama-macos-arm64" if legacy else "seedvr2-3b-fp16-macos-arm64",
               "profile": args.profile, "revision": "1",
               "displayName": "标准本地修复" if legacy else "SeedVR2 3B 本地增强", "architecture": "arm64", "minimumMacOS": "13.0" if legacy else "14.0",
               "pythonRelativePath": "python/bin/python3", "upstreamRelativePath": "upstream",
               "modelsRelativePath": "models", "totalDownloadBytes": runtime_size + model_size,
               "runtimeDownloadBytes": runtime_size, "modelDownloadBytes": model_size,
               "minimumFreeDiskBytes": (3 if legacy else 16) * 1024**3,
               "requirementsSHA256": hashlib.sha256(locked.encode()).hexdigest(),
               "licenseFiles": [{"filename": name, "bytes": (license_directory / name).stat().st_size,
                                 "sha256": digest(license_directory / name)} for name in license_names],
               "policy": {"networkDuringInstallationOnly": True, "uploadsMedia": False,
                          "globalPythonRequired": False, "modelsBundledInApplication": False},
               "downloads": downloads}
    if legacy:
        catalog["workerFiles"] = [{"filename": name, "bytes": (ROOT / "MacDownloader/VideoRepairWorker" / name).stat().st_size,
                                   "sha256": digest(ROOT / "MacDownloader/VideoRepairWorker" / name)}
                                  for name in ("worker.py", "detector.py", "srvgg_arch.py", "rrdb_arch.py", "super_resolution.py", "requirements.txt", "README.md")]
        catalog["upstream"] = {"url": "https://github.com/xinntao/Real-ESRGAN", "license": "BSD-3-Clause",
                               "architectureSource": "https://github.com/XPixelGroup/BasicSR", "architectureLicense": "Apache-2.0"}
    else:
        catalog["upstream"] = {"url": "https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler",
                               "commit": UPSTREAM_COMMIT, "license": "Apache-2.0"}
    (RESOURCES / catalog_name).write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    if args.download_wheels:
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            for path in pool.map(lambda item: download(item, args.downloads), wheels):
                print(path.name, flush=True)
    print(json.dumps({"catalog": str(RESOURCES / catalog_name), "wheels": len(wheels),
                      "runtimeDownloadBytes": runtime_size, "modelDownloadBytes": model_size}, indent=2))


if __name__ == "__main__":
    main()
