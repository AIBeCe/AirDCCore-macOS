"""GitFlow rehearsal never modifies refs in the source repository."""
import importlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))


class RehearsalTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / "scripts/lib/release_rehearsal.py").is_file(), "local release rehearsal is missing")
        self.module = importlib.import_module("release_rehearsal")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name).resolve() / "source"
        self.project.mkdir()
        self.git("init", "-q", "-b", "develop")
        (self.project / "source.txt").write_text("committed input\n")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")

    def git(self, *args):
        return subprocess.check_output(["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                                        "-C", self.project, *args], text=True).strip()

    def test_first_release_bootstrap_tag_and_merge_back_are_isolated(self):
        before = self.git("show-ref")
        receipt = self.module.rehearse_release(self.project, "0.0.0")
        self.addCleanup(__import__("shutil").rmtree, Path(receipt["repository"]).parent)
        self.assertEqual(receipt["result"], "PASS")
        self.assertEqual(before, self.git("show-ref"))
        repository = Path(receipt["repository"])
        def ref(name):
            return subprocess.check_output(["git", "-C", repository, "rev-parse", name], text=True).strip()
        self.assertEqual(ref("master"), ref("release/0.0.0"))
        self.assertEqual(ref("master"), ref("v0.0.0^{commit}"))
        self.assertNotEqual(ref("v0.0.0"), ref("v0.0.0^{commit}"))
        self.assertNotEqual(ref("develop"), ref("master"))
        subprocess.run(["git", "-C", repository, "merge-base", "--is-ancestor", "master", "develop"], check=True)
        self.assertFalse((self.project / ".release-rehearsal").exists())

    def test_invalid_version_rejects_without_source_ref_changes(self):
        before = self.git("show-ref")
        with self.assertRaises(ValueError):
            self.module.rehearse_release(self.project, "../../escape")
        self.assertEqual(before, self.git("show-ref"))

    def test_dirty_source_is_not_imported_or_modified(self):
        (self.project / "source.txt").write_text("dirty work\n")
        (self.project / "private.txt").write_text("untracked work\n")
        receipt = self.module.rehearse_release(self.project, "1.2.3")
        self.addCleanup(__import__("shutil").rmtree, Path(receipt["repository"]).parent)
        self.assertEqual((Path(receipt["repository"]) / "source.txt").read_text(), "committed input\n")
        self.assertFalse((Path(receipt["repository"]) / "private.txt").exists())
        self.assertEqual((self.project / "source.txt").read_text(), "dirty work\n")
