"""Strict, canonical, data-only contract for reproducible dependencies."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[2]
HEX256 = re.compile(r"[0-9a-f]{64}\Z")
HEX_COMMIT = re.compile(r"[0-9a-f]{40}\Z")
IDENTITY = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]*\Z")
TOKENS = {"@SOURCE@", "@BUILD@", "@STAGE@", "@JOBS@", "@EPOCH@",
          "@PREFIX:snappy@", "@SDKROOT@"}
SYSTEM_TOOL_OPTIONS = {"CC=/usr/bin/clang", "AR=/usr/bin/ar", "RANLIB=/usr/bin/ranlib"}
# User-selected OpenSSL runtime defaults, not compiler/dependency search paths.
# Only OpenSSL's make build/install options may use these exact assignments.
OPENSSL_RUNTIME_OPTIONS = frozenset({"OPENSSLDIR=/usr/local/ssl",
                                     "ENGINESDIR=/usr/local/lib/engines-3",
                                     "MODULESDIR=/usr/local/lib/ossl-modules"})
UNSAFE_OPTION = re.compile(r"[\x00-\x1f\x7f;&|`$<>\\\"']")


class LockError(ValueError):
    """A lock does not meet the tracked data contract."""


@dataclass(frozen=True)
class Source:
    kind: Literal["archive", "git"]
    url: str
    archive_sha256: str | None
    commit: str | None
    tag: str | None
    tree_manifest_sha256: str


@dataclass(frozen=True)
class Patch:
    path: str
    sha256: str


@dataclass(frozen=True)
class Platform:
    architecture: str
    deployment_target: str
    build_type: str
    cxx_runtime: str
    linkage: str


@dataclass(frozen=True)
class DependencyRecord:
    name: str
    version: str
    role: Literal["aggregate", "build-only"]
    source: Source
    source_date_epoch: int
    dependencies: tuple[str, ...]
    adapter: str
    configure_options: tuple[str, ...]
    build_options: tuple[str, ...]
    install_options: tuple[str, ...]
    expected_headers: tuple[str, ...]
    expected_archives: tuple[str, ...]
    expected_metadata: tuple[str, ...]
    forbidden_globs: tuple[str, ...]
    license_spdx: str
    license_paths: tuple[str, ...]
    patches: tuple[Patch, ...]
    platform: Platform


@dataclass(frozen=True)
class DependencyLock:
    schema_version: int
    dependencies: tuple[DependencyRecord, ...]


def reject_duplicate_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise LockError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def canonical_bytes(lock: DependencyLock) -> bytes:
    return canonical_json(asdict(lock))


def _object(value, fields: set[str], label: str):
    if not isinstance(value, dict):
        raise LockError(f"{label} must be an object")
    unknown = set(value) - fields
    missing = fields - set(value)
    if unknown:
        raise LockError(f"{label}: unknown field: {sorted(unknown)[0]}")
    if missing:
        raise LockError(f"{label}: missing field: {sorted(missing)[0]}")
    return value


def _text(value, label: str) -> str:
    if not isinstance(value, str) or not value or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise LockError(f"{label}: unsafe or empty text")
    return value


def _identity(value, label: str) -> str:
    value = _text(value, label)
    if not IDENTITY.fullmatch(value):
        raise LockError(f"{label}: unsafe identity")
    return value


def _sha(value, label: str) -> str:
    if not isinstance(value, str) or not HEX256.fullmatch(value):
        raise LockError(f"{label}: invalid sha256")
    return value


def _path(value, label: str) -> str:
    value = _text(value, label)
    parts = value.split("/")
    if value.startswith("/") or any(part in ("", ".", "..") for part in parts) or "\\" in value:
        raise LockError(f"{label}: unsafe path")
    if any(c in value for c in ";&|`$<>\"'"):
        raise LockError(f"{label}: unsafe path")
    return value


def _strings(value, label: str, validator=_text) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise LockError(f"{label} must be an array")
    return tuple(validator(item, label) for item in value)


def _option(value, label: str, runtime_options=frozenset()) -> str:
    value = _text(value, label)
    if UNSAFE_OPTION.search(value):
        raise LockError(f"{label}: unsafe option")
    residue = value
    for token in TOKENS:
        residue = residue.replace(token, "")
    if "@" in residue:
        raise LockError(f"{label}: unknown substitution token")
    if value not in SYSTEM_TOOL_OPTIONS and value not in runtime_options:
        path_view = value
        for token in TOKENS:
            path_view = re.sub(re.escape(token) + r"(?:/[A-Za-z0-9_+-][A-Za-z0-9._+-]*)*", "", path_view)
        if "/" in path_view:
            raise LockError(f"{label}: literal host path is not allowed")
    return value


def _source(value) -> Source:
    value = _object(value, set(Source.__dataclass_fields__), "source")
    kind = value["kind"]
    if kind not in ("archive", "git"):
        raise LockError("source.kind must be archive or git")
    url = _text(value["url"], "source.url")
    if UNSAFE_OPTION.search(url):
        raise LockError("unsafe source URL")
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise LockError("source URL must be HTTPS without credentials or fragment")
    tree_hash = _sha(value["tree_manifest_sha256"], "source.tree_manifest_sha256")
    if kind == "archive":
        archive_hash = _sha(value["archive_sha256"], "source.archive_sha256")
        if value["commit"] is not None or value["tag"] is not None:
            raise LockError("archive source cannot declare commit or tag")
        return Source(kind, url, archive_hash, None, None, tree_hash)
    if value["archive_sha256"] is not None:
        raise LockError("git source cannot declare archive_sha256")
    commit = value["commit"]
    if not isinstance(commit, str) or not HEX_COMMIT.fullmatch(commit):
        raise LockError("source.commit must be a full 40-character Git commit")
    tag = _identity(value["tag"], "source.tag") if value["tag"] is not None else None
    return Source(kind, url, None, commit, tag, tree_hash)


def _patch(value) -> Patch:
    value = _object(value, set(Patch.__dataclass_fields__), "patch")
    path = _path(value["path"], "patch.path")
    digest = _sha(value["sha256"], "patch.sha256")
    target = ROOT / path
    if not target.is_file() or target.is_symlink() or not target.resolve().is_relative_to(ROOT):
        raise LockError(f"patch missing or unsafe: {path}")
    tracked = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "--error-unmatch", "--", path],
        capture_output=True, check=False,
    )
    if tracked.returncode:
        raise LockError(f"untracked patch: {path}")
    if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
        raise LockError(f"patch sha256 mismatch: {path}")
    return Patch(path, digest)


def _platform(value) -> Platform:
    value = _object(value, set(Platform.__dataclass_fields__), "platform")
    expected = Platform("arm64", "14.0", "Release", "libc++", "static")
    if value != asdict(expected):
        raise LockError("unsupported platform contract")
    return expected


def _record(value) -> DependencyRecord:
    value = _object(value, set(DependencyRecord.__dataclass_fields__), "dependency")
    name = _identity(value["name"], "name")
    version = _identity(value["version"], "version")
    role = value["role"]
    if role not in ("aggregate", "build-only"):
        raise LockError(f"{name}: invalid role")
    epoch = value["source_date_epoch"]
    if type(epoch) is not int or epoch < 0:
        raise LockError(f"{name}: invalid source_date_epoch")
    adapter = _identity(value["adapter"], "adapter")
    if adapter not in ("bzip2", "cmake", "openssl", "boost"):
        raise LockError(f"{name}: unsupported adapter")
    dependencies = _strings(value["dependencies"], "dependencies", _identity)
    if len(set(dependencies)) != len(dependencies):
        raise LockError(f"{name}: duplicate dependency edge")
    patches = value["patches"]
    if not isinstance(patches, list):
        raise LockError(f"{name}: patches must be an array")
    runtime_options = OPENSSL_RUNTIME_OPTIONS if name == "openssl" and adapter == "openssl" else frozenset()
    def make_option(option, label):
        return _option(option, label, runtime_options)
    return DependencyRecord(
        name=name, version=version, role=role, source=_source(value["source"]),
        source_date_epoch=epoch, dependencies=dependencies, adapter=adapter,
        configure_options=_strings(value["configure_options"], "configure_options", _option),
        build_options=_strings(value["build_options"], "build_options", make_option),
        install_options=_strings(value["install_options"], "install_options", make_option),
        expected_headers=_strings(value["expected_headers"], "expected_headers", _path),
        expected_archives=_strings(value["expected_archives"], "expected_archives", _path),
        expected_metadata=_strings(value["expected_metadata"], "expected_metadata", _path),
        forbidden_globs=_strings(value["forbidden_globs"], "forbidden_globs", _path),
        license_spdx=_identity(value["license_spdx"], "license_spdx"),
        license_paths=_strings(value["license_paths"], "license_paths", _path),
        patches=tuple(_patch(item) for item in patches), platform=_platform(value["platform"]),
    )


def topological_records(lock: DependencyLock) -> tuple[DependencyRecord, ...]:
    records = lock.dependencies
    names = {record.name for record in records}
    if len(names) != len(records):
        raise LockError("duplicate dependency name")
    by_name = {record.name: record for record in records}
    for record in records:
        for dependency in record.dependencies:
            if dependency not in names:
                raise LockError(f"{record.name}: undeclared dependency: {dependency}")
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(name: str) -> None:
        if name in visiting:
            raise LockError(f"dependency cycle involving {name}")
        if name in visited:
            return
        visiting.add(name)
        for dependency in by_name[name].dependencies:
            visit(dependency)
        visiting.remove(name)
        visited.add(name)

    for record in records:
        visit(record.name)
    earlier: set[str] = set()
    for record in records:
        if not set(record.dependencies).issubset(earlier):
            raise LockError(f"{record.name}: dependency records violate topological order")
        earlier.add(record.name)
    return records


def load_lock(path: Path) -> DependencyLock:
    data = path.read_bytes()
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=reject_duplicate_pairs,
                           parse_constant=lambda constant: (_ for _ in ()).throw(LockError(f"invalid JSON constant: {constant}")))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LockError(f"invalid UTF-8 JSON: {error}") from error
    value = _object(value, set(DependencyLock.__dataclass_fields__), "lock")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise LockError("schema_version must be 1")
    if not isinstance(value["dependencies"], list):
        raise LockError("dependencies must be an array")
    lock = DependencyLock(1, tuple(_record(record) for record in value["dependencies"]))
    topological_records(lock)
    if canonical_bytes(lock) != data:
        raise LockError("non-canonical lock bytes")
    return lock


def fingerprint(lock: DependencyLock) -> str:
    return hashlib.sha256(canonical_bytes(lock)).hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("validate", "record", "fingerprint"):
        commands.add_parser(command).add_argument("--lock", type=Path, default=ROOT / "config/dependencies.lock")
    commands.choices["record"].add_argument("--name", required=True)
    commands.choices["record"].add_argument("--field", required=True)
    args = parser.parse_args(argv)
    try:
        lock = load_lock(args.lock)
        if args.command == "record":
            record = next((item for item in lock.dependencies if item.name == args.name), None)
            if record is None:
                raise LockError(f"unknown dependency: {args.name}")
            value: object = asdict(record)
            for component in args.field.split("."):
                if not isinstance(value, dict) or component not in value:
                    raise LockError(f"unknown record field: {args.field}")
                value = value[component]
            if isinstance(value, dict):
                raise LockError(f"record field is not scalar or array: {args.field}")
            if value is None:
                raise LockError(f"record field is absent: {args.field}")
            print(json.dumps(value, ensure_ascii=False) if isinstance(value, (list, tuple)) else value)
        else:
            print(fingerprint(lock))
    except (LockError, OSError) as error:
        print(f"dependency lock: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
