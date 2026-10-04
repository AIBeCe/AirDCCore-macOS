"""Publication identity changes only the validated staging-root field."""
import hashlib
import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


class PublicIdentityTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / "scripts/lib/public_core_identity.py").is_file(),
                        "public Core identity normalization is missing")
        self.identity = importlib.import_module("public_core_identity")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def evidence(self, name, *, authority_change=None, input_change=None):
        evidence = self.root / name
        (evidence / "source").mkdir(parents=True)
        authority = dict(schema=1, staged_root=str(evidence / "source"),
            upstream_commit="a" * 40, generator_sha256="b" * 64,
            python=dict(sha256="c" * 64), source_date_epoch=1234,
            version=dict(tag="v1"), output_path="airdcpp/core/version.inc")
        if authority_change:
            authority_change(authority)
        inputs = dict(schema=1, version_authority_sha256=digest(authority),
            original_manifest_sha256="d" * 64, patched_manifest_sha256="e" * 64,
            implementation=[dict(path="core_stage.py", sha256="f" * 64)],
            tool_inventory=dict(cxx=dict(sha256="1" * 64)), python=dict(sha256="c" * 64))
        if input_change:
            input_change(inputs)
        provenance = dict(staged_root=str(evidence / "source"),
            version_authority_sha256=digest(authority), core_input_fingerprint=digest(inputs))
        (evidence / "version-authority.json").write_bytes(canonical(authority))
        (evidence / "core-inputs.json").write_bytes(canonical(inputs))
        (evidence / "core-input-fingerprint.txt").write_text(digest(inputs) + "\n")
        return evidence, provenance

    def test_relocation_equal_with_private_receipts_preserved(self):
        first, first_proof = self.evidence("first")
        second, second_proof = self.evidence("second")
        before = {p.name: p.read_bytes() for p in first.iterdir() if p.is_file()}
        self.assertNotEqual(first_proof["core_input_fingerprint"], second_proof["core_input_fingerprint"])
        actual = self.identity.public_core_fingerprint(first, first_proof)
        self.assertEqual(actual, self.identity.public_core_fingerprint(second, second_proof))
        authority = json.loads(before["version-authority.json"])
        authority["staged_root"] = "$CORE_SOURCE"
        expected = json.loads(before["core-inputs.json"])
        expected["version_authority_sha256"] = digest(authority)
        self.assertEqual(actual, digest(expected))
        self.assertEqual(before, {p.name: p.read_bytes() for p in first.iterdir() if p.is_file()})

    def test_non_path_authority_and_input_changes_stay_bound(self):
        base, proof = self.evidence("base")
        expected = self.identity.public_core_fingerprint(base, proof)
        for field in ("upstream_commit", "generator_sha256", "python", "source_date_epoch", "version", "output_path"):
            with self.subTest(authority=field):
                path, changed = self.evidence(field, authority_change=lambda a: a.update({field: "changed"}))
                self.assertNotEqual(expected, self.identity.public_core_fingerprint(path, changed))
        for field in ("original_manifest_sha256", "patched_manifest_sha256", "implementation", "tool_inventory", "python"):
            with self.subTest(input=field):
                path, changed = self.evidence("input-" + field, input_change=lambda a: a.update({field: "changed"}))
                self.assertNotEqual(expected, self.identity.public_core_fingerprint(path, changed))

    def test_rejects_raw_private_receipt_and_authority_digest_drift(self):
        for field in ("core_input_fingerprint", "version_authority_sha256"):
            path, proof = self.evidence(field)
            proof[field] = "0" * 64
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.identity.public_core_fingerprint(path, proof)
        path, proof = self.evidence("receipt")
        (path / "core-input-fingerprint.txt").write_text("0" * 64 + "\n")
        with self.assertRaises(ValueError):
            self.identity.public_core_fingerprint(path, proof)
        path, proof = self.evidence("input-authority", input_change=lambda a: a.update(version_authority_sha256="0" * 64))
        with self.assertRaises(ValueError):
            self.identity.public_core_fingerprint(path, proof)

    def test_rejects_wrong_stage_even_with_rehashed_private_evidence(self):
        path, proof = self.evidence("wrong", authority_change=lambda a: a.update(staged_root=str(self.root / "elsewhere")))
        with self.assertRaises(ValueError):
            self.identity.public_core_fingerprint(path, proof)
        path, proof = self.evidence("wrong-provenance")
        proof["staged_root"] = str(self.root / "elsewhere")
        with self.assertRaises(ValueError):
            self.identity.public_core_fingerprint(path, proof)

    def test_rejects_noncanonical_or_symlinked_evidence(self):
        path, proof = self.evidence("noncanonical")
        authority = json.loads((path / "version-authority.json").read_bytes())
        (path / "version-authority.json").write_text(json.dumps(authority, indent=2))
        with self.assertRaises(ValueError):
            self.identity.public_core_fingerprint(path, proof)
        link = self.root / "link"
        link.symlink_to(path, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.identity.public_core_fingerprint(link, proof)


if __name__ == "__main__":
    unittest.main()
