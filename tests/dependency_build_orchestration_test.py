#!/usr/bin/env python3
"""Behavioral tests for isolated dependency builds and accepted prefixes."""

from __future__ import annotations

from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "scripts/lib"
sys.path.insert(0, str(LIB))

import dependency_build as build
import dependency_prefix as prefix
from dependency_lock import DependencyLock, DependencyRecord, Platform, Source


def record(name="fixture", dependencies=()):
    return DependencyRecord(
        name=name,
        version="1.0",
        role="aggregate",
        source=Source("archive", "https://example.invalid/fixture.tar.gz", "0" * 64,
                      None, None, "1" * 64),
        source_date_epoch=1_700_000_000,
        dependencies=tuple(dependencies),
        adapter="cmake",
        configure_options=("-S", "@SOURCE@", "-B", "@BUILD@",
                           "-DCMAKE_INSTALL_PREFIX=@STAGE@", "-DSDK=@SDKROOT@"),
        build_options=("--parallel", "@JOBS@"),
        install_options=("--prefix=@STAGE@",),
        expected_headers=("include/fixture.h",),
        expected_archives=("lib/libfixture.a",),
        expected_metadata=("lib/pkgconfig/fixture.pc",),
        forbidden_globs=("**/*.dylib", "**/*.so", "**/*.so.*", "**/*.la"),
        license_spdx="MIT",
        license_paths=("LICENSE",),
        patches=(),
        platform=Platform("arm64", "14.0", "Release", "libc++", "static"),
    )


def run(*argv, cwd=None):
    subprocess.run(argv, cwd=cwd, check=True, capture_output=True)


def make_archive(destination: Path, architecture="arm64", embedded="clean"):
    source = destination.with_suffix(".c")
    obj = destination.with_suffix(".o")
    source.write_text(f'const char *fixture_path = "{embedded}"; int fixture(void) {{ return 42; }}\n')
    clang = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    ar = subprocess.check_output(["xcrun", "--find", "ar"], text=True).strip()
    run(clang, "-arch", architecture, "-mmacosx-version-min=14.0", "-c", str(source), "-o", str(obj))
    run(ar, "rcs", str(destination), str(obj))
    source.unlink()
    obj.unlink()


class PrefixValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys.platform != "darwin":
            raise unittest.SkipTest("ARM64 Mach-O prefix validation requires macOS")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="airdc-prefix-test-")
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name).resolve()
        self.source = self.project / "Dependencies/fixture"
        self.build_root = self.project / "Build/dependencies/fixture"
        self.home = self.project / "private-home"
        self.accepted = self.project / "Build/prefix/fixture"
        for path in (self.source, self.build_root, self.home):
            path.mkdir(parents=True)
        self.roots = {
            "project": self.project,
            "source": self.source,
            "build": self.build_root,
            "home": self.home,
        }

    def valid_prefix(self, root=None, *, architecture="arm64", embedded="clean"):
        root = root or self.accepted
        (root / "include").mkdir(parents=True)
        (root / "lib/pkgconfig").mkdir(parents=True)
        (root / "include/fixture.h").write_text("int fixture(void);\n")
        (root / "lib/pkgconfig/fixture.pc").write_text(
            "prefix=${pcfiledir}/../..\nName: fixture\nVersion: 1.0\nLibs: -L${prefix}/lib -lfixture\n"
        )
        (root / "LICENSE").write_text("MIT\n")
        make_archive(root / "lib/libfixture.a", architecture, embedded)
        return root

    def test_valid_real_arm64_archive_produces_normalized_manifest_and_inventory(self):
        self.valid_prefix()
        report = prefix.validate_prefix(record(), self.accepted, self.roots)
        self.assertEqual(report.role, "aggregate")
        self.assertEqual(len(report.manifest_sha256), 64)
        self.assertIn("$PREFIX/lib/libfixture.a", report.manifest)
        self.assertEqual(report.archives[0].architectures, ("arm64",))
        self.assertIn("fixture", report.archives[0].defined_symbols)

    def test_missing_expected_output_and_forbidden_or_foreign_outputs_are_rejected(self):
        cases = {
            "missing expected": lambda p: (p / "include/fixture.h").unlink(),
            "shared output": lambda p: (p / "lib/libbad.dylib").write_bytes(b"bad"),
            "foreign library file": lambda p: (p / "lib/README.txt").write_text("bad"),
            "undeclared top-level root": lambda p: (p / "bin").mkdir(),
        }
        for message, mutate in cases.items():
            with self.subTest(message=message):
                root = self.project / ("case-" + message.replace(" ", "-"))
                self.valid_prefix(root)
                mutate(root)
                with self.assertRaisesRegex(prefix.PrefixError, message):
                    prefix.validate_prefix(record(), root, self.roots)

    def test_absolute_and_escaping_symlinks_are_rejected(self):
        for target in ("/tmp/outside", "../../outside"):
            with self.subTest(target=target):
                root = self.project / ("link-" + hashlib.sha256(target.encode()).hexdigest()[:6])
                self.valid_prefix(root)
                (root / "include/bad.h").symlink_to(target)
                with self.assertRaisesRegex(prefix.PrefixError, "unsafe link"):
                    prefix.validate_prefix(record(), root, self.roots)

    def test_symlink_chain_cannot_escape_prefix(self):
        root = self.valid_prefix(self.project / "link-chain")
        (root / "include/first.h").symlink_to("second.h")
        (root / "include/second.h").symlink_to("../../../outside")
        with self.assertRaisesRegex(prefix.PrefixError, "unsafe link"):
            prefix.validate_prefix(record(), root, self.roots)

    def test_wrong_architecture_and_non_archive_bytes_are_rejected(self):
        wrong = self.project / "wrong"
        self.valid_prefix(wrong, architecture="x86_64")
        with self.assertRaisesRegex(prefix.PrefixError, "architecture"):
            prefix.validate_prefix(record(), wrong, self.roots)
        bogus = self.project / "bogus"
        self.valid_prefix(bogus)
        (bogus / "lib/libfixture.a").write_bytes(b"not an archive")
        with self.assertRaisesRegex(prefix.PrefixError, "archive"):
            prefix.validate_prefix(record(), bogus, self.roots)

    def test_source_build_home_and_homebrew_leakage_is_rejected(self):
        leaks = (str(self.project), str(self.source), str(self.build_root), str(self.home),
                 str(Path.home()), "/opt/homebrew", "/usr/local/Cellar/zlib", "Cellar/zlib")
        for index, leak in enumerate(leaks):
            with self.subTest(leak=leak):
                root = self.project / f"leak-{index}"
                self.valid_prefix(root)
                (root / "include/fixture.h").write_text(f'const char *p = "{leak}";\n')
                with self.assertRaisesRegex(prefix.PrefixError, "path leakage"):
                    prefix.validate_prefix(record(), root, self.roots)

    def test_archive_string_leakage_is_rejected(self):
        root = self.project / "archive-leak"
        self.valid_prefix(root, embedded="/opt/homebrew/Cellar/fixture/1.0")
        with self.assertRaisesRegex(prefix.PrefixError, "path leakage"):
            prefix.validate_prefix(record(), root, self.roots)

    def test_malformed_package_metadata_is_rejected(self):
        root = self.valid_prefix(self.project / "malformed")
        (root / "lib/pkgconfig/fixture.pc").write_text("prefix without equals\n")
        with self.assertRaisesRegex(prefix.PrefixError, "malformed package metadata"):
            prefix.validate_prefix(record(), root, self.roots)

    def test_package_metadata_requires_name_and_version_fields(self):
        root = self.valid_prefix(self.project / "missing-pc-fields")
        (root / "lib/pkgconfig/fixture.pc").write_text("Name: fixture\nLibs: -lfixture\n")
        with self.assertRaisesRegex(prefix.PrefixError, "malformed package metadata"):
            prefix.validate_prefix(record(), root, self.roots)


class OrchestrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys.platform != "darwin":
            raise unittest.SkipTest("dependency build fixtures require macOS")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="airdc-build-test-")
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name).resolve()
        (self.project / "config").mkdir(parents=True)
        (self.project / "scripts/lib/dependencies").mkdir(parents=True)
        self.records = (record("a"), record("b", ("a",)))
        self.lock = DependencyLock(1, self.records)
        for item in self.records:
            source = self.project / "Dependencies" / item.name
            (source / "payload/include").mkdir(parents=True)
            (source / "payload/lib/pkgconfig").mkdir(parents=True)
            (source / "payload/include/fixture.h").write_text("int fixture(void);\n")
            (source / "payload/lib/pkgconfig/fixture.pc").write_text(
                "prefix=${pcfiledir}/../..\nName: fixture\nVersion: 1.0\nLibs: -L${prefix}/lib -lfixture\n"
            )
            (source / "payload/LICENSE").write_text("MIT\n")
            make_archive(source / "payload/lib/libfixture.a")
            self.write_adapter(item.name)
        self.tools = build.ToolInventory(
            sdkroot="/SDK", sdk_version="14.4", apple={
                "cc": "/usr/bin/clang", "cxx": "/usr/bin/clang++",
                "ar": "/usr/bin/ar", "ranlib": "/usr/bin/ranlib",
                "lipo": "/usr/bin/lipo", "nm": "/usr/bin/nm",
                "otool": "/usr/bin/otool", "strings": "/usr/bin/strings",
            }, host={"cmake": "/opt/homebrew/bin/cmake", "ninja": "/opt/homebrew/bin/ninja",
                     "perl": "/usr/bin/perl", "make": "/usr/bin/make"})

    def write_adapter(self, name, extra=""):
        path = self.project / f"scripts/lib/dependencies/build_{name}.sh"
        path.write_text("""#!/bin/sh
set -eu
source=$1
build=$2
stage=$3
/bin/mkdir -p "$build" "$stage"
/usr/bin/printf '%s\\n' "$@" > "$build/argv.txt"
/usr/bin/env | /usr/bin/sort > "$build/env.txt"
/bin/cp -R "$source/payload/." "$stage/"
""" + extra)
        path.chmod(0o755)
        return path

    def invoke(self, lock=None):
        with patch.object(build, "acquire_all") as acquire, \
             patch.object(build, "resolve_tool_inventory", return_value=self.tools), \
             patch.object(build, "job_count", return_value=3):
            build.build_all(self.project, lock or self.lock)
            acquire.assert_called_once_with(self.project, lock or self.lock, True)

    def test_builds_in_lock_order_with_exact_argv_expansions_and_allowlisted_environment(self):
        order = self.project / "order.txt"
        for item in self.records:
            self.write_adapter(item.name, f'/usr/bin/printf "%s\\n" {item.name} >> "{order}"\n')
        self.invoke()
        self.assertEqual(order.read_text().splitlines(), ["a", "b"])
        for item in self.records:
            component = self.project / "Build/dependencies" / item.name
            argv = (component / "build/argv.txt").read_text().splitlines()
            self.assertEqual(argv[0], str(self.project / "Dependencies" / item.name))
            self.assertEqual(argv[1], str(component / "build"))
            self.assertTrue(Path(argv[2]).name.startswith(f".staging-{item.name}-"))
            self.assertEqual(argv[3:5], ["3", str(item.source_date_epoch)])
            if item.name == "b":
                self.assertEqual(argv[5:], [str(self.project / "Build/prefix/a")])
            environment = dict(line.split("=", 1) for line in (component / "build/env.txt").read_text().splitlines())
            # /bin/sh itself synthesizes these bookkeeping names after exec;
            # the orchestrator-provided environment remains the strict set.
            self.assertEqual(set(environment) - {"PWD", "SHLVL", "_"},
                             set(build.BUILD_ENVIRONMENT_KEYS))
            self.assertEqual(environment["HOME"], str(component / "home"))
            self.assertEqual(environment["TMPDIR"], str(component / "tmp"))
            self.assertEqual(environment["MACOSX_DEPLOYMENT_TARGET"], "14.0")
            self.assertEqual(environment["SDKROOT"], "/SDK")
        options = json.loads((self.project / "Build/dependencies/a/evidence/expanded-options.json").read_text())
        self.assertEqual(options["configure"][:4], ["-S", str(self.project / "Dependencies/a"),
                                                    "-B", str(self.project / "Build/dependencies/a/build")])
        self.assertEqual(options["build"], ["--parallel", "3"])
        self.assertEqual(options["install"][0].split("=", 1)[0], "--prefix")
        licenses = json.loads((self.project / "Build/dependencies/a/evidence/license-inventory.json").read_text())
        self.assertEqual(licenses, [{"path": "$PREFIX/LICENSE",
                                     "sha256": hashlib.sha256(b"MIT\n").hexdigest()}])

    def test_matching_fingerprint_and_revalidated_prefix_is_a_noop(self):
        self.invoke()
        evidence = self.project / "Build/dependencies/a/evidence"
        accepted = self.project / "Build/prefix/a"
        before = (evidence.stat().st_mtime_ns, prefix.tree_digest(accepted))
        with patch.object(build, "run_adapter", side_effect=AssertionError("adapter reran")), \
             patch.object(build, "acquire_all"), \
             patch.object(build, "resolve_tool_inventory", return_value=self.tools), \
             patch.object(build, "job_count", return_value=3):
            build.build_all(self.project, self.lock)
        self.assertEqual(before, (evidence.stat().st_mtime_ns, prefix.tree_digest(accepted)))

    def test_failure_preserves_prior_prefix_and_retry_archives_immutable_evidence(self):
        old = self.project / "Build/prefix/a"
        old.mkdir(parents=True)
        (old / "marker").write_text("old\n")
        self.write_adapter("a", "exit 7\n")
        with self.assertRaises(build.BuildError):
            self.invoke(DependencyLock(1, (self.records[0],)))
        self.assertEqual((old / "marker").read_text(), "old\n")
        evidence = self.project / "Build/dependencies/a/evidence"
        self.assertEqual((evidence / "exit-status.txt").read_text(), "7\n")
        self.write_adapter("a")
        self.invoke(DependencyLock(1, (self.records[0],)))
        attempt = evidence / "attempts/0001"
        self.assertEqual((attempt / "exit-status.txt").read_text(), "7\n")
        check = subprocess.run(["shasum", "-a", "256", "-c", "sha256.txt"], cwd=attempt,
                               capture_output=True, text=True)
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertFalse((old / "marker").exists())

    def test_retry_refuses_symlinked_attempt_history(self):
        evidence = self.project / "Build/dependencies/a/evidence"
        evidence.mkdir(parents=True)
        (evidence / "adapter.log").write_text("failed\n")
        outside = self.project / "outside"
        outside.mkdir()
        (evidence / "attempts").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(build.BuildError, "unsafe evidence"):
            self.invoke(DependencyLock(1, (self.records[0],)))
        self.assertEqual(list(outside.iterdir()), [])
        self.assertEqual((evidence / "adapter.log").read_text(), "failed\n")

    def test_cross_prefix_write_is_detected(self):
        self.invoke(DependencyLock(1, (self.records[0],)))
        self.write_adapter("b", '/usr/bin/printf "tampered\\n" >> "$6/LICENSE"\n')
        with self.assertRaisesRegex(build.BuildError, "cross-prefix write"):
            self.invoke()

    def test_adapter_cannot_create_another_accepted_prefix(self):
        self.write_adapter("a", '/bin/mkdir -p "$(/usr/bin/dirname "$stage")/intruder"\n')
        with self.assertRaisesRegex(build.BuildError, "cross-prefix write"):
            self.invoke(DependencyLock(1, (self.records[0],)))
        self.assertFalse((self.project / "Build/prefix/a").exists())

    def test_existing_component_symlink_cannot_redirect_evidence(self):
        outside = self.project / "outside"
        outside.mkdir()
        component = self.project / "Build/dependencies/a"
        component.parent.mkdir(parents=True)
        component.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(build.BuildError, "unsafe build directory"):
            self.invoke(DependencyLock(1, (self.records[0],)))
        self.assertEqual(list(outside.iterdir()), [])

    def test_failed_publication_does_not_mark_old_prefix_accepted(self):
        self.invoke(DependencyLock(1, (self.records[0],)))
        evidence = self.project / "Build/dependencies/a/evidence"
        old_fingerprint = (evidence / "input-fingerprint.txt").read_bytes()
        adapter = self.write_adapter("a", '/usr/bin/printf "new\\n" >> "$stage/LICENSE"\n')
        with patch.object(build, "_rename_swap", side_effect=OSError("publication failed")):
            with self.assertRaises(build.BuildError):
                self.invoke(DependencyLock(1, (self.records[0],)))
        self.assertFalse((evidence / "input-fingerprint.txt").exists())
        self.assertEqual((evidence / "attempts/0001/input-fingerprint.txt").read_bytes(), old_fingerprint)
        self.assertEqual((self.project / "Build/prefix/a/LICENSE").read_text(), "MIT\n")
        self.assertIn("publication", (evidence / "error.txt").read_text())
        self.assertTrue(adapter.exists())

    def test_failed_validation_does_not_replace_prior_prefix(self):
        old = self.project / "Build/prefix/a"
        old.mkdir(parents=True)
        (old / "marker").write_text("old\n")
        self.write_adapter("a", '/usr/bin/touch "$stage/lib/libbad.dylib"\n')
        with self.assertRaises(build.BuildError):
            self.invoke(DependencyLock(1, (self.records[0],)))
        self.assertEqual((old / "marker").read_text(), "old\n")

    def test_publication_uses_pinned_parent_when_visible_prefix_root_is_swapped(self):
        root = self.project / "Build/prefix"
        root.mkdir(parents=True)
        stage = root / ".staging-a-test"
        stage.mkdir()
        (stage / "marker").write_text("new\n")
        outside = self.project / "outside"
        outside.mkdir()
        (outside / "marker").write_text("outside\n")
        moved = root.with_name("prefix-original")
        real_rename = os.rename
        real_rename_atx = build._rename_atx
        swapped = False

        def race(parent_fd, src, dst, flags):
            nonlocal swapped
            if not swapped:
                swapped = True
                real_rename(root, moved)
                root.symlink_to(outside, target_is_directory=True)
            return real_rename_atx(parent_fd, src, dst, flags)

        try:
            with patch.object(build, "_rename_atx", side_effect=race):
                with self.assertRaisesRegex(build.BuildError, "identity changed"):
                    build.publish_prefix(stage, root / "a", root)
            self.assertEqual((outside / "marker").read_text(), "outside\n")
            self.assertFalse((outside / "a").exists())
        finally:
            if root.is_symlink():
                root.unlink()
            if moved.exists():
                moved.rename(root)

    def test_first_publication_refuses_target_created_after_check(self):
        root = self.project / "Build/prefix"
        root.mkdir(parents=True)
        stage = root / ".staging-a-test"
        stage.mkdir()
        (stage / "marker").write_text("new\n")
        target = root / "a"

        def appear(path):
            self.assertEqual(path, target)
            target.mkdir()
            return None

        with patch.object(build, "_identity", side_effect=appear):
            with self.assertRaises(build.BuildError):
                build.publish_prefix(stage, target, root)
        self.assertTrue(target.is_dir())
        self.assertEqual(list(target.iterdir()), [])
        self.assertEqual((stage / "marker").read_text(), "new\n")

    def test_staging_name_swap_cannot_discard_existing_prefix(self):
        root = self.project / "Build/prefix"
        root.mkdir(parents=True)
        stage = root / ".staging-a-test"
        stage.mkdir()
        (stage / "marker").write_text("new\n")
        target = root / "a"
        target.mkdir()
        (target / "marker").write_text("old\n")
        hidden = root / ".hidden-stage"
        real_swap = build._rename_swap
        substituted = False

        def substitute(parent_fd, first, second):
            nonlocal substituted
            if not substituted:
                substituted = True
                stage.rename(hidden)
                stage.mkdir()
                (stage / "marker").write_text("unvalidated\n")
            return real_swap(parent_fd, first, second)

        with patch.object(build, "_rename_swap", side_effect=substitute):
            with self.assertRaisesRegex(build.BuildError, "staging identity changed"):
                build.publish_prefix(stage, target, root)
        self.assertEqual((target / "marker").read_text(), "old\n")


class BuildEntryPointTests(unittest.TestCase):
    def test_build_dependencies_mode_executes_python_entry_point(self):
        with tempfile.TemporaryDirectory(prefix="airdc-entry-test-") as directory:
            project = Path(directory)
            (project / "scripts/lib").mkdir(parents=True)
            shutil.copyfile(ROOT / "scripts/build", project / "scripts/build")
            (project / "scripts/build").chmod(0o755)
            marker = project / "marker"
            (project / "scripts/lib/dependency_build.py").write_text(
                "from pathlib import Path\nimport sys\n"
                f"Path({str(marker)!r}).write_text(' '.join(sys.argv[1:]))\n"
            )
            result = subprocess.run([str(project / "scripts/build"), "--build-dependencies"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(marker.read_text(), f"--project-root {project.resolve()}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
