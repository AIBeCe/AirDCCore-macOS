#!/usr/bin/env python3
"""Complete package validation and preservation using real Darwin objects."""
from dataclasses import asdict, replace
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / "scripts/lib/distribution_package.py").is_file(),
                        "complete package implementation is missing")
        import distribution_package as package
        import distribution_aggregate as aggregate
        from dependency_acquire import tree_manifest
        from dependency_lock import load_lock
        from dependency_prefix import PrefixReport, _entry_manifest
        from core_stage import version_bytes
        self.package, self.aggregate = package, aggregate
        self.temporary = tempfile.TemporaryDirectory(prefix="airdc-package-test-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name).resolve()
        self.project = self.work / "project"
        self.project.mkdir()
        shutil.copytree(ROOT / "config", self.project / "config")
        shutil.copytree(ROOT / "licenses", self.project / "licenses")
        self.source = self.project / "Dependencies/libmaxminddb"
        self.source.mkdir(parents=True)
        (self.source / "NOTICE").write_text("Copyright MaxMind fixture\n")
        lock_data = json.loads((self.project / "config/dependencies.lock").read_text())
        for record in lock_data["dependencies"]:
            if record["name"] == "libmaxminddb":
                record["source"]["tree_manifest_sha256"] = aggregate.sha(tree_manifest(self.source))
        (self.project / "config/dependencies.lock").write_text(json.dumps(lock_data, sort_keys=True, indent=2) + "\n")
        self.lock = load_lock(self.project / "config/dependencies.lock")
        core = self.project / "Build/airdcpp-core/reproducible-release"
        stage = core / "source"
        policy = json.loads((self.project / "config/core-reproducible-policy.json").read_text())
        core_files = {
            "airdcpp/core/Version.h": b"/* Copyright fixture. GNU General Public License version 3 or later. */\n#pragma once\n#include <string>\nnamespace dcpp { std::string getVersionTag(); std::string getGitCommit(); }\n",
            "airdcpp/stdinc.h": b"/* GNU General Public License version 3 or later. */\n#pragma once\n#include <string>\n",
            "airdcpp/core/version.inc": version_bytes(policy),
            "airdcpp/modules/private.h": b"#include <unavailable-module.h>\n",
            "airdcpp/core/io/compress/ZipFile.h": b"#include <minizip.h>\n",
        }
        core_rows = []
        for relative, content in core_files.items():
            path = stage / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            core_rows.append(dict(path=relative, mode="100644", sha256=aggregate.sha(content)))
        core_rows.sort(key=lambda r: r["path"])
        (core / "staged-source-manifest.json").write_bytes(aggregate.canonical(core_rows))
        reports = {}
        for record in self.lock.dependencies:
            prefix = self.project / "Build/prefix" / record.name
            for relative in (*record.expected_headers, *record.license_paths):
                path = prefix / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("/* " + record.name + " fixture */\n")
            extra = prefix / "include" / record.name / "nested.hpp"
            extra.parent.mkdir(parents=True, exist_ok=True)
            extra.write_text("#pragma once\n")
            manifest = "".join(aggregate.canonical(dict(json.loads(line),
                path="$PREFIX/" + json.loads(line)["path"])).decode()
                for line in _entry_manifest(prefix).decode().splitlines())
            reports[record.name] = PrefixReport(record.name, record.role, manifest,
                                               aggregate.sha(manifest.encode()), ())
        ingredients = self.work / "ingredients"
        ingredients.mkdir()
        components = []
        for ordinal, (slug, owner, relative) in enumerate(aggregate.ORDER, 1):
            cfile, obj, archive = ingredients / (slug + ".c"), ingredients / (slug + ".o"), ingredients / (slug + ".a")
            cfile.write_text("int component_" + str(ordinal) + "(void) { return " + str(ordinal) + "; }\n")
            compiler = "/usr/bin/clang"
            if owner is None:
                cfile = cfile.with_suffix(".cpp")
                cfile.write_text('#include <string>\nnamespace dcpp { std::string getVersionTag() { return "'
                    + policy["version"]["tag"] + '"; } std::string getGitCommit() { return "'
                    + policy["upstream_commit"] + '"; } }\n')
                compiler = "/usr/bin/clang++"
            subprocess.run([compiler, "-arch", "arm64", "-mmacosx-version-min=14.0",
                            "-c", str(cfile), "-o", str(obj)], check=True, capture_output=True)
            subprocess.run(["/usr/bin/libtool", "-static", "-D", "-o", str(archive), str(obj)],
                           check=True, capture_output=True)
            records = {r.name: r for r in self.lock.dependencies}
            provenance = ({"source": {"commit": policy["upstream_commit"]},
                           "source_manifest_sha256": aggregate.sha(aggregate.canonical(core_rows)),
                           "core_input_fingerprint": "a" * 64}
                          if owner is None else {"record": asdict(records[owner]),
                              "install_manifest_sha256": reports[owner].manifest_sha256})
            components.append(aggregate.Component(ordinal, slug, archive,
                              dict(provenance, archive_sha256=aggregate.sha(archive.read_bytes()))))
        # Match real accepted prefixes: archive digests are part of their install manifests.
        for component, (slug, owner, relative) in zip(components, aggregate.ORDER):
            if owner is not None:
                destination = self.project / "Build/prefix" / owner / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(component.archive, destination)
        for record in self.lock.dependencies:
            prefix = self.project / "Build/prefix" / record.name
            manifest = "".join(aggregate.canonical(dict(json.loads(line),
                path="$PREFIX/" + json.loads(line)["path"])).decode()
                for line in _entry_manifest(prefix).decode().splitlines())
            reports[record.name] = PrefixReport(record.name, record.role, manifest,
                                               aggregate.sha(manifest.encode()), ())
        components = [replace(component, provenance=dict(component.provenance,
            install_manifest_sha256=reports[owner].manifest_sha256)) if owner is not None else component
            for component, (slug, owner, relative) in zip(components, aggregate.ORDER)]
        members = aggregate.inspect_members(components)
        archive = self.work / "aggregate.a"
        aggregate.build_aggregate(members, archive)
        proof = aggregate.verify_aggregate(archive, members)
        self.result = dict(archive=archive, components=components, members=members, reports=reports,
            core=dict(staged_root=str(stage), staged_manifest_sha256=aggregate.sha(aggregate.canonical(core_rows)),
                      upstream_commit=policy["upstream_commit"]),
            decisions=aggregate.classify_repetitions(members),
            provenance=dict(schema=1, algorithm="ADR-0001 canonical members; LC_ALL=C; Apple libtool -static -D -filelist",
                components=[dict(ordinal=c.ordinal, component=c.slug, **c.provenance) for c in components],
                container=proof, independent_containers=2,
                tool=dict(name="Apple libtool", sha256="b" * 64, version="Apple Inc. version fixture-1")))
        from dependency_build import ToolInventory
        sdk = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-path"], text=True).strip()
        cxx = subprocess.check_output(["/usr/bin/xcrun", "--find", "clang++"], text=True).strip()
        cxx_identity = dict(sha256=aggregate.sha(Path(cxx).resolve().read_bytes()),
            version=subprocess.check_output([cxx, "--version"], text=True).splitlines()[0])
        tools = ToolInventory(sdk, subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-version"], text=True).strip(),
            {}, {}, {"apple.cxx": cxx_identity})
        self.result["tools"] = tools
        flags = "-O3 -DNDEBUG -std=c++20 -arch arm64 -isysroot $SDK -mmacosx-version-min=14.0"
        build_policy = dict(schema_version=1, upstream_commit=policy["upstream_commit"],
            archive_sha256=components[0].provenance["archive_sha256"], core_input_fingerprint="a" * 64,
            compiler=dict(name="Apple Clang C++", **cxx_identity),
            aggregate_tool=self.result["provenance"]["tool"], sdk_version=tools.sdk_version, compile_flags=flags,
            include_flags="-I$CORE_SOURCE", common_definitions="-DNO_CLIENT_UPDATER", definition_overrides=[],
            rationale="fixture accepted compile policy")
        (self.project / "config/packaging-core-policy.json").write_bytes(aggregate.canonical(build_policy))
        (core / "build.ninja").write_text("build upstream/core.o: CXX_COMPILER__airdcpp_unscanned_Release core.cpp\n"
            + "  FLAGS = " + flags.replace("$SDK", tools.sdkroot) + "\n"
            + "  INCLUDES = -I" + str(stage) + "\n  DEFINES = -DNO_CLIENT_UPDATER\n\n")
        self.candidate = self.project / ".package-fixture"
        self.candidate.mkdir()

    def stage(self):
        self.package.stage_candidate(self.project, self.candidate, self.result)
        return self.candidate

    def resign(self, package):
        # Deliberate adversarial rewrite proves verifier checks more than hashes.
        rows = []
        for path in sorted(package.rglob("*"), key=lambda p: p.relative_to(package).as_posix().encode()):
            if path.is_file() and path.relative_to(package).as_posix() != "metadata/checksums.sha256":
                rows.append(self.aggregate.sha(path.read_bytes()) + "  " + path.relative_to(package).as_posix())
        (package / "metadata/checksums.sha256").write_text("\n".join(rows) + "\n")

    def test_complete_candidate_is_relocatable_and_preserves_enabled_headers(self):
        self.stage()
        self.assertTrue((self.candidate / "metadata/consumer-proof.json").is_file(),
                        "public package lacks measured relocated consumer proof")
        self.assertTrue((self.candidate / "include/airdcpp/core/Version.h").is_file())
        self.assertTrue((self.candidate / "include/airdcpp/core/version.inc").is_file())
        self.assertTrue((self.candidate / "include/boost/nested.hpp").is_file())
        self.assertFalse((self.candidate / "include/airdcpp/modules").exists())
        self.assertFalse((self.candidate / "include/airdcpp/core/io/compress/ZipFile.h").exists())
        relocated = self.work / "relocated"
        self.candidate.rename(relocated)
        shutil.rmtree(self.project / "Build")
        shutil.rmtree(self.project / "Dependencies")
        verified = self.package.verify_package(relocated, self.project)
        self.assertEqual(verified["member_count"], 9)
        self.assertEqual([p.name for p in (relocated / "lib").iterdir()], ["libairdcpp.a"])

    def test_schema_two_package_pins_public_identity_after_relocation(self):
        from public_core_identity import public_core_fingerprint
        core = Path(self.result["core"]["staged_root"]).parent
        authority = dict(schema=1, staged_root=str(core / "source"),
            generator_sha256="c" * 64, upstream_commit=self.result["core"]["upstream_commit"])
        authority_digest = self.aggregate.sha(self.aggregate.canonical(authority))
        inputs = dict(schema=1, version_authority_sha256=authority_digest,
            implementation=[dict(path="core_stage.py", sha256="d" * 64)])
        raw_digest = self.aggregate.sha(self.aggregate.canonical(inputs))
        (core / "version-authority.json").write_bytes(self.aggregate.canonical(authority))
        (core / "core-inputs.json").write_bytes(self.aggregate.canonical(inputs))
        (core / "core-input-fingerprint.txt").write_text(raw_digest + "\n")
        self.result["core"].update(version_authority_sha256=authority_digest, core_input_fingerprint=raw_digest)
        public_digest = public_core_fingerprint(core, self.result["core"])
        self.assertNotEqual(raw_digest, public_digest)
        self.result["provenance"]["components"][0]["core_input_fingerprint"] = public_digest
        policy_path = self.project / "config/packaging-core-policy.json"
        policy = json.loads(policy_path.read_bytes())
        policy["schema_version"] = 2
        policy["core_input_fingerprint"] = public_digest
        policy_path.write_bytes(self.aggregate.canonical(policy))
        try:
            self.stage()
        except ValueError as error:
            self.fail("schema-two publication must succeed: " + str(error))
        manifest = json.loads((self.candidate / "metadata/manifest.json").read_bytes())
        self.assertEqual(manifest["schema_version"], 2)
        self.assertEqual(manifest["components"][0]["core_input_fingerprint"], policy["core_input_fingerprint"])
        self.assertNotEqual(manifest["components"][0]["core_input_fingerprint"], raw_digest)
        relocated = self.work / "schema-two-relocated"
        self.candidate.rename(relocated)
        shutil.rmtree(self.project / "Build")
        shutil.rmtree(self.project / "Dependencies")
        self.assertEqual(self.package.verify_package(relocated, self.project)["member_count"], 9)
        for field in ("core_input_fingerprint", "archive_sha256"):
            with self.subTest(field=field):
                changed = json.loads(json.dumps(manifest))
                changed["components"][0][field] = "0" * 64
                provenance_path = relocated / "metadata/aggregate-provenance.json"
                provenance = json.loads(provenance_path.read_bytes())
                provenance["components"] = changed["components"]
                provenance_path.write_bytes(self.aggregate.canonical(provenance))
                (relocated / "metadata/manifest.json").write_bytes(self.aggregate.canonical(changed))
                self.resign(relocated)
                with self.assertRaisesRegex(ValueError, "Core.*identity"):
                    self.package.verify_package(relocated, self.project)

    def test_legacy_schema_one_cannot_use_schema_two_authority(self):
        self.stage()
        path = self.project / "config/packaging-core-policy.json"
        policy = json.loads(path.read_bytes())
        policy["schema_version"] = 2
        path.write_bytes(self.aggregate.canonical(policy))
        with self.assertRaisesRegex(ValueError, "schema"):
            self.package.verify_package(self.candidate, self.project)

    def test_header_source_drift_rejects_copy(self):
        (self.project / "Build/prefix/zlib/include/zlib.h").write_text("drift\n")
        with self.assertRaisesRegex(ValueError, "header.*digest"):
            self.stage()

    def test_build_only_boost_header_manifest_digest_is_bound(self):
        from dataclasses import replace
        report = self.result["reports"]["boost"]
        self.result["reports"]["boost"] = replace(report, manifest_sha256="0" * 64)
        with self.assertRaisesRegex(ValueError, "prefix.*manifest.*digest"):
            self.stage()

    def test_non_utf8_header_body_preserves_original_notice(self):
        core = self.project / "Build/airdcpp-core/reproducible-release"
        header = core / "source/airdcpp/core/Version.h"
        header.write_bytes(header.read_bytes() + b"/* original non-UTF8 quote: \x91 */\n")
        rows = json.loads((core / "staged-source-manifest.json").read_bytes())
        for row in rows:
            if row["path"] == "airdcpp/core/Version.h":
                row["sha256"] = self.aggregate.sha(header.read_bytes())
        raw = self.aggregate.canonical(rows)
        (core / "staged-source-manifest.json").write_bytes(raw)
        digest = self.aggregate.sha(raw)
        self.result["core"]["staged_manifest_sha256"] = digest
        self.result["provenance"]["components"][0]["source_manifest_sha256"] = digest
        self.stage()
        self.assertEqual((self.candidate / "include/airdcpp/core/Version.h").read_bytes(), header.read_bytes())
        notices = json.loads((self.candidate / "licenses/core/header-notices.json").read_bytes())
        self.assertEqual(notices[0]["notice"], "/* Copyright fixture. GNU General Public License version 3 or later. */")

    def test_missing_original_notice_blocks_candidate(self):
        (self.project / "Build/prefix/boost/LICENSE_1_0.txt").unlink()
        with self.assertRaises((OSError, ValueError)):
            self.stage()

    def test_maxmind_notice_must_match_locked_source_tree(self):
        (self.source / "NOTICE").write_text("drift\n")
        with self.assertRaisesRegex(ValueError, "source.*manifest"):
            self.stage()

    def test_missing_header_or_notice_is_rejected_even_with_rewritten_checksums(self):
        self.stage()
        for relative in ("include/airdcpp/core/Version.h", "licenses/boost/LICENSE_1_0.txt"):
            path = self.candidate / relative
            content = path.read_bytes()
            path.unlink()
            self.resign(self.candidate)
            with self.subTest(relative=relative), self.assertRaises(ValueError):
                self.package.verify_package(self.candidate, self.project)
            path.write_bytes(content)
        self.resign(self.candidate)
        self.package.verify_package(self.candidate, self.project)

    def test_corruption_and_undeclared_files_are_rejected(self):
        self.stage()
        header = self.candidate / "include/zlib.h"
        content = header.read_bytes()
        header.write_bytes(content + b"drift")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.package.verify_package(self.candidate, self.project)
        header.write_bytes(content)
        (self.candidate / "extra.txt").write_text("unexpected\n")
        self.resign(self.candidate)
        with self.assertRaisesRegex(ValueError, "inventory"):
            self.package.verify_package(self.candidate, self.project)

    def test_changed_pin_and_link_boundary_fail_even_with_rewritten_checksums(self):
        self.stage()
        manifest = self.candidate / "metadata/manifest.json"
        saved = manifest.read_bytes()
        data = json.loads(saved)
        data["dependencies"][0]["version"] = "unapproved"
        manifest.write_bytes(self.aggregate.canonical(data))
        self.resign(self.candidate)
        with self.assertRaisesRegex(ValueError, "lock|pin"):
            self.package.verify_package(self.candidate, self.project)
        manifest.write_bytes(saved)
        interface = self.candidate / "metadata/link-interface.json"
        data = json.loads(interface.read_bytes())
        data["frameworks"] = ["Foundation"]
        interface.write_bytes(self.aggregate.canonical(data))
        self.resign(self.candidate)
        with self.assertRaisesRegex(ValueError, "link.*boundary"):
            self.package.verify_package(self.candidate, self.project)

    def test_actual_archive_is_inspected_despite_self_consistent_metadata(self):
        self.stage()
        archive = self.candidate / "lib/libairdcpp.a"
        data = bytearray(archive.read_bytes())
        # Corrupt the Mach-O CPU field of one member, then update declared hashes.
        magic = data.index(b"\xcf\xfa\xed\xfe")
        data[magic + 4:magic + 8] = b"\x07\x00\x00\x01"
        archive.write_bytes(data)
        manifest = self.candidate / "metadata/manifest.json"
        metadata = json.loads(manifest.read_bytes())
        metadata["aggregate_sha256"] = self.aggregate.sha(data)
        manifest.write_bytes(self.aggregate.canonical(metadata))
        from inspect_core_archive import archive_members
        changed_name, changed_payload = next(archive_members(archive))
        mapping_path = self.candidate / "metadata/member-map.json"
        mapping = json.loads(mapping_path.read_bytes())
        for row in mapping:
            if row["canonical_name"] == changed_name:
                row["sha256"] = self.aggregate.sha(changed_payload)
        mapping_path.write_bytes(self.aggregate.canonical(mapping))
        provenance_path = self.candidate / "metadata/aggregate-provenance.json"
        provenance = json.loads(provenance_path.read_bytes())
        provenance["container"]["archive_sha256"] = self.aggregate.sha(data)
        provenance_path.write_bytes(self.aggregate.canonical(provenance))
        self.resign(self.candidate)
        with self.assertRaisesRegex(ValueError, "arm64"):
            self.package.verify_package(self.candidate, self.project)

    def test_metadata_cannot_publish_private_paths(self):
        self.stage()
        manifest = self.candidate / "metadata/manifest.json"
        data = json.loads(manifest.read_bytes())
        data["private_path"] = "/Users/builder/Build/core"
        manifest.write_bytes(self.aggregate.canonical(data))
        self.resign(self.candidate)
        with self.assertRaisesRegex(ValueError, "path|schema"):
            self.package.verify_package(self.candidate, self.project)

    def test_successful_publish_and_failed_candidate_preserve_accepted_distribution(self):
        self.stage()
        target = self.project / "Dist"
        self.package.publish_candidate(self.candidate, target, self.project)
        before = {str(p.relative_to(target)): p.read_bytes() for p in target.rglob("*") if p.is_file()}
        bad = self.project / ".package-bad"
        shutil.copytree(target, bad)
        (bad / "include/zlib.h").unlink()
        with self.assertRaises(ValueError):
            self.package.publish_candidate(bad, target, self.project)
        after = {str(p.relative_to(target)): p.read_bytes() for p in target.rglob("*") if p.is_file()}
        self.assertEqual(after, before)

    def test_unsafe_output_and_symlink_target_are_rejected(self):
        self.stage()
        sentinel = self.project / "sentinel"
        sentinel.mkdir()
        (sentinel / "safe.txt").write_text("untouched\n")
        with self.assertRaisesRegex(ValueError, "target"):
            self.package.publish_candidate(self.candidate, sentinel, self.project)
        (self.project / "Dist").symlink_to(sentinel)
        with self.assertRaises((OSError, ValueError, RuntimeError)):
            self.package.publish_candidate(self.candidate, self.project / "Dist", self.project)
        self.assertEqual((sentinel / "safe.txt").read_text(), "untouched\n")

    def test_post_publication_validation_exception_rolls_back(self):
        from unittest.mock import patch
        self.stage()
        target = self.project / "Dist"
        self.package.publish_candidate(self.candidate, target, self.project)
        old = (target / "metadata/aggregate-provenance.json").read_bytes()
        old_inode = target.stat().st_ino
        candidate = self.project / ".package-next"
        shutil.copytree(target, candidate)
        original = self.package.verify_package
        def validation_failure(path, authority):
            if path == target:
                raise TypeError("simulated validation failure after atomic swap")
            return original(path, authority)
        # This fault is injected at the real transaction's finalization boundary;
        # assertions inspect actual target bytes after real macOS rename/swap.
        with patch("distribution_package.verify_package", side_effect=validation_failure):
            with self.assertRaises((TypeError, RuntimeError)):
                self.package.publish_candidate(candidate, target, self.project)
        self.assertEqual((target / "metadata/aggregate-provenance.json").read_bytes(), old)
        self.assertEqual(target.stat().st_ino, old_inode)

    def test_rerun_publishes_identical_file_content(self):
        self.stage()
        before = {str(p.relative_to(self.candidate)): p.read_bytes() for p in self.candidate.rglob("*") if p.is_file()}
        second = self.project / ".package-second"
        second.mkdir()
        self.package.stage_candidate(self.project, second, self.result)
        self.assertEqual({str(p.relative_to(second)): p.read_bytes() for p in second.rglob("*") if p.is_file()}, before)
        self.package.publish_candidate(self.candidate, self.project / "Dist", self.project)
        self.package.publish_candidate(second, self.project / "Dist", self.project)
        self.assertEqual({str(p.relative_to(self.project / "Dist")): p.read_bytes() for p in (self.project / "Dist").rglob("*") if p.is_file()}, before)

    def test_missing_construction_authority_and_changed_ingredient_digest_fail(self):
        self.stage()
        provenance_path = self.candidate / "metadata/aggregate-provenance.json"
        manifest_path = self.candidate / "metadata/manifest.json"
        saved_provenance, saved_manifest = provenance_path.read_bytes(), manifest_path.read_bytes()
        for field in ("schema", "algorithm", "tool"):
            data = json.loads(saved_provenance)
            del data[field]
            provenance_path.write_bytes(self.aggregate.canonical(data))
            self.resign(self.candidate)
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "provenance"):
                self.package.verify_package(self.candidate, self.project)
        provenance = json.loads(saved_provenance)
        manifest = json.loads(saved_manifest)
        provenance["components"][1]["archive_sha256"] = "0" * 64
        manifest["components"][1]["archive_sha256"] = "0" * 64
        provenance_path.write_bytes(self.aggregate.canonical(provenance))
        manifest_path.write_bytes(self.aggregate.canonical(manifest))
        self.resign(self.candidate)
        with self.assertRaisesRegex(ValueError, "ingredient.*digest"):
            self.package.verify_package(self.candidate, self.project)

    def test_core_url_and_declared_compile_flags_are_required_and_bound(self):
        self.stage()
        manifest_path = self.candidate / "metadata/manifest.json"
        saved = manifest_path.read_bytes()
        data = json.loads(saved)
        self.assertEqual(data["core"].get("source_url"), "https://github.com/airdcpp/airdcpp-core.git")
        self.assertEqual(data["core"].get("build_policy", {}).get("compile_flags"),
                         "-O3 -DNDEBUG -std=c++20 -arch arm64 -isysroot $SDK -mmacosx-version-min=14.0")
        for field in ("source_url", "build_policy"):
            changed = json.loads(saved)
            del changed["core"][field]
            manifest_path.write_bytes(self.aggregate.canonical(changed))
            self.resign(self.candidate)
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "Core.*policy|Core.*source"):
                self.package.verify_package(self.candidate, self.project)
        changed = json.loads(saved)
        changed["core"]["build_policy"]["compile_flags"] = "-O0"
        manifest_path.write_bytes(self.aggregate.canonical(changed))
        self.resign(self.candidate)
        with self.assertRaisesRegex(ValueError, "Core.*policy"):
            self.package.verify_package(self.candidate, self.project)

    def test_public_consumer_binding_and_fresh_measurement_reject_rehashed_drift(self):
        self.stage()
        proof_path = self.candidate / "metadata/consumer-proof.json"
        saved = proof_path.read_bytes()
        for field, value in (("result", "pending"), ("force_loaded_members", 0)):
            proof = json.loads(saved)
            proof[field] = value
            proof_path.write_bytes(self.aggregate.canonical(proof))
            self.resign(self.candidate)
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "consumer"):
                self.package.verify_package(self.candidate, self.project)
        proof = json.loads(saved)
        proof["final_system_imports"] = ["_invented_system_import"]
        proof_path.write_bytes(self.aggregate.canonical(proof))
        self.resign(self.candidate)
        with self.assertRaisesRegex(ValueError, "fresh.*consumer"):
            self.package.verify_package(self.candidate, self.project, fresh_consumer=True)

    def test_observed_ninja_compile_flags_must_match_bound_policy(self):
        ninja = self.project / "Build/airdcpp-core/reproducible-release/build.ninja"
        ninja.write_text(ninja.read_text().replace("-O3", "-O0"))
        with self.assertRaisesRegex(ValueError, "Core.*compile.*policy"):
            self.stage()


if __name__ == "__main__":
    unittest.main()
