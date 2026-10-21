#!/usr/bin/env python3
"""Install verified optional AI artifacts using only their private interpreter.

The host verifies/downloads catalog artifacts and extracts the specifically
audited CPython archive to DESTINATION/python first. This script has no download
code. All dependency resolution is local and hash constrained. The host owns
transaction/activation/cancellation; an interrupted staging directory is never
an active component.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import subprocess
import sys
import tarfile
import time


def emit(event: str, **values) -> None:
    print(json.dumps({"event": event, **values}, ensure_ascii=False), flush=True)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def child_environment(root: Path | None = None) -> dict:
    env = dict(os.environ)
    for name in ("PYTHONPATH", "PYTHONHOME", "PYTHONUSERBASE", "PIP_INDEX_URL", "PIP_EXTRA_INDEX_URL"):
        env.pop(name, None)
    env.update(PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1", PIP_NO_INDEX="1",
               PIP_DISABLE_PIP_VERSION_CHECK="1", PIP_CONFIG_FILE=os.devnull,
               HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_DATASETS_OFFLINE="1",
               MPLBACKEND="Agg", OMP_NUM_THREADS="2", OPENBLAS_NUM_THREADS="2")
    if root is not None:
        env.update(MPLCONFIGDIR=str(root / ".cache/matplotlib"), HF_HOME=str(root / ".cache/huggingface"),
                   TORCH_HOME=str(root / ".cache/torch"), XDG_CACHE_HOME=str(root / ".cache"))
    return env


def checked_archive(archive_path: Path, expected_root: str) -> list[tarfile.TarInfo]:
    def normalized(value: str, base: PurePosixPath = PurePosixPath()) -> PurePosixPath:
        candidate = PurePosixPath(value)
        if candidate.is_absolute() or "\\" in value:
            raise ValueError("Unsafe absolute archive path")
        parts = list(base.parts)
        for part in candidate.parts:
            if part in ("", "."):
                continue
            if part == "..":
                if not parts:
                    raise ValueError("Archive path traversal")
                parts.pop()
            else:
                parts.append(part)
        result = PurePosixPath(*parts)
        if not result.parts or result.parts[0] != expected_root:
            raise ValueError("Unexpected archive root")
        return result

    links = {}
    seen = set()
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
    for member in members:
        name = normalized(member.name)
        if name in seen:
            raise ValueError("Duplicate archive entry")
        seen.add(name)
        if member.issym() or member.islnk():
            links[name] = normalized(member.linkname, name.parent if member.issym() else PurePosixPath())
        elif not (member.isfile() or member.isdir()):
            raise ValueError("Special archive file rejected")
    for member in members:
        name = normalized(member.name)
        if any(parent in links for parent in name.parents):
            raise ValueError("Archive writes through symbolic link")
    for start, target in links.items():
        visited = {start}
        while target in links:
            if target in visited:
                raise ValueError("Archive link cycle")
            visited.add(target)
            target = links[target]
        if target not in seen:
            raise ValueError("Dangling archive link")
    return members


def extract_source(path: Path, destination: Path, root: str) -> None:
    members = checked_archive(path, root)
    if destination.exists():
        raise ValueError("Upstream staging directory already exists")
    destination.mkdir()
    # GitHub source archives currently contain only directories and files.
    # Reject links here instead of allowing an unreviewed new source layout.
    with tarfile.open(path, "r:gz") as archive:
        for member in members:
            relative = PurePosixPath(member.name).relative_to(root)
            target = destination.joinpath(*relative.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(member.mode & 0o777)
            else:
                raise ValueError("Source archive links are not permitted")


def link_or_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(source, destination)
    except OSError:
        shutil.copy2(source, destination)


def sign_native(root: Path) -> int:
    magics = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
              b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    signed = 0
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            if stream.read(4) not in magics:
                continue
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(path)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        signed += 1
    return signed


def self_check(root: Path, catalog: dict) -> dict:
    """CPU only: no model load, MPS allocation, video operation or network."""
    python = root / catalog["pythonRelativePath"]
    code = r'''
import importlib, importlib.metadata, json, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
profile = sys.argv[2]
assert pathlib.Path(sys.prefix).resolve() == root / "python", (sys.prefix, root)
sys.path.insert(0, str(root / "upstream" if profile == "seedvr2" else root))
import torch, numpy, cv2
torch.set_num_threads(2)
value = torch.nn.functional.conv3d(torch.ones((1,1,3,3,3)), torch.ones((1,1,2,2,2)))
assert value.device.type == "cpu" and value.sum().item() == 64.0
assert cv2.resize(numpy.zeros((2,2,3), dtype=numpy.uint8), (4,4)).shape == (4,4,3)
if profile == "seedvr2":
    import torchvision, diffusers, transformers, peft, safetensors
    boxes = torch.tensor([[0.,0.,1.,1.],[0.,0.,1.,1.]])
    assert torchvision.ops.nms(boxes, torch.tensor([1.,0.5]), 0.5).tolist() == [0]
    importlib.import_module("src.core.generation_phases")
    names = ("torch", "torchvision", "numpy", "opencv-python", "diffusers", "transformers", "peft", "safetensors")
else:
    import worker, detector, super_resolution, rrdb_arch, srvgg_arch
    # Deserialization/strict architecture checks stay on CPU; no MPS device is used.
    for scale in (2,4):
        model = rrdb_arch.RRDBNet(num_in_ch=3,num_out_ch=3,num_feat=64,num_block=23,num_grow_ch=32,scale=scale)
        state = torch.load(root/"models"/f"RealESRGAN_x{scale}plus.pth",map_location="cpu",weights_only=True)
        model.load_state_dict(state.get("params_ema",state.get("params",state)),strict=True)
        del state, model
    torch.jit.load(str(root/"models"/"big-lama.pt"),map_location="cpu")
    names = ("torch", "numpy", "opencv-python-headless")
versions = {name: importlib.metadata.version(name) for name in names}
installed = {distribution.metadata["Name"].lower().replace("_","-"):distribution.version
             for distribution in importlib.metadata.distributions()}
print(json.dumps({"status":"passed", "device":"cpu", "versions":versions,
                  "installedPackages":installed, "profile":profile,
                  "pythonVersion":sys.version.split()[0], "pythonPrefix":str(pathlib.Path(sys.prefix).resolve())}))
'''
    result = subprocess.run([str(python), "-I", "-B", "-c", code, str(root), catalog.get("profile", "seedvr2")],
                            env=child_environment(root), text=True, timeout=180,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError("CPU import handshake failed: " + result.stderr[-5000:])
    # Upstream may print banners during import; the final line is the handshake.
    handshake = json.loads(result.stdout.strip().splitlines()[-1])
    expected = {item["name"].lower().replace("_", "-"): item["version"]
                for item in catalog["downloads"] if item["kind"] == "wheel"}
    for name, version in expected.items():
        if handshake["installedPackages"].get(name) != version:
            raise ValueError("Installed dependency version differs from catalog: " + name)
    return handshake


def write_manifest(root: Path, catalog: dict) -> Path:
    files = []
    for path in sorted(root.rglob("*")):
        if path.relative_to(root).parts[0] == ".cache":
            continue
        if path.is_symlink():
            files.append({"path": str(path.relative_to(root)), "link": os.readlink(path)})
        elif path.is_file() and path.name != "component-manifest.json":
            files.append({"path": str(path.relative_to(root)), "bytes": path.stat().st_size, "sha256": digest(path)})
    manifest = {"schemaVersion": 1, "componentID": catalog["id"], "revision": catalog["revision"],
                "files": files, "hashesAfterCodeSigning": True, "mutablePaths": [".cache"]}
    target = root / "component-manifest.json"
    target.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    return target


def install(args, catalog: dict) -> None:
    root = args.destination.resolve()
    if not root.is_dir() or root.is_symlink():
        raise ValueError("Destination must be a real staging directory")
    if (root / "component-receipt.json").exists():
        raise ValueError("Install destination already contains an installed component")
    if any(path.name != "python" for path in root.iterdir()):
        raise ValueError("Install destination must contain only the extracted private Python")
    if Path(sys.prefix).resolve() != root / "python":
        raise ValueError("Bootstrap must run with destination/python, never global Python")
    if platform.system() != "Darwin" or platform.machine() != catalog["architecture"]:
        raise ValueError("This component requires macOS arm64")
    actual_os = tuple(int(value) for value in platform.mac_ver()[0].split(".")[:2])
    minimum_os = tuple(int(value) for value in catalog["minimumMacOS"].split("."))
    if actual_os < minimum_os:
        raise ValueError("This component requires macOS " + catalog["minimumMacOS"])
    if digest(args.requirements) != catalog["requirementsSHA256"]:
        raise ValueError("Locked requirements SHA mismatch")
    started = time.time()
    artifacts = {}
    for index, item in enumerate(catalog["downloads"]):
        filename = item["filename"]
        if Path(filename).name != filename:
            raise ValueError("Unsafe download filename")
        source = args.downloads / filename
        if source.is_symlink() or not source.is_file():
            raise ValueError("Missing artifact: " + filename)
        if source.stat().st_size != item["bytes"] or digest(source) != item["sha256"]:
            raise ValueError("Artifact checksum mismatch: " + filename)
        if item["kind"] == "python":
            checked_archive(source, "python")
        artifacts[item["id"]] = source
        emit("progress", stage="verify", completed=index + 1, total=len(catalog["downloads"]), filename=filename)
    upstream = next((item for item in catalog["downloads"] if item["kind"] == "source"), None)
    if upstream:
        extract_source(artifacts[upstream["id"]], root / "upstream", upstream["archiveRoot"])
    if catalog.get("workerFiles"):
        if not args.worker_directory:
            raise ValueError("This component requires --worker-directory")
        for item in catalog["workerFiles"]:
            filename = item["filename"]
            if Path(filename).name != filename:
                raise ValueError("Unsafe worker filename")
            source = args.worker_directory / filename
            if source.is_symlink() or not source.is_file() or source.stat().st_size != item["bytes"] or digest(source) != item["sha256"]:
                raise ValueError("Packaged worker differs from catalog: " + filename)
            shutil.copy2(source, root / filename)
    for item in catalog.get("licenseFiles", []):
        filename = item["filename"]
        if Path(filename).name != filename:
            raise ValueError("Unsafe license filename")
        source = Path(__file__).resolve().parent / "licenses" / filename
        if source.is_symlink() or not source.is_file() or source.stat().st_size != item["bytes"] or digest(source) != item["sha256"]:
            raise ValueError("Packaged license differs from catalog: " + filename)
        (root / "licenses").mkdir(exist_ok=True)
        shutil.copy2(source, root / "licenses" / filename)
    wheelhouse = root / ".wheelhouse"
    wheelhouse.mkdir()
    for item in catalog["downloads"]:
        if item["kind"] == "wheel":
            link_or_copy(artifacts[item["id"]], wheelhouse / item["filename"])
        elif item["kind"] == "model":
            link_or_copy(artifacts[item["id"]], root / "models" / item["filename"])
    emit("progress", stage="install", completed=0, total=1)
    python = root / catalog["pythonRelativePath"]
    pip = subprocess.run([str(python), "-I", "-B", "-m", "pip", "install", "--no-index",
                          "--find-links", str(wheelhouse), "--require-hashes", "--only-binary=:all:",
                          "--no-compile", "--disable-pip-version-check", "--no-warn-script-location",
                          "-r", str(args.requirements.resolve())], env=child_environment(root), text=True,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if pip.returncode:
        raise RuntimeError("Offline wheel install failed: " + pip.stdout[-7000:])
    shutil.rmtree(wheelhouse)
    emit("progress", stage="sign", completed=0, total=1)
    count = sign_native(root / "python")
    emit("progress", stage="self-check", completed=0, total=1)
    handshake = self_check(root, catalog)
    # Prefixes are diagnostic, never relied on by launch code after activation.
    receipt = {"schemaVersion": 1, "componentID": catalog["id"], "revision": catalog["revision"],
               "architecture": catalog["architecture"], "minimumMacOS": catalog["minimumMacOS"],
               "profile": catalog.get("profile", "seedvr2"),
               "upstreamCommit": catalog["upstream"].get("commit"), "requirementsSHA256": catalog["requirementsSHA256"],
               "offlineInstall": True, "uploadsMedia": False, "signedMachOFiles": count,
               "selfCheck": handshake, "elapsedSeconds": round(time.time() - started, 3)}
    (root / "component-receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    emit("progress", stage="manifest", completed=0, total=1)
    manifest = write_manifest(root, catalog)
    emit("completed", componentID=catalog["id"], revision=catalog["revision"],
         destination=str(root), receipt="component-receipt.json", manifest=str(manifest), selfCheck=handshake)


def verify(args, catalog: dict) -> None:
    root = args.destination.resolve()
    manifest = json.loads((root / "component-manifest.json").read_text())
    for item in manifest["files"]:
        relative = Path(item["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Unsafe installed manifest path")
        path = root / relative
        if "link" in item:
            if not path.is_symlink() or os.readlink(path) != item["link"]:
                raise ValueError("Installed link differs: " + item["path"])
        elif path.is_symlink() or not path.is_file() or path.stat().st_size != item["bytes"] or digest(path) != item["sha256"]:
            raise ValueError("Installed file differs: " + item["path"])
    handshake = self_check(root, catalog)
    emit("completed", componentID=catalog["id"], destination=str(root), verifiedFiles=len(manifest["files"]), selfCheck=handshake)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("install", "verify"))
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--downloads", type=Path)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--requirements", type=Path)
    parser.add_argument("--worker-directory", type=Path)
    args = parser.parse_args()
    catalog = json.loads(args.catalog.read_text())
    if catalog.get("schemaVersion") != 1:
        raise ValueError("Unsupported AI component catalog")
    if args.command == "install":
        if not args.downloads or not args.requirements:
            parser.error("install requires --downloads and --requirements")
        install(args, catalog)
    else:
        verify(args, catalog)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        emit("error", message=str(error), errorType=type(error).__name__)
        sys.exit(1)
