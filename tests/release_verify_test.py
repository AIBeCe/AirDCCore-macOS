"""Public CLI, exact comparison, and retained failed clean-build receipts."""
import importlib
import contextlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / "scripts/lib/release_verify.py").is_file(), "release verification is missing")
        self.module = importlib.import_module("release_verify")

    def test_cli_reports_missing_package_and_rejects_extra_arguments(self):
        for args, code in ((["/private/tmp/airdc-absent-package"], 1), (["a", "b"], 2)):
            result = subprocess.run([sys.executable, ROOT / "scripts/verify", *args], capture_output=True, text=True)
            self.assertEqual(result.returncode, code)
            self.assertIn("error", result.stderr)

    def fixture(self):
        import distribution_package_test
        fixture = distribution_package_test.PackageTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.stage()
        return fixture

    def test_complete_public_verifier_uses_fresh_consumer_and_rejects_drift(self):
        fixture = self.fixture()
        report = self.module.verify_distribution(fixture.project, fixture.candidate)
        self.assertEqual(report["member_count"], 9)
        archive = fixture.candidate / "lib/libairdcpp.a"
        archive.write_bytes(archive.read_bytes() + b"drift")
        fixture.resign(fixture.candidate)
        with self.assertRaises(ValueError):
            self.module.verify_distribution(fixture.project, fixture.candidate)

    def test_rehashed_unmeasured_consumer_proof_cannot_pass(self):
        fixture = self.fixture()
        path = fixture.candidate / "metadata/consumer-proof.json"
        proof = json.loads(path.read_bytes())
        proof["final_system_imports"] = ["_invented_system_import"]
        path.write_bytes(fixture.aggregate.canonical(proof))
        fixture.resign(fixture.candidate)
        with self.assertRaisesRegex(ValueError, "fresh.*consumer"):
            self.module.verify_distribution(fixture.project, fixture.candidate)


class DriverTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / "scripts/lib/release_verify.py").is_file(), "clean-build release driver is missing")
        self.module = importlib.import_module("release_verify")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name).resolve() / "project"
        self.project.mkdir()
        self.git("init", "-q", "-b", "develop")
        shutil.copytree(ROOT / "config", self.project / "config")
        (self.project / "scripts").mkdir()
        for name in ("update", "build", "package", "verify"):
            path = self.project / "scripts" / name
            path.write_text("#!/bin/sh\nexit " + ("7" if name == "update" else "0") + "\n")
            path.chmod(0o755)
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")

    def git(self, *args):
        return subprocess.check_output(["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                                        "-C", self.project, *args], text=True).strip()

    def test_failed_build_retains_logs_and_no_partial_pass(self):
        with self.assertRaises(self.module.ReleaseError) as caught:
            self.module.run_clean_builds(self.project)
        evidence = caught.exception.evidence
        self.addCleanup(shutil.rmtree, evidence)
        receipt = json.loads((evidence / "receipt.json").read_bytes())
        self.assertEqual(receipt["result"], "FAIL")
        first = json.loads((evidence / "run-1/receipt.json").read_bytes())
        self.assertEqual(first["result"], "FAIL")
        self.assertEqual(first["commands"][-1]["status"], 7)
        self.assertEqual(len(first["commands"]), 1)
        for ordinal in (1, 2):
            project = evidence / f"run-{ordinal}/project"
            self.assertTrue((project / ".git").is_dir())
            for name in ("Source", "Dependencies", "Build", "Dist"):
                self.assertFalse((project / name).exists())
        with self.assertRaises(ValueError):
            self.module.compare_receipts(evidence / "run-1/receipt.json", evidence / "run-2/receipt.json")
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_dirty_implementation_rejects_before_builds(self):
        (self.project / "scripts/update").write_text("changed\n")
        with self.assertRaisesRegex(ValueError, "uncommitted"):
            self.module.run_clean_builds(self.project)

    def test_complete_inventory_comparison_rejects_extra_or_changed_file(self):
        first, second = self.project / "one", self.project / "two"
        first.mkdir()
        second.mkdir()
        for directory in (first, second):
            (directory / "header.h").write_text("header")
            (directory / "archive.a").write_bytes(b"archive")
        self.assertEqual(self.module.distribution_inventory(first), self.module.distribution_inventory(second))
        (second / "header.h").write_text("drift")
        self.assertNotEqual(self.module.distribution_inventory(first), self.module.distribution_inventory(second))
        (second / "header.h").write_text("header")
        (second / "extra.h").write_text("extra")
        self.assertNotEqual(self.module.distribution_inventory(first), self.module.distribution_inventory(second))

    def test_partial_self_reported_receipts_cannot_pass(self):
        first, second = self.project / "first.json", self.project / "second.json"
        for path in (first, second):
            path.write_text(json.dumps(dict(result="PASS", implementation_commit="a" * 40,
                inventory=[], archive_sha256="b" * 64)))
        with self.assertRaises(ValueError):
            self.module.compare_receipts(first, second)

    def test_gate_is_opt_in_and_rejects_arguments(self):
        import os
        env = dict(os.environ, AIRDCCORE_RUN_RELEASE_TESTS="0")
        result = subprocess.run(["/bin/sh", ROOT / "tests/gate8_release_test.sh"], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("SKIP", result.stdout)
        result = subprocess.run(["/bin/sh", ROOT / "tests/gate8_release_test.sh", "--clean", self.project], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 64)
        self.assertTrue((self.project / "scripts/update").is_file())

    def successful_fixture(self, *, core_drift=False):
        # Simulate expensive native commands at their process boundary. Real
        # public verifier behavior is covered above; this tests driver ownership,
        # sequencing, receipt binding and comparison without rebuilding Core.
        script = '''import hashlib,json,sys
from pathlib import Path
root=Path.cwd()
canonical=lambda v:(json.dumps(v,sort_keys=True,separators=(",",":"))+"\\n").encode()
digest=lambda v:hashlib.sha256(canonical(v)).hexdigest()
def put(path,content,once=False):
 path.parent.mkdir(parents=True,exist_ok=True)
 if not once or not path.exists(): path.write_bytes(content)
mode=sys.argv[1]
if mode=="update":
 put(root/("Dependencies" if len(sys.argv)>2 else "Source")/"pin",b"pin",True)
elif mode=="build" and sys.argv[2]=="--build-dependencies":
 for name in ("dependencies","prefix"): put(root/"Build"/name/"fixture/pin",b"pin",True)
elif mode=="build" and sys.argv[2]=="--build-reproducible-core":
 core=root/"Build/airdcpp-core/reproducible-release"
 (core/"source").mkdir(parents=True,exist_ok=True)
 authority=dict(schema=1,staged_root=str(core/"source"),generator_sha256="a"*64)
 inputs=dict(schema=1,version_authority_sha256=digest(authority),implementation=[dict(path="fixture",sha256="b"*64)])
 proof=dict(staged_root=str(core/"source"),version_authority_sha256=digest(authority),core_input_fingerprint=digest(inputs))
 for name,value in (("version-authority.json",authority),("core-inputs.json",inputs),("core-source-provenance.json",proof),("tool-inventory.json",dict(sdk="fixture"))): put(core/name,canonical(value))
 put(core/"core-input-fingerprint.txt",(digest(inputs)+"\\n").encode())
 put(core/"upstream/libairdcpp.a",b"core fixture")
elif mode=="build" and sys.argv[2]=="--link-reproducible-consumer":
 if (root/"Dist").exists() or (root/"Dist").is_symlink():
  print("build: error: reproducible consumer: Dist already exists",file=sys.stderr)
  sys.exit(1)
elif mode=="package":
 core=root/"Build/airdcpp-core/reproducible-release"
 authority=json.loads((core/"version-authority.json").read_bytes())
 authority["staged_root"]="$CORE_SOURCE"
 inputs=json.loads((core/"core-inputs.json").read_bytes())
 inputs["version_authority_sha256"]=digest(authority)
 put(root/"Dist/lib/libairdcpp.a",b"fixture archive")
 put(root/"Dist/include/header.h",b"fixture header")
 put(root/"Dist/metadata/manifest.json",canonical(dict(schema_version=2,components=[dict(core_input_fingerprint=digest(inputs))])))
elif mode=="verify":
 print("verify: PASS "+json.dumps(dict(archive_sha256=hashlib.sha256((root/"Dist/lib/libairdcpp.a").read_bytes()).hexdigest(),member_count=1,file_count=3)))
'''
        if core_drift:
            script = script.replace('put(core/"upstream/libairdcpp.a",b"core fixture")',
                'put(core/"upstream/libairdcpp.a",b"second core" if (core/"upstream/libairdcpp.a").exists() else b"first core")')
        (self.project / "fixture.py").write_text(script)
        for name in ("update", "build", "package", "verify"):
            (self.project / "scripts" / name).write_text("#!/bin/sh\nexec " + sys.executable + ' "$PWD/fixture.py" ' + name + ' "$@"\n')
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "native-command fixtures")
        with contextlib.redirect_stdout(io.StringIO()):
            result = self.module.run_clean_builds(self.project)
        self.addCleanup(shutil.rmtree, result["evidence"])
        self.addCleanup(shutil.rmtree, Path(result["release_rehearsal"]["repository"]).parent)
        return Path(result["evidence"])

    def test_private_consumer_repeats_before_both_publication_passes(self):
        evidence = self.successful_fixture()
        expected_phases = [
            "update", "dependencies", "dependency-build", "core",
            "private-consumer",
            "repeat-update", "repeat-dependencies", "repeat-dependency-build",
            "repeat-core", "repeat-private-consumer",
            "package", "verify", "repeat-package", "repeat-verify",
        ]
        for ordinal in (1, 2):
            directory = evidence / f"run-{ordinal}"
            receipt = json.loads((directory / "receipt.json").read_bytes())
            commands = receipt["commands"]
            self.assertEqual(receipt["result"], "PASS")
            self.assertEqual(len(commands), 14)
            self.assertEqual(
                [command["phase"] for command in commands], expected_phases
            )
            self.assertTrue(all(command["status"] == 0 for command in commands))
            for argv in (["scripts/package"], ["scripts/verify"]):
                self.assertEqual(
                    sum(command["argv"] == argv for command in commands), 2
                )
            self.assertEqual(
                json.loads((directory / "first-dist-inventory.json").read_bytes()),
                json.loads((directory / "final-dist-inventory.json").read_bytes()),
            )

    def test_two_complete_fixture_runs_compare_actual_full_content(self):
        evidence = self.successful_fixture()
        first, second = (evidence / f"run-{n}/receipt.json" for n in (1, 2))
        result = self.module.compare_receipts(first, second)
        self.assertTrue(result["exact_full_inventory_equal"])
        self.assertTrue(result["independent_roots"])
        left, right = (json.loads(path.read_bytes()) for path in (first, second))
        self.assertNotEqual(left["private_core_fingerprint"], right["private_core_fingerprint"])
        self.assertEqual(left["published_core_fingerprint"], right["published_core_fingerprint"])
        self.assertEqual(len(left["commands"]), 14)
        with self.assertRaisesRegex(ValueError, "independently"):
            self.module.compare_receipts(first, first)
        header = evidence / "run-2/project/Dist/include/header.h"
        header.write_bytes(b"drift")
        with self.assertRaisesRegex(ValueError, "inventory|bytes"):
            self.module.compare_receipts(first, second)
        # Rebind the local integrity inventories. Cross-run byte equality must
        # still reject a differing public header even when each receipt agrees
        # with its own package and the aggregate archive is unchanged.
        changed = self.module.distribution_inventory(header.parents[1])
        from distribution_aggregate import canonical, sha
        for name in ("first-dist-inventory.json", "final-dist-inventory.json"):
            (second.parent / name).write_bytes(canonical(changed))
        right["inventory_sha256"] = sha(canonical(changed))
        second.write_bytes(canonical(right))
        with self.assertRaisesRegex(ValueError, "two-clean-build"):
            self.module.compare_receipts(first, second)

    def test_missing_noop_snapshot_cannot_earn_pass(self):
        evidence = self.successful_fixture()
        (evidence / "run-1/no-op-snapshots.json").unlink()
        with self.assertRaises((ValueError, OSError)):
            self.module.compare_receipts(evidence / "run-1/receipt.json", evidence / "run-2/receipt.json")

    def test_repeated_core_archive_drift_fails_before_publication(self):
        with self.assertRaises(self.module.ReleaseError) as caught:
            self.successful_fixture(core_drift=True)
        self.addCleanup(shutil.rmtree, caught.exception.evidence)
        receipt = json.loads((caught.exception.evidence / "run-1/receipt.json").read_bytes())
        self.assertEqual(receipt["result"], "FAIL")
        self.assertEqual(receipt["commands"][-1]["phase"], "repeat-core")
