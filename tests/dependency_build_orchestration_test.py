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


def filesystem_state(root: Path):
    """Capture every entry without following links for exact restoration checks."""
    entries = []
    for path in sorted(root.rglob("*"), key=lambda item: os.fsencode(item.relative_to(root))):
        relative = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode
        if path.is_symlink():
            detail = ("symlink", os.readlink(path))
        elif path.is_dir():
            detail = ("directory",)
        else:
            detail = ("file", hashlib.sha256(path.read_bytes()).hexdigest(), mode & 0o777)
        entries.append((relative, *detail))
    return tuple(entries)


def make_archive(destination: Path, architecture="arm64", embedded="clean",
                 minimum="14.0", target=None):
    source = destination.with_suffix(".c")
    obj = destination.with_suffix(".o")
    source.write_text(f'const char *fixture_path = "{embedded}"; int fixture(void) {{ return 42; }}\n')
    clang = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    ar = subprocess.check_output(["xcrun", "--find", "ar"], text=True).strip()
    platform_args = ("-target", target) if target else ("-arch", architecture,
                     f"-mmacosx-version-min={minimum}")
    run(clang, *platform_args, "-c", str(source), "-o", str(obj))
    run(ar, "rcs", str(destination), str(obj))
    source.unlink()
    obj.unlink()


class InspectionOutputTests(unittest.TestCase):
    def test_run_preserves_non_utf8_output_as_byte_escapes(self):
        output = prefix._run((sys.executable, "-c",
                              "import os; os.write(1, b'clean\\xf0\\n'); os.write(2, b'\\xff')"))
        self.assertEqual(output, "clean\\xf0\n")


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

    def test_validator_uses_inventoried_inspection_tools(self):
        self.valid_prefix()
        names = ("ar", "lipo", "nm", "otool", "strings")
        inventory = {name: subprocess.check_output(["xcrun", "--find", name],
                                                    text=True).strip() for name in names}
        with patch.object(prefix, "_apple_tool", side_effect=AssertionError("ambient resolution")):
            report = prefix.validate_prefix(record(), self.accepted, self.roots,
                                            tools=inventory)
        self.assertEqual(report.archives[0].architectures, ("arm64",))

    def test_strings_path_leak_adjacent_to_non_utf8_byte_is_rejected(self):
        self.valid_prefix()
        inspect_run = prefix._run

        def output_with_leak(argv, **kwargs):
            if kwargs.get("purpose", "").startswith("strings "):
                return inspect_run((sys.executable, "-c",
                                    "import os; os.write(1, b'\\xf0/opt/homebrew/lib/forbidden\\xff')"))
            return inspect_run(argv, **kwargs)

        with patch.object(prefix, "_run", side_effect=output_with_leak):
            with self.assertRaisesRegex(prefix.PrefixError, "path leakage"):
                prefix.validate_prefix(record(), self.accepted, self.roots)

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

    def test_archive_rejects_arm64_dylib_member(self):
        root = self.valid_prefix(self.project / "dylib-member")
        source = self.project / "member.c"
        member = self.project / "member.dylib"
        source.write_text("int fixture(void) { return 42; }\n")
        clang = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
        ar = subprocess.check_output(["xcrun", "--find", "ar"], text=True).strip()
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        compiled = subprocess.run([clang, "-arch", "arm64", "-dynamiclib", "-install_name",
                                   "@rpath/member.dylib", "-mmacosx-version-min=14.0",
                                   "-isysroot", sdk, str(source), "-o", str(member)],
                                  capture_output=True, text=True)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        archive = root / "lib/libfixture.a"
        archive.unlink()
        run(ar, "rcs", str(archive), str(member))
        with self.assertRaisesRegex(prefix.PrefixError, "relocatable object"):
            prefix.validate_prefix(record(), root, self.roots)

    def test_archive_rejects_newer_macos_minimum(self):
        root = self.valid_prefix(self.project / "newer-minimum")
        make_archive(root / "lib/libfixture.a", minimum="15.0")
        with self.assertRaisesRegex(prefix.PrefixError, "deployment target"):
            prefix.validate_prefix(record(), root, self.roots)

    def test_archive_rejects_ios_object(self):
        root = self.valid_prefix(self.project / "ios-member")
        make_archive(root / "lib/libfixture.a", target="arm64-apple-ios17.0")
        with self.assertRaisesRegex(prefix.PrefixError, "platform"):
            prefix.validate_prefix(record(), root, self.roots)

    def test_archive_rejects_index_only_and_foreign_members(self):
        ar = subprocess.check_output(["xcrun", "--find", "ar"], text=True).strip()
        for kind in ("empty", "foreign"):
            with self.subTest(kind=kind):
                root = self.valid_prefix(self.project / f"archive-{kind}")
                archive = root / "lib/libfixture.a"
                archive.unlink()
                if kind == "empty":
                    archive.write_bytes(b"!<arch>\n")
                else:
                    member = self.project / "foreign.txt"
                    member.write_text("not Mach-O\n")
                    run(ar, "rcs", str(archive), str(member))
                with self.assertRaises(prefix.PrefixError):
                    prefix.validate_prefix(record(), root, self.roots)

    def test_archive_rejects_mixed_object_and_foreign_member(self):
        root = self.valid_prefix(self.project / "archive-mixed")
        member = self.project / "foreign.txt"
        member.write_text("not Mach-O\n")
        ar = subprocess.check_output(["xcrun", "--find", "ar"], text=True).strip()
        archive = root / "lib/libfixture.a"
        payload = member.read_bytes()
        header = (b"foreign.txt/".ljust(16) + b"0".ljust(12) + b"0".ljust(6)
                  + b"0".ljust(6) + b"100644".ljust(8)
                  + str(len(payload)).encode().ljust(10) + b"`\n")
        archive.write_bytes(archive.read_bytes() + header + payload
                            + (b"\n" if len(payload) % 2 else b""))
        self.assertIn("foreign.txt", subprocess.check_output(
            [ar, "-t", str(archive)], text=True))
        with self.assertRaises(prefix.PrefixError):
            prefix.validate_prefix(record(), root, self.roots)

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

    def test_pkgconfig_accepts_empty_optional_fields_and_continuation(self):
        root = self.valid_prefix(self.project / "optional-pc")
        pc = root / "lib/pkgconfig/fixture.pc"
        pc.write_text("prefix=${pcfiledir}/../..\nName: fixture\nDescription: test\n"
                      "Version: 1.0\nRequires:\nLibs: -L${prefix}/lib \\\n+-lfixture\nLibs.private:\n")
        checked = subprocess.run(["pkg-config", "--validate", str(pc)],
                                 capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        prefix.validate_prefix(record(), root, self.roots)

    def test_cmake_metadata_rejects_balanced_junk(self):
        root = self.valid_prefix(self.project / "cmake-junk")
        metadata = root / "lib/fixture-config.cmake"
        metadata.write_text("not valid cmake\n")
        configured = replace(record(), expected_metadata=(*record().expected_metadata,
                                                         "lib/fixture-config.cmake"))
        with self.assertRaisesRegex(prefix.PrefixError, "malformed package metadata"):
            prefix.validate_prefix(configured, root, self.roots)

    def test_cmake_metadata_accepts_comments_brackets_and_escaped_quote(self):
        root = self.valid_prefix(self.project / "cmake-valid")
        metadata = root / "lib/fixture-config.cmake"
        metadata.write_text('# unbalanced ( " comment\n'
                            '#[=[ unbalanced ) " bracket comment ]=]\n'
                            'set(_fixture [==[text ) " inside bracket]==])\n'
                            'set(_quoted "escaped \\" quote")\n')
        configured = replace(record(), expected_metadata=(*record().expected_metadata,
                                                         "lib/fixture-config.cmake"))
        prefix.validate_prefix(configured, root, self.roots)


class ToolResolutionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys.platform != "darwin":
            raise unittest.SkipTest("tool resolution requires macOS")

    def test_poisoned_ambient_path_cannot_select_host_tools(self):
        with tempfile.TemporaryDirectory(prefix="airdc-poison-tools-") as directory:
            poison = Path(directory)
            for name in ("cmake", "ninja", "perl", "make"):
                fake = poison / name
                fake.write_text("#!/bin/sh\nexit 99\n")
                fake.chmod(0o755)
            with patch.dict(os.environ, {"PATH": str(poison) + ":/usr/bin:/bin"}):
                inventory = build.resolve_tool_inventory()
            for name in ("cmake", "ninja", "perl", "make"):
                with self.subTest(name=name):
                    self.assertFalse(Path(inventory.host[name]).is_relative_to(poison))
                    self.assertFalse(Path(inventory.identities[f"host.{name}"]["resolved_path"])
                                     .is_relative_to(poison))

    def test_real_inventory_records_version_for_each_resolved_tool(self):
        inventory = build.resolve_tool_inventory()
        self.assertEqual(len(inventory.identities), 13)
        for name, identity in inventory.identities.items():
            with self.subTest(name=name):
                self.assertTrue(identity["version"])
                self.assertEqual(len(identity["sha256"]), 64)

    def test_same_executable_bytes_with_changed_version_output_changes_inventory(self):
        with tempfile.TemporaryDirectory(prefix="airdc-tool-version-") as directory:
            root = Path(directory)
            version_file = root / "version.txt"
            executable = root / "tool"
            executable.write_text(f'#!/bin/sh\n/bin/cat "{version_file}"\n')
            executable.chmod(0o755)
            with patch.object(build, "_trusted_host_tool", return_value=executable):
                version_file.write_text("first version\n")
                first = build.resolve_tool_inventory()
                version_file.write_text("second version\n")
                second = build.resolve_tool_inventory()
            before = first.identities["host.cmake"]
            after = second.identities["host.cmake"]
            self.assertEqual(before["resolved_path"], after["resolved_path"])
            self.assertEqual(before["sha256"], after["sha256"])
            self.assertEqual(before["version"], "first version")
            self.assertEqual(after["version"], "second version")
            self.assertNotEqual(build._canonical_json(build.asdict(first)),
                                build._canonical_json(build.asdict(second)))


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

    def test_restricted_environment_runs_unqualified_standard_commands(self):
        self.write_adapter("a", 'sh -c \'mkdir -p "$1/probe"; cp "$2/LICENSE" "$1/probe/copy"; rm "$1/probe/copy"\' sh "$build" "$stage"\n')
        with patch.dict(os.environ, {"PATH": "/private/tmp/unapproved:/usr/bin:/bin"}):
            self.invoke(DependencyLock(1, (self.records[0],)))
        self.assertTrue((self.project / "Build/dependencies/a/build/probe").is_dir())
        environment = (self.project / "Build/dependencies/a/build/env.txt").read_text()
        self.assertNotIn("/private/tmp/unapproved", environment)

    def test_tool_inventory_changes_when_executable_changes_at_same_path(self):
        executable = self.project / "cmake"
        executable.write_text("#!/bin/sh\necho first\n")
        executable.chmod(0o755)
        with patch.object(build, "_trusted_host_tool", return_value=executable):
            first = build.resolve_tool_inventory()
            executable.write_text("#!/bin/sh\necho second\n")
            second = build.resolve_tool_inventory()
        self.assertNotEqual(build.asdict(first), build.asdict(second))

    def test_retargeted_tool_links_cannot_replace_build_or_validator_executables(self):
        inventory = build.resolve_tool_inventory()
        tool_links = self.project / "tool-links"
        tool_links.mkdir()
        marker = self.project / "poison-ran"
        poison = tool_links / "poison"
        poison.write_text(f'#!/bin/sh\n/usr/bin/touch "{marker}"\nexit 99\n')
        poison.chmod(0o755)
        cmake_link = tool_links / "cmake"
        ar_link = tool_links / "ar"
        cmake_link.symlink_to(inventory.host["cmake"])
        ar_link.symlink_to(inventory.apple["ar"])
        self.tools = replace(
            inventory,
            host={**inventory.host, "cmake": str(cmake_link)},
            apple={**inventory.apple, "ar": str(ar_link)},
        )
        cmake_link.unlink()
        cmake_link.symlink_to(poison)
        ar_link.unlink()
        ar_link.symlink_to(poison)
        self.write_adapter("a", 'cmake --version > "$build/cmake-version.txt"\n')

        self.invoke(DependencyLock(1, (self.records[0],)))

        self.assertFalse(marker.exists())
        self.assertIn("cmake version", (self.project /
                      "Build/dependencies/a/build/cmake-version.txt").read_text())
        self.assertTrue((self.project / "Build/prefix/a/lib/libfixture.a").is_file())

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

    def test_same_path_tool_version_change_invalidates_accepted_fingerprint(self):
        only_a = DependencyLock(1, (self.records[0],))
        identity = {"resolved_path": "/opt/homebrew/bin/cmake",
                    "sha256": "0" * 64, "version": "first version"}
        self.tools = replace(self.tools, identities={"host.cmake": identity})
        self.invoke(only_a)
        evidence = self.project / "Build/dependencies/a/evidence"
        first = (evidence / "input-fingerprint.txt").read_bytes()
        identity = {**identity, "version": "second version"}
        self.tools = replace(self.tools, identities={"host.cmake": identity})

        self.invoke(only_a)

        self.assertNotEqual((evidence / "input-fingerprint.txt").read_bytes(), first)
        self.assertEqual((evidence / "attempts/0001/input-fingerprint.txt").read_bytes(), first)

    def test_helper_only_change_rebuilds_and_archives_previous_acceptance(self):
        only_a = DependencyLock(1, (self.records[0],))
        helpers = self.project / "scripts/lib/dependencies"
        (helpers / "z_helper.py").write_text("VALUE = 'unchanged'\n")
        helper = helpers / "a_helper.py"
        helper.write_text("VALUE = 'first'\n")
        marker = self.project / "adapter-runs.txt"
        self.write_adapter("a", f'/usr/bin/printf "run\\n" >> "{marker}"\n')
        self.invoke(only_a)
        evidence = self.project / "Build/dependencies/a/evidence"
        first = (evidence / "input-fingerprint.txt").read_bytes()
        accepted = (evidence / "prefix-report.json").read_bytes()
        inputs = json.loads((evidence / "inputs.json").read_text())
        self.assertEqual(inputs["adapter_helpers"], [
            {"path": "scripts/lib/dependencies/a_helper.py",
             "sha256": hashlib.sha256(b"VALUE = 'first'\n").hexdigest()},
            {"path": "scripts/lib/dependencies/z_helper.py",
             "sha256": hashlib.sha256(b"VALUE = 'unchanged'\n").hexdigest()},
        ])
        self.invoke(only_a)
        self.assertEqual(marker.read_text().splitlines(), ["run"])
        self.assertEqual((evidence / "input-fingerprint.txt").read_bytes(), first)
        self.assertFalse((evidence / "attempts").exists())

        helper.write_text("VALUE = 'second'\n")
        self.invoke(only_a)

        self.assertEqual(marker.read_text().splitlines(), ["run", "run"])
        self.assertNotEqual((evidence / "input-fingerprint.txt").read_bytes(), first)
        self.assertEqual((evidence / "attempts/0001/input-fingerprint.txt").read_bytes(), first)
        self.assertEqual((evidence / "attempts/0001/prefix-report.json").read_bytes(), accepted)

    def test_unsafe_python_helper_refuses_accepted_reuse_before_reading(self):
        only_a = DependencyLock(1, (self.records[0],))
        self.invoke(only_a)
        evidence = self.project / "Build/dependencies/a/evidence"
        before = filesystem_state(evidence)
        helper = self.project / "scripts/lib/dependencies/unsafe_helper.py"
        target = self.project / "outside.py"
        target.write_text("VALUE = 'outside'\n")
        for kind in ("symlink", "directory", "fifo"):
            with self.subTest(kind=kind):
                if kind == "symlink":
                    helper.symlink_to(target)
                elif kind == "directory":
                    helper.mkdir()
                else:
                    os.mkfifo(helper)
                try:
                    with self.assertRaisesRegex(build.BuildError, "unsafe dependency adapter helper"):
                        self.invoke(only_a)
                    self.assertEqual(filesystem_state(evidence), before)
                finally:
                    if kind == "directory":
                        helper.rmdir()
                    else:
                        helper.unlink()

    def test_changed_accepted_header_is_not_reused_with_stale_evidence(self):
        only_a = DependencyLock(1, (self.records[0],))
        self.invoke(only_a)
        accepted = self.project / "Build/prefix/a"
        evidence = self.project / "Build/dependencies/a/evidence"
        saved = (evidence / "install-manifest.jsonl").read_bytes()
        (accepted / "include/fixture.h").write_text("int changed(void);\n")
        with patch.object(build, "run_adapter", side_effect=AssertionError("adapter reran")):
            with self.assertRaisesRegex(build.BuildError, "accepted output drift"):
                self.invoke(only_a)
        self.assertEqual((evidence / "install-manifest.jsonl").read_bytes(), saved)

    def test_changed_archive_license_or_acceptance_evidence_refuses_reuse(self):
        only_a = DependencyLock(1, (self.records[0],))
        self.invoke(only_a)
        accepted = self.project / "Build/prefix/a"
        evidence = self.project / "Build/dependencies/a/evidence"
        cases = (
            (accepted / "LICENSE", b"changed license\n"),
            (evidence / "prefix-report.json", b"{}\n"),
            (evidence / "install-manifest.jsonl", b""),
        )
        for path, replacement in cases:
            with self.subTest(path=path.name):
                original = path.read_bytes()
                path.write_bytes(replacement)
                try:
                    with patch.object(build, "run_adapter", side_effect=AssertionError("adapter reran")):
                        with self.assertRaisesRegex(build.BuildError, "accepted output drift"):
                            self.invoke(only_a)
                finally:
                    path.write_bytes(original)
        archive = accepted / "lib/libfixture.a"
        original = archive.read_bytes()
        make_archive(archive, embedded="changed but valid")
        try:
            with self.assertRaisesRegex(build.BuildError, "accepted output drift"):
                self.invoke(only_a)
        finally:
            archive.write_bytes(original)
        missing = evidence / "license-inventory.json"
        original = missing.read_bytes()
        missing.unlink()
        try:
            with self.assertRaisesRegex(build.BuildError, "accepted output drift"):
                self.invoke(only_a)
        finally:
            missing.write_bytes(original)

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

    def test_retry_attempt_directory_swap_cannot_redirect_copy(self):
        evidence = self.project / "Build/dependencies/a/evidence"
        evidence.mkdir(parents=True)
        (evidence / "adapter.log").write_bytes(b"previous")
        outside = self.project / "outside"
        outside.mkdir()
        (outside / "0001").mkdir()
        (outside / "sentinel").write_bytes(b"untouched")
        original = build.shutil.copyfileobj
        swapped = False

        def redirect(source, destination, *args, **kwargs):
            nonlocal swapped
            if not swapped:
                swapped = True
                attempts = evidence / "attempts"
                attempts.rename(evidence / "attempts-original")
                attempts.symlink_to(outside, target_is_directory=True)
            return original(source, destination, *args, **kwargs)

        with patch.object(build.shutil, "copyfileobj", side_effect=redirect):
            with self.assertRaises(build.BuildError):
                self.invoke(DependencyLock(1, (self.records[0],)))
        self.assertEqual((outside / "sentinel").read_bytes(), b"untouched")
        self.assertEqual(list((outside / "0001").iterdir()), [])
        self.assertEqual((evidence / "adapter.log").read_bytes(), b"previous")

    def test_adapter_cannot_mutate_earlier_attempt_history(self):
        only_a = DependencyLock(1, (self.records[0],))
        self.write_adapter("a", "exit 7\n")
        with self.assertRaises(build.BuildError):
            self.invoke(only_a)
        self.write_adapter("a", 'printf "tampered" >> "$(dirname "$build")/evidence/attempts/0001/exit-status.txt"\n')
        with self.assertRaisesRegex(build.BuildError, "attempt history"):
            self.invoke(only_a)
        attempt = self.project / "Build/dependencies/a/evidence/attempts/0001"
        self.assertEqual((attempt / "exit-status.txt").read_bytes(), b"7\n")

    def test_cross_prefix_write_is_detected(self):
        self.invoke(DependencyLock(1, (self.records[0],)))
        before = prefix.tree_digest(self.project / "Build/prefix/a")
        self.write_adapter("b", '/usr/bin/printf "tampered\\n" >> "$6/LICENSE"\n')
        with self.assertRaisesRegex(build.BuildError, "cross-prefix write"):
            self.invoke()
        self.assertEqual(prefix.tree_digest(self.project / "Build/prefix/a"), before)

    def test_failed_adapter_restores_deleted_dependency_prefix_file(self):
        self.invoke(DependencyLock(1, (self.records[0],)))
        accepted = self.project / "Build/prefix/a"
        before = prefix.tree_digest(accepted)
        self.write_adapter("b", '/bin/rm "$6/LICENSE"\nexit 7\n')
        with self.assertRaisesRegex(build.BuildError, "cross-prefix write"):
            self.invoke()
        self.assertEqual(prefix.tree_digest(accepted), before)

    def test_adapter_restores_new_files_and_prior_component_on_failure(self):
        self.invoke()
        accepted_a = self.project / "Build/prefix/a"
        accepted_b = self.project / "Build/prefix/b"
        before_a = prefix.tree_digest(accepted_a)
        before_b = prefix.tree_digest(accepted_b)
        self.write_adapter("b", 'printf "unexpected" > "$6/include/new.h"\n'
                           f'printf "overwrite" > "{accepted_b}/LICENSE"\nexit 7\n')
        with self.assertRaisesRegex(build.BuildError, "cross-prefix write"):
            self.invoke()
        self.assertEqual(prefix.tree_digest(accepted_a), before_a)
        self.assertEqual(prefix.tree_digest(accepted_b), before_b)

    def test_adapter_cannot_create_another_accepted_prefix(self):
        self.write_adapter("a", '/bin/mkdir -p "$(/usr/bin/dirname "$stage")/intruder"\n')
        with self.assertRaisesRegex(build.BuildError, "cross-prefix write"):
            self.invoke(DependencyLock(1, (self.records[0],)))
        self.assertFalse((self.project / "Build/prefix/a").exists())

    def test_failed_adapter_restores_complete_prefix_root_after_hidden_addition(self):
        self.invoke()
        prefix_root = self.project / "Build/prefix"
        accepted = prefix_root / "a"
        evidence = self.project / "Build/dependencies/a/evidence"
        outside = self.project / "outside"
        outside.mkdir()
        sentinel = outside / "sentinel"
        sentinel.write_bytes(b"untouched")
        root_before = prefix.tree_digest(prefix_root)
        accepted_before = prefix.tree_digest(accepted)
        evidence_before = prefix.tree_digest(evidence)
        self.write_adapter("b", '/bin/mkdir -p "$(/usr/bin/dirname "$stage")/.intruder"\nexit 7\n')

        with self.assertRaisesRegex(build.BuildError, "cross-prefix write"):
            self.invoke()

        self.assertEqual(prefix.tree_digest(prefix_root), root_before)
        self.assertEqual(prefix.tree_digest(accepted), accepted_before)
        self.assertEqual(prefix.tree_digest(evidence), evidence_before)
        self.assertEqual(sentinel.read_bytes(), b"untouched")

    def test_failed_adapter_build_ancestor_substitution_preserves_both_trees(self):
        self.invoke()
        build_root = self.project / "Build"
        original_prefix = build_root / "prefix"
        prefix_before = filesystem_state(original_prefix)
        prefix_digest_before = prefix.tree_digest(original_prefix)
        accepted_before = filesystem_state(original_prefix / "a")
        evidence_before = filesystem_state(build_root / "dependencies/a/evidence")
        accepted_fingerprint = (build_root / "dependencies/b/evidence/input-fingerprint.txt").read_bytes()
        replacement = self.project / "replacement-build"
        (replacement / "prefix/victim").mkdir(parents=True)
        (replacement / "prefix/victim/marker").write_bytes(b"foreign build replacement")
        (replacement / "sentinel").write_bytes(b"keep replacement intact")
        replacement_identity = build._identity(replacement)
        replacement_before = filesystem_state(replacement)
        self.write_adapter(
            "b",
            'build_root="$(/usr/bin/dirname "$(/usr/bin/dirname "$(/usr/bin/dirname "$build")")")"\n'
            '/bin/mv "$build_root" "${build_root}-original"\n'
            f'/bin/mv "{replacement}" "$build_root"\n'
            'exit 7\n',
        )

        with self.assertRaises(build.BuildError):
            self.invoke()

        moved_build = self.project / "Build-original"
        moved_prefix = moved_build / "prefix"
        self.assertEqual(build._identity(build_root), replacement_identity)
        self.assertEqual(filesystem_state(build_root), replacement_before)
        self.assertEqual((build_root / "sentinel").read_bytes(), b"keep replacement intact")
        self.assertEqual(filesystem_state(moved_prefix), prefix_before)
        self.assertEqual(prefix.tree_digest(moved_prefix), prefix_digest_before)
        self.assertEqual(filesystem_state(moved_prefix / "a"), accepted_before)
        self.assertEqual(filesystem_state(moved_build / "dependencies/a/evidence"), evidence_before)
        self.assertEqual((moved_build / "dependencies/b/evidence/attempts/0001/input-fingerprint.txt").read_bytes(),
                         accepted_fingerprint)
        self.assertFalse(any(path.name.startswith((".staging-", ".prior-", ".cleanup-"))
                             for path in moved_prefix.iterdir()))
        self.assertEqual(tuple(build_root.glob(".prefix-quarantine-*")), ())
        self.assertEqual(tuple(moved_build.glob(".prefix-quarantine-*")), ())

    def test_successful_adapter_build_ancestor_substitution_fails_closed(self):
        self.invoke()
        build_root = self.project / "Build"
        prefix_before = filesystem_state(build_root / "prefix")
        prefix_digest_before = prefix.tree_digest(build_root / "prefix")
        accepted_fingerprint = (build_root / "dependencies/b/evidence/input-fingerprint.txt").read_bytes()
        replacement = self.project / "replacement-build"
        (replacement / "prefix/victim").mkdir(parents=True)
        (replacement / "prefix/victim/marker").write_bytes(b"foreign build replacement")
        replacement_identity = build._identity(replacement)
        replacement_before = filesystem_state(replacement)
        self.write_adapter(
            "b",
            'build_root="$(/usr/bin/dirname "$(/usr/bin/dirname "$(/usr/bin/dirname "$build")")")"\n'
            '/bin/mv "$build_root" "${build_root}-original"\n'
            f'/bin/mv "{replacement}" "$build_root"\n',
        )

        with self.assertRaises(build.BuildError):
            self.invoke()

        self.assertEqual(build._identity(build_root), replacement_identity)
        self.assertEqual(filesystem_state(build_root), replacement_before)
        moved_prefix = self.project / "Build-original/prefix"
        self.assertEqual(filesystem_state(moved_prefix), prefix_before)
        self.assertEqual(prefix.tree_digest(moved_prefix), prefix_digest_before)
        self.assertEqual((self.project / "Build-original/dependencies/b/evidence/attempts/0001/input-fingerprint.txt").read_bytes(),
                         accepted_fingerprint)
        self.assertFalse(any(path.name.startswith((".staging-", ".prior-", ".cleanup-"))
                             for path in moved_prefix.iterdir()))

    def _assert_build_ancestor_evidence_tamper_is_restored(self, adapter_status):
        self.invoke()
        build_root = self.project / "Build"
        prefix_root = build_root / "prefix"
        accepted_a = prefix_root / "a"
        evidence_a = build_root / "dependencies/a/evidence"
        evidence_b = build_root / "dependencies/b/evidence"
        build_identity = build._identity(build_root)
        prefix_identity = build._identity(prefix_root)
        accepted_a_identity = build._identity(accepted_a)
        prefix_before = filesystem_state(prefix_root)
        prefix_digest_before = prefix.tree_digest(prefix_root)
        accepted_a_before = filesystem_state(accepted_a)
        evidence_a_before = filesystem_state(evidence_a)
        evidence_a_digest_before = prefix.tree_digest(evidence_a)
        prior_b_files = {
            path.name: path.read_bytes()
            for path in evidence_b.iterdir()
            if path.is_file() and not path.is_symlink()
        }
        replacement = self.project / f"replacement-build-{adapter_status}"
        (replacement / "prefix/victim").mkdir(parents=True)
        (replacement / "prefix/victim/marker").write_bytes(b"foreign build replacement")
        (replacement / "sentinel").write_bytes(b"keep replacement intact")
        replacement_identity = build._identity(replacement)
        replacement_before = filesystem_state(replacement)
        exit_line = f"exit {adapter_status}\n" if adapter_status else ""
        self.write_adapter(
            "b",
            'build_root="$(/usr/bin/dirname "$(/usr/bin/dirname "$(/usr/bin/dirname "$build")")")"\n'
            '/bin/mv "$build_root" "${build_root}-original"\n'
            f'/bin/mv "{replacement}" "$build_root"\n'
            '/usr/bin/printf "tampered-history\\n" > '
            '"${build_root}-original/dependencies/b/evidence/attempts/0001/input-fingerprint.txt"\n'
            '/usr/bin/printf "tampered-accepted\\n" > '
            '"${build_root}-original/dependencies/a/evidence/input-fingerprint.txt"\n'
            + exit_line,
        )

        with self.assertRaises(build.BuildError):
            self.invoke()

        moved_build = self.project / "Build-original"
        moved_prefix = moved_build / "prefix"
        moved_evidence_a = moved_build / "dependencies/a/evidence"
        attempt = moved_build / "dependencies/b/evidence/attempts/0001"
        self.assertEqual(build._identity(build_root), replacement_identity)
        self.assertEqual(filesystem_state(build_root), replacement_before)
        self.assertEqual((build_root / "sentinel").read_bytes(), b"keep replacement intact")
        self.assertEqual(build._identity(moved_build), build_identity)
        self.assertEqual(build._identity(moved_prefix), prefix_identity)
        self.assertEqual(build._identity(moved_prefix / "a"), accepted_a_identity)
        self.assertEqual(filesystem_state(moved_prefix), prefix_before)
        self.assertEqual(prefix.tree_digest(moved_prefix), prefix_digest_before)
        self.assertEqual(filesystem_state(moved_prefix / "a"), accepted_a_before)
        self.assertEqual(filesystem_state(moved_evidence_a), evidence_a_before)
        self.assertEqual(prefix.tree_digest(moved_evidence_a), evidence_a_digest_before)
        self.assertEqual(
            sorted(path.name for path in attempt.iterdir()),
            sorted((*prior_b_files, "sha256.txt")),
        )
        for name, content in prior_b_files.items():
            self.assertEqual((attempt / name).read_bytes(), content)
        expected_hashes = "".join(
            f"{hashlib.sha256(content).hexdigest()}  {name}\n"
            for name, content in sorted(prior_b_files.items())
        ).encode()
        self.assertEqual((attempt / "sha256.txt").read_bytes(), expected_hashes)
        self.assertEqual((moved_build / "dependencies/b/evidence/exit-status.txt").read_text(),
                         f"{adapter_status or 1}\n")
        self.assertTrue((moved_build / "dependencies/b/evidence/error.txt").is_file())
        self.assertFalse(any(path.name.startswith((".staging-", ".prior-", ".cleanup-"))
                             for path in moved_prefix.iterdir()))
        self.assertEqual(tuple(build_root.glob(".prefix-quarantine-*")), ())
        self.assertEqual(tuple(moved_build.glob(".prefix-quarantine-*")), ())

    def test_failed_adapter_build_ancestor_substitution_restores_tampered_evidence(self):
        self._assert_build_ancestor_evidence_tamper_is_restored(7)

    def test_successful_adapter_build_ancestor_substitution_restores_tampered_evidence(self):
        self._assert_build_ancestor_evidence_tamper_is_restored(0)

    def _assert_build_ancestor_evidence_deletion_is_restored(self, adapter_status):
        self.invoke()
        build_root = self.project / "Build"
        prefix_root = build_root / "prefix"
        accepted_a = prefix_root / "a"
        evidence_a = build_root / "dependencies/a/evidence"
        build_identity = build._identity(build_root)
        prefix_identity = build._identity(prefix_root)
        accepted_a_identity = build._identity(accepted_a)
        prefix_before = filesystem_state(prefix_root)
        prefix_digest_before = prefix.tree_digest(prefix_root)
        accepted_a_before = filesystem_state(accepted_a)
        evidence_a_before = filesystem_state(evidence_a)
        evidence_a_digest_before = prefix.tree_digest(evidence_a)
        acceptance_files = {
            name: (evidence_a / name).read_bytes()
            for name in (
                "input-fingerprint.txt",
                "prefix-report.json",
                "license-inventory.json",
                "install-manifest.jsonl",
                "exit-status.txt",
            )
        }
        replacement = self.project / f"replacement-build-deletion-{adapter_status}"
        (replacement / "prefix/victim").mkdir(parents=True)
        (replacement / "prefix/victim/marker").write_bytes(b"foreign build replacement")
        (replacement / "sentinel").write_bytes(b"keep replacement intact")
        replacement_identity = build._identity(replacement)
        replacement_before = filesystem_state(replacement)
        exit_line = f"exit {adapter_status}\n" if adapter_status else ""
        self.write_adapter(
            "b",
            'build_root="$(/usr/bin/dirname "$(/usr/bin/dirname "$(/usr/bin/dirname "$build")")")"\n'
            '/bin/mv "$build_root" "${build_root}-original"\n'
            f'/bin/mv "{replacement}" "$build_root"\n'
            '/bin/rm -rf "${build_root}-original/dependencies/a/evidence"\n'
            + exit_line,
        )

        with self.assertRaises(build.BuildError):
            self.invoke()

        moved_build = self.project / "Build-original"
        moved_prefix = moved_build / "prefix"
        moved_evidence_a = moved_build / "dependencies/a/evidence"
        self.assertEqual(build._identity(build_root), replacement_identity)
        self.assertEqual(filesystem_state(build_root), replacement_before)
        self.assertEqual((build_root / "sentinel").read_bytes(), b"keep replacement intact")
        self.assertEqual(build._identity(moved_build), build_identity)
        self.assertEqual(build._identity(moved_prefix), prefix_identity)
        self.assertEqual(build._identity(moved_prefix / "a"), accepted_a_identity)
        self.assertEqual(filesystem_state(moved_prefix), prefix_before)
        self.assertEqual(prefix.tree_digest(moved_prefix), prefix_digest_before)
        self.assertEqual(filesystem_state(moved_prefix / "a"), accepted_a_before)
        self.assertEqual(filesystem_state(moved_evidence_a), evidence_a_before)
        self.assertEqual(prefix.tree_digest(moved_evidence_a), evidence_a_digest_before)
        for name, content in acceptance_files.items():
            self.assertEqual((moved_evidence_a / name).read_bytes(), content)
        self.assertEqual((moved_build / "dependencies/b/evidence/exit-status.txt").read_text(),
                         f"{adapter_status or 1}\n")
        self.assertTrue((moved_build / "dependencies/b/evidence/error.txt").is_file())
        self.assertFalse(any(path.name.startswith((".staging-", ".prior-", ".cleanup-"))
                             for path in moved_prefix.iterdir()))
        self.assertEqual(tuple(build_root.glob(".prefix-quarantine-*")), ())
        self.assertEqual(tuple(moved_build.glob(".prefix-quarantine-*")), ())
        self.assertFalse(any(path.name.startswith(".evidence-recovery-")
                             for path in (moved_build / "dependencies/a").iterdir()))

    def test_failed_adapter_build_ancestor_substitution_restores_deleted_evidence(self):
        self._assert_build_ancestor_evidence_deletion_is_restored(7)

    def test_successful_adapter_build_ancestor_substitution_restores_deleted_evidence(self):
        self._assert_build_ancestor_evidence_deletion_is_restored(0)

    def test_failed_adapter_prefix_root_substitution_preserves_both_roots(self):
        self.invoke()
        build_root = self.project / "Build"
        prefix_root = build_root / "prefix"
        prefix_before = filesystem_state(prefix_root)
        prefix_digest_before = prefix.tree_digest(prefix_root)
        accepted_before = filesystem_state(prefix_root / "a")
        evidence_before = filesystem_state(build_root / "dependencies/a/evidence")
        accepted_fingerprint = (build_root / "dependencies/b/evidence/input-fingerprint.txt").read_bytes()
        replacement = self.project / "replacement-prefix"
        (replacement / "victim").mkdir(parents=True)
        (replacement / "victim/marker").write_bytes(b"foreign prefix replacement")
        (replacement / "sentinel").write_bytes(b"keep replacement intact")
        replacement_identity = build._identity(replacement)
        replacement_before = filesystem_state(replacement)
        self.write_adapter(
            "b",
            'prefix_root="$(/usr/bin/dirname "$stage")"\n'
            '/bin/mv "$prefix_root" "${prefix_root}-original"\n'
            f'/bin/mv "{replacement}" "$prefix_root"\n'
            'exit 7\n',
        )

        with self.assertRaises(build.BuildError):
            self.invoke()

        original = build_root / "prefix-original"
        self.assertEqual(build._identity(prefix_root), replacement_identity)
        self.assertEqual(filesystem_state(prefix_root), replacement_before)
        self.assertEqual((prefix_root / "sentinel").read_bytes(), b"keep replacement intact")
        self.assertEqual(filesystem_state(original), prefix_before)
        self.assertEqual(prefix.tree_digest(original), prefix_digest_before)
        self.assertEqual(filesystem_state(original / "a"), accepted_before)
        self.assertEqual(filesystem_state(build_root / "dependencies/a/evidence"), evidence_before)
        self.assertEqual((build_root / "dependencies/b/evidence/attempts/0001/input-fingerprint.txt").read_bytes(),
                         accepted_fingerprint)
        self.assertFalse(any(path.name.startswith((".staging-", ".prior-", ".cleanup-"))
                             for path in original.iterdir()))
        self.assertEqual(tuple(build_root.glob(".prefix-quarantine-*")), ())

    def test_successful_adapter_prefix_root_substitution_fails_closed(self):
        self.invoke()
        build_root = self.project / "Build"
        prefix_root = build_root / "prefix"
        prefix_before = filesystem_state(prefix_root)
        prefix_digest_before = prefix.tree_digest(prefix_root)
        evidence_before = filesystem_state(build_root / "dependencies/a/evidence")
        accepted_fingerprint = (build_root / "dependencies/b/evidence/input-fingerprint.txt").read_bytes()
        replacement = self.project / "replacement-prefix"
        (replacement / "victim").mkdir(parents=True)
        (replacement / "victim/marker").write_bytes(b"foreign prefix replacement")
        replacement_identity = build._identity(replacement)
        replacement_before = filesystem_state(replacement)
        self.write_adapter(
            "b",
            'prefix_root="$(/usr/bin/dirname "$stage")"\n'
            '/bin/mv "$prefix_root" "${prefix_root}-original"\n'
            f'/bin/mv "{replacement}" "$prefix_root"\n',
        )

        with self.assertRaises(build.BuildError):
            self.invoke()

        original = build_root / "prefix-original"
        self.assertEqual(build._identity(prefix_root), replacement_identity)
        self.assertEqual(filesystem_state(prefix_root), replacement_before)
        self.assertEqual(filesystem_state(original), prefix_before)
        self.assertEqual(prefix.tree_digest(original), prefix_digest_before)
        self.assertEqual(filesystem_state(build_root / "dependencies/a/evidence"), evidence_before)
        self.assertEqual((build_root / "dependencies/b/evidence/attempts/0001/input-fingerprint.txt").read_bytes(),
                         accepted_fingerprint)
        self.assertFalse(any(path.name.startswith((".staging-", ".prior-", ".cleanup-"))
                             for path in original.iterdir()))

    def test_existing_component_symlink_cannot_redirect_evidence(self):
        outside = self.project / "outside"
        outside.mkdir()
        component = self.project / "Build/dependencies/a"
        component.parent.mkdir(parents=True)
        component.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(build.BuildError, "unsafe build directory"):
            self.invoke(DependencyLock(1, (self.records[0],)))
        self.assertEqual(list(outside.iterdir()), [])

    def test_reuse_refuses_symlinked_evidence_directory(self):
        only_a = DependencyLock(1, (self.records[0],))
        self.invoke(only_a)
        evidence = self.project / "Build/dependencies/a/evidence"
        outside = self.project / "outside"
        evidence.rename(outside)
        evidence.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(build.BuildError, "unsafe.*evidence"):
            self.invoke(only_a)

    def test_adapter_time_evidence_swap_cannot_redirect_reports(self):
        outside = self.project / "outside"
        outside.mkdir()
        sentinel = outside / "sentinel"
        sentinel.write_bytes(b"untouched")
        self.write_adapter("a", 'mv "$(dirname "$build")/evidence" "$(dirname "$build")/old-evidence"\n'
                           f'ln -s "{outside}" "$(dirname "$build")/evidence"\n')
        with self.assertRaisesRegex(build.BuildError, "identity changed"):
            self.invoke(DependencyLock(1, (self.records[0],)))
        self.assertEqual(sentinel.read_bytes(), b"untouched")
        self.assertEqual(sorted(path.name for path in outside.iterdir()), ["sentinel"])

    def test_adapter_time_component_swap_cannot_redirect_evidence(self):
        outside = self.project / "outside"
        outside.mkdir()
        (outside / "sentinel").write_bytes(b"untouched")
        self.write_adapter("a", 'component="$(dirname "$build")"\n'
                           'mv "$component" "${component}-moved"\n'
                           f'ln -s "{outside}" "$component"\n')
        with self.assertRaisesRegex(build.BuildError, "identity changed"):
            self.invoke(DependencyLock(1, (self.records[0],)))
        self.assertEqual((outside / "sentinel").read_bytes(), b"untouched")
        self.assertEqual(sorted(path.name for path in outside.iterdir()), ["sentinel"])

    def test_predictable_temporary_symlink_cannot_redirect_evidence_write(self):
        outside = self.project / "outside"
        outside.mkdir()
        sentinel = outside / "sentinel"
        sentinel.write_bytes(b"untouched")
        evidence = self.project / "Build/dependencies/a/evidence"
        original = build.secrets.token_hex

        def plant(length):
            name = original(length)
            if evidence.is_dir():
                (evidence / f".inputs.json.{name}.tmp").symlink_to(sentinel)
            return name

        with patch.object(build.secrets, "token_hex", side_effect=plant):
            with self.assertRaises((build.BuildError, OSError)):
                self.invoke(DependencyLock(1, (self.records[0],)))
        self.assertEqual(sentinel.read_bytes(), b"untouched")

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

    def test_stage_replaced_after_validation_preserves_previous_acceptance(self):
        only_a = DependencyLock(1, (self.records[0],))
        self.invoke(only_a)
        prefix_root = self.project / "Build/prefix"
        root_before = prefix.tree_digest(prefix_root)
        accepted = self.project / "Build/prefix/a"
        evidence = self.project / "Build/dependencies/a/evidence"
        old_digest = prefix.tree_digest(accepted)
        old_fingerprint = (evidence / "input-fingerprint.txt").read_bytes()
        self.write_adapter("a", '/usr/bin/printf "new\\n" >> "$stage/LICENSE"\n')
        original = build.publish_prefix

        def replace_stage(stage, target, root, **kwargs):
            stage.rename(stage.with_name(stage.name + "-hidden"))
            stage.mkdir()
            (stage / "unvalidated").write_text("bad\n")
            return original(stage, target, root, **kwargs)

        with patch.object(build, "publish_prefix", side_effect=replace_stage):
            with self.assertRaises(build.BuildError):
                self.invoke(only_a)
        self.assertEqual(prefix.tree_digest(accepted), old_digest)
        self.assertEqual(prefix.tree_digest(prefix_root), root_before)
        self.assertEqual(sorted(path.name for path in prefix_root.iterdir()), ["a"])
        self.assertEqual((evidence / "attempts/0001/input-fingerprint.txt").read_bytes(),
                         old_fingerprint)

    def test_target_replaced_during_exchange_restores_previous_prefix(self):
        only_a = DependencyLock(1, (self.records[0],))
        self.invoke(only_a)
        prefix_root = self.project / "Build/prefix"
        accepted = self.project / "Build/prefix/a"
        before = prefix.tree_digest(accepted)
        root_before = prefix.tree_digest(prefix_root)
        evidence = self.project / "Build/dependencies/a/evidence"
        old_fingerprint = (evidence / "input-fingerprint.txt").read_bytes()
        self.write_adapter("a", '/usr/bin/printf "new\\n" >> "$stage/LICENSE"\n')
        original = build._rename_swap
        swapped = False
        outside = self.project / "outside"
        outside.mkdir()
        (outside / "sentinel").write_bytes(b"untouched")

        def substitute(parent_fd, first, second):
            nonlocal swapped
            if not swapped:
                swapped = True
                accepted.rename(accepted.with_name(".prior-a"))
                accepted.symlink_to(outside, target_is_directory=True)
            return original(parent_fd, first, second)

        with patch.object(build, "_rename_swap", side_effect=substitute):
            with self.assertRaises(build.BuildError):
                self.invoke(only_a)
        self.assertEqual(prefix.tree_digest(accepted), before)
        self.assertEqual(prefix.tree_digest(prefix_root), root_before)
        self.assertEqual(sorted(path.name for path in prefix_root.iterdir()), ["a"])
        self.assertEqual((evidence / "attempts/0001/input-fingerprint.txt").read_bytes(),
                         old_fingerprint)
        self.assertEqual((outside / "sentinel").read_bytes(), b"untouched")

    def test_exchange_rollback_preserves_substituted_nonowned_directory(self):
        only_a = DependencyLock(1, (self.records[0],))
        self.invoke(only_a)
        prefix_root = self.project / "Build/prefix"
        root_before = prefix.tree_digest(prefix_root)
        accepted = prefix_root / "a"
        outside = self.project / "outside"
        outside.mkdir()
        intruder = outside / "intruder"
        intruder.mkdir()
        (intruder / "marker").write_bytes(b"keep this identity")
        intruder_identity = build._identity(intruder)
        self.write_adapter("a", '/usr/bin/printf "new\\n" >> "$stage/LICENSE"\n')
        original = build._rename_swap
        swapped = False

        def substitute(parent_fd, first, second):
            nonlocal swapped
            if not swapped:
                swapped = True
                accepted.rename(prefix_root / ".prior-a")
                intruder.rename(accepted)
            return original(parent_fd, first, second)

        with patch.object(build, "_rename_swap", side_effect=substitute):
            with self.assertRaises(build.BuildError):
                self.invoke(only_a)

        self.assertEqual(prefix.tree_digest(prefix_root), root_before)
        self.assertEqual(sorted(path.name for path in prefix_root.iterdir()), ["a"])
        quarantines = tuple((self.project / "Build").glob(".prefix-quarantine-*"))
        preserved = [path for root in quarantines for path in root.iterdir()
                     if build._identity(path) == intruder_identity]
        self.assertEqual(len(preserved), 1)
        self.assertEqual((preserved[0] / "marker").read_bytes(), b"keep this identity")


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
