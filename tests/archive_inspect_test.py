"""Native-Darwin contract tests for member-by-member Core archive inspection."""

import hashlib
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSPECTOR = ROOT / "scripts/lib/inspect_core_archive.py"


class ArchiveInspectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if platform.system() != "Darwin" or platform.machine() != "arm64" or not shutil.which("xcrun"):
            raise unittest.SkipTest("native Apple Silicon macOS with Xcode is required")
        result = subprocess.run(["xcrun", "--find", "clang"], capture_output=True, text=True)
        if result.returncode:
            raise unittest.SkipTest("native Apple Silicon macOS with Xcode is required")

    def setUp(self):
        # macOS /var is a system symlink; use the physical temp root so the
        # output-path guard tests our fixture, not that system alias.
        self.temp = tempfile.TemporaryDirectory(prefix="airdc-archive-test-", dir="/private/tmp")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.archive = self.work / "libfixture.a"
        self.members = self.work / "members.tsv"
        self.symbols = self.work / "symbols.txt"

    def compile_object(self, folder, symbol, arch="arm64", basename=None):
        directory = self.work / folder
        directory.mkdir(parents=True, exist_ok=True)
        stem = basename or symbol
        source = directory / f"{stem}.c"
        obj = directory / f"{stem}.o"
        source.write_text(f"int {symbol}(void) {{ return {len(symbol)}; }}\n")
        subprocess.run(["xcrun", "clang", "-c", "-arch", arch, str(source), "-o", str(obj)], check=True)
        return obj

    def make_archive(self, *objects):
        subprocess.run(["/usr/bin/libtool", "-static", "-o", str(self.archive), *(str(obj) for obj in objects)],
                       check=True, capture_output=True, text=True)

    def inspect(self):
        return subprocess.run([sys.executable, str(INSPECTOR), str(self.archive), str(self.members), str(self.symbols)],
                              capture_output=True, text=True)

    def assert_no_report(self):
        self.assertFalse(self.members.exists(), "failure must not publish a successful member report")
        self.assertFalse(self.symbols.exists(), "failure must not publish a symbol report")

    def test_two_arm64_members_in_archive_order(self):
        first = self.compile_object("first", "a")
        second = self.compile_object("second", "b")
        self.make_archive(first, second)

        result = self.inspect()
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [line.split("\t") for line in self.members.read_text().splitlines()]
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0], ["1", "a.o", hashlib.sha256(first.read_bytes()).hexdigest(), "arm64"])
        self.assertEqual(rows[1], ["2", "b.o", hashlib.sha256(second.read_bytes()).hexdigest(), "arm64"])
        self.assertIn("_a", self.symbols.read_text())
        self.assertIn("_b", self.symbols.read_text())

    def test_duplicate_member_names_are_inspected_independently(self):
        first = self.compile_object("one", "first_function", basename="duplicate")
        second = self.compile_object("two", "second_function", basename="duplicate")
        self.make_archive(first, second)

        result = self.inspect()
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [line.split("\t") for line in self.members.read_text().splitlines()]
        self.assertEqual(len(rows), 2)
        self.assertEqual([row[1] for row in rows], ["duplicate.o", "duplicate.o"])
        self.assertEqual([row[2] for row in rows], [hashlib.sha256(first.read_bytes()).hexdigest(),
                                                      hashlib.sha256(second.read_bytes()).hexdigest()])

    def test_x86_64_member_is_rejected_without_reports(self):
        obj = self.compile_object("wrong-arch", "wrong_arch", arch="x86_64")
        self.make_archive(obj)

        result = self.inspect()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("arm64", result.stderr)
        self.assert_no_report()

    def test_truncated_archive_is_rejected_without_reports(self):
        self.archive.write_bytes(b"!<arch>\npartial header")
        result = self.inspect()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_report()

    def test_empty_archive_is_rejected_without_reports(self):
        self.archive.write_bytes(b"!<arch>\n")
        result = self.inspect()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_report()

    def test_symlinked_report_does_not_overwrite_target(self):
        self.make_archive(self.compile_object("valid", "valid"))
        sentinel = self.work / "sentinel.txt"
        sentinel.write_text("untouched\n")
        self.members.symlink_to(sentinel)

        result = self.inspect()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), "untouched\n")
        self.assertFalse(self.symbols.exists())


if __name__ == "__main__":
    unittest.main()
