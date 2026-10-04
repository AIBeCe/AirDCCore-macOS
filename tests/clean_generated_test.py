"""Cleanup safety is exercised only against disposable Git projects."""
import importlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))


class CleanTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / "scripts/lib/clean_generated.py").is_file(), "safe generated cleanup is missing")
        self.clean = importlib.import_module("clean_generated")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name).resolve()
        self.project = self.work / "project"
        self.project.mkdir()
        subprocess.run(["git", "init", "-q", self.project], check=True)
        (self.project / "tracked.txt").write_text("original\n")
        subprocess.run(["git", "-C", self.project, "add", "tracked.txt"], check=True)
        for name in ("Source", "Dependencies", "Build", "Dist"):
            (self.project / name).mkdir()
            (self.project / name / "content").write_text(name)
        (self.project / "tracked.txt").write_text("dirty tracked work\n")
        (self.project / "dirty.cpp").write_text("untracked source\n")

    def test_removes_only_generated_trees_and_is_idempotent(self):
        self.assertEqual(self.clean.clean_generated(self.project)["removed"], ["Build", "Dist"])
        self.assertEqual(self.clean.clean_generated(self.project)["removed"], [])
        self.assertEqual((self.project / "tracked.txt").read_text(), "dirty tracked work\n")
        self.assertEqual((self.project / "dirty.cpp").read_text(), "untracked source\n")
        for name in ("Source", "Dependencies"):
            self.assertEqual((self.project / name / "content").read_text(), name)

    def test_top_level_symlink_rejects_before_either_tree_is_removed(self):
        import shutil
        shutil.rmtree(self.project / "Dist")
        (self.project / "Dist").symlink_to(self.project / "Source", target_is_directory=True)
        with self.assertRaises(ValueError):
            self.clean.clean_generated(self.project)
        self.assertTrue((self.project / "Build/content").is_file())
        self.assertTrue((self.project / "Source/content").is_file())

    def test_nested_symlinks_are_unlinked_without_following(self):
        (self.project / "Build/escape").symlink_to(self.project / "Source", target_is_directory=True)
        (self.project / "Dist/escape").symlink_to(self.project / "tracked.txt")
        self.clean.clean_generated(self.project)
        self.assertTrue((self.project / "Source/content").is_file())
        self.assertEqual((self.project / "tracked.txt").read_text(), "dirty tracked work\n")

    def test_tracked_generated_content_rejects_before_mutation(self):
        subprocess.run(["git", "-C", self.project, "add", "Dist/content"], check=True)
        with self.assertRaisesRegex(ValueError, "tracked"):
            self.clean.clean_generated(self.project)
        self.assertTrue((self.project / "Build/content").is_file())
        self.assertTrue((self.project / "Dist/content").is_file())

    def test_unsafe_root_or_file_target_rejects_before_mutation(self):
        import shutil
        alias = self.work / "alias"
        alias.symlink_to(self.project, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            self.clean.clean_generated(alias)
        with self.assertRaises(ValueError):
            self.clean.clean_generated(self.project / "Source")
        shutil.rmtree(self.project / "Dist")
        (self.project / "Dist").write_text("unexpected file")
        with self.assertRaises(ValueError):
            self.clean.clean_generated(self.project)
        self.assertTrue((self.project / "Build/content").is_file())

    def test_cli_rejects_arbitrary_cleanup_target(self):
        result = subprocess.run([sys.executable, ROOT / "scripts/clean", self.project], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage", result.stderr)
        self.assertTrue((self.project / "Build/content").is_file())
