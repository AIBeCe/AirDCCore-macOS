#!/usr/bin/env python3
"""Build locked dependencies into isolated, validated ARM64 prefixes."""

from __future__ import annotations

import argparse
from contextlib import ExitStack
import ctypes
from dataclasses import asdict, dataclass, field
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Callable, Mapping

from dependency_acquire import AcquireError, OwnedDirectory, _identity, acquire_all
from dependency_lock import (DependencyLock, DependencyRecord, LockError,
                             canonical_bytes, load_lock, topological_records)
from dependency_prefix import PrefixError, PrefixReport, tree_digest, validate_prefix


class BuildError(RuntimeError):
    """A dependency build or publication failed closed."""


BUILD_ENVIRONMENT_KEYS = (
    "AR", "CC", "CXX", "HOME", "LANG", "LC_ALL",
    "MACOSX_DEPLOYMENT_TARGET", "PATCH", "PATH", "RANLIB", "SDKROOT",
    "SOURCE_DATE_EPOCH", "TMPDIR", "ZERO_AR_DATE",
)


@dataclass(frozen=True)
class ToolInventory:
    sdkroot: str
    sdk_version: str
    apple: Mapping[str, str]
    host: Mapping[str, str]
    identities: Mapping[str, Mapping[str, str]] = field(default_factory=dict)


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


@dataclass(frozen=True)
class PrefixSnapshot:
    identity: tuple[int, int, int]
    digest: str


@dataclass(frozen=True)
class EvidenceGuard:
    label: str
    parent: OwnedDirectory
    owner: OwnedDirectory
    name: str
    identity: tuple[int, int, int]
    manifest: bytes
    backup_fd: int


@dataclass(frozen=True)
class EvidenceChildGuard:
    label: str
    parent: OwnedDirectory
    name: str
    identity: tuple[int, int, int] | None
    manifest: bytes | None
    backup_fd: int | None


def _run_text(argv: tuple[str, ...]) -> str:
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"}
    result = subprocess.run(argv, capture_output=True, text=True, env=env)
    if result.returncode:
        raise BuildError(f"failed to resolve required tool: {argv[-1]}")
    return result.stdout.strip()


def _run_version(argv: tuple[str, ...]) -> str:
    result = subprocess.run(argv, capture_output=True, text=True,
                            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"})
    version = (result.stdout + result.stderr).strip()
    if result.returncode or not version:
        raise BuildError(f"failed to identify required tool: {argv[0]}")
    return version


def _trusted_host_tool(name: str, developer_root: Path) -> Path:
    # Homebrew's public links are stable across formula upgrades. The resolved
    # target must still belong to that formula's Cellar, not an arbitrary link.
    candidates = (Path("/opt/homebrew/bin") / name,
                  Path("/usr/local/bin") / name,
                  Path("/usr/bin") / name, Path("/bin") / name)
    for candidate in candidates:
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            continue
        resolved = candidate.resolve(strict=True)
        if candidate.parent in (Path("/opt/homebrew/bin"), Path("/usr/local/bin")):
            cellar = candidate.parent.parent / "Cellar" / name
            relative = resolved.relative_to(cellar) if resolved.is_relative_to(cellar) else None
            if (relative is None or len(relative.parts) < 3
                    or relative.parts[1:] != ("bin", name)):
                raise BuildError(f"untrusted Homebrew host tool: {name}")
        elif not (resolved.is_relative_to(developer_root)
                  or resolved.is_relative_to(Path("/usr/bin"))
                  or resolved.is_relative_to(Path("/bin"))):
            raise BuildError(f"untrusted system host tool: {name}")
        return resolved
    raise BuildError(f"missing required host tool: {name}")


def _version_output(name: str, invocation: Path, apple_toolchain_version: str) -> str:
    flags = {"apple.ranlib": "-V"}
    # These Apple utilities do not provide a successful version command.
    if name in ("apple.ar", "apple.lipo", "apple.strings"):
        return "Apple toolchain clang --version:\n" + apple_toolchain_version
    return _run_version((str(invocation), flags.get(name, "--version")))


def resolve_tool_inventory() -> ToolInventory:
    apple_names = {
        "cc": "clang", "cxx": "clang++", "ar": "ar", "ranlib": "ranlib",
        "lipo": "lipo", "nm": "nm", "otool": "otool", "strings": "strings",
    }
    xcrun = "/usr/bin/xcrun"
    apple = {key: _run_text((xcrun, "--find", name)) for key, name in apple_names.items()}
    sdkroot = _run_text((xcrun, "--sdk", "macosx", "--show-sdk-path"))
    sdk_version = _run_text((xcrun, "--sdk", "macosx", "--show-sdk-version"))
    developer_root = Path(_run_text((xcrun, "--show-toolchain-path"))).parent.parent
    host = {name: str(_trusted_host_tool(name, developer_root))
            for name in ("cmake", "ninja", "perl", "make")}
    # Boost's one reviewed patch uses Apple's patch explicitly, independent of PATH.
    host["patch"] = "/usr/bin/patch"
    if not Path(xcrun).is_file():
        raise BuildError("missing required Apple tool: xcrun")
    identities = {}
    discovered = {**{f"apple.{key}": value for key, value in apple.items()},
                  **{f"host.{key}": value for key, value in host.items()},
                  "xcrun": xcrun}
    apple_toolchain_version = _run_version((apple["cc"], "--version"))
    for name, path in discovered.items():
        invocation = Path(path).absolute()
        resolved = Path(path).resolve(strict=True)
        if not resolved.is_file() or not os.access(resolved, os.X_OK):
            raise BuildError(f"unsafe tool executable: {name}")
        identities[name] = {"invocation_path": str(invocation),
                            "resolved_path": str(resolved),
                            "sha256": hashlib.sha256(resolved.read_bytes()).hexdigest(),
                            "version": _version_output(name, invocation, apple_toolchain_version)}
    return ToolInventory(sdkroot, sdk_version, apple, host, identities)


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
    apple = _pinned_tools(tools.apple, tools.identities, "apple")
    host = _pinned_tools(tools.host, tools.identities, "host")
    tool_dirs = []
    for value in (*apple.values(), *host.values(), "/usr/bin/xcrun",
                  "/usr/bin/sh", "/bin/sh"):
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
        "CC": apple["cc"], "CXX": apple["cxx"],
        "AR": apple["ar"], "RANLIB": apple["ranlib"],
        "PATCH": host["patch"],
        "LC_ALL": "C", "LANG": "C",
    }


def _pinned_tools(paths: Mapping[str, str],
                  identities: Mapping[str, Mapping[str, str]], kind: str) -> dict[str, str]:
    # The alias selects driver behavior (clang++/ranlib); resolved content is
    # retained separately in the fingerprint, rather than used as argv[0].
    pinned = {}
    for name, path in paths.items():
        identity = identities.get(f"{kind}.{name}", {})
        invocation = identity.get("invocation_path", path)
        if "invocation_path" in identity:
            try:
                resolved = Path(invocation).resolve(strict=True)
                unchanged = (str(resolved) == identity.get("resolved_path")
                             and resolved.is_file() and os.access(resolved, os.X_OK)
                             and hashlib.sha256(resolved.read_bytes()).hexdigest()
                             == identity.get("sha256"))
            except (OSError, RuntimeError) as error:
                raise BuildError(f"inventoried tool is unavailable: {kind}.{name}") from error
            if not unchanged:
                raise BuildError(f"inventoried tool identity changed: {kind}.{name}")
        pinned[name] = invocation
    return pinned


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


def _write_descriptor(owner: OwnedDirectory, name: str, data: bytes | str,
                      *, check_path: bool):
    raw = data.encode() if isinstance(data, str) else data
    if check_path:
        owner.check()
    else:
        _check_open_directory(owner)
    temporary = "." + name + "." + secrets.token_hex(16) + ".tmp"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 0o600, dir_fd=owner.fd)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        if check_path:
            owner.check()
        else:
            _check_open_directory(owner)
        os.replace(temporary, name, src_dir_fd=owner.fd, dst_dir_fd=owner.fd)
        if check_path:
            owner.check()
        else:
            _check_open_directory(owner)
    finally:
        try:
            os.unlink(temporary, dir_fd=owner.fd)
        except FileNotFoundError:
            pass


def _write(path: Path, data: bytes | str, owner: OwnedDirectory | None = None):
    if owner is None:
        with OwnedDirectory(path.parent) as opened:
            _write(path, data, opened)
        return
    _write_descriptor(owner, path.name, data, check_path=True)


def _write_owned(owner: OwnedDirectory, name: str, data: bytes | str):
    """Write through the pinned directory even after its public path moved."""
    _write_descriptor(owner, name, data, check_path=False)


def _input_document(lock: DependencyLock, record: DependencyRecord, adapter: Path,
                    dependency_reports: Mapping[str, PrefixReport], tools: ToolInventory):
    helpers = []
    # Shared execution helpers affect every adapter, even if this record does
    # not import them directly. Conservative invalidation avoids stale reuse.
    for helper in sorted(adapter.parent.glob("*.py"), key=lambda path: path.name):
        try:
            before = helper.lstat()
            if not stat.S_ISREG(before.st_mode):
                raise BuildError(f"unsafe dependency adapter helper: {helper.name}")
            fd = os.open(helper, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as stream:
                opened = os.fstat(stream.fileno())
                if (not stat.S_ISREG(opened.st_mode)
                        or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)):
                    raise BuildError(f"unsafe dependency adapter helper: {helper.name}")
                digest = hashlib.sha256(stream.read()).hexdigest()
        except OSError as error:
            raise BuildError(f"unsafe dependency adapter helper: {helper.name}") from error
        helpers.append({"path": f"scripts/lib/dependencies/{helper.name}", "sha256": digest})
    return {
        "lock_sha256": hashlib.sha256(canonical_bytes(lock)).hexdigest(),
        "source": {"kind": record.source.kind,
                   "identity": record.source.commit or record.source.archive_sha256,
                   "tree_manifest_sha256": record.source.tree_manifest_sha256},
        "adapter": {"path": f"scripts/lib/dependencies/{adapter.name}",
                    "sha256": hashlib.sha256(adapter.read_bytes()).hexdigest()},
        "adapter_helpers": helpers,
        "dependencies": [{"name": name,
                          "manifest_sha256": dependency_reports[name].manifest_sha256}
                         for name in record.dependencies],
        "tools": asdict(tools),
        "sdk_version": tools.sdk_version,
    }


def _accepted_evidence_matches(record: DependencyRecord, target: Path,
                               evidence: Path, report: PrefixReport) -> bool:
    expected = {
        "prefix-report.json": _canonical_json(report.as_dict()),
        "install-manifest.jsonl": report.manifest.encode(),
        "license-inventory.json": _canonical_json([
            {"path": "$PREFIX/" + relative,
             "sha256": hashlib.sha256((target / relative).read_bytes()).hexdigest()}
            for relative in record.license_paths]),
        "exit-status.txt": b"0\n",
    }
    for name, content in expected.items():
        path = evidence / name
        if path.is_symlink() or not path.is_file() or path.read_bytes() != content:
            return False
    return True


def _archive_evidence(evidence: Path):
    if not evidence.exists():
        return
    try:
        with OwnedDirectory(evidence) as current:
            items = sorted((name for name in os.listdir(current.fd) if name != "attempts"),
                           key=os.fsencode)
            if not items:
                return
            try:
                os.mkdir("attempts", dir_fd=current.fd)
            except FileExistsError:
                pass
            with OwnedDirectory(evidence / "attempts") as attempts:
                number = 1
                while _identity(evidence / "attempts" / f"{number:04d}") is not None:
                    number += 1
                pending = ".pending-" + secrets.token_hex(16)
                os.mkdir(pending, 0o700, dir_fd=attempts.fd)
                try:
                    with OwnedDirectory(evidence / "attempts" / pending) as destination:
                        hashes = []
                        for name in items:
                            source_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW,
                                                dir_fd=current.fd)
                            try:
                                if not stat.S_ISREG(os.fstat(source_fd).st_mode):
                                    raise BuildError(f"unsafe evidence item before retry: {name}")
                                target_fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                                    | os.O_NOFOLLOW, 0o600, dir_fd=destination.fd)
                                with os.fdopen(os.dup(source_fd), "rb") as source_stream, \
                                     os.fdopen(target_fd, "wb") as target_stream:
                                    shutil.copyfileobj(source_stream, target_stream)
                                copied_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW,
                                                    dir_fd=destination.fd)
                                with os.fdopen(copied_fd, "rb") as copied:
                                    digest = hashlib.file_digest(copied, "sha256").hexdigest()
                                hashes.append(f"{digest}  {name}\n")
                            finally:
                                os.close(source_fd)
                            current.check()
                            attempts.check()
                            destination.check()
                        _write(evidence / "attempts" / pending / "sha256.txt",
                               "".join(hashes), destination)
                    attempts.check()
                    current.check()
                    _rename_atx(attempts.fd, pending, f"{number:04d}", 0x00000004)
                    for name in items:
                        os.unlink(name, dir_fd=current.fd)
                finally:
                    if _identity(evidence / "attempts" / pending) is not None:
                        _remove_at(attempts.fd, pending)
    except (AcquireError, OSError) as error:
        raise BuildError("unsafe evidence attempt history") from error


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


def _identity_at(parent_fd: int, name: str):
    try:
        info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    return info.st_dev, info.st_ino, stat.S_IFMT(info.st_mode)


def _check_open_directory(owner: OwnedDirectory):
    """Verify the open object without reacquiring its possibly substituted path."""
    info = os.fstat(owner.fd)
    expected = owner.identities[owner.path]
    if (info.st_dev, info.st_ino, stat.S_IFMT(info.st_mode)) != expected:
        raise BuildError("owned build directory identity changed")


def _directory_manifest_fd(root_fd: int) -> bytes:
    entries = []

    def visit(directory_fd: int, parent: tuple[str, ...]):
        for name in sorted(os.listdir(directory_fd), key=os.fsencode):
            relative_parts = (*parent, name)
            relative = "/".join(relative_parts)
            info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            mode = info.st_mode
            if stat.S_ISLNK(mode):
                entries.append({"path": relative, "type": "symlink",
                                "target": os.readlink(name, dir_fd=directory_fd)})
            elif stat.S_ISDIR(mode):
                entries.append({"path": relative, "type": "directory"})
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=directory_fd)
                try:
                    visit(child, relative_parts)
                finally:
                    os.close(child)
            elif stat.S_ISREG(mode):
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
                try:
                    with os.fdopen(fd, "rb") as stream:
                        digest = hashlib.file_digest(stream, "sha256").hexdigest()
                    fd = -1
                finally:
                    if fd >= 0:
                        os.close(fd)
                entries.append({"path": relative, "type": "file", "sha256": digest,
                                "executable": bool(mode & 0o111)})
            else:
                raise BuildError(f"unsafe prefix entry: {relative}")

    visit(root_fd, ())
    return b"".join((json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n").encode()
                    for entry in entries)


def _tree_digest_fd(root_fd: int) -> str:
    return hashlib.sha256(_directory_manifest_fd(root_fd)).hexdigest()


def _child_digest(parent_fd: int, name: str) -> str:
    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        return _tree_digest_fd(child)
    finally:
        os.close(child)


def _copy_directory_fd_to_path(source_fd: int, destination: Path):
    destination.mkdir()
    for name in sorted(os.listdir(source_fd), key=os.fsencode):
        info = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
        target = destination / name
        if stat.S_ISDIR(info.st_mode):
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=source_fd)
            try:
                _copy_directory_fd_to_path(child, target)
            finally:
                os.close(child)
        elif stat.S_ISREG(info.st_mode):
            source = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=source_fd)
            try:
                with os.fdopen(source, "rb") as input_stream, target.open("xb") as output_stream:
                    shutil.copyfileobj(input_stream, output_stream)
                source = -1
            finally:
                if source >= 0:
                    os.close(source)
            target.chmod(stat.S_IMODE(info.st_mode))
        elif stat.S_ISLNK(info.st_mode):
            target.symlink_to(os.readlink(name, dir_fd=source_fd))
        else:
            raise BuildError(f"unsafe protected prefix entry: {name}")


def _copy_directory_fd(source_fd: int, destination_fd: int):
    """Copy a directory tree without reacquiring either directory by pathname."""
    for name in sorted(os.listdir(source_fd), key=os.fsencode):
        info = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            os.mkdir(name, stat.S_IMODE(info.st_mode), dir_fd=destination_fd)
            source_child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                   dir_fd=source_fd)
            destination_child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                        dir_fd=destination_fd)
            try:
                _copy_directory_fd(source_child, destination_child)
                os.fsync(destination_child)
            finally:
                os.close(destination_child)
                os.close(source_child)
        elif stat.S_ISREG(info.st_mode):
            source = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=source_fd)
            target = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             stat.S_IMODE(info.st_mode), dir_fd=destination_fd)
            try:
                with os.fdopen(os.dup(source), "rb") as input_stream, \
                     os.fdopen(os.dup(target), "wb") as output_stream:
                    shutil.copyfileobj(input_stream, output_stream)
                    output_stream.flush()
                    os.fsync(output_stream.fileno())
                os.fchmod(target, stat.S_IMODE(info.st_mode))
            finally:
                os.close(target)
                os.close(source)
        elif stat.S_ISLNK(info.st_mode):
            os.symlink(os.readlink(name, dir_fd=source_fd), name, dir_fd=destination_fd)
        else:
            raise BuildError(f"unsafe evidence entry: {name}")


def _clear_directory_fd(directory_fd: int):
    for name in os.listdir(directory_fd):
        _remove_at(directory_fd, name)


def _restore_directory_contents(directory_fd: int, backup_fd: int, manifest: bytes):
    _clear_directory_fd(directory_fd)
    _copy_directory_fd(backup_fd, directory_fd)
    os.fsync(directory_fd)
    if _directory_manifest_fd(directory_fd) != manifest:
        raise BuildError("failed to restore protected evidence")


def _make_backup_fd(backup_root_fd: int, name: str, source_fd: int) -> int:
    os.mkdir(name, 0o700, dir_fd=backup_root_fd)
    backup_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=backup_root_fd)
    try:
        _copy_directory_fd(source_fd, backup_fd)
        os.fsync(backup_fd)
    except Exception:
        os.close(backup_fd)
        raise
    return backup_fd


def _copy_path_to_directory_fd(source: Path, destination_fd: int, name: str):
    info = source.lstat()
    if not stat.S_ISDIR(info.st_mode):
        raise BuildError(f"unsafe protected prefix backup: {name}")
    os.mkdir(name, stat.S_IMODE(info.st_mode), dir_fd=destination_fd)
    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=destination_fd)
    try:
        for source_child in sorted(source.iterdir(), key=lambda item: os.fsencode(item.name)):
            child_info = source_child.lstat()
            if stat.S_ISDIR(child_info.st_mode):
                _copy_path_to_directory_fd(source_child, child, source_child.name)
            elif stat.S_ISREG(child_info.st_mode):
                output = os.open(source_child.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                 | os.O_NOFOLLOW, stat.S_IMODE(child_info.st_mode), dir_fd=child)
                try:
                    with source_child.open("rb") as input_stream, os.fdopen(output, "wb") as output_stream:
                        shutil.copyfileobj(input_stream, output_stream)
                    output = -1
                finally:
                    if output >= 0:
                        os.close(output)
            elif stat.S_ISLNK(child_info.st_mode):
                os.symlink(os.readlink(source_child), source_child.name, dir_fd=child)
            else:
                raise BuildError(f"unsafe protected prefix backup: {source_child.name}")
    finally:
        os.close(child)


def _cleanup_stage_owned(prefix_owner: OwnedDirectory,
                         expected_identity: tuple[int, int, int] | None):
    if expected_identity is None:
        return
    _check_open_directory(prefix_owner)
    current_name = _identity_name(prefix_owner.fd, expected_identity)
    if current_name is None:
        return
    quarantine = ".cleanup-" + secrets.token_hex(16)
    _rename_atx(prefix_owner.fd, current_name, quarantine, 0x00000004)
    if _identity_at(prefix_owner.fd, quarantine) == expected_identity:
        _remove_at(prefix_owner.fd, quarantine)


def _rename_atx(parent_fd: int, first: str, second: str, flags: int):
    _rename_between_atx(parent_fd, first, parent_fd, second, flags)


def _rename_between_atx(source_fd: int, first: str,
                        destination_fd: int, second: str, flags: int):
    library = ctypes.CDLL(None, use_errno=True)
    try:
        rename = library.renameatx_np
    except AttributeError as error:
        raise BuildError("atomic prefix publication requires macOS renameatx_np") from error
    rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(source_fd, os.fsencode(first), destination_fd, os.fsencode(second), flags):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def _rename_swap(parent_fd: int, first: str, second: str):
    _rename_atx(parent_fd, first, second, 0x00000002)  # RENAME_SWAP


def publish_prefix(stage: Path, target: Path, prefix_root: Path,
                   *, expected_stage: tuple[int, int, int] | None = None,
                   expected_digest: str | None = None,
                   finalize: Callable[[], None] | None = None):
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
                if expected_stage is not None and _identity(stage) != expected_stage:
                    raise BuildError("validated staging identity changed before publication")
                if expected_digest is not None and tree_digest(stage) != expected_digest:
                    raise BuildError("validated staging tree changed before publication")
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
                    if existing is not None and _identity(stage) != existing:
                        raise BuildError("accepted target identity changed before publication")
                    if expected_digest is not None and tree_digest(target) != expected_digest:
                        raise BuildError("validated staging tree changed during publication")
                    owned.check()
                    if finalize is not None:
                        finalize()
                    if _identity(target) is None or _identity(target)[:2] != identity:
                        raise BuildError("published target identity changed before acceptance")
                    if expected_digest is not None and tree_digest(target) != expected_digest:
                        raise BuildError("published target tree changed before acceptance")
                    owned.check()
                except (AcquireError, BuildError, PrefixError, OSError):
                    if published:
                        if existing is None:
                            if (_identity(target) is not None
                                    and _identity(target)[:2] == identity):
                                _remove_at(owned.fd, target.name)
                        else:
                            if _identity(stage) != existing:
                                raise BuildError("prior prefix identity changed before rollback")
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


def _prefix_snapshots(prefix_owner: OwnedDirectory,
                      excluded: set[str]) -> dict[str, PrefixSnapshot]:
    snapshots = {}
    _check_open_directory(prefix_owner)
    for name in os.listdir(prefix_owner.fd):
        if name in excluded:
            continue
        identity = _identity_at(prefix_owner.fd, name)
        if identity is None or identity[2] != stat.S_IFDIR:
            raise BuildError(f"unsafe accepted prefix: {name}")
        snapshots[name] = PrefixSnapshot(identity, _child_digest(prefix_owner.fd, name))
    return snapshots


def _assert_snapshots(prefix_owner: OwnedDirectory, snapshots: Mapping[str, PrefixSnapshot],
                      excluded: set[str]):
    current = _prefix_snapshots(prefix_owner, excluded)
    if current != snapshots:
        raise BuildError("cross-prefix write detected")
    for name, snapshot in snapshots.items():
        if (_identity_at(prefix_owner.fd, name) != snapshot.identity
                or _child_digest(prefix_owner.fd, name) != snapshot.digest):
            raise BuildError(f"cross-prefix write detected: {name}")


def _identity_name(parent_fd: int, expected: tuple[int, int, int]) -> str | None:
    for name in os.listdir(parent_fd):
        try:
            item = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        identity = item.st_dev, item.st_ino, stat.S_IFMT(item.st_mode)
        if identity == expected:
            return name
    return None


def _restore_snapshots(build_owner: OwnedDirectory, prefix_owner: OwnedDirectory,
                       backup: Path, stage_name: str,
                       stage_identity: tuple[int, int, int],
                       snapshots: Mapping[str, PrefixSnapshot]):
    quarantine_fd = None

    def quarantine(name: str):
        nonlocal quarantine_fd
        _check_open_directory(build_owner)
        _check_open_directory(prefix_owner)
        if quarantine_fd is None:
            quarantine_name = ".prefix-quarantine-" + secrets.token_hex(16)
            os.mkdir(quarantine_name, 0o700, dir_fd=build_owner.fd)
            quarantine_fd = os.open(quarantine_name, os.O_RDONLY | os.O_DIRECTORY
                                    | os.O_NOFOLLOW, dir_fd=build_owner.fd)
        expected = _identity_at(prefix_owner.fd, name)
        _rename_between_atx(prefix_owner.fd, name, quarantine_fd, name, 0x00000004)
        moved = _identity_at(quarantine_fd, name)
        if moved != expected:
            raise BuildError(f"substituted prefix identity changed during quarantine: {name}")

    try:
        _restore_snapshots_owned(backup, stage_name, stage_identity,
                                 snapshots, prefix_owner, quarantine)
    finally:
        if quarantine_fd is not None:
            os.close(quarantine_fd)


def _restore_snapshots_owned(backup: Path, stage_name: str,
                             stage_identity: tuple[int, int, int],
                             snapshots: Mapping[str, PrefixSnapshot],
                             owned: OwnedDirectory, quarantine: Callable[[str], None]):
    _check_open_directory(owned)
    for name, snapshot in snapshots.items():
        current = _identity_at(owned.fd, name)
        if (current == snapshot.identity
                and _child_digest(owned.fd, name) == snapshot.digest):
            continue
        original_name = _identity_name(owned.fd, snapshot.identity)
        if original_name == name:
            _remove_at(owned.fd, name)
            _copy_path_to_directory_fd(backup / name, owned.fd, name)
            continue
        if original_name is not None:
            if current == stage_identity and original_name == stage_name:
                _rename_swap(owned.fd, stage_name, name)
                continue
            if current is not None:
                if current == stage_identity:
                    stage_current = _identity_at(owned.fd, stage_name)
                    if stage_current is not None:
                        quarantine(stage_name)
                    _rename_atx(owned.fd, name, stage_name, 0x00000004)
                else:
                    quarantine(name)
            _rename_atx(owned.fd, original_name, name, 0x00000004)
            continue
        if current is not None:
            quarantine(name)
        _copy_path_to_directory_fd(backup / name, owned.fd, name)

    for name in os.listdir(owned.fd):
        if name in snapshots:
            continue
        if name == stage_name and _identity_at(owned.fd, name) == stage_identity:
            continue
        if _identity_at(owned.fd, name) == stage_identity:
            _remove_at(owned.fd, name)
        else:
            quarantine(name)

    for name, snapshot in snapshots.items():
        _check_open_directory(owned)
        if (_identity_at(owned.fd, name) is None
                or _child_digest(owned.fd, name) != snapshot.digest):
            raise BuildError(f"failed to restore protected prefix: {name}")
    _check_open_directory(owned)


def _snapshot_evidence(label: str, parent: OwnedDirectory, owner: OwnedDirectory,
                       name: str, backup_root_fd: int, backup_name: str) -> EvidenceGuard:
    _check_open_directory(parent)
    _check_open_directory(owner)
    identity = _identity_at(parent.fd, name)
    opened = os.fstat(owner.fd)
    owner_identity = opened.st_dev, opened.st_ino, stat.S_IFMT(opened.st_mode)
    if identity != owner_identity:
        raise BuildError(f"protected evidence binding changed before adapter: {label}")
    manifest = _directory_manifest_fd(owner.fd)
    backup_fd = _make_backup_fd(backup_root_fd, backup_name, owner.fd)
    return EvidenceGuard(label, parent, owner, name, owner_identity, manifest, backup_fd)


def _snapshot_evidence_child(label: str, parent: OwnedDirectory, name: str,
                             backup_root_fd: int, backup_name: str) -> EvidenceChildGuard:
    _check_open_directory(parent)
    identity = _identity_at(parent.fd, name)
    if identity is None:
        return EvidenceChildGuard(label, parent, name, None, None, None)
    if identity[2] != stat.S_IFDIR:
        raise BuildError(f"unsafe protected evidence directory: {label}")
    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent.fd)
    try:
        manifest = _directory_manifest_fd(child)
        backup_fd = _make_backup_fd(backup_root_fd, backup_name, child)
    finally:
        os.close(child)
    return EvidenceChildGuard(label, parent, name, identity, manifest, backup_fd)


def _publish_restored_evidence(guard: EvidenceGuard):
    """Restore a deleted evidence directory below its pinned component parent."""
    _check_open_directory(guard.parent)
    recovery_name = ".evidence-recovery-" + secrets.token_hex(16)
    recovery_identity = None
    published = False
    try:
        os.mkdir(recovery_name, 0o700, dir_fd=guard.parent.fd)
        recovery_identity = _identity_at(guard.parent.fd, recovery_name)
        recovery = os.open(recovery_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                           dir_fd=guard.parent.fd)
        try:
            _copy_directory_fd(guard.backup_fd, recovery)
            os.fsync(recovery)
            if _directory_manifest_fd(recovery) != guard.manifest:
                raise BuildError(f"protected evidence backup could not be restored: {guard.label}")
        finally:
            os.close(recovery)

        _check_open_directory(guard.parent)
        if _identity_at(guard.parent.fd, guard.name) is not None:
            raise BuildError(f"protected evidence binding changed during restoration: {guard.label}")
        _rename_atx(guard.parent.fd, recovery_name, guard.name, 0x00000004)
        published = True
        os.fsync(guard.parent.fd)
        if _identity_at(guard.parent.fd, guard.name) != recovery_identity:
            raise BuildError(f"protected evidence binding changed during restoration: {guard.label}")
        restored = os.open(guard.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                           dir_fd=guard.parent.fd)
        try:
            if _directory_manifest_fd(restored) != guard.manifest:
                raise BuildError(f"protected evidence could not be restored: {guard.label}")
        finally:
            os.close(restored)
    finally:
        if not published and recovery_identity is not None:
            if _identity_at(guard.parent.fd, recovery_name) == recovery_identity:
                _remove_at(guard.parent.fd, recovery_name)


def _repair_evidence_guard(guard: EvidenceGuard) -> bool:
    """Restore evidence content and binding using only descriptors opened pre-adapter."""
    _check_open_directory(guard.parent)
    _check_open_directory(guard.owner)
    changed = False
    current = _identity_at(guard.parent.fd, guard.name)
    if current != guard.identity:
        changed = True
        original_name = _identity_name(guard.parent.fd, guard.identity)
        if original_name is None:
            if current is None:
                _publish_restored_evidence(guard)
                return True
            if current[2] == stat.S_IFDIR:
                replacement = os.open(guard.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                      dir_fd=guard.parent.fd)
                try:
                    if _directory_manifest_fd(replacement) == guard.manifest:
                        return True
                finally:
                    os.close(replacement)
            raise BuildError(f"protected evidence binding could not be restored: {guard.label}")
        if current is not None:
            _remove_at(guard.parent.fd, guard.name)
        _rename_atx(guard.parent.fd, original_name, guard.name, 0x00000004)
    if _directory_manifest_fd(guard.owner.fd) != guard.manifest:
        changed = True
        _restore_directory_contents(guard.owner.fd, guard.backup_fd, guard.manifest)
    if (_identity_at(guard.parent.fd, guard.name) != guard.identity
            or _directory_manifest_fd(guard.owner.fd) != guard.manifest):
        raise BuildError(f"protected evidence could not be restored: {guard.label}")
    return changed


def _repair_evidence_child(guard: EvidenceChildGuard) -> bool:
    """Restore a protected evidence child relative to its pinned parent."""
    _check_open_directory(guard.parent)
    current = _identity_at(guard.parent.fd, guard.name)
    if guard.identity is None:
        if current is None:
            return False
        _remove_at(guard.parent.fd, guard.name)
        if _identity_at(guard.parent.fd, guard.name) is not None:
            raise BuildError(f"protected evidence could not be restored: {guard.label}")
        return True

    changed = False
    identity_lost = False
    if current != guard.identity:
        changed = True
        original_name = _identity_name(guard.parent.fd, guard.identity)
        if current is not None:
            _remove_at(guard.parent.fd, guard.name)
        if original_name is not None:
            _rename_atx(guard.parent.fd, original_name, guard.name, 0x00000004)
        else:
            os.mkdir(guard.name, 0o700, dir_fd=guard.parent.fd)
            identity_lost = True
    child = os.open(guard.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=guard.parent.fd)
    try:
        if _directory_manifest_fd(child) != guard.manifest:
            changed = True
            _restore_directory_contents(child, guard.backup_fd, guard.manifest)
        if _directory_manifest_fd(child) != guard.manifest:
            raise BuildError(f"protected evidence could not be restored: {guard.label}")
    finally:
        os.close(child)
    if identity_lost:
        raise BuildError(f"protected evidence identity could not be restored: {guard.label}")
    return changed


def _repair_evidence(guards: tuple[EvidenceGuard, ...],
                     child_guards: tuple[EvidenceChildGuard, ...]) -> tuple[str, ...]:
    changed = []
    failures = []
    for guard in guards:
        try:
            if _repair_evidence_guard(guard):
                changed.append(guard.label)
        except (BuildError, OSError) as error:
            failures.append(f"{guard.label}: {error}")
    for guard in child_guards:
        try:
            if _repair_evidence_child(guard):
                changed.append(guard.label)
        except (BuildError, OSError) as error:
            failures.append(f"{guard.label}: {error}")
    if failures:
        raise BuildError("failed to preserve protected evidence: " + "; ".join(failures))
    return tuple(changed)


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


def build_all(project_root: Path, lock: DependencyLock, *, force_rebuild: bool = False) -> None:
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
        if evidence.is_symlink() or (evidence.exists() and not evidence.is_dir()):
            raise BuildError("unsafe build directory: evidence")
        if evidence.exists():
            with OwnedDirectory(evidence) as existing_evidence:
                if (not fingerprint_file.is_symlink() and fingerprint_file.is_file()
                        and fingerprint_file.read_text() == fingerprint_value + "\n"):
                    try:
                        report = validate_prefix(record, target, _allowed_roots(fingerprint_paths),
                                                 tools=_pinned_tools(tools.apple, tools.identities, "apple"))
                    except PrefixError as error:
                        raise BuildError(f"{record.name}: accepted output drift: {error}") from error
                    else:
                        if not _accepted_evidence_matches(record, target, evidence, report):
                            raise BuildError(f"{record.name}: accepted output drift in evidence or prefix")
                        existing_evidence.check()
                        if not force_rebuild:
                            accepted[record.name] = target
                            reports[record.name] = report
                            continue

        _prepare_component(component, evidence)
        stage = Path(tempfile.mkdtemp(prefix=f".staging-{record.name}-", dir=prefix_root))
        stage_identity = _identity(stage)
        paths = BuildPaths(project_root, source, component, component / "build", stage,
                           evidence, component / "home", component / "tmp")
        jobs = job_count()
        options = expand_options(record, paths, jobs, tools, dependency_prefixes)
        env = _environment(record, paths, tools)
        argv = adapter_argv(record, paths, dependency_prefixes, jobs)
        ownership = ExitStack()
        backup = None
        evidence_backup = None
        try:
            build_owner = ownership.enter_context(OwnedDirectory(project_root / "Build"))
            prefix_owner = ownership.enter_context(OwnedDirectory(prefix_root))
            protected = _prefix_snapshots(prefix_owner, {stage.name})
            backup = Path(tempfile.mkdtemp(prefix="airdc-protected-prefixes-"))
            for name in protected:
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=prefix_owner.fd)
                try:
                    _copy_directory_fd_to_path(child, backup / name)
                finally:
                    os.close(child)
            evidence_backup = Path(tempfile.mkdtemp(prefix="airdc-evidence-backups-"))
            evidence_backup_fd = os.open(evidence_backup, os.O_RDONLY | os.O_DIRECTORY
                                         | os.O_NOFOLLOW)
            ownership.callback(os.close, evidence_backup_fd)
            evidence_owner = ownership.enter_context(OwnedDirectory(evidence))
            attempts_guard = _snapshot_evidence_child(
                f"{record.name} attempt history", evidence_owner, "attempts",
                evidence_backup_fd, "current-attempts",
            )
            if attempts_guard.backup_fd is not None:
                ownership.callback(os.close, attempts_guard.backup_fd)
            evidence_guards = []
            for accepted_name in accepted:
                accepted_component = dependencies_root / accepted_name
                accepted_component_owner = ownership.enter_context(
                    OwnedDirectory(accepted_component)
                )
                accepted_evidence_owner = ownership.enter_context(
                    OwnedDirectory(accepted_component / "evidence")
                )
                guard = _snapshot_evidence(
                    f"{accepted_name} accepted evidence", accepted_component_owner,
                    accepted_evidence_owner, "evidence", evidence_backup_fd,
                    f"accepted-{accepted_name}",
                )
                ownership.callback(os.close, guard.backup_fd)
                evidence_guards.append(guard)
            evidence_guards = tuple(evidence_guards)
            evidence_child_guards = (attempts_guard,)
        except Exception:
            ownership.close()
            if backup is not None:
                shutil.rmtree(backup)
            if evidence_backup is not None:
                shutil.rmtree(evidence_backup)
            raise
        status = 0
        try:
            _write(evidence / "inputs.json", _canonical_json(inputs), evidence_owner)
            _write(evidence / "tool-inventory.json", _canonical_json(asdict(tools)), evidence_owner)
            _write(evidence / "expanded-options.json", _canonical_json(options), evidence_owner)
            _write(evidence / "command.json", _canonical_json(argv), evidence_owner)
            log_fd = os.open("adapter.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=evidence_owner.fd)
            with os.fdopen(log_fd, "wb") as log:
                try:
                    run_adapter(record, paths, dependency_prefixes, env, jobs=jobs, log=log)
                except subprocess.CalledProcessError as error:
                    status = error.returncode
            changed_evidence = _repair_evidence(evidence_guards, evidence_child_guards)
            if changed_evidence:
                raise BuildError("protected evidence changed and was restored: "
                                 + ", ".join(changed_evidence))
            _write_owned(evidence_owner, "exit-status.txt", f"{status}\n")
            try:
                build_owner.check()
                prefix_owner.check()
                _assert_snapshots(prefix_owner, protected, {stage.name})
            except (AcquireError, BuildError, PrefixError, OSError) as error:
                _restore_snapshots(build_owner, prefix_owner, backup, stage.name,
                                   stage_identity, protected)
                raise BuildError("cross-prefix write detected and restored") from error
            if status:
                raise BuildError(f"{record.name}: adapter failed; inspect {evidence / 'adapter.log'}")
            validated_identity = _identity(stage)
            validated_digest = tree_digest(stage)
            report = validate_prefix(record, stage, _allowed_roots(paths),
                                     tools=_pinned_tools(tools.apple, tools.identities, "apple"))
            if _identity(stage) != validated_identity or tree_digest(stage) != validated_digest:
                raise BuildError("validated staging tree changed during validation")
            _write(evidence / "prefix-report.json", _canonical_json(report.as_dict()), evidence_owner)
            _write(evidence / "install-manifest.jsonl", report.manifest, evidence_owner)
            licenses = [{"path": "$PREFIX/" + relative,
                         "sha256": hashlib.sha256((stage / relative).read_bytes()).hexdigest()}
                        for relative in record.license_paths]
            _write(evidence / "license-inventory.json", _canonical_json(licenses), evidence_owner)
            final_report = None

            def finalize_publication():
                nonlocal final_report
                evidence_owner.check()
                checked = validate_prefix(record, target, _allowed_roots(paths),
                                          tools=_pinned_tools(tools.apple, tools.identities, "apple"))
                if checked.manifest != report.manifest:
                    raise BuildError("validated staging report changed during publication")
                _write(evidence / "input-fingerprint.txt", fingerprint_value + "\n",
                       evidence_owner)
                final_report = checked

            publish_prefix(stage, target, prefix_root, expected_stage=validated_identity,
                           expected_digest=validated_digest, finalize=finalize_publication)
            stage = Path()
        except (AcquireError, BuildError, PrefixError, OSError) as error:
            try:
                changed_evidence = _repair_evidence(evidence_guards, evidence_child_guards)
                if changed_evidence:
                    error = BuildError("protected evidence changed and was restored: "
                                       + ", ".join(changed_evidence))
            except (AcquireError, BuildError, OSError) as recovery_error:
                error = recovery_error
            try:
                build_owner.check()
                prefix_owner.check()
                _assert_snapshots(prefix_owner, protected, {stage.name})
            except (AcquireError, BuildError, PrefixError, OSError):
                _restore_snapshots(build_owner, prefix_owner, backup, stage.name,
                                   stage_identity, protected)
            try:
                _check_open_directory(evidence_owner)
                try:
                    os.unlink("input-fingerprint.txt", dir_fd=evidence_owner.fd)
                except FileNotFoundError:
                    pass
                if _identity_at(evidence_owner.fd, "exit-status.txt") is None:
                    _write_owned(evidence_owner, "exit-status.txt", f"{status or 1}\n")
                _write_owned(evidence_owner, "error.txt",
                             f"{type(error).__name__}: {error}\n")
            except (AcquireError, BuildError, OSError) as evidence_error:
                error = BuildError(f"failure evidence could not be preserved: {evidence_error}")
            raise BuildError(f"{record.name}: dependency prefix validation failed: {error}") from error
        finally:
            try:
                if stage and stage != Path() and stage.parent == prefix_root:
                    _cleanup_stage_owned(prefix_owner, stage_identity)
            finally:
                ownership.close()
                shutil.rmtree(backup)
                shutil.rmtree(evidence_backup)
        accepted[record.name] = target
        reports[record.name] = final_report


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
