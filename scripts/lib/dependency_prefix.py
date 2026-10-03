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
import struct
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
                            text=True, encoding="utf-8", errors="backslashreplace",
                            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
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


def _valid_cmake_syntax(text: str) -> bool:
    """Parse command boundaries and argument quoting without evaluating commands."""
    size = len(text)
    position = 0

    def skip_comment(at: int) -> int:
        bracket = re.match(r"#\[(=*)\[", text[at:])
        if bracket:
            closing = "]" + bracket.group(1) + "]"
            end = text.find(closing, at + len(bracket.group(0)))
            return size + 1 if end < 0 else end + len(closing)
        end = text.find("\n", at)
        return size if end < 0 else end + 1

    while position < size:
        if text[position].isspace():
            position += 1
            continue
        if text[position] == "#":
            position = skip_comment(position)
            continue
        command = re.match(r"[A-Za-z_][A-Za-z0-9_]*", text[position:])
        if not command:
            return False
        position += len(command.group(0))
        while position < size and text[position].isspace():
            position += 1
        if position >= size or text[position] != "(":
            return False
        depth = 1
        position += 1
        while position < size and depth:
            char = text[position]
            if char == "#":
                position = skip_comment(position)
                continue
            bracket = re.match(r"\[(=*)\[", text[position:])
            if bracket:
                closing = "]" + bracket.group(1) + "]"
                end = text.find(closing, position + len(bracket.group(0)))
                if end < 0:
                    return False
                position = end + len(closing)
                continue
            if char == '"':
                position += 1
                while position < size:
                    if text[position] == "\\":
                        position += 2
                    elif text[position] == '"':
                        position += 1
                        break
                    else:
                        position += 1
                else:
                    return False
                continue
            if char == "\\":
                position += 2
                continue
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
            position += 1
        if depth:
            return False
    return position == size


def _validate_metadata(path: Path):
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError) as error:
        raise PrefixError(f"malformed package metadata: {path.name}") from error
    if "\x00" in text:
        raise PrefixError(f"malformed package metadata: {path.name}")
    if path.suffix == ".pc":
        fields = {}
        for line in re.sub(r"\\\r?\n", "", text).splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            delimiter = "=" if "=" in line and (":" not in line or line.index("=") < line.index(":")) else ":"
            key, separator, value = line.partition(delimiter)
            key = key.strip()
            if not separator or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]*", key):
                raise PrefixError(f"malformed package metadata: {path.name}")
            if delimiter == ":":
                if key in fields:
                    raise PrefixError(f"malformed package metadata: {path.name}")
                fields[key] = value.strip()
        if not fields.get("Name") or not fields.get("Version"):
            raise PrefixError(f"malformed package metadata: {path.name}")
    elif path.suffix == ".cmake":
        if not _valid_cmake_syntax(text):
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


def _check_build_versions(output: str, relative: str, minimum: str) -> tuple[str, ...]:
    found = []
    required = tuple(int(part) for part in minimum.split("."))
    for command in output.split("Load command"):
        match = re.search(r"\bcmd (LC_BUILD_VERSION|LC_VERSION_MIN_[A-Z0-9_]+)\b", command)
        if not match:
            continue
        name = match.group(1)
        if name == "LC_BUILD_VERSION":
            platform = re.search(r"\bplatform\s+(\S+)", command)
            version = re.search(r"\bminos\s+(\d+(?:\.\d+){1,2})", command)
            if not platform or platform.group(1).lower() not in ("1", "macos"):
                raise PrefixError(f"wrong Apple platform in {relative}")
        else:
            if name != "LC_VERSION_MIN_MACOSX":
                raise PrefixError(f"wrong Apple platform in {relative}")
            version = re.search(r"\bversion\s+(\d+(?:\.\d+){1,2})", command)
        if not version:
            raise PrefixError(f"malformed build version in {relative}")
        actual = tuple(int(part) for part in version.group(1).split("."))
        width = max(len(actual), len(required))
        if actual + (0,) * (width - len(actual)) > required + (0,) * (width - len(required)):
            raise PrefixError(f"deployment target newer than {minimum} in {relative}")
        found.extend(line.strip() for line in command.splitlines()
                     if line.strip().startswith(("cmd ", "platform ", "minos ", "sdk ", "version ")))
    return tuple(found)


def _inspect_archive(path: Path, relative: str, patterns: tuple[bytes, ...],
                     minimum: str, tools: Mapping[str, str]) -> ArchiveReport:
    ar = tools["ar"]
    lipo = tools["lipo"]
    nm = tools["nm"]
    otool = tools["otool"]
    strings = tools["strings"]
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
    object_count = 0
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
            header = obj.read_bytes()[:16]
            if (len(header) != 16 or header[:4] != b"\xcf\xfa\xed\xfe"
                    or struct.unpack_from("<I", header, 12)[0] != 1):
                raise PrefixError(f"archive member is not a relocatable object: {relative}:{member}")
            object_count += 1
            archs = tuple(_run((lipo, "-archs", obj), purpose=f"archive architecture {relative}").split())
            if archs != ("arm64",):
                raise PrefixError(f"wrong architecture in {relative}:{member}")
            architectures.update(archs)
            defined.update(_symbols(_run((nm, "-gU", obj), purpose=f"defined symbols {relative}")))
            undefined.update(_symbols(_run((nm, "-u", obj), purpose=f"undefined symbols {relative}")))
            load_commands = _run((otool, "-l", obj), purpose=f"build versions {relative}")
            versions.extend(_check_build_versions(load_commands, relative, minimum))
            string_output = _run((strings, obj), purpose=f"strings {relative}").encode()
            _reject_leaks(f"{relative}:{member}", obj.read_bytes() + b"\n" + string_output, patterns)
    if not object_count:
        raise PrefixError(f"archive has no relocatable object: {relative}")
    return ArchiveReport(relative, _sha(path), table, tuple(sorted(architectures)),
                         tuple(sorted(defined)), tuple(sorted(undefined)), tuple(versions))


def validate_prefix(record: DependencyRecord, prefix: Path,
                    allowed_roots: Mapping[str, Path],
                    *, tools: Mapping[str, str] | None = None) -> PrefixReport:
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

    inspection_tools = tools or {name: _apple_tool(name) for name in
                                 ("ar", "lipo", "nm", "otool", "strings")}
    archives = tuple(_inspect_archive(prefix / relative, relative, patterns,
                                      record.platform.deployment_target, inspection_tools)
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
