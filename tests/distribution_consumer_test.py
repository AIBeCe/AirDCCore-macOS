#!/usr/bin/env python3
"""Real Apple compiler/linker behavior at the relocated public boundary."""
import importlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))


class ConsumerTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / "scripts/lib/distribution_consumer.py").is_file(),
                        "relocated public consumer implementation is missing")
        self.consumer = importlib.import_module("distribution_consumer")
        self.temp = tempfile.TemporaryDirectory(prefix="airdc-public-consumer-test-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name).resolve()
        self.dist = self.work / "relocated/Dist"
        include = self.dist / "include/airdcpp/core"
        include.mkdir(parents=True)
        (include.parent / "stdinc.h").write_text("#pragma once\n#include <string>\n")
        (include / "version.h").write_text("#pragma once\nnamespace dcpp { std::string getVersionTag(); std::string getGitCommit(); }\n")
        # A genuine common definition and repeated weak definition must resolve
        # when every object is forced into the output, not only selected symbols.
        cpp = self.work / "core.cpp"
        cpp.write_text('#include <string>\nnamespace dcpp { std::string getVersionTag() { return "0.0.0"; } std::string getGitCommit() { return "fixture-pin"; } }\n')
        sources = [(cpp, "01-core--0001-core.o")]
        for n in (2, 3):
            source = self.work / (str(n) + ".c")
            source.write_text("int shared_common; __attribute__((weak)) int shared_weak(void) { return 7; }\n")
            sources.append((source, f"0{n}-fixture--0001-{n}.o"))
        objects = []
        for source, name in sources:
            obj = self.work / name
            subprocess.run(["/usr/bin/clang++" if source.suffix == ".cpp" else "/usr/bin/clang",
                "-arch", "arm64", "-mmacosx-version-min=14.0", "-fcommon", "-c", str(source), "-o", str(obj)],
                capture_output=True, check=True)
            objects.append(obj)
        (self.dist / "lib").mkdir()
        subprocess.run(["/usr/bin/libtool", "-static", "-D", "-o", str(self.dist / "lib/libairdcpp.a"), *map(str, objects)],
                       capture_output=True, check=True)
        self.headers = [dict(path=p.relative_to(self.dist).as_posix(), component="core",
            sha256=self.consumer.sha(p.read_bytes())) for p in sorted((self.dist / "include").rglob("*.h"))]
        self.identity = dict(commit="fixture-pin", tag="0.0.0")

    def test_real_relocated_identity_and_force_load_common_weak_resolution(self):
        proof = self.consumer.prove_consumer(self.dist, self.headers, self.identity)
        self.assertEqual(proof["runtime_identity"], {"commit": "fixture-pin", "tag": "0.0.0"})
        self.assertEqual(proof["force_loaded_members"], 3)
        self.assertEqual(proof["load_commands"], ["/usr/lib/libSystem.B.dylib", "/usr/lib/libc++.1.dylib", "/usr/lib/libiconv.2.dylib"])
        self.assertIn("_shared_common", proof["resolved_definitions"])
        self.assertIn("_shared_weak", proof["resolved_definitions"])
        self.assertNotIn(str(self.work), json.dumps(proof))
        self.consumer.validate_consumer_proof(self.dist, self.headers, self.identity, proof)

    def test_identity_mismatch_rejects_real_runtime(self):
        with self.assertRaisesRegex(ValueError, "runtime.*identity"):
            self.consumer.prove_consumer(self.dist, self.headers, dict(commit="wrong-pin", tag="0.0.0"))

    def test_guarded_platform_headers_and_missing_public_dependency(self):
        header = self.dist / "include/airdcpp/core/platform.h"
        header.write_text('#ifdef HAVE_INTEL_TBB\n#include <missing-tbb.h>\n#endif\n#ifdef _MSC_VER\n#include <missing-msvc.h>\n#endif\n')
        row = dict(path="include/airdcpp/core/platform.h", component="core", sha256=self.consumer.sha(header.read_bytes()))
        self.consumer.prove_consumer(self.dist, [*self.headers, row], self.identity)
        header.write_text('#include <missing-public-dependency.h>\n')
        row["sha256"] = self.consumer.sha(header.read_bytes())
        with self.assertRaisesRegex(ValueError, "header.*closure"):
            self.consumer.prove_consumer(self.dist, [*self.headers, row], self.identity)

    def test_private_header_reach_back_is_denied_by_real_compiler(self):
        forbidden = self.work / "Source"
        forbidden.mkdir()
        secret = forbidden / "secret.h"
        secret.write_text("#pragma once\n")
        header = self.dist / "include/airdcpp/core/private.h"
        header.write_text('#include "' + str(secret) + '"\n')
        row = dict(path="include/airdcpp/core/private.h", component="core", sha256=self.consumer.sha(header.read_bytes()))
        with self.assertRaisesRegex(ValueError, "public header closure failed"):
            self.consumer.prove_consumer(self.dist, [*self.headers, row], self.identity, forbidden_roots=[forbidden])

    def test_rehashed_header_and_archive_binding_cannot_reuse_public_proof(self):
        proof = self.consumer.prove_consumer(self.dist, self.headers, self.identity)
        changed = json.loads(json.dumps(proof))
        changed["inputs"]["archive_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "consumer.*binding"):
            self.consumer.validate_consumer_proof(self.dist, self.headers, self.identity, changed)

    def test_source_definitions_are_not_reported_as_final_system_imports(self):
        proof = self.consumer.prove_consumer(self.dist, self.headers, self.identity)
        changed = json.loads(json.dumps(proof))
        changed["resolved_definitions"] = []
        with self.assertRaisesRegex(ValueError, "consumer.*definition"):
            self.consumer.validate_consumer_proof(self.dist, self.headers, self.identity, changed)
        changed = json.loads(json.dumps(proof))
        changed["final_system_imports"] = ["_shared_common"]
        with self.assertRaisesRegex(ValueError, "consumer.*import"):
            self.consumer.validate_consumer_proof(self.dist, self.headers, self.identity, changed)

    def test_link_map_symbol_encoding_does_not_hide_member_coverage(self):
        self.assertTrue(hasattr(self.consumer, "map_members"), "byte-safe native link-map member reader is missing")
        self.assertEqual(self.consumer.map_members(b"[ 1] /tmp/libairdcpp.a(01-core--0001-core.o)\n# Symbols\nraw-\xf3-symbol\n"),
                         ["01-core--0001-core.o"])

    def test_contextual_fragments_are_parsed_through_declared_public_context(self):
        files = {
            "airdcpp/core/localization/StringDefs.h": "enum Strings { FILE };\n",
            "airdcpp/core/localization/ResourceManager.h": '#pragma once\nnamespace dcpp { class ResourceManager {\n#include <airdcpp/core/localization/StringDefs.h>\n}; }\n',
            "airdcpp/core/update/UpdateManager.h": "#pragma once\nnamespace dcpp { class UpdateManager { static int publicKey; }; }\n",
            "airdcpp/core/crypto/pubkey.h": "int dcpp::UpdateManager::publicKey = 7;\n",
        }
        rows = list(self.headers)
        for name, content in files.items():
            path = self.dist / "include" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            rows.append(dict(path="include/" + name, component="core", sha256=self.consumer.sha(path.read_bytes())))
        proof = self.consumer.prove_consumer(self.dist, rows, self.identity)
        self.assertIn("airdcpp/core/localization/StringDefs.h", proof["public_header_dependencies"])
        self.assertIn("airdcpp/core/crypto/pubkey.h", proof["public_header_dependencies"])


if __name__ == "__main__":
    unittest.main()
