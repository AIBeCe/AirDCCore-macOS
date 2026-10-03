#!/usr/bin/env python3
"""Hermetic acquisition contracts: only transport is substituted, never validation."""
import contextlib
import errno
from dataclasses import replace
import hashlib
import importlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from dependency_lock import DependencyLock, canonical_bytes, load_lock


def digest(data):
    return hashlib.sha256(data).hexdigest()


class AcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / "scripts/lib/dependency_acquire.py").is_file(),
                        "dependency acquisition implementation is missing")
        self.a = importlib.import_module("dependency_acquire")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.project = self.base / "project"
        self.project.mkdir()
        self.template = load_lock(ROOT / "config/dependencies.lock").dependencies[0]

    def archive(self, entries=None, suffix="tar", **changes):
        if entries is None:
            entries = [("pkg/LICENSE", b"license\n"), ("pkg/code.c", b"source\n")]
        path = self.base / ("input." + suffix)
        mode = {"tar": "w", "tar.gz": "w:gz", "tar.bz2": "w:bz2"}[suffix]
        with tarfile.open(path, mode) as tf:
            for entry in entries:
                name, data, *extra = entry
                info = tarfile.TarInfo(name)
                info.mode = 0o755 if data is None else 0o644
                info.type = tarfile.DIRTYPE if data is None else tarfile.REGTYPE
                if extra:
                    info.type, info.linkname = extra[0]
                info.size = len(data) if info.isreg() else 0
                tf.addfile(info, io.BytesIO(data) if info.isreg() else None)
        manifest = b''.join((json.dumps({"executable": False, "path": name,
                                        "sha256": digest(data), "type": "file"},
                                       sort_keys=True, separators=(",", ":")) + "\n").encode()
                            for name, data in [("LICENSE", b"license\n"), ("code.c", b"source\n")])
        record = replace(self.template, name="fixture", version="1",
                         source=replace(self.template.source, url="https://example.invalid/pkg." + suffix,
                                        archive_sha256=digest(path.read_bytes()),
                                        tree_manifest_sha256=digest(manifest)))
        return path, replace(record, **changes)

    def cache(self, archive, record):
        directory = self.project / "Dependencies/.downloads"
        directory.mkdir(parents=True, exist_ok=True)
        suffix = record.source.url.split("pkg.")[-1]
        target = directory / f"{record.name}-{record.version}-{record.source.archive_sha256[:12]}.{suffix}"
        shutil.copyfile(archive, target)
        return target

    def acquire(self, record, offline=True):
        self.a.acquire_all(self.project, DependencyLock(1, (record,)), offline)

    def test_archive_formats_offline_reuse_and_noop(self):
        for suffix in ("tar", "tar.gz", "tar.bz2"):
            with self.subTest(suffix=suffix):
                archive, record = self.archive(suffix=suffix)
                self.cache(archive, record)
                self.acquire(record)
                source = self.project / "Dependencies/fixture"
                self.assertEqual((source / "code.c").read_bytes(), b"source\n")
                self.assertEqual((source / "code.c").stat().st_mtime, record.source_date_epoch)
                before = {str(p): p.lstat().st_mtime_ns for p in (self.project / "Dependencies").rglob("*")}
                with patch.object(self.a, "open_https", side_effect=AssertionError("network on reuse")):
                    self.acquire(record)
                self.assertEqual(before, {str(p): p.lstat().st_mtime_ns for p in (self.project / "Dependencies").rglob("*")})
                shutil.rmtree(source)
        self.assertFalse((self.project / "Build").exists())
        self.assertFalse((self.project / "Dist").exists())

    def test_checksum_precedes_tar_open(self):
        archive, record = self.archive()
        record = replace(record, source=replace(record.source, archive_sha256="0" * 64))
        with patch.object(tarfile, "open", side_effect=AssertionError("opened unverified bytes")):
            with self.assertRaisesRegex(self.a.AcquireError, "checksum"):
                self.a.inspect_archive(archive, record)

    def test_unsafe_archive_members(self):
        cases = [
            [("/escape", b"x")], [("pkg/../escape", b"x")],
            [("pkg/a", b"x"), ("pkg/./a", b"y")],
            [("pkg/a", b"x"), ("pkg/a/b", b"y")],
            [("pkg/a", None), ("pkg/a/", b"y")],
            [("pkg/a", b"x", (tarfile.CHRTYPE, ""))],
            [("pkg/a", b"x", (tarfile.FIFOTYPE, ""))],
            [("pkg/a", b"", (tarfile.SYMTYPE, "../../outside"))],
            [("pkg/a", b"", (tarfile.LNKTYPE, "other/file"))],
            [("pkg/a", b"x"), ("other/b", b"y")],
            [("pkg/A", b"x"), ("pkg/a", b"y")],
            [("pkg/caf\u00e9", b"x"), ("pkg/cafe\u0301", b"y")],
            [("pkg/a", b"", (tarfile.SYMTYPE, "b")), ("pkg/a/file", b"x")],
            [("pkg/.git/config", b"x")],
        ]
        for entries in cases:
            with self.subTest(entries=entries):
                archive, record = self.archive(entries)
                with self.assertRaises(self.a.AcquireError):
                    self.a.inspect_archive(archive, record)

    def test_archive_member_limit(self):
        archive, record = self.archive([(f"pkg/{i}", b"") for i in range(100001)])
        with self.assertRaisesRegex(self.a.AcquireError, "100000|member limit"):
            self.a.inspect_archive(archive, record)

    def test_pinned_boost_member_limit_exception(self):
        boost_sha256 = "49551aff3b22cbc5c5a9ed3dbc92f0e23ea50a0f7325b0d198b705e8ee3fc305"
        archive, base_record = self.archive()
        pinned = replace(base_record, name="boost", version="1.90.0",
                         source=replace(base_record.source, archive_sha256=boost_sha256))

        def synthetic_stream(count):
            root = tarfile.TarInfo("pkg")
            root.type = tarfile.DIRTYPE
            yield root
            for index in range(count - 1):
                member = tarfile.TarInfo(f"pkg/file-{index}")
                member.type = tarfile.REGTYPE
                yield member

        def inspect_with_member_count(record, count):
            stream = synthetic_stream(count)
            with patch.object(self.a, "_sha", return_value=boost_sha256), \
                    patch.object(tarfile, "open", return_value=contextlib.nullcontext(stream)):
                return self.a.inspect_archive(archive, record)

        plan = inspect_with_member_count(pinned, 103065)
        self.assertEqual(len(plan.members), 103065)
        with self.assertRaisesRegex(self.a.AcquireError, "103065 member limit"):
            inspect_with_member_count(pinned, 103066)

    def test_boost_member_limit_exception_requires_exact_lock_identity(self):
        boost_sha256 = "49551aff3b22cbc5c5a9ed3dbc92f0e23ea50a0f7325b0d198b705e8ee3fc305"
        archive, base_record = self.archive()
        pinned = replace(base_record, name="boost", version="1.90.0",
                         source=replace(base_record.source, archive_sha256=boost_sha256))
        non_pinned_records = (
            replace(pinned, name="other"),
            replace(pinned, version="1.90.1"),
            replace(pinned, source=replace(pinned.source, archive_sha256="0" * 64)),
        )
        root = tarfile.TarInfo("pkg")
        root.type = tarfile.DIRTYPE

        def synthetic_stream():
            yield root
            for index in range(100000):
                member = tarfile.TarInfo(f"pkg/file-{index}")
                member.type = tarfile.REGTYPE
                yield member

        for record in non_pinned_records:
            with self.subTest(name=record.name, version=record.version,
                              sha256=record.source.archive_sha256):
                # The synthetic archive represents verified input for this boundary test.
                with patch.object(self.a, "_sha", return_value=record.source.archive_sha256), \
                        patch.object(tarfile, "open", return_value=contextlib.nullcontext(synthetic_stream())):
                    with self.assertRaisesRegex(self.a.AcquireError, "100000 member limit"):
                        self.a.inspect_archive(archive, record)

    def test_safe_links_and_canonical_manifest(self):
        archive, record = self.archive([
            ("pkg/", None), ("pkg/LICENSE", b"license\n"),
            ("pkg/dir", None), ("pkg/dir/link", b"", (tarfile.SYMTYPE, "../LICENSE")),
            ("pkg/copy", b"", (tarfile.LNKTYPE, "pkg/LICENSE"))])
        want = (f'{{"executable":false,"path":"LICENSE","sha256":"{digest(b"license" + bytes([10]))}","type":"file"}}\n'
                f'{{"executable":false,"path":"copy","sha256":"{digest(b"license" + bytes([10]))}","type":"file"}}\n'
                '{"path":"dir","type":"directory"}\n'
                '{"path":"dir/link","target":"../LICENSE","type":"symlink"}\n').encode()
        record = replace(record, source=replace(record.source, tree_manifest_sha256=digest(want)))
        self.cache(archive, record)
        self.acquire(record)
        source = self.project / "Dependencies/fixture"
        self.assertEqual(self.a.tree_manifest(source), want)

        def input_mtimes():
            return {name: (source / name).lstat().st_mtime_ns
                    for name in ("LICENSE", "copy", "dir/link")}

        expected = {name: record.source_date_epoch * 1_000_000_000
                    for name in ("LICENSE", "copy", "dir/link")}
        self.assertEqual(input_mtimes(), expected)
        dependencies = self.project / "Dependencies"
        before = {str(p): p.lstat().st_mtime_ns
                  for p in [dependencies, *dependencies.rglob("*")]}
        self.acquire(record)
        self.assertEqual(before, {
            str(p): p.lstat().st_mtime_ns
            for p in [dependencies, *dependencies.rglob("*")]
        })
        shutil.rmtree(source)
        self.acquire(record)
        self.assertEqual(self.a.tree_manifest(source), want)
        self.assertEqual(input_mtimes(), expected)

    def test_license_and_tree_mismatch_refuse_publication(self):
        archive, record = self.archive()
        self.cache(archive, record)
        for invalid in (replace(record, license_paths=("MISSING",)),
                        replace(record, source=replace(record.source, tree_manifest_sha256="0" * 64))):
            with self.assertRaises(self.a.AcquireError):
                self.acquire(invalid)
            self.assertFalse((self.project / "Dependencies/fixture").exists())

    def test_source_drift_refused_without_repair(self):
        archive, record = self.archive()
        self.cache(archive, record)
        self.acquire(record)
        source = self.project / "Dependencies/fixture/code.c"
        source.write_bytes(b"local edit")
        with self.assertRaisesRegex(self.a.AcquireError, "drift|manifest"):
            self.acquire(record)
        self.assertEqual(source.read_bytes(), b"local edit")

    def test_offline_lists_all_missing_in_order_without_extraction(self):
        archive, record = self.archive()
        self.cache(archive, record)
        lock = DependencyLock(1, (record, replace(record, name="second"), replace(record, name="third")))
        with self.assertRaisesRegex(self.a.AcquireError, r"(?s)second.*third"):
            self.a.acquire_all(self.project, lock, True)
        self.assertFalse((self.project / "Dependencies/fixture").exists())

    def test_offline_reports_missing_cache_even_when_source_exists(self):
        archive, record = self.archive()
        cached = self.cache(archive, record)
        self.acquire(record)
        cached.unlink()
        with self.assertRaisesRegex(self.a.AcquireError, "missing.*fixture"):
            self.acquire(record)
        self.assertEqual((self.project / "Dependencies/fixture/code.c").read_bytes(), b"source\n")

    def test_interrupted_download_leaves_no_cache_or_source(self):
        _, record = self.archive()
        class Interrupted(io.BytesIO):
            def read(self, size=-1):
                if self.tell():
                    raise OSError("interrupted")
                return super().read(10)
        with patch.object(self.a, "open_https", return_value=Interrupted(b"incomplete archive")):
            with self.assertRaises(self.a.AcquireError):
                self.acquire(record, False)
        self.assertEqual(list((self.project / "Dependencies/.downloads").iterdir()), [])
        self.assertFalse((self.project / "Dependencies/fixture").exists())

    def test_download_checksum_and_cache_then_no_network(self):
        archive, record = self.archive()
        with patch.object(self.a, "open_https", return_value=io.BytesIO(archive.read_bytes())):
            self.acquire(record, False)
        shutil.rmtree(self.project / "Dependencies/fixture")
        with patch.object(self.a, "open_https", side_effect=AssertionError("unneeded network")):
            self.acquire(record, False)

    def test_bad_download_and_cache_are_never_published_or_repaired(self):
        archive, record = self.archive()
        with patch.object(self.a, "open_https", return_value=io.BytesIO(b"wrong")):
            with self.assertRaisesRegex(self.a.AcquireError, "checksum"):
                self.acquire(record, False)
        self.assertEqual(list((self.project / "Dependencies/.downloads").iterdir()), [])
        cached = self.cache(archive, record)
        cached.write_bytes(b"preserve bad cache")
        with self.assertRaisesRegex(self.a.AcquireError, "checksum"):
            self.acquire(record, False)
        self.assertEqual(cached.read_bytes(), b"preserve bad cache")

    def test_whitespace_url_refused_before_mutation(self):
        _, record = self.archive()
        record = replace(record, source=replace(record.source, url="https://example.invalid/a b.tar"))
        with self.assertRaisesRegex(self.a.AcquireError, "whitespace"):
            self.acquire(record, False)
        self.assertFalse((self.project / "Dependencies").exists())

    def test_cache_symlink_refused_even_with_existing_valid_source(self):
        archive, record = self.archive()
        cached = self.cache(archive, record)
        self.acquire(record)
        cached.unlink()
        cached.symlink_to(archive)
        with self.assertRaises(self.a.AcquireError):
            self.acquire(record)

    def test_staging_identity_changed_before_publication(self):
        archive, record = self.archive()
        self.cache(archive, record)
        original = self.a._extract
        def substitute(*args):
            original(*args)
            staging = getattr(args[2], "path", args[2])
            staging.rename(staging.with_name(staging.name + "-original"))
            staging.mkdir()
        with patch.object(self.a, "_extract", side_effect=substitute):
            with self.assertRaisesRegex(self.a.AcquireError, "path identity changed before publication"):
                self.acquire(record)
        self.assertFalse((self.project / "Dependencies/fixture").exists())

    def test_staging_swap_before_extraction_leaves_outside_unchanged(self):
        archive, record = self.archive()
        self.cache(archive, record)
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "marker").write_bytes(b"keep")
        before = self.a.tree_manifest(outside), outside.stat().st_mtime_ns
        original = self.a._extract
        def substitute(*args):
            staging = getattr(args[2], "path", args[2])
            staging.rename(staging.with_name(staging.name + "-original"))
            staging.symlink_to(outside, target_is_directory=True)
            return original(*args)
        with patch.object(self.a, "_extract", side_effect=substitute):
            with self.assertRaises(self.a.AcquireError):
                self.acquire(record)
        self.assertEqual((self.a.tree_manifest(outside), outside.stat().st_mtime_ns), before)

    def test_concurrent_cache_publication_preserves_winner_inode(self):
        archive, record = self.archive()
        original = self.a._publish_fd
        winner = None
        def publish_winner(src, dst, *args, **kwargs):
            nonlocal winner
            if winner is None:
                winner = self.cache(archive, record).stat().st_ino
            return original(src, dst, *args, **kwargs)
        with patch.object(self.a, "open_https", return_value=io.BytesIO(archive.read_bytes())), \
             patch.object(self.a, "_publish_fd", side_effect=publish_winner):
            try:
                self.acquire(record, False)
            except self.a.AcquireError:
                pass
        self.assertIsNotNone(winner)
        cached = self.project / "Dependencies/.downloads" / self.a.cache_name(record)
        self.assertEqual(cached.stat().st_ino, winner, "publication clobbered another accepted cache")

    def test_extraction_remains_contained_after_initial_identity_check(self):
        archive, record = self.archive()
        self.cache(archive, record)
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "marker").write_bytes(b"keep")
        before = self.a.tree_manifest(outside), outside.stat().st_mtime_ns
        original = self.a._extract
        def swap_after_check(archive, plan, owner, record):
            checked = owner.check
            swapped = False
            def check():
                nonlocal swapped
                checked()
                if not swapped:
                    swapped = True
                    owner.path.rename(owner.path.with_name(owner.path.name + "-original"))
                    owner.path.symlink_to(outside, target_is_directory=True)
            with patch.object(owner, "check", side_effect=check):
                return original(archive, plan, owner, record)
        with patch.object(self.a, "_extract", side_effect=swap_after_check):
            with self.assertRaises(self.a.AcquireError):
                self.acquire(record)
        self.assertEqual((self.a.tree_manifest(outside), outside.stat().st_mtime_ns), before)

    def test_unsupported_clone_filesystem_fails_closed(self):
        archive, record = self.archive()
        def unsupported(*args):
            self.a.ctypes.set_errno(errno.ENOTSUP)
            return -1
        class UnsupportedLibrary:
            fclonefileat = staticmethod(unsupported)
        with patch.object(self.a, "open_https", return_value=io.BytesIO(archive.read_bytes())), \
             patch.object(self.a.ctypes, "CDLL", return_value=UnsupportedLibrary()):
            with self.assertRaises(self.a.AcquireError):
                self.acquire(record, False)
        self.assertFalse((self.project / "Dependencies/.downloads" / self.a.cache_name(record)).exists())
        self.assertFalse((self.project / "Dependencies/fixture").exists())

    def test_source_publication_uses_verified_directory_fd(self):
        archive, record = self.archive()
        self.cache(archive, record)
        original = self.a._publish_fd
        def swap_temporary(src, dst, name):
            staging = next((self.project / "Dependencies").glob(".staging-*"))
            staging.rename(staging.with_name(staging.name + "-verified"))
            staging.mkdir()
            (staging / "LICENSE").write_bytes(b"unverified replacement")
            return original(src, dst, name)
        with patch.object(self.a, "_publish_fd", side_effect=swap_temporary):
            with self.assertRaises(self.a.AcquireError):
                self.acquire(record)
        published = self.project / "Dependencies/fixture"
        self.assertEqual((published / "LICENSE").read_bytes(), b"license\n")
        self.assertEqual((published / "code.c").read_bytes(), b"source\n")

    def test_publication_uses_verified_inode_after_temporary_entry_substitution(self):
        archive, record = self.archive()
        original = self.a._publish_fd
        substituted = False
        def swap_temporary(src, dst, *args, **kwargs):
            nonlocal substituted
            if not substituted:
                substituted = True
                partial = next((self.project / "Dependencies/.downloads").glob(".partial-*"))
                partial.rename(partial.with_name(partial.name + "-verified"))
                partial.write_bytes(b"unverified replacement")
            return original(src, dst, *args, **kwargs)
        with patch.object(self.a, "open_https", return_value=io.BytesIO(archive.read_bytes())), \
             patch.object(self.a, "_publish_fd", side_effect=swap_temporary):
            try:
                self.acquire(record, False)
            except self.a.AcquireError:
                pass
        self.assertTrue(substituted)
        cached = self.project / "Dependencies/.downloads" / self.a.cache_name(record)
        if cached.exists():
            self.assertEqual(cached.read_bytes(), archive.read_bytes(), "unverified bytes became public")

    def test_symlink_layout_rejected(self):
        _, record = self.archive()
        outside = self.base / "outside"
        outside.mkdir()
        (self.project / "Dependencies").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(self.a.AcquireError):
            self.acquire(record)
        self.assertEqual(list(outside.iterdir()), [])

    def test_publication_races_do_not_touch_outside(self):
        for mode in ("cache", "destination"):
            with self.subTest(mode=mode):
                archive, record = self.archive()
                outside = self.base / ("outside-" + mode)
                outside.mkdir()
                marker = outside / "marker"
                marker.write_bytes(b"keep")
                real_replace = self.a._publish_fd
                raced = False
                def race(src, dst, *args, **kwargs):
                    nonlocal raced
                    if not raced:
                        raced = True
                        target = self.project / "Dependencies" / (".downloads" if mode == "cache" else "fixture")
                        if target.exists():
                            target.rename(target.with_name(target.name + "-old"))
                        target.symlink_to(outside, target_is_directory=True)
                    return real_replace(src, dst, *args, **kwargs)
                if mode == "destination":
                    self.cache(archive, record)
                (self.project / "config").mkdir(exist_ok=True)
                (self.project / "config/dependencies.lock").write_bytes(canonical_bytes(DependencyLock(1, (record,))))
                stderr = io.StringIO()
                with patch.object(self.a, "open_https", return_value=io.BytesIO(archive.read_bytes())), \
                     patch.object(self.a, "_publish_fd", side_effect=race), contextlib.redirect_stderr(stderr):
                    self.assertEqual(self.a.main(["--project-root", str(self.project)]), 1)
                self.assertIn("path identity changed before publication", stderr.getvalue())
                self.assertEqual(marker.read_bytes(), b"keep")
                shutil.rmtree(self.project / "Dependencies")

    def git(self, directory, *args):
        return subprocess.run(["git", "-C", str(directory), *args], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

    def git_record(self, gitlink=False):
        remote = self.base / "remote"
        remote.mkdir()
        self.git(remote, "init", "-q")
        self.git(remote, "config", "user.name", "Fixture")
        self.git(remote, "config", "user.email", "fixture@example.invalid")
        self.git(remote, "config", "commit.gpgsign", "false")
        (remote / "LICENSE").write_bytes(b"license\n")
        self.git(remote, "add", ".")
        self.git(remote, "commit", "-qm", "fixture")
        if gitlink:
            head = self.git(remote, "rev-parse", "HEAD").decode().strip()
            self.git(remote, "update-index", "--add", "--cacheinfo", f"160000,{head},third_party/googletest")
            self.git(remote, "commit", "-qm", "gitlink")
        commit = self.git(remote, "rev-parse", "HEAD").decode().strip()
        source = replace(self.template.source, kind="git", url="https://example.invalid/repo.git",
                         archive_sha256=None, commit=commit, tag=None,
                         tree_manifest_sha256=digest(self.git(remote, "ls-tree", "-r", "--full-tree", commit)))
        record = replace(self.template, name="snappy", adapter="cmake", source=source,
                         configure_options=("-DSNAPPY_BUILD_TESTS=OFF", "-DSNAPPY_BUILD_BENCHMARKS=OFF"))
        def fetch(repository, pinned):
            self.git(repository, "-c", "protocol.file.allow=always", "fetch", "--no-tags", "--no-recurse-submodules",
                     str(remote), pinned.source.commit)
        return record, fetch

    def test_git_cache_offline_and_drift(self):
        record, fetch = self.git_record()
        with patch.object(self.a, "_fetch_git", side_effect=fetch):
            self.acquire(record, False)
        source = self.project / "Dependencies/snappy"
        self.assertEqual(self.git(source, "rev-parse", "HEAD").decode().strip(), record.source.commit)
        self.assertEqual((source / "LICENSE").lstat().st_mtime_ns,
                         record.source_date_epoch * 1_000_000_000)
        shutil.rmtree(source)
        self.acquire(record)
        self.assertEqual((source / "LICENSE").lstat().st_mtime_ns,
                         record.source_date_epoch * 1_000_000_000)
        dependencies = self.project / "Dependencies"
        before = {str(p): p.lstat().st_mtime_ns
                  for p in [dependencies, *dependencies.rglob("*")]}
        self.acquire(record)
        self.assertEqual(before, {str(p): p.lstat().st_mtime_ns
                                 for p in [dependencies, *dependencies.rglob("*")]})
        for mode in ("tracked", "staged", "untracked", "ignored"):
            with self.subTest(mode=mode):
                if mode in ("tracked", "staged"):
                    (source / "LICENSE").write_bytes(b"drift")
                    if mode == "staged":
                        self.git(source, "add", "LICENSE")
                else:
                    (source / "extra").write_bytes(b"drift")
                    if mode == "ignored":
                        (source / ".git/info/exclude").write_text("extra\n")
                with self.assertRaisesRegex(self.a.AcquireError, "drift"):
                    self.acquire(record)
                shutil.rmtree(source)
                self.acquire(record)

    def test_git_wrong_commit_tree_and_origin(self):
        record, fetch = self.git_record()
        with patch.object(self.a, "_fetch_git", side_effect=fetch):
            self.acquire(record, False)
        source = self.project / "Dependencies/snappy"
        for invalid in (replace(record, source=replace(record.source, commit="0" * 40)),
                        replace(record, source=replace(record.source, tree_manifest_sha256="0" * 64)),
                        replace(record, source=replace(record.source, url="https://example.invalid/other.git"))):
            with self.assertRaises(self.a.AcquireError):
                self.acquire(invalid)
        self.assertTrue((source / "LICENSE").is_file())

    def test_git_reuse_never_executes_local_commands(self):
        record, fetch = self.git_record()
        with patch.object(self.a, "_fetch_git", side_effect=fetch):
            self.acquire(record, False)
        source = self.project / "Dependencies/snappy"
        marker = self.base / "executed"
        helper = self.base / "hostile-command"
        helper.write_text(f"#!/bin/sh\ntouch '{marker}'\n")
        helper.chmod(0o755)
        self.git(source, "config", "core.fsmonitor", str(helper))
        try:
            self.acquire(record)
        except self.a.AcquireError:
            pass
        self.assertFalse(marker.exists(), "verification executed local core.fsmonitor")
        self.git(source, "config", "--unset", "core.fsmonitor")
        self.git(source, "config", "filter.hostile.clean", str(helper))
        (source / ".git/info/attributes").write_text("LICENSE filter=hostile\n")
        try:
            self.acquire(record)
        except self.a.AcquireError:
            pass
        self.assertFalse(marker.exists(), "verification executed local clean filter")

    def test_git_corrupt_bundle_refused_with_valid_source(self):
        record, fetch = self.git_record()
        with patch.object(self.a, "_fetch_git", side_effect=fetch):
            self.acquire(record, False)
        cached = self.project / "Dependencies/.downloads" / self.a.cache_name(record)
        good = cached.read_bytes()
        for data in (b"not a bundle", good[:-30]):
            with self.subTest(size=len(data)):
                cached.write_bytes(data)
                with self.assertRaises(self.a.AcquireError):
                    self.acquire(record)
                self.assertEqual(cached.read_bytes(), data)
                self.assertEqual((self.project / "Dependencies/snappy/LICENSE").read_bytes(), b"license\n")

    def test_git_wrong_bundle_refused_with_valid_source(self):
        record, fetch = self.git_record()
        with patch.object(self.a, "_fetch_git", side_effect=fetch):
            self.acquire(record, False)
        cached = self.project / "Dependencies/.downloads" / self.a.cache_name(record)
        remote = self.base / "remote"
        self.git(remote, "checkout", "--orphan", "unrelated")
        (remote / "LICENSE").write_bytes(b"other license\n")
        self.git(remote, "add", ".")
        self.git(remote, "commit", "-qm", "unrelated")
        cached.unlink()
        self.git(remote, "bundle", "create", str(cached), "HEAD")
        with self.assertRaises(self.a.AcquireError):
            self.acquire(record)

    def test_git_attached_branch_is_identity_drift(self):
        record, fetch = self.git_record()
        with patch.object(self.a, "_fetch_git", side_effect=fetch):
            self.acquire(record, False)
        source = self.project / "Dependencies/snappy"
        self.git(source, "checkout", "-qb", "mutable")
        with self.assertRaisesRegex(self.a.AcquireError, "detached|drift"):
            self.acquire(record)

    def test_git_transport_environment_has_no_ambient_credentials_or_proxies(self):
        self.git(self.project, "init", "-q")
        ambient = self.base / "ambient"
        ambient.mkdir()
        (ambient / ".netrc").write_text("machine example.invalid login private password secret\n")
        with patch.dict(os.environ, {"HOME": str(ambient), "HTTPS_PROXY": "https://private:secret@proxy.invalid",
                                     "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "credential.helper",
                                     "GIT_CONFIG_VALUE_0": "private-helper"}):
            raw = self.a._git(self.project, "-c", "alias.environment=!env", "environment")
        environment = dict(line.split("=", 1) for line in raw.decode().splitlines() if "=" in line)
        self.assertNotIn("HTTPS_PROXY", environment)
        self.assertNotIn("GIT_CONFIG_COUNT", environment)
        self.assertIn("HOME", environment, "libcurl needs an explicit isolated home to avoid passwd-home .netrc fallback")
        self.assertFalse(Path(environment["HOME"]).is_dir())

    def test_gitlinks_uninitialized_and_required_gitlinks_refused(self):
        record, fetch = self.git_record(True)
        with patch.object(self.a, "_fetch_git", side_effect=fetch):
            self.acquire(record, False)
        source = self.project / "Dependencies/snappy"
        link = source / "third_party/googletest"
        self.assertFalse(link.exists())
        self.git(source, "update-index", "--cacheinfo", f"160000,{'1' * 40},third_party/googletest")
        with self.assertRaisesRegex(self.a.AcquireError, "drift"):
            self.acquire(record)
        shutil.rmtree(source)
        self.acquire(record)
        link.mkdir(parents=True)
        (link / "local").write_text("initialized")
        with self.assertRaises(self.a.AcquireError):
            self.acquire(record)
        shutil.rmtree(source)
        required = replace(record, configure_options=("-DSNAPPY_BUILD_TESTS=ON",))
        with self.assertRaisesRegex(self.a.AcquireError, "gitlink"):
            self.acquire(required)

    def test_update_cli_forms_and_gate_default_skip(self):
        for args in (("--offline",), ("--dependencies", "extra"), ("--dependencies", "--offline", "extra")):
            result = subprocess.run([str(ROOT / "scripts/update"), *args], capture_output=True)
            self.assertEqual(result.returncode, 64)
        for relative in ("scripts/update", "scripts/lib/dependency_acquire.py", "scripts/lib/dependency_lock.py"):
            target = self.project / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        (self.project / "config").mkdir()
        _, record = self.archive()
        (self.project / "config/dependencies.lock").write_bytes(canonical_bytes(DependencyLock(1, (record,))))
        result = subprocess.run([str(self.project / "scripts/update"), "--dependencies", "--offline"], capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"missing", result.stderr)
        gate = ROOT / "tests/gate6_dependency_acquisition_test.sh"
        self.assertTrue(gate.is_file())
        result = subprocess.run(["sh", str(gate)], env={**os.environ, "AIRDCCORE_RUN_DEPENDENCY_NETWORK_TESTS": "0"}, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"SKIP", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
