#!/usr/bin/env python3
"""Behavioral checks for validated, lossless Darwin archive aggregation."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))


class AggregateTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / "scripts/lib/distribution_aggregate.py").is_file(),
                        "packaging aggregate implementation is missing")
        import distribution_aggregate
        self.module = distribution_aggregate
        self.temporary = tempfile.TemporaryDirectory(prefix="airdc-aggregate-test-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name).resolve()

    def object(self, name, code, target="14.0", arch="arm64"):
        source = self.work / (name + ".c")
        obj = self.work / (name + ".o")
        source.write_text(code)
        subprocess.run(["/usr/bin/clang", "-arch", arch,
                        "-mmacosx-version-min=" + target, "-c", str(source),
                        "-o", str(obj)], check=True, capture_output=True)
        return obj.read_bytes()

    def archive(self, name, rows):
        # BSD ar fixture preserves duplicate original basenames and odd lengths.
        content = b"!<arch>\n"
        for member, payload in rows:
            encoded = member.encode()
            body = encoded + payload
            header = ("#1/" + str(len(encoded))).ljust(16) + "0".ljust(12)
            header += "0".ljust(6) + "0".ljust(6) + "100644".ljust(8)
            header += str(len(body)).ljust(10) + "`\n"
            content += header.encode() + body + (b"\n" if len(body) % 2 else b"")
        archive = self.work / name
        archive.write_bytes(content)
        return archive

    def component(self, ordinal, slug, rows):
        path = self.archive(slug + ".a", rows)
        return self.module.Component(ordinal, slug, path, {})

    def test_evidence_binding_rejects_pin_policy_and_hash_drift(self):
        expected = {"source": {"identity": "pin"}, "policy": "14.0", "archive": "hash"}
        (self.work / "inputs.json").write_bytes(self.module.canonical(expected))
        (self.work / "input-fingerprint.txt").write_text(
            hashlib.sha256(self.module.canonical(expected)).hexdigest() + "\n")
        self.module.validate_input_binding(self.work, expected)
        for key, value in (("source", {"identity": "wrong"}),
                           ("policy", "15.0"), ("archive", "drift")):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "input"):
                self.module.validate_input_binding(self.work, dict(expected, **{key: value}))

    def test_duplicate_original_names_preserve_both_payloads_and_ordinals(self):
        first = self.object("first", "int first(void) { return 1; }")
        second = self.object("second", "int second(void) { return 2; }")
        members = self.module.inspect_members([self.component(1, "core", [("same.o", first), ("same.o", second)])])
        self.assertEqual([m.canonical_name for m in members],
                         ["01-core--0001-same.o", "01-core--0002-same.o"])
        self.assertEqual([m.sha256 for m in members],
                         [hashlib.sha256(first).hexdigest(), hashlib.sha256(second).hexdigest()])

    def test_normalization_cannot_escape_namespace(self):
        payload = self.object("safe", "int safe(void) { return 0; }")
        members = self.module.inspect_members([self.component(2, "bzip2", [("../bad name.o", payload)])])
        self.assertEqual(members[0].canonical_name, "02-bzip2--0001-.._bad_name.o")

    def test_duplicate_strong_definitions_fail_before_construction(self):
        payload = self.object("strong", "int collision(void) { return 0; }")
        members = self.module.inspect_members([self.component(1, "core", [("a.o", payload), ("b.o", payload)])])
        with self.assertRaisesRegex(ValueError, "duplicate strong.*_collision"):
            self.module.classify_repetitions(members)

    def test_distinct_original_names_cannot_normalize_to_same_suffix(self):
        payload = self.object("normalized", "int normalized(void) { return 0; }")
        with self.assertRaisesRegex(ValueError, "normalization collision"):
            self.module.inspect_members([self.component(1, "core", [("a/b.o", payload), ("a?b.o", payload)])])

    def test_actual_weak_definitions_receive_member_bound_decision(self):
        payload = self.object("weak", "__attribute__((weak)) int shared(void) { return 0; }")
        members = self.module.inspect_members([self.component(1, "core", [("a.o", payload), ("b.o", payload)])])
        decisions = self.module.classify_repetitions(members)
        self.assertEqual([d["symbol"] for d in decisions], ["_shared"])
        self.assertEqual([d["member"] for d in decisions[0]["definitions"]],
                         ["01-core--0001-a.o", "01-core--0002-b.o"])
        self.assertTrue(all(d["descriptor"] & 0x80 for d in decisions[0]["definitions"]))

    def test_repeated_weak_absolute_symbol_is_unclassified(self):
        # N_ABS is not a coalescible section definition even if WEAK_DEF is set.
        payload = self.object("absolute", "__asm__(\".globl _absolute\\n.set _absolute, 1\\n\");")
        data = bytearray(payload)
        import struct
        command_offset = 32
        for unused in range(struct.unpack_from("<I", data, 16)[0]):
            command, size = struct.unpack_from("<II", data, command_offset)
            if command == 2:
                symoff, count = struct.unpack_from("<II", data, command_offset + 8)
                for i in range(count):
                    offset = symoff + 16 * i
                    if data[offset + 4] == 3:  # N_ABS | N_EXT
                        struct.pack_into("<H", data, offset + 6, 0x80)
            command_offset += size
        members = self.module.inspect_members([self.component(1, "core", [("a.o", bytes(data)), ("b.o", bytes(data))])])
        with self.assertRaisesRegex(ValueError, "unclassified.*_absolute"):
            self.module.classify_repetitions(members)

    def test_wrong_architecture_and_newer_deployment_fail(self):
        for arch, target, message in (("x86_64", "14.0", "arm64"), ("arm64", "15.0", "deployment")):
            with self.subTest(arch=arch, target=target):
                payload = self.object(arch + target, "int policy(void) { return 0; }", target, arch)
                with self.assertRaisesRegex(ValueError, message):
                    self.module.inspect_members([self.component(1, "core", [("policy.o", payload)])])

    def test_fresh_containers_are_equal_sorted_and_independently_verified(self):
        a = self.object("a", "int a(void) { return 1; }")
        b = self.object("b", "int b(void) { return 2; }")
        members = self.module.inspect_members([
            self.component(2, "bzip2", [("b.o", b)]), self.component(1, "core", [("a.o", a)])])
        one, two = self.work / "one.a", self.work / "two.a"
        self.module.build_aggregate(members, one)
        self.module.build_aggregate(members, two)
        self.assertEqual(one.read_bytes(), two.read_bytes())
        from inspect_core_archive import archive_members
        self.assertEqual([n for n, p in archive_members(one)],
                         ["01-core--0001-a.o", "02-bzip2--0001-b.o"])
        report = self.module.verify_aggregate(one, members)
        self.assertEqual(report["member_count"], 2)
        self.assertTrue(report["toc_verified"])
        # A same-shaped valid container containing substituted bytes must fail.
        altered = self.module.inspect_members([self.component(1, "core", [("a.o", b)])])
        self.module.build_aggregate(altered, self.work / "altered.a")
        with self.assertRaisesRegex(ValueError, "member.*identity"):
            self.module.verify_aggregate(self.work / "altered.a", members)

    def test_missing_toc_and_embedded_build_path_fail(self):
        payload = self.object("leak", 'const char *leak = "/opt/homebrew/Cellar/leak";')
        with self.assertRaisesRegex(ValueError, "path"):
            self.module.inspect_members([self.component(1, "core", [("leak.o", payload)])])
        clean = self.object("clean", "int clean(void) { return 1; }")
        members = self.module.inspect_members([self.component(1, "core", [("clean.o", clean)])])
        no_toc = self.archive("no-toc.a", [(members[0].canonical_name, clean)])
        with self.assertRaisesRegex(ValueError, "TOC"):
            self.module.verify_aggregate(no_toc, members)

    def test_common_external_is_inventory_definition_but_not_default_apple_toc_entry(self):
        source, obj = self.work / "common.c", self.work / "common.o"
        source.write_text("int common;\n")
        subprocess.run(["/usr/bin/clang", "-arch", "arm64", "-mmacosx-version-min=14.0",
                        "-fcommon", "-c", str(source), "-o", str(obj)], check=True, capture_output=True)
        members = self.module.inspect_members([self.component(1, "core", [("common.o", obj.read_bytes())])])
        self.assertEqual([(s["symbol"], s["type"], s["value"]) for s in members[0].symbols],
                         [("_common", 1, 4)])
        output = self.work / "common.a"
        self.module.build_aggregate(members, output)
        self.assertEqual(self.module.verify_aggregate(output, members)["defined_symbols"], 1)


if __name__ == "__main__":
    unittest.main()
