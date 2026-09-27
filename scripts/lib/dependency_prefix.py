#!/usr/bin/env python3
"""Validate one staged or accepted dependency prefix without trusting metadata."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tempfile
from typing import Mapping

from dependency_lock import DependencyRecord


class PrefixError(ValueError):
    """A component prefix violates the locked static-library contract."""


@dataclass(frozen=True)
class ArchiveReport:
    path: str
    sha256: str
    members: tuple[str, ...]
    architectures: tuple[str, ...]
    defined_symbols: tuple[str, ...]
    undefined_symbols: tuple[str, ...]
    build_versions: tuple[str, ...]


@dataclass(frozen=True)
class PrefixReport:
    name: str
    role: str
    manifest: str
    manifest_sha256: str
    archives: tuple[ArchiveReport, ...]

    def as_dict(self):
        return asdict(self)


def _sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _entry_manifest(root: Path) -> bytes:
    entries = []

    def visit(directory: Path):
        for path in sorted(directory.iterdir(), key=lambda item: os.fsencode(item.name)):
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                entries.append({"path": relative, "type": "symlink", "target": os.readlink(path)})
            elif stat.S_ISDIR(mode):
                entries.append({"path": relative, "type": "directory"})
                visit(path)
            elif stat.S_ISREG(mode):
                entries.append({"path": relative, "type": "file", "sha256": _sha(path),
                                "executable": bool(mode & 0o111)})
            else:
                raise PrefixError(f"foreign/non-archive file type: {relative}")

    visit(root)
    return b"".join((json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n").encode()
                    for entry in entries)


def tree_digest(root: Path) -> str:
    """Return a stable digest for a prefix without following symbolic links."""
    return hashlib.sha256(_entry_manifest(Path(root))).hexdigest()


def _run(argv, *, cwd=None, purpose="tool") -> str:
    result = subprocess.run([str(item) for item in argv], cwd=cwd, capture_output=True,
                            text=True, env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                                            "LC_ALL": "C", "LANG": "C"})
    if result.returncode:
        raise PrefixError(f"{purpose} failed")
    return result.stdout


def _apple_tool(name: str) -> str:
    return _run(("xcrun", "--find", name), purpose=f"resolve {name}").strip()


def _safe_link(root: Path, path: Path):
    target = os.readlink(path)
    if not target or os.path.isabs(target) or "\\" in target or "\x00" in target:
        raise PrefixError(f"unsafe link: {path.relative_to(root)}")
    lexical = Path(os.path.normpath(path.parent / target))
    try:
        lexical.relative_to(root)
    except ValueError as error:
        raise PrefixError(f"unsafe link: {path.relative_to(root)}") from error
    if not lexical.exists() and not lexical.is_symlink():
        raise PrefixError(f"unsafe link: {path.relative_to(root)}")


def _validate_metadata(path: Path):
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError) as error:
        raise PrefixError(f"malformed package metadata: {path.name}") from error
    if "\x00" in text:
        raise PrefixError(f"malformed package metadata: {path.name}")
    if path.suffix == ".pc":
        fields = {}
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            delimiter = "=" if "=" in line and (":" not in line or line.index("=") < line.index(":")) else ":"
            key, separator, value = line.partition(delimiter)
            if (not separator or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]*", key.strip())
                    or not value.strip()):
                raise PrefixError(f"malformed package metadata: {path.name}")
            if delimiter == ":":
                if key in fields:
                    raise PrefixError(f"malformed package metadata: {path.name}")
                fields[key] = value.strip()
        if not fields.get("Name") or not fields.get("Version"):
            raise PrefixError(f"malformed package metadata: {path.name}")
    elif path.suffix == ".cmake":
        if text.count("(") != text.count(")") or text.count('"') % 2:
            raise PrefixError(f"malformed package metadata: {path.name}")


def _leak_patterns(allowed_roots: Mapping[str, Path]) -> tuple[bytes, ...]:
    values = [b"/opt/homebrew", b"/usr/local/Cellar", b"Cellar/"]
    for value in (*allowed_roots.values(), Path.home()):
        raw = os.fsencode(Path(value))
        if raw and raw not in values:
            values.append(raw)
    return tuple(values)


def _reject_leaks(label: str, data: bytes, patterns: tuple[bytes, ...]):
    if any(pattern in data for pattern in patterns):
        raise PrefixError(f"path leakage in {label}")


def _symbols(output: str) -> tuple[str, ...]:
    symbols = []
    for line in output.splitlines():
        fields = line.split()
        if fields:
            symbol = fields[-1]
            symbols.append(symbol[1:] if symbol.startswith("_") else symbol)
    return tuple(sorted(set(symbols)))


def _inspect_archive(path: Path, relative: str, patterns: tuple[bytes, ...]) -> ArchiveReport:
    ar = _apple_tool("ar")
    lipo = _apple_tool("lipo")
    nm = _apple_tool("nm")
    otool = _apple_tool("otool")
    strings = _apple_tool("strings")
    table = tuple(line for line in _run((ar, "-t", path), purpose=f"archive table {relative}").splitlines()
                  if line)
    if not table or len(set(table)) != len(table):
        raise PrefixError(f"invalid archive members: {relative}")
    for member in table:
        if member in (".", "..") or "/" in member or "\\" in member or "\x00" in member:
            raise PrefixError(f"unsafe archive member: {relative}")
    architectures = set()
    defined = set()
    undefined = set()
    versions = []
    with tempfile.TemporaryDirectory(prefix="airdc-prefix-inspect-") as directory:
        inspection = Path(directory)
        _run((ar, "-x", path), cwd=inspection, purpose=f"archive extraction {relative}")
        for member in table:
            # Apple/BSD ar may expose its generated symbol index in the table.
            # It is archive metadata, not a Mach-O member.
            if member in ("__.SYMDEF", "__.SYMDEF SORTED"):
                continue
            obj = inspection / member
            if not obj.is_file() or obj.is_symlink():
                raise PrefixError(f"non-archive object: {relative}:{member}")
            archs = tuple(_run((lipo, "-archs", obj), purpose=f"archive architecture {relative}").split())
            if archs != ("arm64",):
                raise PrefixError(f"wrong architecture in {relative}:{member}")
            architectures.update(archs)
            defined.update(_symbols(_run((nm, "-gU", obj), purpose=f"defined symbols {relative}")))
            undefined.update(_symbols(_run((nm, "-u", obj), purpose=f"undefined symbols {relative}")))
            load_commands = _run((otool, "-l", obj), purpose=f"build versions {relative}")
            if "LC_BUILD_VERSION" in load_commands:
                versions.extend(line.strip() for line in load_commands.splitlines()
                                if line.strip().startswith(("cmd LC_BUILD_VERSION", "platform ", "minos ", "sdk ")))
            string_output = _run((strings, obj), purpose=f"strings {relative}").encode()
            _reject_leaks(f"{relative}:{member}", obj.read_bytes() + b"\n" + string_output, patterns)
    return ArchiveReport(relative, _sha(path), table, tuple(sorted(architectures)),
                         tuple(sorted(defined)), tuple(sorted(undefined)), tuple(versions))


def validate_prefix(record: DependencyRecord, prefix: Path,
                    allowed_roots: Mapping[str, Path]) -> PrefixReport:
    """Validate and inventory a component prefix, failing closed on drift."""
    prefix = Path(os.path.abspath(prefix))
    try:
        mode = prefix.lstat().st_mode
    except FileNotFoundError as error:
        raise PrefixError(f"missing prefix: {record.name}") from error
    if not stat.S_ISDIR(mode):
        raise PrefixError(f"unsafe prefix: {record.name}")
    roots = {str(name): Path(os.path.abspath(value)) for name, value in allowed_roots.items()}
    required = (*record.expected_headers, *record.expected_archives,
                *record.expected_metadata, *record.license_paths)
    for relative in required:
        path = prefix / relative
        try:
            item_mode = path.lstat().st_mode
        except FileNotFoundError as error:
            raise PrefixError(f"missing expected output: {relative}") from error
        if not stat.S_ISREG(item_mode):
            raise PrefixError(f"missing expected regular output: {relative}")

    allowed_top = {PurePosixPath(relative).parts[0] for relative in required}
    expected_archives = set(record.expected_archives)
    expected_metadata = set(record.expected_metadata)
    licenses = set(record.license_paths)
    patterns = _leak_patterns(roots)
    for path in prefix.rglob("*"):
        relative = path.relative_to(prefix).as_posix()
        mode = path.lstat().st_mode
        if PurePosixPath(relative).parts[0] not in allowed_top:
            raise PrefixError(f"undeclared top-level root: {relative}")
        if any(fnmatch.fnmatch(relative, glob) for glob in record.forbidden_globs) or path.suffix == ".dylib":
            raise PrefixError(f"shared output: {relative}")
        if stat.S_ISLNK(mode):
            _safe_link(prefix, path)
            continue
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise PrefixError(f"foreign/non-archive file type: {relative}")
        top = PurePosixPath(relative).parts[0]
        if top == "lib":
            if path.suffix == ".a" and relative not in expected_archives:
                raise PrefixError(f"foreign library file (non-archive contract): {relative}")
            if path.suffix != ".a" and relative not in expected_metadata:
                raise PrefixError(f"foreign library file (non-archive contract): {relative}")
        elif top != "include" and relative not in licenses:
            raise PrefixError(f"foreign/non-archive file: {relative}")
        data = path.read_bytes()
        _reject_leaks(relative, data, patterns)
        if relative in expected_metadata:
            _validate_metadata(path)

    archives = tuple(_inspect_archive(prefix / relative, relative, patterns)
                     for relative in record.expected_archives)
    raw_manifest = _entry_manifest(prefix)
    normalized_lines = []
    for line in raw_manifest.decode().splitlines():
        entry = json.loads(line)
        entry["path"] = "$PREFIX/" + entry["path"]
        normalized_lines.append(json.dumps(entry, sort_keys=True, separators=(",", ":")))
    manifest = "\n".join(normalized_lines) + "\n"
    return PrefixReport(record.name, record.role, manifest,
                        hashlib.sha256(manifest.encode()).hexdigest(), archives)
