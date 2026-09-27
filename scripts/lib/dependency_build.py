#!/usr/bin/env python3
"""Build locked dependencies into isolated, validated ARM64 prefixes."""

from __future__ import annotations

import argparse
import ctypes
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Mapping

from dependency_acquire import AcquireError, OwnedDirectory, _identity, acquire_all
from dependency_lock import (DependencyLock, DependencyRecord, LockError,
                             canonical_bytes, load_lock, topological_records)
from dependency_prefix import PrefixError, PrefixReport, tree_digest, validate_prefix


class BuildError(RuntimeError):
    """A dependency build or publication failed closed."""


BUILD_ENVIRONMENT_KEYS = (
    "AR", "CC", "CXX", "HOME", "LANG", "LC_ALL",
    "MACOSX_DEPLOYMENT_TARGET", "PATH", "RANLIB", "SDKROOT",
    "SOURCE_DATE_EPOCH", "TMPDIR", "ZERO_AR_DATE",
)


@dataclass(frozen=True)
class ToolInventory:
    sdkroot: str
    sdk_version: str
    apple: Mapping[str, str]
    host: Mapping[str, str]


@dataclass(frozen=True)
class BuildPaths:
    project: Path
    source: Path
    component: Path
    build: Path
    stage: Path
    evidence: Path
    home: Path
    temporary: Path


def _run_text(argv: tuple[str, ...]) -> str:
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "LANG": "C"}
    result = subprocess.run(argv, capture_output=True, text=True, env=env)
    if result.returncode:
        raise BuildError(f"failed to resolve required tool: {argv[-1]}")
    return result.stdout.strip()


def resolve_tool_inventory() -> ToolInventory:
    apple_names = {
        "cc": "clang", "cxx": "clang++", "ar": "ar", "ranlib": "ranlib",
        "lipo": "lipo", "nm": "nm", "otool": "otool", "strings": "strings",
    }
    apple = {key: _run_text(("xcrun", "--find", name)) for key, name in apple_names.items()}
    sdkroot = _run_text(("xcrun", "--sdk", "macosx", "--show-sdk-path"))
    sdk_version = _run_text(("xcrun", "--sdk", "macosx", "--show-sdk-version"))
    host = {}
    for name in ("cmake", "ninja", "perl", "make"):
        path = shutil.which(name)
        if path is None:
            raise BuildError(f"missing required host tool: {name}")
        host[name] = os.path.abspath(path)
    return ToolInventory(sdkroot, sdk_version, apple, host)


def job_count() -> int:
    return max(1, os.cpu_count() or 1)


def adapter_path(project_root: Path, record: DependencyRecord) -> Path:
    return project_root / "scripts/lib/dependencies" / f"build_{record.name}.sh"


def _regular_executable(path: Path):
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError as error:
        raise BuildError(f"missing dependency adapter: {path.name}") from error
    if not stat.S_ISREG(mode) or not mode & 0o111:
        raise BuildError(f"unsafe or non-executable dependency adapter: {path.name}")


def _tokens(paths: BuildPaths, jobs: int, tools: ToolInventory,
            dependency_prefixes: Mapping[str, Path]) -> dict[str, str]:
    values = {
        "@SOURCE@": str(paths.source), "@BUILD@": str(paths.build),
        "@STAGE@": str(paths.stage), "@JOBS@": str(jobs),
        "@EPOCH@": "", "@SDKROOT@": tools.sdkroot,
    }
    values.update({f"@PREFIX:{name}@": str(path) for name, path in dependency_prefixes.items()})
    return values


def expand_options(record: DependencyRecord, paths: BuildPaths, jobs: int,
                   tools: ToolInventory, dependency_prefixes: Mapping[str, Path]):
    tokens = _tokens(paths, jobs, tools, dependency_prefixes)
    tokens["@EPOCH@"] = str(record.source_date_epoch)

    def expand(values):
        result = []
        for value in values:
            expanded = value
            for token, replacement in tokens.items():
                expanded = expanded.replace(token, replacement)
            if "@" in expanded:
                raise BuildError(f"unexpanded lock token for {record.name}")
            result.append(expanded)
        return result

    return {"configure": expand(record.configure_options),
            "build": expand(record.build_options),
            "install": expand(record.install_options)}


def _environment(record: DependencyRecord, paths: BuildPaths, tools: ToolInventory) -> dict[str, str]:
    tool_dirs = []
    for value in (*tools.apple.values(), *tools.host.values(), "/usr/bin/xcrun"):
        directory = str(Path(value).parent)
        if directory not in tool_dirs:
            tool_dirs.append(directory)
    return {
        "PATH": os.pathsep.join(tool_dirs),
        "HOME": str(paths.home),
        "TMPDIR": str(paths.temporary),
        "SOURCE_DATE_EPOCH": str(record.source_date_epoch),
        "ZERO_AR_DATE": "1",
        "SDKROOT": tools.sdkroot,
        "MACOSX_DEPLOYMENT_TARGET": record.platform.deployment_target,
        "CC": tools.apple["cc"], "CXX": tools.apple["cxx"],
        "AR": tools.apple["ar"], "RANLIB": tools.apple["ranlib"],
        "LC_ALL": "C", "LANG": "C",
    }


def adapter_argv(record: DependencyRecord, paths: BuildPaths,
                 dependency_prefixes: Mapping[str, Path], jobs: int) -> list[str]:
    argv = [str(adapter_path(paths.project, record)), str(paths.source), str(paths.build),
            str(paths.stage), str(jobs), str(record.source_date_epoch)]
    argv.extend(str(dependency_prefixes[name]) for name in record.dependencies)
    return argv


def run_adapter(record: DependencyRecord, paths: BuildPaths,
                dependency_prefixes: Mapping[str, Path], env: Mapping[str, str],
                *, jobs: int | None = None, log=None):
    argv = adapter_argv(record, paths, dependency_prefixes, jobs or job_count())
    subprocess.run(argv, env=dict(env), stdout=log, stderr=subprocess.STDOUT, check=True)


def _canonical_json(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def _write(path: Path, data: bytes | str):
    raw = data.encode() if isinstance(data, str) else data
    temporary = path.with_name("." + path.name + ".tmp")
    temporary.write_bytes(raw)
    os.replace(temporary, path)


def _input_document(lock: DependencyLock, record: DependencyRecord, adapter: Path,
                    dependency_reports: Mapping[str, PrefixReport], tools: ToolInventory):
    return {
        "lock_sha256": hashlib.sha256(canonical_bytes(lock)).hexdigest(),
        "source": {"kind": record.source.kind,
                   "identity": record.source.commit or record.source.archive_sha256,
                   "tree_manifest_sha256": record.source.tree_manifest_sha256},
        "adapter": {"path": f"scripts/lib/dependencies/{adapter.name}",
                    "sha256": hashlib.sha256(adapter.read_bytes()).hexdigest()},
        "dependencies": [{"name": name,
                          "manifest_sha256": dependency_reports[name].manifest_sha256}
                         for name in record.dependencies],
        "tools": asdict(tools),
        "sdk_version": tools.sdk_version,
    }


def _archive_evidence(evidence: Path):
    if not evidence.exists():
        return
    attempts = evidence / "attempts"
    if attempts.is_symlink() or (attempts.exists() and not attempts.is_dir()):
        raise BuildError("unsafe evidence attempt history")
    items = sorted((path for path in evidence.iterdir() if path.name != "attempts"),
                   key=lambda item: os.fsencode(item.name))
    if not items:
        return
    attempts.mkdir(exist_ok=True)
    number = 1
    while (attempts / f"{number:04d}").exists():
        number += 1
    destination = attempts / f"{number:04d}"
    destination.mkdir()
    hashes = []
    for item in items:
        if item.is_symlink() or not item.is_file():
            raise BuildError(f"unsafe evidence item before retry: {item.name}")
        target = destination / item.name
        shutil.copyfile(item, target)
        hashes.append(f"{hashlib.sha256(target.read_bytes()).hexdigest()}  {item.name}\n")
    (destination / "sha256.txt").write_text("".join(hashes))
    for item in items:
        item.unlink()


def _remove_at(parent_fd: int, name: str):
    mode = os.stat(name, dir_fd=parent_fd, follow_symlinks=False).st_mode
    if stat.S_ISDIR(mode):
        child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
        try:
            for entry in os.listdir(child):
                _remove_at(child, entry)
        finally:
            os.close(child)
        os.rmdir(name, dir_fd=parent_fd)
    else:
        os.unlink(name, dir_fd=parent_fd)


def _rename_atx(parent_fd: int, first: str, second: str, flags: int):
    library = ctypes.CDLL(None, use_errno=True)
    try:
        rename = library.renameatx_np
    except AttributeError as error:
        raise BuildError("atomic prefix publication requires macOS renameatx_np") from error
    rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(parent_fd, os.fsencode(first), parent_fd, os.fsencode(second), flags):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def _rename_swap(parent_fd: int, first: str, second: str):
    _rename_atx(parent_fd, first, second, 0x00000002)  # RENAME_SWAP


def publish_prefix(stage: Path, target: Path, prefix_root: Path):
    """Publish stage relative to a pinned parent and never follow a swapped root."""
    stage, target, prefix_root = map(Path, (stage, target, prefix_root))
    if stage.parent != prefix_root or target.parent != prefix_root:
        raise BuildError("prefix publication paths are not siblings")
    try:
        with OwnedDirectory(prefix_root) as owned:
            stage_fd = os.open(stage.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                               dir_fd=owned.fd)
            try:
                before = os.fstat(stage_fd)
                identity = before.st_dev, before.st_ino
                existing = _identity(target)
                owned.check()
                published = False
                try:
                    if existing is None:
                        _rename_atx(owned.fd, stage.name, target.name, 0x00000004)  # RENAME_EXCL
                    else:
                        if existing[2] != stat.S_IFDIR:
                            raise BuildError("unsafe accepted prefix before replacement")
                        _rename_swap(owned.fd, stage.name, target.name)
                    published = True
                    actual = os.stat(target.name, dir_fd=owned.fd, follow_symlinks=False)
                    if (actual.st_dev, actual.st_ino) != identity:
                        raise BuildError("staging identity changed before publication")
                    owned.check()
                except (AcquireError, BuildError, OSError):
                    if published:
                        if existing is None:
                            _remove_at(owned.fd, target.name)
                        else:
                            _rename_swap(owned.fd, stage.name, target.name)
                    raise
                os.fsync(owned.fd)
                if existing is not None:
                    _remove_at(owned.fd, stage.name)
            finally:
                os.close(stage_fd)
    except BuildError:
        raise
    except (AcquireError, OSError) as error:
        raise BuildError("prefix root identity changed during publication") from error


def _prefix_snapshots(prefix_root: Path, excluded: set[str]) -> dict[str, str]:
    snapshots = {}
    if not prefix_root.exists():
        return snapshots
    for path in prefix_root.iterdir():
        if path.name in excluded or path.name.startswith(".staging-"):
            continue
        if path.is_symlink() or not path.is_dir():
            raise BuildError(f"unsafe accepted prefix: {path.name}")
        snapshots[path.name] = tree_digest(path)
    return snapshots


def _assert_snapshots(prefix_root: Path, snapshots: Mapping[str, str]):
    current = _prefix_snapshots(prefix_root, set())
    if current != snapshots:
        raise BuildError("cross-prefix write detected")
    for name, digest in snapshots.items():
        path = prefix_root / name
        if not path.is_dir() or path.is_symlink() or tree_digest(path) != digest:
            raise BuildError(f"cross-prefix write detected: {name}")


def _prepare_component(component: Path, evidence: Path):
    if evidence.is_symlink() or (evidence.exists() and not evidence.is_dir()):
        raise BuildError("unsafe build directory: evidence")
    evidence.mkdir(parents=True, exist_ok=True)
    _archive_evidence(evidence)
    for name in ("build", "home", "tmp"):
        path = component / name
        if path.exists() or path.is_symlink():
            if path.is_symlink() or not path.is_dir():
                raise BuildError(f"unsafe component path: {name}")
            shutil.rmtree(path)
        path.mkdir()


def _allowed_roots(paths: BuildPaths):
    return {"project": paths.project, "source": paths.source,
            "build": paths.component, "home": paths.home}


def build_all(project_root: Path, lock: DependencyLock) -> None:
    project_root = Path(os.path.abspath(project_root))
    records = topological_records(lock)
    acquire_all(project_root, lock, True)
    tools = resolve_tool_inventory()
    prefix_root = project_root / "Build/prefix"
    dependencies_root = project_root / "Build/dependencies"
    for path in (project_root / "Build", prefix_root, dependencies_root):
        if path.exists() and (path.is_symlink() or not path.is_dir()):
            raise BuildError(f"unsafe build directory: {path.name}")
        path.mkdir(exist_ok=True)
    accepted: dict[str, Path] = {}
    reports: dict[str, PrefixReport] = {}
    for record in records:
        adapter = adapter_path(project_root, record)
        _regular_executable(adapter)
        source = project_root / "Dependencies" / record.name
        component = dependencies_root / record.name
        if component.is_symlink() or (component.exists() and not component.is_dir()):
            raise BuildError(f"unsafe build directory: {record.name}")
        component.mkdir(exist_ok=True)
        evidence = component / "evidence"
        target = prefix_root / record.name
        dependency_prefixes = {name: accepted[name] for name in record.dependencies}
        dependency_reports = {name: reports[name] for name in record.dependencies}
        # Fingerprints deliberately do not include the random stage path.
        placeholder = prefix_root / f".staging-{record.name}"
        fingerprint_paths = BuildPaths(project_root, source, component, component / "build",
                                       placeholder, evidence, component / "home", component / "tmp")
        inputs = _input_document(lock, record, adapter, dependency_reports, tools)
        fingerprint_value = hashlib.sha256(_canonical_json(inputs)).hexdigest()
        fingerprint_file = evidence / "input-fingerprint.txt"
        if fingerprint_file.is_file() and fingerprint_file.read_text() == fingerprint_value + "\n":
            try:
                report = validate_prefix(record, target, _allowed_roots(fingerprint_paths))
            except PrefixError:
                pass
            else:
                accepted[record.name] = target
                reports[record.name] = report
                continue

        _prepare_component(component, evidence)
        stage = Path(tempfile.mkdtemp(prefix=f".staging-{record.name}-", dir=prefix_root))
        paths = BuildPaths(project_root, source, component, component / "build", stage,
                           evidence, component / "home", component / "tmp")
        jobs = job_count()
        options = expand_options(record, paths, jobs, tools, dependency_prefixes)
        env = _environment(record, paths, tools)
        argv = adapter_argv(record, paths, dependency_prefixes, jobs)
        protected = _prefix_snapshots(prefix_root, {stage.name})
        _write(evidence / "inputs.json", _canonical_json(inputs))
        _write(evidence / "tool-inventory.json", _canonical_json(asdict(tools)))
        _write(evidence / "expanded-options.json", _canonical_json(options))
        _write(evidence / "command.json", _canonical_json(argv))
        status = 0
        try:
            with (evidence / "adapter.log").open("wb") as log:
                try:
                    run_adapter(record, paths, dependency_prefixes, env, jobs=jobs, log=log)
                except subprocess.CalledProcessError as error:
                    status = error.returncode
            _write(evidence / "exit-status.txt", f"{status}\n")
            if status:
                raise BuildError(f"{record.name}: adapter failed; inspect {evidence / 'adapter.log'}")
            _assert_snapshots(prefix_root, protected)
            report = validate_prefix(record, stage, _allowed_roots(paths))
            _write(evidence / "prefix-report.json", _canonical_json(report.as_dict()))
            _write(evidence / "install-manifest.jsonl", report.manifest)
            licenses = [{"path": "$PREFIX/" + relative,
                         "sha256": hashlib.sha256((stage / relative).read_bytes()).hexdigest()}
                        for relative in record.license_paths]
            _write(evidence / "license-inventory.json", _canonical_json(licenses))
            publish_prefix(stage, target, prefix_root)
            stage = Path()
        except (BuildError, PrefixError, OSError) as error:
            if not (evidence / "exit-status.txt").exists():
                _write(evidence / "exit-status.txt", "1\n")
            _write(evidence / "error.txt", f"{type(error).__name__}: {error}\n")
            raise BuildError(f"{record.name}: dependency prefix validation failed: {error}") from error
        finally:
            if stage and stage != Path() and stage.exists() and stage.parent == prefix_root:
                shutil.rmtree(stage)
        report = validate_prefix(record, target, _allowed_roots(paths))
        _write(evidence / "input-fingerprint.txt", fingerprint_value + "\n")
        accepted[record.name] = target
        reports[record.name] = report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        lock = load_lock(args.project_root / "config/dependencies.lock")
        build_all(args.project_root, lock)
        print("dependency build: accepted all locked component prefixes")
    except (AcquireError, BuildError, LockError, PrefixError, OSError) as error:
        print(f"dependency build: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
