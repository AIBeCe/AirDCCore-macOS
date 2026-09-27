#!/usr/bin/env python3
"""Reconstruct locked dependency sources without configuring or building them."""
from __future__ import annotations

import argparse
import ctypes
from contextlib import ExitStack, contextmanager, nullcontext
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
import urllib.error
import urllib.request
from urllib.parse import urlsplit

from dependency_lock import (DependencyLock, DependencyRecord, LockError,
                             fingerprint, load_lock, topological_records)


class AcquireError(ValueError):
    """Unsafe, unavailable, or drifted acquisition input."""


def _publish_fd(source_fd: int, destination_fd: int, name: str):
    """Atomic, no-clobber macOS publication of the verified open object.

    Unlike renameat, fclonefileat never resolves the source's temporary name.
    Its native atomicity covers both files and directory hierarchies. Fail closed
    on filesystems without clone support instead of falling back to a pathname
    rename with a source-substitution window.
    """
    library = ctypes.CDLL(None, use_errno=True)
    try:
        clone = library.fclonefileat
    except AttributeError as error:
        raise AcquireError("atomic descriptor publication requires macOS clonefile support") from error
    clone.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_int)
    clone.restype = ctypes.c_int
    if clone(source_fd, destination_fd, os.fsencode(name), 1):  # CLONE_NOFOLLOW
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def _sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _identity(path: Path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    return info.st_dev, info.st_ino, stat.S_IFMT(info.st_mode)


class OwnedDirectory:
    """Pin all ancestors and the opened directory; publish relative to its fd."""
    def __init__(self, path: Path):
        self.path = path
        self.identities = {p: _identity(p) for p in (*reversed(path.parents), path)}
        if any(value is None or value[2] != stat.S_IFDIR for value in self.identities.values()):
            raise AcquireError(f"unsafe or symlinked directory: {path}")
        self.fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.check()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        os.close(self.fd)

    def check(self):
        if any(_identity(p) != identity for p, identity in self.identities.items()):
            raise AcquireError("path identity changed before publication")
        actual = os.fstat(self.fd)
        if (actual.st_dev, actual.st_ino) != self.identities[self.path][:2]:
            raise AcquireError("path identity changed before publication")

    @contextmanager
    def directory_fd(self, parts=(), create=False):
        """Walk from the pinned root, never traversing a symlink component."""
        fd = os.dup(self.fd)
        try:
            for part in parts:
                if part in ("", ".", "..") or "/" in part:
                    raise AcquireError("unsafe descriptor-relative path")
                if create:
                    try:
                        os.mkdir(part, 0o755, dir_fd=fd)
                    except FileExistsError:
                        pass
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
            yield fd
        finally:
            os.close(fd)

    def publish(self, temporary: Path, target: str, source_fd: int):
        self.check()
        info = os.fstat(source_fd)
        temporary_identity = info.st_dev, info.st_ino, stat.S_IFMT(info.st_mode)
        if (temporary_identity[2] not in (stat.S_IFREG, stat.S_IFDIR)
                or _identity(temporary) != temporary_identity):
            raise AcquireError("path identity changed before publication")
        if _identity(self.path / target) is not None:
            raise AcquireError("path identity changed before publication")
        try:
            _publish_fd(source_fd, self.fd, target)
        except OSError as error:
            raise AcquireError("path identity changed before publication") from error
        self.check()
        published = _identity(self.path / target)
        if published is None or published[2] != temporary_identity[2]:
            raise AcquireError("path identity changed before publication")
        os.fsync(self.fd)


def _regular(path: Path):
    identity = _identity(path)
    if identity is None or identity[2] != stat.S_IFREG:
        raise AcquireError(f"expected regular non-symlink file: {path.name}")


def normalize_member(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if (not name or name.startswith("/") or ".." in path.parts or "\\" in name
            or any(ord(c) < 32 or ord(c) == 127 for c in name)
            or any(part.casefold() == ".git" for part in path.parts)):
        raise AcquireError(f"unsafe archive member: {name!r}")
    normalized = PurePosixPath(*(part for part in path.parts if part not in ("", ".")))
    if not normalized.parts:
        raise AcquireError(f"empty archive member: {name!r}")
    return normalized


def _link_target(path: PurePosixPath, target: str, hard: bool) -> PurePosixPath:
    if not target or target.startswith("/") or "\\" in target or any(ord(c) < 32 for c in target):
        raise AcquireError(f"unsafe link target: {target!r}")
    parts = [] if hard else list(path.parent.parts)
    for part in target.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if len(parts) <= 1:
                raise AcquireError(f"escaping link target: {target!r}")
            parts.pop()
        else:
            parts.append(part)
    result = normalize_member("/".join(parts))
    if result.parts[0] != path.parts[0]:
        raise AcquireError(f"escaping link target: {target!r}")
    return result


@dataclass(frozen=True)
class ArchivePlan:
    root: str
    members: tuple[tarfile.TarInfo, ...]


def _validate_entries(entries):
    """Validate both explicit entries and implicit parent directories."""
    explicit = {}
    nodes = {}
    folded = {}
    for path, kind, target in entries:
        if path in explicit:
            raise AcquireError(f"duplicate normalized member: {path}")
        explicit[path] = (kind, target)
        for candidate in (*reversed(path.parents[:-1]), path):
            wanted = kind if candidate == path else "directory"
            key = unicodedata.normalize("NFC", str(candidate)).casefold()
            if key in folded and folded[key] != candidate:
                raise AcquireError(f"case-fold or NFC member collision: {candidate}")
            folded[key] = candidate
            if candidate in nodes and nodes[candidate] != wanted:
                raise AcquireError(f"file/directory member alias: {candidate}")
            nodes[candidate] = wanted
    roots = {path.parts[0] for path in nodes}
    if len(roots) != 1:
        raise AcquireError("archive must have one top-level root")
    root = next(iter(roots))
    if nodes[PurePosixPath(root)] != "directory":
        raise AcquireError("top-level root must be a directory")
    for path, (kind, target) in explicit.items():
        if kind not in ("symlink", "hardlink"):
            continue
        resolved = _link_target(path, target, kind == "hardlink")
        if nodes.get(resolved) not in (("file",) if kind == "hardlink" else ("file", "directory")):
            raise AcquireError(f"unsafe or missing link target: {path}")
        for parent in resolved.parents:
            if parent != PurePosixPath(".") and nodes.get(parent) != "directory":
                raise AcquireError(f"link target crosses non-directory: {path}")
    return root


def inspect_archive(archive: Path, record: DependencyRecord) -> ArchivePlan:
    _regular(archive)
    if _sha(archive) != record.source.archive_sha256:
        raise AcquireError(f"{record.name}: archive checksum mismatch")
    members = []
    entries = []
    with tarfile.open(archive, "r:*") as stream:
        for member in stream:
            if len(members) >= 100000:
                raise AcquireError("archive exceeds 100000 member limit")
            path = normalize_member(member.name)
            if member.isdir():
                kind = "directory"
            elif member.isreg():
                kind = "file"
            elif member.issym():
                kind = "symlink"
            elif member.islnk():
                kind = "hardlink"
            else:
                raise AcquireError(f"unsupported archive member type: {path}")
            entries.append((path, kind, member.linkname))
            members.append(member)
    return ArchivePlan(_validate_entries(entries), tuple(members))


def _manifest(entries) -> bytes:
    return b"".join((json.dumps(entry, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
                    for entry in sorted(entries, key=lambda item: item["path"].encode("utf-8")))


def _tree_manifest(root: Path, exclude_git: bool = False) -> bytes:
    entries = []
    def visit(directory):
        for path in directory.iterdir():
            if exclude_git and directory == root and path.name == ".git":
                continue
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                entry = dict(path=relative, type="symlink", target=os.readlink(path))
            elif stat.S_ISDIR(mode):
                entry = dict(path=relative, type="directory")
                visit(path)
            elif stat.S_ISREG(mode):
                entry = dict(path=relative, type="file", executable=bool(mode & 0o111), sha256=_sha(path))
            else:
                raise AcquireError(f"unsupported source file: {relative}")
            entries.append(entry)
    visit(root)
    return _manifest(entries)


def tree_manifest(root: Path) -> bytes:
    return _tree_manifest(root)


def _licenses(root: Path, record: DependencyRecord):
    for name in record.license_paths:
        target = root / name
        if not target.is_file() or not target.resolve().is_relative_to(root):
            raise AcquireError(f"{record.name}: missing or unsafe license: {name}")


def _set_times(root: Path | OwnedDirectory, epoch: int):
    def visit(fd):
        for name in os.listdir(fd):
            if name == ".git":
                continue
            mode = os.stat(name, dir_fd=fd, follow_symlinks=False).st_mode
            if stat.S_ISDIR(mode):
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    visit(child)
                finally:
                    os.close(child)
            else:
                os.utime(name, (epoch, epoch), dir_fd=fd, follow_symlinks=False)
        os.utime(fd, (epoch, epoch))
    with (nullcontext(root) if isinstance(root, OwnedDirectory) else OwnedDirectory(root)) as owned:
        owned.check()
        visit(owned.fd)
        owned.check()


def _extract(archive: Path, plan: ArchivePlan, root: OwnedDirectory, record: DependencyRecord):
    root.check()
    with tarfile.open(archive, "r:*") as stream:
        for member in plan.members:
            relative = normalize_member(member.name).parts[1:]
            if not relative:
                continue
            with root.directory_fd(relative[:-1], create=True) as parent:
                if member.isdir():
                    with root.directory_fd(relative, create=True):
                        pass
                elif member.isreg():
                    fd = os.open(relative[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=parent)
                    with stream.extractfile(member) as source, os.fdopen(fd, "wb") as output:
                        shutil.copyfileobj(source, output)
                        os.fchmod(output.fileno(), 0o755 if member.mode & 0o111 else 0o644)
        # Links are materialized last; no write ever traverses one.
        for member in plan.members:
            path = normalize_member(member.name)
            if not (member.issym() or member.islnk()):
                continue
            with root.directory_fd(path.parts[1:-1]) as parent:
                if member.issym():
                    os.symlink(member.linkname, path.name, dir_fd=parent)
                else:
                    linked = _link_target(path, member.linkname, True)
                    with root.directory_fd(linked.parts[1:-1]) as source_parent:
                        os.link(linked.name, path.name, src_dir_fd=source_parent,
                                dst_dir_fd=parent, follow_symlinks=False)
    root.check()
    _licenses(root.path, record)
    if hashlib.sha256(tree_manifest(root.path)).hexdigest() != record.source.tree_manifest_sha256:
        raise AcquireError(f"{record.name}: source tree manifest mismatch")
    _set_times(root, record.source_date_epoch)


def _https_url(url: str):
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.fragment or any(c.isspace() for c in url)):
        raise AcquireError("source URL must be credential-free HTTPS without whitespace")


class _HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        _https_url(newurl)
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def open_https(url: str):
    _https_url(url)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _HTTPSRedirect())
    return opener.open(url, timeout=60)


def cache_name(record: DependencyRecord) -> str:
    if record.source.kind == "git":
        digest = record.source.tree_manifest_sha256
        suffix = "bundle"
    else:
        digest = record.source.archive_sha256
        path = urlsplit(record.source.url).path
        suffix = next((suffix for suffix in ("tar.gz", "tar.bz2", "tar") if path.endswith("." + suffix)), None)
        if suffix is None:
            raise AcquireError(f"{record.name}: unsupported archive suffix")
    return f"{record.name}-{record.version}-{digest[:12]}.{suffix}"


def _download(cache: OwnedDirectory, record: DependencyRecord):
    cache.check()
    fd, name = tempfile.mkstemp(prefix=".partial-", dir=cache.path)
    temporary = Path(name)
    try:
        checksum = hashlib.sha256()
        with os.fdopen(fd, "w+b") as output:
            with open_https(record.source.url) as response:
                while chunk := response.read(1024 * 1024):
                    checksum.update(chunk)
                    output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
            if checksum.hexdigest() != record.source.archive_sha256:
                raise AcquireError(f"{record.name}: download checksum mismatch")
            cache.publish(temporary, cache_name(record), output.fileno())
    finally:
        # Unlink through the pinned descriptor, even if the directory was renamed.
        try:
            os.unlink(temporary.name, dir_fd=cache.fd)
        except FileNotFoundError:
            pass


def _git(root: Path, *args: str) -> bytes:
    # No global configuration, URL rewrites, helpers, proxies, hooks or prompts.
    env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "SYSTEMROOT") if key in os.environ}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0",
               GIT_NO_REPLACE_OBJECTS="1", LC_ALL="C")
    # This child-only home prevents libcurl falling back to the account's .netrc;
    # the operator's shell environment and actual home are never modified.
    env["HOME"] = os.devnull
    result = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=",
                             "-c", "core.fsmonitor=false", "-c", "core.attributesFile=/dev/null",
                             "-c", "http.proxy=", "-c", "http.followRedirects=false",
                             "-c", "protocol.allow=never", "-c", "protocol.https.allow=always",
                             "-c", "submodule.recurse=false", "-c", "core.autocrlf=false",
                             "-C", str(root), *args], env=env, capture_output=True)
    if result.returncode:
        # Transport output may contain URLs or ambient credentials: do not echo it.
        raise AcquireError(f"Git {args[0]} failed")
    return result.stdout


def _fetch_git(repository: Path, record: DependencyRecord):
    _git(repository, "fetch", "--no-tags", "--no-recurse-submodules", "origin", record.source.commit)


def _git_tree(root: Path, record: DependencyRecord):
    if _git(root, "rev-parse", "--abbrev-ref", "HEAD").strip() != b"HEAD":
        raise AcquireError(f"{record.name}: Git checkout is not detached; identity drift")
    if _git(root, "rev-parse", "HEAD").decode().strip() != record.source.commit:
        raise AcquireError(f"{record.name}: Git commit drift")
    tree = _git(root, "ls-tree", "-r", "--full-tree", record.source.commit)
    if hashlib.sha256(tree).hexdigest() != record.source.tree_manifest_sha256:
        raise AcquireError(f"{record.name}: Git tree manifest mismatch")
    nodes = []
    links = []
    for line in _git(root, "ls-tree", "-rz", "--full-tree", record.source.commit).split(b"\0"):
        if not line:
            continue
        metadata, raw_path = line.split(b"\t", 1)
        mode, kind, oid = metadata.decode().split()
        path = normalize_member("root/" + raw_path.decode("utf-8"))
        relative = "/".join(path.parts[1:])
        if mode == "160000":
            required = {f"-D{record.name.upper()}_BUILD_TESTS=OFF", f"-D{record.name.upper()}_BUILD_BENCHMARKS=OFF"}
            if (record.name not in ("snappy", "leveldb") or record.adapter != "cmake"
                    or not required.issubset(record.configure_options)
                    or relative not in ("third_party/googletest", "third_party/benchmark")):
                raise AcquireError(f"{record.name}: adapter requires undeclared gitlink: {relative}")
            links.append(relative)
            continue
        if mode not in ("100644", "100755", "120000") or kind != "blob":
            raise AcquireError(f"{record.name}: unsupported Git tree entry")
        data = _git(root, "cat-file", "blob", oid)
        if mode == "120000":
            target = data.decode("utf-8")
            nodes.append((path, "symlink", target))
        else:
            nodes.append((path, "file", ""))
        yield relative, mode, data
    _validate_entries(nodes)
    return links


def _git_expected(root: Path, record: DependencyRecord):
    iterator = _git_tree(root, record)
    entries = {}
    while True:
        try:
            path, mode, data = next(iterator)
        except StopIteration as result:
            return _manifest(entries.values()), result.value
        for parent in PurePosixPath(path).parents:
            if str(parent) != ".":
                entries[str(parent)] = dict(path=str(parent), type="directory")
        if mode == "120000":
            entries[path] = dict(path=path, type="symlink", target=data.decode("utf-8"))
        else:
            entries[path] = dict(path=path, type="file", executable=mode == "100755", sha256=hashlib.sha256(data).hexdigest())


def _git_actual(root: Path) -> bytes:
    # tree_manifest's archive API includes all entries. Only Git's private metadata
    # is excluded here; ignored/untracked source files remain visible.
    return _tree_manifest(root, exclude_git=True)


def _verify_git(root: Path, record: DependencyRecord, fresh=False):
    with OwnedDirectory(root / ".git"):
        # Read without includes before running worktree commands. Status can
        # invoke filters from local attributes, and command-valued config is not
        # limited to hooks/fsmonitor. Only acquisition's inert init/origin keys
        # are accepted; includes, extensions and unknown keys fail closed.
        allowed = {"core.repositoryformatversion", "core.filemode", "core.bare",
                   "core.logallrefupdates", "core.ignorecase", "core.precomposeunicode",
                   "remote.origin.url", "remote.origin.fetch"}
        for entry in _git(root, "config", "--local", "--no-includes", "--null", "--list").split(b"\0"):
            if entry and entry.split(b"\n", 1)[0].decode() not in allowed:
                raise AcquireError(f"{record.name}: unsafe local Git configuration")
        if _git(root, "remote", "get-url", "--all", "origin").decode().splitlines() != [record.source.url]:
            raise AcquireError(f"{record.name}: Git origin drift")
        expected, links = _git_expected(root, record)
        for relative in links:
            target = root / relative
            if fresh and target.is_dir() and not target.is_symlink() and not any(target.iterdir()):
                target.rmdir()
                parent = target.parent
                while parent != root and not any(parent.iterdir()):
                    parent.rmdir()
                    parent = parent.parent
            elif _identity(target) is not None:
                raise AcquireError(f"{record.name}: initialized submodule drift: {relative}")
        if (_git(root, "status", "--porcelain=v1", "--untracked-files=all", "--ignored", "--ignore-submodules=all")
                or _git(root, "diff", "--cached", "--name-only", "--ignore-submodules=none", record.source.commit)
                or _git_actual(root) != expected):
            raise AcquireError(f"{record.name}: Git source drift; preserve or remove it explicitly")
    _licenses(root, record)


def _prepare_git(root: Path, record: DependencyRecord, cache_path: Path | None):
    _git(root, "init", "-q")
    _git(root, "remote", "add", "origin", record.source.url)
    if cache_path is None:
        _fetch_git(root, record)
    else:
        _regular(cache_path)
        _git(root, "-c", "protocol.file.allow=always", "fetch", "--no-tags", "--no-recurse-submodules",
             str(cache_path), record.source.commit)
    _git(root, "checkout", "--detach", "--force", record.source.commit)
    _verify_git(root, record, fresh=True)
    _set_times(root, record.source_date_epoch)


def _verify_git_cache(cache_path: Path, record: DependencyRecord):
    # An existing checkout must never supply objects missing from the bundle.
    # Reconstruct in an empty private repository and verify the full object
    # graph, pinned commit, locked tree and each materialized blob independently.
    with tempfile.TemporaryDirectory(prefix="airdc-bundle-check-") as directory:
        root = Path(directory).resolve()
        _prepare_git(root, record, cache_path)
        _git(root, "fsck", "--full", "--no-reflogs")


def acquire_all(project_root: Path, lock: DependencyLock, offline: bool) -> None:
    project_root = Path(os.path.abspath(project_root))
    records = topological_records(lock)
    try:
        with ExitStack() as stack:
            project = stack.enter_context(OwnedDirectory(project_root))
            for record in records:
                _https_url(record.source.url)
            dependencies = project_root / "Dependencies"
            downloads = dependencies / ".downloads"
            # Validate every preexisting path before any network or extraction.
            for directory in (dependencies, downloads):
                identity = _identity(directory)
                if identity is not None and identity[2] != stat.S_IFDIR:
                    raise AcquireError(f"unsafe or symlinked directory: {directory.name}")
            pending = []
            missing = []
            for record in records:
                source = dependencies / record.name
                cache_path = downloads / cache_name(record)
                if _identity(cache_path) is not None:
                    _regular(cache_path)
                    if record.source.kind == "archive" and _sha(cache_path) != record.source.archive_sha256:
                        raise AcquireError(f"{record.name}: cache checksum mismatch")
                    if record.source.kind == "git":
                        _verify_git_cache(cache_path, record)
                else:
                    missing.append(record.name)
                identity = _identity(source)
                if identity is not None:
                    with OwnedDirectory(source):
                        if record.source.kind == "git":
                            _verify_git(source, record)
                        else:
                            _licenses(source, record)
                            if hashlib.sha256(tree_manifest(source)).hexdigest() != record.source.tree_manifest_sha256:
                                raise AcquireError(f"{record.name}: source drift; preserve or remove it explicitly")
                    continue
                pending.append(record)
            if offline and missing:
                raise AcquireError("offline missing caches in lock order: " + ", ".join(missing))
            if not pending:
                return
            project.check()
            dependencies.mkdir(exist_ok=True)
            owned = stack.enter_context(OwnedDirectory(dependencies))
            downloads.mkdir(exist_ok=True)
            cache = stack.enter_context(OwnedDirectory(downloads))
            for record in pending:
                owned.check()
                cache.check()
                cached = downloads / cache_name(record)
                if record.source.kind == "archive" and not cached.exists():
                    _download(cache, record)
                staging = Path(tempfile.mkdtemp(prefix=".staging-", dir=dependencies))
                stage_owner = OwnedDirectory(staging)
                try:
                    if record.source.kind == "archive":
                        plan = inspect_archive(cached, record)
                        _extract(cached, plan, stage_owner, record)
                    else:
                        _prepare_git(staging, record, cached if cached.exists() else None)
                        if not cached.exists():
                            fd, name = tempfile.mkstemp(prefix=".partial-", dir=downloads)
                            temporary = Path(name)
                            try:
                                with os.fdopen(fd, "w+b") as stream:
                                    stream.write(_git(staging, "bundle", "create", "-", "HEAD"))
                                    stream.flush()
                                    os.fsync(stream.fileno())
                                    cache.publish(temporary, cached.name, stream.fileno())
                            finally:
                                try:
                                    os.unlink(temporary.name, dir_fd=cache.fd)
                                except FileNotFoundError:
                                    pass
                    stage_owner.check()
                    owned.publish(staging, record.name, stage_owner.fd)
                finally:
                    # Never recurse through a changed project path on failure.
                    try:
                        owned.check()
                        if _identity(staging) is not None:
                            stage_owner.check()
                            shutil.rmtree(staging)
                    finally:
                        stage_owner.__exit__(None, None, None)
    except AcquireError:
        raise
    except (OSError, tarfile.TarError, UnicodeError, urllib.error.URLError) as error:
        raise AcquireError(f"dependency acquisition failed ({type(error).__name__})") from error


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", required=True, type=Path)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args(argv)
    try:
        lock = load_lock(args.project_root / "config/dependencies.lock")
        acquire_all(args.project_root, lock, args.offline)
        print(f"dependencies verified: lock={fingerprint(lock)}")
    except (AcquireError, LockError, OSError) as error:
        print(f"dependency acquisition: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
