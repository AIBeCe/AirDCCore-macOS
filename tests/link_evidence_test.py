import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NORMALIZER = ROOT / "scripts/lib/normalize_link_evidence.py"


class LinkEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="airdc-link-evidence-")
        self.work = Path(self.temporary.name)
        self.project = self.work / "Project Root"
        self.project.mkdir()
        self.command = self.work / "link-command.txt"
        self.omissions = self.work / "omissions.tsv"
        self.output = self.work / "link-interface.tsv"
        self.omissions.write_text(
            "pass\tordinal\tlogical\tclassification\tbuild_exit\n"
            "1\t1\tBZip2\trequired\t1\n",
            encoding="utf-8",
        )

    def tearDown(self):
        self.temporary.cleanup()

    def run_normalizer(self):
        return subprocess.run(
            [
                "python3",
                str(NORMALIZER),
                "--project-root",
                str(self.project),
                "--command",
                str(self.command),
                "--omissions",
                str(self.omissions),
                "--output",
                str(self.output),
            ],
            text=True,
            capture_output=True,
        )

    def test_order_deduplication_and_framework_pairing(self):
        core = self.project / "Build/airdcpp-core/link-interface/stage/lib/libairdcpp.a"
        self.command.write_text(
            f'/usr/bin/clang++ main.o "-Wl,-force_load,{core}" '
            '"/opt/homebrew/opt/bzip2/lib/libbz2.a" '
            '"/opt/homebrew/opt/bzip2/lib/libbz2.a" '
            '-framework CoreFoundation -lSystem -o airdcpp-smoke\n',
            encoding="utf-8",
        )

        result = self.run_normalizer()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.output.read_text(encoding="utf-8"),
            "1\tcore\tstage/lib/libairdcpp.a\n"
            "2\tlibrary\t/opt/homebrew/opt/bzip2/lib/libbz2.a\n"
            "3\tframework\tCoreFoundation\n"
            "4\tsystem\t-lSystem\n",
        )

    def test_exact_project_root_is_normalized_without_prefix_collision(self):
        inside = self.project / "vendor/libinside.a"
        outside = Path(f"{self.project}-other/vendor/liboutside.a")
        self.command.write_text(
            f'/usr/bin/clang++ main.o "{inside}" "{outside}" -o app\n', encoding="utf-8"
        )

        result = self.run_normalizer()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.output.read_text(encoding="utf-8"),
            f"1\tlibrary\t$PROJECT_ROOT/vendor/libinside.a\n"
            f"2\tlibrary\t{outside}\n",
        )

    def test_sdk_stub_is_retained_as_a_system_item(self):
        stub = "/Applications/Xcode.app/SDK/usr/lib/libiconv.tbd"
        self.command.write_text(f'/usr/bin/clang++ main.o "{stub}" -o app\n', encoding="utf-8")

        result = self.run_normalizer()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), f"1\tsystem\t{stub}\n")

    def test_malformed_framework_does_not_publish_output(self):
        self.output.write_text("preserve me\n", encoding="utf-8")
        self.command.write_text("/usr/bin/clang++ main.o -framework\n", encoding="utf-8")

        result = self.run_normalizer()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("link-evidence: error:", result.stderr)
        self.assertIn("framework", result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "preserve me\n")

    def test_malformed_omission_row_does_not_publish_output(self):
        self.output.write_text("preserve me\n", encoding="utf-8")
        self.command.write_text("/usr/bin/clang++ main.o -lSystem -o app\n", encoding="utf-8")
        self.omissions.write_text("pass\tordinal\tlogical\tclassification\tbuild_exit\n1\t1\tBZip2\n", encoding="utf-8")

        result = self.run_normalizer()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("omission", result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "preserve me\n")


if __name__ == "__main__":
    unittest.main()
