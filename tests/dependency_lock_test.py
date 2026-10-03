"""Offline contract tests for the canonical dependency lock."""

import copy
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/lib/dependency_lock.py"
TRACKED_LOCK = ROOT / "config/dependencies.lock"
ZERO_HASH = "0" * 64


def fixture_record(name="fixture"):
    return {
        "adapter": "cmake",
        "build_options": [],
        "configure_options": ["-DCMAKE_INSTALL_PREFIX=@STAGE@"],
        "dependencies": [],
        "expected_archives": ["lib/libfixture.a"],
        "expected_headers": ["include/fixture.h"],
        "expected_metadata": [],
        "forbidden_globs": ["**/*.dylib", "**/*.so", "**/*.so.*", "**/*.la"],
        "install_options": [],
        "license_paths": ["LICENSE"],
        "license_spdx": "MIT",
        "name": name,
        "patches": [],
        "platform": {
            "architecture": "arm64", "build_type": "Release",
            "cxx_runtime": "libc++", "deployment_target": "14.0", "linkage": "static",
        },
        "role": "aggregate",
        "source": {
            "archive_sha256": ZERO_HASH, "commit": None, "kind": "archive",
            "tag": None, "tree_manifest_sha256": ZERO_HASH,
            "url": "https://example.org/fixture.tar.gz",
        },
        "source_date_epoch": 1,
        "version": "1.0",
    }


def canonical(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


class DependencyLockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="airdc-lock-test-")
        self.addCleanup(self.temp.cleanup)
        self.lock_path = Path(self.temp.name) / "dependencies.lock"
        self.value = {"schema_version": 1, "dependencies": [fixture_record()]}

    def validate_bytes(self, data):
        self.lock_path.write_bytes(data)
        return subprocess.run(
            [sys.executable, str(VALIDATOR), "validate", "--lock", str(self.lock_path)],
            capture_output=True, text=True,
        )

    def validate_value(self, value):
        return self.validate_bytes(canonical(value))

    def assert_rejected(self, value, message):
        result = self.validate_value(value)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)

    def test_tracked_lock_is_accepted_and_has_exact_records(self):
        result = subprocess.run(
            [sys.executable, str(VALIDATOR), "validate", "--lock", str(TRACKED_LOCK)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        data = TRACKED_LOCK.read_bytes()
        self.assertEqual(data, canonical(json.loads(data)))
        self.assertEqual(result.stdout.strip(), hashlib.sha256(data).hexdigest())
        records = json.loads(data)["dependencies"]
        self.assertEqual([record["name"] for record in records], [
            "bzip2", "zlib", "openssl", "miniupnpc", "libmaxminddb",
            "snappy", "leveldb", "boost",
        ])
        self.assertEqual([record["dependencies"] for record in records],
                         [[], [], [], [], [], [], ["snappy"], []])

    def test_duplicate_json_key_is_rejected(self):
        result = self.validate_bytes(b'{"schema_version":1,"schema_version":1,"dependencies":[]}\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate JSON key: schema_version", result.stderr)

    def test_noncanonical_bytes_are_rejected(self):
        result = self.validate_bytes(json.dumps(self.value).encode() + b"\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-canonical", result.stderr)

    def test_schema_version_must_be_one(self):
        self.value["schema_version"] = 2
        self.assert_rejected(self.value, "schema_version")

    def test_unknown_fields_are_rejected(self):
        self.value["dependencies"][0]["surprise"] = "ignored?"
        self.assert_rejected(self.value, "unknown field")

    def test_duplicate_names_are_rejected(self):
        self.value["dependencies"].append(fixture_record())
        self.assert_rejected(self.value, "duplicate dependency")

    def test_invalid_role_is_rejected(self):
        self.value["dependencies"][0]["role"] = "system"
        self.assert_rejected(self.value, "role")

    def test_malformed_sha256_is_rejected(self):
        self.value["dependencies"][0]["source"]["archive_sha256"] = "0" * 63
        self.assert_rejected(self.value, "sha256")

    def test_archive_url_must_be_https(self):
        self.value["dependencies"][0]["source"]["url"] = "http://example.org/a.tar.gz"
        self.assert_rejected(self.value, "HTTPS")

    def test_url_shell_metacharacters_are_rejected(self):
        self.value["dependencies"][0]["source"]["url"] = "https://example.org/a;touch"
        self.assert_rejected(self.value, "unsafe")

    def test_git_commit_must_be_full_hash(self):
        source = self.value["dependencies"][0]["source"]
        source.update(kind="git", url="https://example.org/repo.git",
                      archive_sha256=None, commit="abc123", tag="1.0")
        self.assert_rejected(self.value, "commit")

    def test_undeclared_dependency_is_rejected(self):
        self.value["dependencies"][0]["dependencies"] = ["missing"]
        self.assert_rejected(self.value, "undeclared dependency")

    def test_cycles_are_rejected(self):
        first = self.value["dependencies"][0]
        second = fixture_record("other")
        first["dependencies"] = ["other"]
        second["dependencies"] = ["fixture"]
        self.value["dependencies"].append(second)
        self.assert_rejected(self.value, "cycle")

    def test_declared_dependencies_must_precede_dependents(self):
        self.value["dependencies"][0]["dependencies"] = ["other"]
        self.value["dependencies"].append(fixture_record("other"))
        self.assert_rejected(self.value, "topological order")

    def test_unsafe_adapter_name_is_rejected(self):
        self.value["dependencies"][0]["adapter"] = "../../evil"
        self.assert_rejected(self.value, "adapter")

    def test_unsafe_options_are_rejected(self):
        for option in ("a; touch /tmp/evil", "a\nb", "a\x00b"):
            with self.subTest(option=option):
                value = copy.deepcopy(self.value)
                value["dependencies"][0]["build_options"] = [option]
                self.assert_rejected(value, "unsafe")

    def test_literal_host_paths_in_options_are_rejected(self):
        for field, option in (
            ("configure_options", "-DCMAKE_PREFIX_PATH=/opt/homebrew"),
            ("build_options", "-I/opt/homebrew/Cellar/zlib/1.3.2/include"),
            ("build_options", "-L/opt/homebrew/lib"),
        ):
            with self.subTest(field=field, option=option):
                value = copy.deepcopy(self.value)
                value["dependencies"][0][field] = [option]
                self.assert_rejected(value, "host path")

    def test_unknown_substitution_token_is_rejected(self):
        self.value["dependencies"][0]["build_options"] = ["-j@SHELL@"]
        self.assert_rejected(self.value, "token")

    def test_exact_openssl_runtime_defaults_are_accepted_only_in_build_install(self):
        options = ["OPENSSLDIR=/usr/local/ssl", "ENGINESDIR=/usr/local/lib/engines-3",
                   "MODULESDIR=/usr/local/lib/ossl-modules"]
        for field in ("build_options", "install_options"):
            value = copy.deepcopy(self.value)
            record = value["dependencies"][0]
            record.update(name="openssl", adapter="openssl")
            record[field] = options
            result = self.validate_value(value)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_openssl_runtime_exception_does_not_admit_other_host_paths(self):
        exact = "OPENSSLDIR=/usr/local/ssl"
        for name, adapter, field, option in (
            ("fixture", "openssl", "build_options", exact),
            ("openssl", "cmake", "build_options", exact),
            ("openssl", "openssl", "configure_options", exact),
            ("openssl", "openssl", "build_options", "OPENSSLDIR=/etc/ssl"),
            ("openssl", "openssl", "build_options", "OPENSSLDIR=/usr/local/ssl/"),
            ("openssl", "openssl", "install_options", "ENGINESDIR=/usr/local/lib64/engines-3"),
            ("openssl", "openssl", "install_options", "MODULESDIR=/usr/local/lib/other"),
            ("openssl", "openssl", "build_options", "-I/usr/local/include"),
            ("openssl", "openssl", "install_options", "-L/usr/local/lib"),
            ("openssl", "openssl", "build_options", "CPPFLAGS=-I/usr/local/include"),
        ):
            with self.subTest(name=name, adapter=adapter, field=field, option=option):
                value = copy.deepcopy(self.value)
                record = value["dependencies"][0]
                record.update(name=name, adapter=adapter)
                record[field] = [option]
                self.assert_rejected(value, "host path")

    def test_expected_paths_must_be_relative_and_confined(self):
        for path in ("/tmp/escape.h", "include/../escape.h", "include//escape.h"):
            with self.subTest(path=path):
                value = copy.deepcopy(self.value)
                value["dependencies"][0]["expected_headers"] = [path]
                self.assert_rejected(value, "path")

    def test_patch_sha256_must_match_tracked_bytes(self):
        self.value["dependencies"][0]["patches"] = [
            {"path": "README.md", "sha256": ZERO_HASH}
        ]
        self.assert_rejected(self.value, "patch")

    def test_matching_untracked_patch_is_rejected(self):
        project = Path(self.temp.name) / "project"
        validator = project / "scripts/lib/dependency_lock.py"
        validator.parent.mkdir(parents=True)
        shutil.copyfile(VALIDATOR, validator)
        patch = project / "change.patch"
        patch.write_bytes(b"untracked patch\n")
        subprocess.run(["git", "init", "-q", str(project)], check=True)
        value = copy.deepcopy(self.value)
        value["dependencies"][0]["patches"] = [
            {"path": "change.patch", "sha256": hashlib.sha256(patch.read_bytes()).hexdigest()}
        ]
        lock = project / "dependencies.lock"
        lock.write_bytes(canonical(value))
        result = subprocess.run(
            [sys.executable, str(validator), "validate", "--lock", str(lock)],
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("untracked patch", result.stderr)

    def test_record_prints_data_and_fingerprint_prints_hash(self):
        self.lock_path.write_bytes(canonical(self.value))
        record = subprocess.run(
            [sys.executable, str(VALIDATOR), "record", "--lock", str(self.lock_path),
             "--name", "fixture", "--field", "dependencies"],
            capture_output=True, text=True,
        )
        self.assertEqual(record.returncode, 0, record.stderr)
        self.assertEqual(record.stdout, "[]\n")
        fingerprint = subprocess.run(
            [sys.executable, str(VALIDATOR), "fingerprint", "--lock", str(self.lock_path)],
            capture_output=True, text=True,
        )
        self.assertEqual(fingerprint.returncode, 0, fingerprint.stderr)
        self.assertEqual(fingerprint.stdout.strip(), hashlib.sha256(self.lock_path.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
