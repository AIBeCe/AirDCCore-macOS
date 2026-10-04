#!/usr/bin/env python3
"""Gate entry policy is exercised as a process, not by source-text matching."""
from pathlib import Path
import os
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GateTests(unittest.TestCase):
    def gate(self, *arguments):
        path = ROOT / "tests/gate7_distribution_test.sh"
        self.assertTrue(path.is_file(), "Gate 7 entry point is missing")
        environment = {**os.environ, "AIRDCCORE_RUN_DISTRIBUTION_TESTS": "0"}
        return subprocess.run(["/bin/sh", str(path), *arguments], env=environment, text=True, capture_output=True)

    def test_live_gate_without_authorization_skips_without_package_mutation(self):
        checksum = ROOT / "Dist/metadata/checksums.sha256"
        before = checksum.read_bytes() if checksum.is_file() else None
        result = self.gate()
        self.assertEqual(result.returncode, 0)
        self.assertIn("SKIP", result.stdout)
        self.assertEqual(checksum.read_bytes() if checksum.is_file() else None, before)

    def test_invalid_arguments_are_refused_before_live_execution(self):
        result = self.gate("--unexpected")
        self.assertEqual(result.returncode, 64)
        result = self.gate("--verify")
        self.assertEqual(result.returncode, 64)


if __name__ == "__main__":
    unittest.main()
