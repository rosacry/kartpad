#!/usr/bin/env python3
"""Fetch only the pinned sources the game-free iOS app shell needs.

Uses KartPad's own builder helpers and dependencies.lock.json pins. Unlike
`kartpad-builder bootstrap --target ios`, this skips the Retro Rewind content
download and the disc-extraction tool, neither of which the app shell uses.
"""
import json
import subprocess
import sys
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(repo / "builder"))
from kartpad_builder.bootstrap import (  # noqa: E402
    _dependency_map, _download, _prepare_gitlinks, _verify_checkout, load_lock,
)

deps = _dependency_map(load_lock(repo))
# Every gitlink must be initialized: write-build-provenance.py fingerprints all of them.
runtime = deps["KartPad WiiCompiled runtime fork"]
_prepare_gitlinks(repo, list(runtime["platformPaths"].values()) + ["vendor/wiicompiled"], install=True)

profile = json.loads((repo / "builder/profiles/mkwii-rmcp01-rev0.json").read_text())
for name in profile["sourceDependencies"]:
    dep = deps[name]
    path = repo / dep["path"]
    if not (path / ".git").exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--recurse-submodules", dep["repository"], str(path)], check=True)
        subprocess.run(["git", "-C", str(path), "checkout", "--detach", dep["commit"]], check=True)
        subprocess.run(["git", "-C", str(path), "submodule", "update", "--init", "--recursive"], check=True)
    _verify_checkout(repo, dep)
    print(f"verified {name} @ {dep['commit'][:12]}", flush=True)

dawn = deps["Dawn prebuilt"]
out = repo / "build/dependency-cache" / f"dawn-ios-arm64-{dawn['version']}.tar.gz"
_download(dawn["iosArm64Url"], dawn["iosArm64Sha256"], out)
print(f"verified Dawn {dawn['version']} (iOS arm64)", flush=True)
