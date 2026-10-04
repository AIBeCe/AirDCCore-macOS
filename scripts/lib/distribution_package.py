#!/usr/bin/env python3
"""Complete relocatable distribution staging and read-only package validation."""
from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import asdict
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tempfile

from core_stage import bound_directory, version_bytes
from dependency_acquire import OwnedDirectory, _identity, _remove_at, tree_manifest
from dependency_build import BuildError, publish_prefix
from dependency_lock import canonical_bytes, load_lock
from dependency_prefix import tree_digest
from distribution_aggregate import (ORDER, Member, canonical, classify_repetitions,
    construct_aggregates, document, macho, regular, sha, verify_aggregate)
from inspect_core_archive import archive_members
from distribution_consumer import prove_consumer, validate_consumer_proof

PLATFORM = dict(architecture="arm64", deployment_target="14.0", build_type="Release",
    cxx_standard=20, cxx_runtime="libc++", linkage="static", enable_natpmp=False, enable_tbb=False)
LINK_INTERFACE = dict(schema_version=1, archive="lib/libairdcpp.a", include_directory="include",
    cxx_standard=20, explicit_system_libraries=["Iconv"],
    implicit_system_libraries=["libc++", "libSystem"], frameworks=[],
    consumer_verification="PASS: relocated force-loaded consumer",
    consumer_proof="metadata/consumer-proof.json")
HEADER_POLICY = dict(core="enabled macOS airdcpp_hdrs plus generated version.inc",
    excluded=["airdcpp/modules/**", "airdcpp/core/io/compress/ZipFile.h"],
    reason="pinned upstream CMakeLists.txt excludes modules and ZipFile on non-Windows",
    external="complete accepted include trees; platform alternatives remain conditional")
MANIFEST_FIELDS = {"schema_version", "platform", "lock_sha256", "dependencies", "core",
    "components", "aggregate_sha256", "header_policy", "headers", "licenses", "files", "prefix_manifest_sha256"}
METADATA_PATHS = {
    "metadata/manifest.json", "metadata/link-interface.json", "metadata/checksums.sha256",
    "metadata/aggregate-provenance.json", "metadata/member-map.json", "metadata/coalescing-decisions.json",
    "metadata/core-source-manifest.json", "metadata/prefix-manifests.json",
    "metadata/maxminddb-source-manifest.json",
    "metadata/consumer-proof.json",
}
AGGREGATE_ALGORITHM = "ADR-0001 canonical members; LC_ALL=C; Apple libtool -static -D -filelist"
PROVENANCE_FIELDS = {"schema", "algorithm", "components", "container", "independent_containers", "tool"}


def _digest_field(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def _upstream_source(authority):
    values = {}
    for line in regular(authority / "config/upstream.env").decode().splitlines():
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or key not in ("AIRDCPP_CORE_URL", "AIRDCPP_CORE_COMMIT") or key in values:
            raise ValueError("Core source authority differs")
        values[key] = value
    if set(values) != {"AIRDCPP_CORE_URL", "AIRDCPP_CORE_COMMIT"}:
        raise ValueError("Core source authority incomplete")
    return dict(url=values["AIRDCPP_CORE_URL"], commit=values["AIRDCPP_CORE_COMMIT"])


def _observed_core_flags(project, result):
    """Compact observed object flags; the tracked policy supplies authority.

    The accepted successful log is not verbose. Ninja is therefore checked
    metadata, bound to archive/input/compiler identities, not an independent
    immutable transcript of every compiler invocation.
    """
    core = Path(result["core"]["staged_root"]).parent
    tools = result["tools"]
    rows = re.findall(r"^build (upstream/[^\n:]+\.o): CXX_COMPILER[^\n]*\n(.*?)(?=\n\n)",
                      regular(core / "build.ninja").decode(), re.MULTILINE | re.DOTALL)
    def normalized(text):
        for sysroot in re.findall(r"-isysroot\s+(\S+)", text):
            if Path(sysroot).resolve() != Path(tools.sdkroot).resolve():
                raise ValueError("Core compile policy SDK differs")
            text = text.replace(sysroot, "$SDK")
        text = text.replace(str(core / "source"), "$CORE_SOURCE").replace(str(core), "$CORE_BUILD")
        for name in result["reports"]:
            text = text.replace(str(project / "Build/prefix" / name), "$PREFIX/" + name)
        return text
    objects, flags, includes, definitions = [], set(), set(), []
    for path, body in rows:
        fields = {}
        for name in ("FLAGS", "INCLUDES", "DEFINES"):
            match = re.search(r"^  " + name + r" = (.*)$", body, re.MULTILINE)
            if match is None:
                raise ValueError("Core compile policy evidence incomplete")
            fields[name] = normalized(match.group(1))
        member = PurePosixPath(path).name
        objects.append(member)
        flags.add(fields["FLAGS"])
        includes.add(fields["INCLUDES"])
        definitions.append((member, fields["DEFINES"]))
    expected = [member.original_name for member in result["members"] if member.component == "core"]
    if sorted(objects) != sorted(expected) or len(flags) != 1 or len(includes) != 1:
        raise ValueError("Core compile policy object/flag inventory differs")
    common = Counter(value for name, value in definitions).most_common(1)[0][0]
    return dict(compile_flags=next(iter(flags)), include_flags=next(iter(includes)), common_definitions=common,
        definition_overrides=[dict(member=name, definitions=value) for name, value in sorted(definitions) if value != common])


def _core_build_policy(project, result=None):
    policy = document(project / "config/packaging-core-policy.json")
    if (policy.get("schema_version") != 1 or not _digest_field(policy.get("archive_sha256"))
            or not _digest_field(policy.get("core_input_fingerprint"))):
        raise ValueError("Core build policy identity differs")
    if result is not None:
        core_component = result["provenance"]["components"][0]
        tools = result["tools"]
        compiler = tools.identities["apple.cxx"]
        identity = dict(name="Apple Clang C++", sha256=compiler["sha256"], version=compiler["version"].splitlines()[0])
        if (policy["archive_sha256"] != core_component["archive_sha256"]
                or policy["core_input_fingerprint"] != core_component["core_input_fingerprint"]
                or policy["upstream_commit"] != result["core"]["upstream_commit"]
                or policy["compiler"] != identity or policy["sdk_version"] != tools.sdk_version
                or policy["aggregate_tool"] != result["provenance"]["tool"]):
            raise ValueError("Core build policy accepted identity differs")
        observed = _observed_core_flags(project, result)
        if any(policy[name] != value for name, value in observed.items()):
            raise ValueError("Core observed compile flags/definitions differ from bound policy")
    return policy


def relative(value):
    if (not isinstance(value, str) or not value or "\\" in value or any(c in value for c in "\0\t\n\r")
            or PurePosixPath(value).is_absolute() or any(p in ("", ".", "..") for p in value.split("/"))):
        raise ValueError("unsafe package relative path")
    return value


def files_in(root):
    root = Path(root).absolute()
    with bound_directory(root):
        files = {}
        for path in root.rglob("*"):
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode):
                continue
            if not stat.S_ISREG(mode) or mode & 0o111:
                raise ValueError("package contains symlink, executable, or unsupported file")
            name = relative(path.relative_to(root).as_posix())
            files[name] = path
        return dict(sorted(files.items(), key=lambda item: item[0].encode()))


def put(root, relative_path, content):
    path = root / relative(relative_path)
    if path.exists() or path.is_symlink():
        raise ValueError(f"duplicate staged file: {relative_path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    path.chmod(0o644)


def _copy(root, relative_path, source, expected, label):
    data = regular(source)
    if sha(data) != expected:
        raise ValueError(f"{label} digest differs: {relative_path}")
    put(root, relative_path, data)


def core_headers(rows):
    return [row for row in rows if row["path"].startswith("airdcpp/")
        and (row["path"].endswith(".h") or row["path"] == "airdcpp/core/version.inc")
        and not row["path"].startswith("airdcpp/modules/")
        and row["path"] != "airdcpp/core/io/compress/ZipFile.h"]


def _prefix_rows(reports):
    for report in reports.values():
        if sha(report.manifest.encode()) != report.manifest_sha256:
            raise ValueError("accepted prefix manifest digest differs")
    return {name: [json.loads(line) for line in report.manifest.splitlines()]
            for name, report in sorted(reports.items())}


def _headers(core_rows, prefix_rows):
    headers = [dict(path="include/" + row["path"], component="core",
                    source_path=row["path"], sha256=row["sha256"]) for row in core_headers(core_rows)]
    for name, rows in prefix_rows.items():
        for row in rows:
            source = row["path"].removeprefix("$PREFIX/")
            if source.startswith("include/") and row["type"] == "file":
                headers.append(dict(path=source, component=name, source_path=source, sha256=row["sha256"]))
            elif source.startswith("include/") and row["type"] not in ("file", "directory"):
                raise ValueError("unsupported public header link")
    headers.sort(key=lambda row: row["path"].encode())
    if len({row["path"] for row in headers}) != len(headers):
        raise ValueError("public header namespace collision")
    return headers


def _core_notices(root, headers):
    notices = []
    for row in headers:
        if row["component"] != "core" or not row["path"].endswith(".h"):
            continue
        raw = regular(root / row["path"])
        match = re.match(rb"\s*(/\*.*?\*/)", raw, re.DOTALL)
        if match and b"GNU General Public License" in match.group(1):
            notices.append(dict(path=row["path"], notice=match.group(1).decode("utf-8")))
    if not notices:
        raise ValueError("missing original Core GPL header notices")
    return canonical(notices)


def _licenses(records, prefix_rows, maxmind_rows, authority):
    rows = []
    for record in records:
        inventory = {row["path"].removeprefix("$PREFIX/"): row for row in prefix_rows[record.name]}
        for source in record.license_paths:
            row = inventory.get(source)
            if row is None or row["type"] != "file":
                raise ValueError(f"missing license manifest: {record.name}/{source}")
            rows.append(dict(path=f"licenses/{record.name}/{source}", component=record.name,
                source_path=source, sha256=row["sha256"], spdx=record.license_spdx))
    notice = next((row for row in maxmind_rows if row["path"] == "NOTICE" and row["type"] == "file"), None)
    if notice is None:
        raise ValueError("missing original MaxMindDB NOTICE")
    rows.append(dict(path="licenses/libmaxminddb/NOTICE", component="libmaxminddb",
                     source_path="NOTICE", sha256=notice["sha256"], spdx="Apache-2.0"))
    licenses = document(authority / "licenses/sources.json")
    source = next(row for row in licenses["licenses"] if row["path"] == "GPL-3.0.txt")
    rows.append(dict(path="licenses/core/GPL-3.0.txt", component="core", source_path="GPL-3.0.txt",
                     sha256=source["sha256"], spdx="GPL-3.0-or-later", url=source["url"]))
    return sorted(rows, key=lambda row: row["path"].encode())


def stage_candidate(project, candidate, result):
    """Copy authenticated public material into a fresh, unpublished directory."""
    project, candidate = Path(project), Path(candidate)
    with bound_directory(candidate):
        if any(candidate.iterdir()):
            raise ValueError("package candidate must be empty")
        lock = load_lock(project / "config/dependencies.lock")
        policy = document(project / "config/core-reproducible-policy.json")
        core_source = _upstream_source(project)
        build_policy = _core_build_policy(project, result)
        if core_source["commit"] != policy["upstream_commit"]:
            raise ValueError("Core source pin policy differs")
        core = result["core"]
        core_rows = document(Path(core["staged_root"]).parent / "staged-source-manifest.json")
        if sha(canonical(core_rows)) != core["staged_manifest_sha256"]:
            raise ValueError("Core source manifest digest differs")
        prefix_rows = _prefix_rows(result["reports"])
        headers = _headers(core_rows, prefix_rows)
        for row in headers:
            source = (Path(core["staged_root"]) / row["source_path"] if row["component"] == "core"
                      else project / "Build/prefix" / row["component"] / row["source_path"])
            _copy(candidate, row["path"], source, row["sha256"], "header")
        maxmind_source = project / "Dependencies/libmaxminddb"
        raw = tree_manifest(maxmind_source)
        record = next(r for r in lock.dependencies if r.name == "libmaxminddb")
        if sha(raw) != record.source.tree_manifest_sha256:
            raise ValueError("MaxMindDB source tree manifest differs")
        maxmind_rows = [json.loads(line) for line in raw.decode().splitlines()]
        licenses = _licenses(lock.dependencies, prefix_rows, maxmind_rows, project)
        for row in licenses:
            if row["component"] == "core":
                source = project / "licenses" / row["source_path"]
            elif row["path"] == "licenses/libmaxminddb/NOTICE":
                source = maxmind_source / "NOTICE"
            else:
                source = project / "Build/prefix" / row["component"] / row["source_path"]
            _copy(candidate, row["path"], source, row["sha256"], "license")
        notices = _core_notices(candidate, headers)
        notice_row = dict(path="licenses/core/header-notices.json", component="core",
                         source_path="public Core header notices", sha256=sha(notices), spdx="GPL-3.0-or-later")
        licenses.append(notice_row)
        licenses.sort(key=lambda row: row["path"].encode())
        put(candidate, notice_row["path"], notices)
        archive_bytes = regular(result["archive"])
        put(candidate, "lib/libairdcpp.a", archive_bytes)
        consumer_identity = dict(commit=core["upstream_commit"], tag=policy["version"]["tag"])
        consumer_proof = prove_consumer(candidate, headers, consumer_identity,
            forbidden_roots=[project / name for name in ("Source", "Dependencies", "Build")])
        provenance = json.loads(canonical(result["provenance"]))
        provenance["components"][0]["source"] = core_source
        provenance["components"][0]["build_policy"] = build_policy
        # This is member-reference inventory, not a solved aggregate boundary.
        provenance["container"]["member_undefined_references"] = provenance["container"].pop("undefined_symbols")
        metadata = {
            "metadata/link-interface.json": LINK_INTERFACE,
            "metadata/aggregate-provenance.json": provenance,
            "metadata/member-map.json": [m.mapping() for m in result["members"]],
            "metadata/coalescing-decisions.json": result["decisions"],
            "metadata/core-source-manifest.json": core_rows,
            "metadata/prefix-manifests.json": prefix_rows,
            "metadata/maxminddb-source-manifest.json": maxmind_rows,
            "metadata/consumer-proof.json": consumer_proof,
        }
        for path, value in metadata.items():
            put(candidate, path, canonical(value))
        manifest = dict(schema_version=1, platform=PLATFORM,
            lock_sha256=sha(canonical_bytes(lock)), dependencies=[asdict(r) for r in lock.dependencies],
            prefix_manifest_sha256={name: report.manifest_sha256 for name, report in sorted(result["reports"].items())},
            core=dict(upstream_commit=core["upstream_commit"], source_manifest_sha256=core["staged_manifest_sha256"],
                      source_url=core_source["url"], build_policy=build_policy,
                      version=policy["version"], source_date_epoch=policy["source_date_epoch"], patch=policy["patch"]),
            components=provenance["components"], aggregate_sha256=sha(archive_bytes),
            header_policy=HEADER_POLICY, headers=headers, licenses=licenses,
            files=sorted([*files_in(candidate), "metadata/manifest.json", "metadata/checksums.sha256"]))
        put(candidate, "metadata/manifest.json", canonical(manifest))
        checksums = "".join(sha(regular(path)) + "  " + name + "\n" for name, path in files_in(candidate).items())
        put(candidate, "metadata/checksums.sha256", checksums.encode())
        return verify_package(candidate, project)


def _safe_metadata(value):
    if isinstance(value, str):
        if any(marker in value for marker in ("/Users/", "/opt/homebrew", "/usr/local/Cellar", "/Source/", "/Build/", "/Dependencies/")):
            raise ValueError("private path in public metadata")
    elif isinstance(value, dict):
        for child in value.values():
            _safe_metadata(child)
    elif isinstance(value, list):
        for child in value:
            _safe_metadata(child)


def _package_members(archive, mapping):
    actual = list(archive_members(archive))
    if len(actual) != len(mapping):
        raise ValueError("aggregate member inventory count differs")
    members, ordinals, suffixes = [], {slug: [] for slug, owner, relative in ORDER}, {}
    for (name, payload), row in zip(actual, mapping):
        ordinal, component = row["component_ordinal"], row["component"]
        if not 1 <= ordinal <= len(ORDER) or component != ORDER[ordinal - 1][0]:
            raise ValueError("aggregate component mapping differs")
        suffix = re.sub(r"[^A-Za-z0-9_.-]", "_", row["original_name"])
        canonical_name = f"{ordinal:02d}-{component}--{row['ordinal']:04d}-{suffix}"
        key = (component, suffix)
        if key in suffixes and suffixes[key] != row["original_name"]:
            raise ValueError("member normalization collision")
        suffixes[key] = row["original_name"]
        if name != row["canonical_name"] or name != canonical_name or sha(payload) != row["sha256"]:
            raise ValueError("aggregate member identity differs")
        symbols, undefined, deployment = macho(payload, name)
        members.append(Member(component, ordinal, row["ordinal"], row["original_name"], name,
                              row["sha256"], payload, symbols, undefined, deployment))
        ordinals[component].append(row["ordinal"])
    for values in ordinals.values():
        if not values or values != list(range(1, len(values) + 1)):
            raise ValueError("component ordinal inventory incomplete")
    return members


def verify_package(package, authority_project, *, fresh_consumer=False, consumer_evidence=None):
    """Read existing Dist; authority reads are limited to tracked config/licenses.

    Checksums are integrity checks, not a signature or a substitute for pin,
    target, archive and header/license contract validation.
    """
    package, authority = Path(package).absolute(), Path(authority_project).absolute()
    files = files_in(package)
    raw_checksums = regular(package / "metadata/checksums.sha256").decode()
    expected = "".join(sha(regular(path)) + "  " + name + "\n" for name, path in files.items()
                       if name != "metadata/checksums.sha256")
    if raw_checksums != expected:
        raise ValueError("package checksum inventory differs")
    metadata = {}
    for name in METADATA_PATHS - {"metadata/checksums.sha256"}:
        value = document(package / name)
        if regular(package / name) != canonical(value):
            raise ValueError("noncanonical public metadata")
        _safe_metadata(value)
        metadata[name] = value
    manifest = metadata["metadata/manifest.json"]
    if set(manifest) != MANIFEST_FIELDS or manifest["schema_version"] != 1:
        raise ValueError("package manifest schema differs")
    if manifest["files"] != list(files):
        raise ValueError("package file inventory differs")
    if manifest["platform"] != PLATFORM or manifest["header_policy"] != HEADER_POLICY:
        raise ValueError("package platform/header policy differs")
    lock = load_lock(authority / "config/dependencies.lock")
    policy = document(authority / "config/core-reproducible-policy.json")
    source, build_policy = _upstream_source(authority), _core_build_policy(authority)
    if manifest["lock_sha256"] != sha(canonical_bytes(lock)) or canonical(manifest["dependencies"]) != canonical([asdict(r) for r in lock.dependencies]):
        raise ValueError("package immutable lock pins differ")
    expected_core = dict(upstream_commit=policy["upstream_commit"], source_url=source["url"], build_policy=build_policy,
        source_manifest_sha256=manifest["core"]["source_manifest_sha256"], version=policy["version"],
        source_date_epoch=policy["source_date_epoch"], patch=policy["patch"])
    if manifest["core"] != expected_core or source["commit"] != policy["upstream_commit"] or build_policy["upstream_commit"] != policy["upstream_commit"]:
        raise ValueError("package Core pin/version/patch policy differs")
    if metadata["metadata/link-interface.json"] != LINK_INTERFACE:
        raise ValueError("package system link boundary differs")
    core_rows, prefix_rows, maxmind_rows = (metadata[p] for p in (
        "metadata/core-source-manifest.json", "metadata/prefix-manifests.json", "metadata/maxminddb-source-manifest.json"))
    if sha(canonical(core_rows)) != manifest["core"]["source_manifest_sha256"]:
        raise ValueError("Core source manifest digest differs")
    if set(prefix_rows) != {r.name for r in lock.dependencies}:
        raise ValueError("public prefix manifest inventory differs")
    if manifest["prefix_manifest_sha256"] != {name: sha(b"".join(canonical(row) for row in rows))
                                               for name, rows in prefix_rows.items()}:
        raise ValueError("public prefix manifest digest differs")
    for record in lock.dependencies:
        inventory = {row["path"].removeprefix("$PREFIX/"): row for row in prefix_rows[record.name]}
        if any(path not in inventory or inventory[path]["type"] != "file" for path in (*record.expected_headers, *record.license_paths)):
            raise ValueError("required public header/license inventory incomplete")
    maxmind = next(r for r in lock.dependencies if r.name == "libmaxminddb")
    # Acquisition serializes source entries with ensure_ascii=False.
    raw_source = b"".join((json.dumps(row, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
                          for row in maxmind_rows)
    if sha(raw_source) != maxmind.source.tree_manifest_sha256:
        raise ValueError("MaxMindDB source manifest authority differs")
    headers = _headers(core_rows, prefix_rows)
    if manifest["headers"] != headers:
        raise ValueError("public header provenance inventory differs")
    if regular(package / "include/airdcpp/core/version.inc") != version_bytes(policy):
        raise ValueError("deterministic generated Core version differs")
    licenses = _licenses(lock.dependencies, prefix_rows, maxmind_rows, authority)
    notices = _core_notices(package, headers)
    licenses.append(dict(path="licenses/core/header-notices.json", component="core",
                         source_path="public Core header notices", sha256=sha(notices), spdx="GPL-3.0-or-later"))
    licenses.sort(key=lambda row: row["path"].encode())
    if manifest["licenses"] != licenses or regular(package / "licenses/core/header-notices.json") != notices:
        raise ValueError("public license inventory differs")
    payload_paths = {"lib/libairdcpp.a", *METADATA_PATHS, *(r["path"] for r in headers), *(r["path"] for r in licenses)}
    if set(files) != payload_paths:
        raise ValueError("package contains undeclared file inventory")
    for row in (*headers, *licenses):
        if sha(regular(package / relative(row["path"]))) != row["sha256"]:
            raise ValueError("published header/license provenance digest differs")
    mapping = metadata["metadata/member-map.json"]
    archive = package / "lib/libairdcpp.a"
    members = _package_members(archive, mapping)
    proof = verify_aggregate(archive, members)
    proof["member_undefined_references"] = proof.pop("undefined_symbols")
    provenance = metadata["metadata/aggregate-provenance.json"]
    if (set(provenance) != PROVENANCE_FIELDS or provenance["schema"] != 1
            or provenance["algorithm"] != AGGREGATE_ALGORITHM):
        raise ValueError("aggregate provenance schema/algorithm differs")
    tool = provenance["tool"]
    if (not isinstance(tool, dict) or set(tool) != {"name", "sha256", "version"}
            or tool["name"] != "Apple libtool" or not _digest_field(tool["sha256"])
            or not isinstance(tool["version"], str)
            or not re.fullmatch(r"Apple Inc\. version [A-Za-z0-9_.-]+", tool["version"])):
        raise ValueError("aggregate provenance tool identity differs")
    if provenance["container"] != proof or manifest["aggregate_sha256"] != proof["archive_sha256"]:
        raise ValueError("aggregate physical verification differs from provenance")
    if provenance["independent_containers"] != 2 or manifest["components"] != provenance["components"]:
        raise ValueError("aggregate construction/component inventory differs")
    records = {r.name: r for r in lock.dependencies}
    if len(manifest["components"]) != len(ORDER):
        raise ValueError("aggregate component count differs")
    for ordinal, ((slug, owner, ingredient), component) in enumerate(zip(ORDER, manifest["components"]), 1):
        if component["ordinal"] != ordinal or component["component"] != slug:
            raise ValueError("aggregate component order differs")
        if owner is None:
            if not _digest_field(component.get("archive_sha256")) or not _digest_field(component.get("core_input_fingerprint")):
                raise ValueError("aggregate Core provenance digest/fingerprint differs")
            if (component["source"] != source or component["source_manifest_sha256"] != manifest["core"]["source_manifest_sha256"]
                    or component.get("build_policy") != build_policy or component["archive_sha256"] != build_policy["archive_sha256"]
                    or component["core_input_fingerprint"] != build_policy["core_input_fingerprint"]
                    or provenance["tool"] != build_policy["aggregate_tool"]):
                raise ValueError("aggregate Core source identity differs")
        else:
            archive_row = next((row for row in prefix_rows[owner]
                                if row["path"] == "$PREFIX/" + ingredient and row["type"] == "file"), None)
            if archive_row is None or not _digest_field(component.get("archive_sha256")) or component["archive_sha256"] != archive_row["sha256"]:
                raise ValueError("aggregate ingredient archive digest differs")
            raw_prefix = b"".join(canonical(row) for row in prefix_rows[owner])
            if canonical(component["record"]) != canonical(asdict(records[owner])) or component["install_manifest_sha256"] != sha(raw_prefix):
                raise ValueError("aggregate dependency pin/install identity differs")
    if metadata["metadata/coalescing-decisions.json"] != classify_repetitions(members):
        raise ValueError("aggregate symbol coalescing decisions differ")
    consumer_identity = dict(commit=policy["upstream_commit"], tag=policy["version"]["tag"])
    consumer = metadata["metadata/consumer-proof.json"]
    validate_consumer_proof(package, headers, consumer_identity, consumer)
    if consumer["compiler"] != build_policy["compiler"] or consumer["sdk_version"] != build_policy["sdk_version"]:
        raise ValueError("consumer proof accepted tool policy differs")
    if fresh_consumer:
        measured = prove_consumer(package, headers, consumer_identity, evidence=consumer_evidence,
            forbidden_roots=[authority / name for name in ("Source", "Dependencies", "Build")])
        if measured != consumer:
            raise ValueError("fresh relocated consumer differs from public proof")
    return dict(member_count=len(members), file_count=len(files), archive_sha256=proof["archive_sha256"],
                consumer_verification=LINK_INTERFACE["consumer_verification"])


def publish_candidate(candidate, target, project):
    project, candidate, target = (Path(p).absolute() for p in (project, candidate, target))
    if target != project / "Dist" or candidate.parent != project or not candidate.name.startswith(".package-"):
        raise ValueError("unsafe distribution publication target/candidate")
    with bound_directory(project):
        if target.is_symlink() or (target.exists() and not target.is_dir()):
            raise ValueError("unsafe existing distribution target")
        verify_package(candidate, project)
        def finalize():
            try:
                verify_package(target, project)
            except Exception as error:
                # The transaction recognizes BuildError. Adapt any validation
                # exception so publication always rolls back a failed candidate.
                raise BuildError("published distribution validation failed") from error
        publish_prefix(candidate, target, project, expected_stage=_identity(candidate),
                       expected_digest=tree_digest(candidate), finalize=finalize)


def package(project):
    project = Path(project).absolute()
    with bound_directory(project):
        target = project / "Dist"
        if target.is_symlink() or (target.exists() and not target.is_dir()):
            raise ValueError("unsafe distribution output target")
        candidate = Path(tempfile.mkdtemp(prefix=".package-", dir=project))
        identity = _identity(candidate)
        try:
            with tempfile.TemporaryDirectory(prefix="airdc-package-", dir="/private/tmp") as work:
                result = construct_aggregates(project, Path(work))
                stage_candidate(project, candidate, result)
                publish_candidate(candidate, target, project)
            return verify_package(target, project)
        finally:
            if _identity(candidate) == identity:
                with OwnedDirectory(project) as owner:
                    _remove_at(owner.fd, candidate.name, expected_identity=identity)


def main(project, argv=None):
    parser = argparse.ArgumentParser(description="Construct Dist or verify an existing relocated distribution.")
    parser.add_argument("--verify", metavar="DIST", help="read-only verification; reads tracked config/license policy only")
    args = parser.parse_args(argv)
    try:
        report = verify_package(Path(args.verify).absolute(), project, fresh_consumer=True) if args.verify else package(project)
        print("package: PASS " + json.dumps(report, sort_keys=True))
        return 0
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        print(f"package: error: {error}", file=sys.stderr)
        return 1
