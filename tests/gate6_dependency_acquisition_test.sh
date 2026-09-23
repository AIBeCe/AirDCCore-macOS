#!/bin/sh
set -eu

if [ "${AIRDCCORE_RUN_DEPENDENCY_NETWORK_TESTS:-0}" != 1 ]; then
  printf 'SKIP: set AIRDCCORE_RUN_DEPENDENCY_NETWORK_TESTS=1 for live acquisition\n'
  exit 0
fi
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
exec python3 - "$PROJECT_ROOT" <<'PY'
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts/lib"))
from dependency_acquire import (OwnedDirectory, _git_actual, _sha, acquire_all,
                                cache_name, tree_manifest)
from dependency_lock import load_lock

lock = load_lock(root / "config/dependencies.lock")
dependencies = root / "Dependencies"
for name in ("Dependencies", "Build", "Dist"):
    if os.path.lexists(root / name):
        raise SystemExit(f"FAIL: live acquisition gate requires initially absent {name}")

def update(offline=False):
    subprocess.run([str(root / "scripts/update"), "--dependencies", *(["--offline"] if offline else [])], check=True)
    if any(os.path.lexists(root / name) for name in ("Build", "Dist")):
        raise SystemExit("FAIL: acquisition created Build or Dist")
    tracked = subprocess.check_output(["git", "-C", str(root), "ls-files", "Dependencies", "Build", "Dist"])
    if tracked:
        raise SystemExit("FAIL: generated acquisition paths are tracked")

def sources_and_caches():
    result = {}
    for record in lock.dependencies:
        source = dependencies / record.name
        manifest = _git_actual(source) if record.source.kind == "git" else tree_manifest(source)
        result[record.name] = hashlib.sha256(manifest).hexdigest()
        for path in [source, *source.rglob("*")]:
            relative = path.relative_to(source)
            if ".git" not in relative.parts:
                if path.lstat().st_mtime != record.source_date_epoch:
                    raise SystemExit(f"FAIL: noncanonical source mtime: {record.name}/{relative}")
                result[f"{record.name}/{relative}:mtime"] = path.lstat().st_mtime_ns
        cached = dependencies / ".downloads" / cache_name(record)
        result[cached.name] = (_sha(cached), cached.stat().st_mtime_ns)
    return result

def full_snapshot():
    return {str(path.relative_to(dependencies)): (path.lstat().st_mode, path.lstat().st_mtime_ns,
            os.readlink(path) if path.is_symlink() else _sha(path) if path.is_file() else None)
            for path in [dependencies, *dependencies.rglob("*")]}

update()
online = sources_and_caches()
# acquire_all verifies licenses, exact commits/origins, tree hashes, and drift
# before the gate removes precisely the validated component directories.
acquire_all(root, lock, True)
with OwnedDirectory(dependencies) as owned:
    for record in lock.dependencies:
        target = dependencies / record.name
        with OwnedDirectory(target) as component:
            owned.check()
            component.check()
            shutil.rmtree(target)
update(offline=True)
if sources_and_caches() != online:
    raise SystemExit("FAIL: offline reconstruction changed source/cache fingerprints or mtimes")
before = full_snapshot()
update(offline=True)
if full_snapshot() != before:
    raise SystemExit("FAIL: repeated offline acquisition is not an unchanged no-op")
print("PASS: live dependency acquisition, offline reconstruction, and idempotence")
PY
