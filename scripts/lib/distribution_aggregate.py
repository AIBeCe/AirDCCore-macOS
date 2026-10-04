#!/usr/bin/env python3
"""Read accepted Phase 6 inputs and construct the ADR 0001 archive container.

This module never rebuilds ingredients or changes their accepted evidence.
Public member/decision documents contain relative identities, not host paths.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import tempfile

from core_stage import validate_core_source
from dependency_build import (ToolInventory, _accepted_evidence_matches,
                              _input_document, _pinned_tools, adapter_path)
from dependency_lock import canonical_bytes, load_lock, topological_records
from dependency_prefix import validate_prefix
from inspect_core_archive import archive_members, SYMBOL_TABLE_NAMES

ORDER = (
    ("core", None, "upstream/libairdcpp.a"),
    ("bzip2", "bzip2", "lib/libbz2.a"),
    ("zlib", "zlib", "lib/libz.a"),
    ("openssl-ssl", "openssl", "lib/libssl.a"),
    ("openssl-crypto", "openssl", "lib/libcrypto.a"),
    ("miniupnpc", "miniupnpc", "lib/libminiupnpc.a"),
    ("leveldb", "leveldb", "lib/libleveldb.a"),
    ("maxminddb", "libmaxminddb", "lib/libmaxminddb.a"),
    ("snappy", "snappy", "lib/libsnappy.a"),
)
FORBIDDEN = (b"/opt/homebrew", b"/usr/local/Cellar", b"/Users/",
             b"/Source/", b"/Build/", b"/Dependencies/")


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def regular(path):
    path = Path(path)
    for parent in path.parents:
        if parent.is_symlink():
            raise ValueError(f"unsafe symlinked input parent: {parent}")
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f"input is not a regular file: {path}")
    return path.read_bytes()


def document(path):
    from dependency_lock import reject_duplicate_pairs
    return json.loads(regular(path), object_pairs_hook=reject_duplicate_pairs)


@dataclass(frozen=True)
class Component:
    ordinal: int
    slug: str
    archive: Path
    provenance: dict


@dataclass(frozen=True)
class Member:
    component: str
    component_ordinal: int
    ordinal: int
    original_name: str
    canonical_name: str
    sha256: str
    payload: bytes
    symbols: tuple[dict, ...]
    undefined: tuple[str, ...]
    deployment: tuple[str, ...]

    def mapping(self):
        return {key: value for key, value in asdict(self).items()
                if key not in ("payload", "symbols", "undefined", "deployment")}


def validate_input_binding(evidence, expected):
    raw = canonical(expected)
    if regular(evidence / "inputs.json") != raw or regular(evidence / "input-fingerprint.txt") != (sha(raw) + "\n").encode():
        raise ValueError("accepted input fingerprint or input document differs")


def validate_inputs(project):
    """Return ordered archives, read-only reports, Core provenance and tools."""
    project = Path(project).absolute()
    core = project / "Build/airdcpp-core/reproducible-release"
    lock = load_lock(project / "config/dependencies.lock")
    if {r.name for r in lock.dependencies} != {"bzip2", "zlib", "openssl", "miniupnpc", "leveldb", "libmaxminddb", "snappy", "boost"}:
        raise ValueError("packaging requires exactly the eight Phase 6 dependencies")
    tools = ToolInventory(**document(core / "tool-inventory.json"))
    apple = _pinned_tools(tools.apple, tools.identities, "apple")
    _pinned_tools(tools.host, tools.identities, "host")
    if regular(core / "lock-fingerprint.txt") != (sha(canonical_bytes(lock)) + "\n").encode():
        raise ValueError("Core lock fingerprint differs")
    python = document(core / "core-python.json")
    executable = Path(python["invocation_path"]).resolve(strict=True)
    if str(executable) != python["resolved_path"] or sha(regular(executable)) != python["sha256"]:
        raise ValueError("Core Python identity differs")
    reports = {}
    for record in topological_records(lock):
        if record.platform.architecture != "arm64" or record.platform.deployment_target != "14.0" or record.platform.linkage != "static":
            raise ValueError(f"{record.name}: packaging platform policy differs")
        build = project / "Build/dependencies" / record.name
        evidence, prefix = build / "evidence", project / "Build/prefix" / record.name
        expected = _input_document(lock, record, adapter_path(project, record),
                                   {n: reports[n] for n in record.dependencies}, tools)
        validate_input_binding(evidence, expected)
        report = validate_prefix(record, prefix, dict(project=project,
            source=project / "Dependencies" / record.name, build=build, home=build / "home"), tools=apple)
        if not _accepted_evidence_matches(record, prefix, evidence, report):
            raise ValueError(f"{record.name}: accepted archive/header/license evidence differs")
        reports[record.name] = report
    provenance = validate_core_source(project, project / "Source/airdcpp-core", core,
                                      tools, python["invocation_path"])
    for name in ("exit-code.txt", "build-exit-code.txt", "scope-status.txt"):
        if regular(core / name) != b"0\n":
            raise ValueError(f"Core accepted status differs: {name}")
    archive = core / "upstream/libairdcpp.a"
    if regular(core / "archive-sha256.txt") != (sha(regular(archive)) + "  upstream/libairdcpp.a\n").encode():
        raise ValueError("Core archive checksum differs")
    members = list(archive_members(archive))
    inventory = "".join(f"{i}\t{name}\t{sha(data)}\tarm64\n" for i, (name, data) in enumerate(members, 1))
    if regular(core / "archive-members.tsv") != inventory.encode():
        raise ValueError("Core accepted member inventory differs")
    records = {r.name: r for r in lock.dependencies}
    components = []
    for ordinal, (slug, owner, relative) in enumerate(ORDER, 1):
        path = core / relative if owner is None else project / "Build/prefix" / owner / relative
        metadata = ({"source": {"commit": provenance["upstream_commit"]},
                     "source_manifest_sha256": provenance["staged_manifest_sha256"],
                     "core_input_fingerprint": provenance["core_input_fingerprint"]}
                    if owner is None else {"record": asdict(records[owner]),
                        "install_manifest_sha256": reports[owner].manifest_sha256})
        components.append(Component(ordinal, slug, path, dict(metadata, archive_sha256=sha(regular(path)))))
    return components, reports, provenance, tools


def macho(payload, label):
    """Parse actual nlist_64 type/descriptor and defining section flags."""
    def unpack(fmt, offset):
        size = struct.calcsize(fmt)
        if offset < 0 or offset + size > len(payload):
            raise ValueError(f"truncated Mach-O: {label}")
        return struct.unpack_from(fmt, payload, offset)

    magic, cpu, subtype, kind, count, command_bytes, flags, reserved = unpack("<8I", 0)
    if magic != 0xFEEDFACF or cpu != 0x0100000C or subtype & 0xFFFFFF != 0 or kind != 1:
        raise ValueError(f"member is not a thin arm64 Mach-O object: {label}")
    if 32 + command_bytes > len(payload):
        raise ValueError(f"invalid Mach-O load commands: {label}")
    offset, sections, versions, symtab = 32, [], [], None
    for unused in range(count):
        command, size = unpack("<II", offset)
        if size < 8 or offset + size > 32 + command_bytes:
            raise ValueError(f"invalid Mach-O load command: {label}")
        if command == 0x19:  # LC_SEGMENT_64
            nsects = unpack("<I", offset + 64)[0]
            if size != 72 + nsects * 80:
                raise ValueError(f"invalid Mach-O sections: {label}")
            for i in range(nsects):
                section = offset + 72 + i * 80
                name, segment = unpack("<16s16s", section)
                section_flags = unpack("<I", section + 64)[0]
                sections.append({"section": name.rstrip(b"\0").decode("ascii"),
                                 "segment": segment.rstrip(b"\0").decode("ascii"),
                                 "section_flags": section_flags})
        elif command == 2:
            if symtab is not None or size != 24:
                raise ValueError(f"invalid Mach-O symbol table: {label}")
            symtab = unpack("<4I", offset + 8)
        elif command in (0x32, 0x24):
            if command == 0x32:
                platform, version = unpack("<II", offset + 8)
                if platform != 1:
                    raise ValueError(f"wrong Mach-O deployment platform: {label}")
            else:
                version = unpack("<I", offset + 8)[0]
            if version > 14 << 16:
                raise ValueError(f"deployment newer than macOS 14.0: {label}")
            versions.append(f"{version >> 16}.{version >> 8 & 255}.{version & 255}")
        elif command in (0x25, 0x2F, 0x30):
            raise ValueError(f"wrong Mach-O deployment platform: {label}")
        offset += size
    if offset != 32 + command_bytes or symtab is None or not versions:
        raise ValueError(f"missing Mach-O symbol/deployment evidence: {label}")
    symoff, nsyms, stroff, strsize = symtab
    if symoff + nsyms * 16 > len(payload) or stroff + strsize > len(payload):
        raise ValueError(f"invalid Mach-O symbol extent: {label}")
    strings = payload[stroff:stroff + strsize]
    defined, undefined = [], []
    for i in range(nsyms):
        index, typ, section, descriptor, value = unpack("<IBBHQ", symoff + i * 16)
        if typ & 0xE0 or not typ & 1:  # debug or non-external
            continue
        if index >= len(strings) or b"\0" not in strings[index:]:
            raise ValueError(f"invalid Mach-O symbol string: {label}")
        symbol = strings[index:strings.index(b"\0", index)].decode("utf-8")
        kind = typ & 0xE
        if kind == 0 and value == 0:
            undefined.append(symbol)
            continue
        if kind not in (0, 2, 0xE):
            raise ValueError(f"unknown Mach-O external definition kind: {label}:{symbol}")
        row = dict(symbol=symbol, type=typ, descriptor=descriptor, value=value,
                   classification="weak" if descriptor & 0x80 else "strong")
        if kind == 0xE:
            if not 1 <= section <= len(sections):
                raise ValueError(f"invalid Mach-O defining section: {label}:{symbol}")
            row.update(sections[section - 1])
        defined.append(row)
    return tuple(defined), tuple(sorted(undefined)), tuple(versions)


def inspect_members(components):
    members, names, component_ids = [], set(), set()
    for component in components:
        if (not 1 <= component.ordinal <= 99 or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", component.slug)
                or component.ordinal in component_ids):
            raise ValueError("invalid or duplicate component namespace")
        component_ids.add(component.ordinal)
        count = 0
        for ordinal, (name, payload) in enumerate(archive_members(component.archive), 1):
            count += 1
            if ordinal > 9999:
                raise ValueError("member ordinal exceeds canonical namespace")
            suffix = re.sub(r"[^A-Za-z0-9_.-]", "_", name)
            canonical_name = f"{component.ordinal:02d}-{component.slug}--{ordinal:04d}-{suffix}"
            if canonical_name in names:
                raise ValueError("canonical member normalization collision")
            names.add(canonical_name)
            if any(pattern in payload for pattern in FORBIDDEN):
                raise ValueError(f"forbidden embedded path in {canonical_name}")
            symbols, undefined, deployment = macho(payload, canonical_name)
            members.append(Member(component.slug, component.ordinal, ordinal, name,
                canonical_name, sha(payload), payload, symbols, undefined, deployment))
        if not count:
            raise ValueError(f"empty component archive: {component.slug}")
    if not members:
        raise ValueError("aggregate has no members")
    return sorted(members, key=lambda member: member.canonical_name.encode("ascii"))


def classify_repetitions(members):
    definitions = {}
    for member in members:
        for symbol in member.symbols:
            definitions.setdefault(symbol["symbol"], []).append(dict(symbol,
                member=member.canonical_name, member_sha256=member.sha256))
    decisions = []
    for symbol, rows in sorted(definitions.items()):
        if len(rows) < 2:
            continue
        if sum(row["classification"] == "strong" for row in rows) > 1:
            raise ValueError(f"duplicate strong external definition: {symbol}")
        # N_WEAK_DEF + N_SECT is the object-file Apple weak-definition contract.
        # Absolute/common/indirect definitions do not qualify by name or order.
        weak = [row for row in rows if row["classification"] == "weak"]
        if not weak or any((row["type"] & 0xE) != 0xE or (row.get("section_flags", -1) & 255) not in (0, 1, 0xB)
                           for row in weak):
            raise ValueError(f"unclassified repeated external definition: {symbol}")
        decisions.append(dict(symbol=symbol, definitions=rows,
            reason="Mach-O N_WEAK_DEF section definitions coalesce under Apple ld; a strong section definition, if present, prevails",
            verification="pending relocated aggregate force-load consumer"))
    return decisions


def _tool(argv):
    result = subprocess.run([str(a) for a in argv], capture_output=True, text=True,
                            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C", "ZERO_AR_DATE": "1"})
    if result.returncode:
        raise ValueError(f"aggregate tool failed: {argv[0]}: {result.stderr.strip()}")
    return result.stdout


def build_aggregate(members, output):
    classify_repetitions(members)
    output = Path(output)
    if output.exists() or output.is_symlink() or not output.parent.is_dir():
        raise ValueError("aggregate output must be a fresh private file")
    for parent in (output.parent, *output.parent.parents):
        if parent.is_symlink():
            raise ValueError("unsafe aggregate output parent")
    with tempfile.TemporaryDirectory(prefix="aggregate-objects-", dir=output.parent) as temporary:
        directory = Path(temporary)
        rows = []
        for member in sorted(members, key=lambda item: item.canonical_name.encode("ascii")):
            path = directory / member.canonical_name
            if path.exists() or sha(member.payload) != member.sha256:
                raise ValueError("duplicate or changed member identity")
            path.write_bytes(member.payload)
            rows.append(str(path))
        filelist = directory / "filelist.txt"
        filelist.write_text("\n".join(rows) + "\n")
        _tool(["/usr/bin/libtool", "-static", "-D", "-filelist", filelist, "-o", output])


def _toc(archive, members):
    """Check BSD ranlib entries point to actual defining object headers."""
    data, offset, tables, objects = regular(archive), 8, [], {}
    while offset < len(data):
        start = offset
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:] != b"`\n":
            raise ValueError("invalid aggregate TOC archive header")
        size, name = int(header[48:58]), header[:16].decode().strip()
        body = data[offset + 60:offset + 60 + size]
        if len(body) != size:
            raise ValueError("truncated aggregate TOC member")
        if name.startswith("#1/"):
            length = int(name[3:])
            name, body = body[:length].rstrip(b"\0").decode(), body[length:]
        elif name.endswith("/"):
            name = name[:-1]
        if name in SYMBOL_TABLE_NAMES:
            tables.append((name, body))
        else:
            objects[start] = name
        offset += 60 + size + size % 2
    if len(tables) != 1 or tables[0][0] not in ("__.SYMDEF", "__.SYMDEF SORTED"):
        raise ValueError("missing or unsupported aggregate TOC")
    body = tables[0][1]
    if len(body) < 8:
        raise ValueError("truncated aggregate TOC")
    length = struct.unpack_from("<I", body)[0]
    if length % 8 or 8 + length > len(body):
        raise ValueError("invalid aggregate TOC entry extent")
    strings_length = struct.unpack_from("<I", body, 4 + length)[0]
    strings = body[8 + length:8 + length + strings_length]
    if len(strings) != strings_length:
        raise ValueError("invalid aggregate TOC strings")
    # Apple libtool indexes N_SECT/N_ABS by default. N_UNDF common storage
    # remains in the object/symbol inventory; indexing it would require -c,
    # which is outside ADR 0001's selected command.
    expected = {(s["symbol"], m.canonical_name) for m in members for s in m.symbols
                if (s["type"] & 0xE) in (2, 0xE)}
    actual = set()
    for position in range(4, 4 + length, 8):
        index, object_offset = struct.unpack_from("<II", body, position)
        if index >= len(strings) or b"\0" not in strings[index:] or object_offset not in objects:
            raise ValueError("invalid aggregate TOC reference")
        actual.add((strings[index:strings.index(b"\0", index)].decode(), objects[object_offset]))
    if actual != expected:
        raise ValueError("aggregate TOC does not match external definitions")


def verify_aggregate(archive, members):
    expected = sorted(members, key=lambda member: member.canonical_name.encode("ascii"))
    actual = list(archive_members(Path(archive)))
    if [(name, sha(payload)) for name, payload in actual] != [(m.canonical_name, m.sha256) for m in expected]:
        raise ValueError("aggregate member count/order/payload identity differs")
    # Reparse bytes from the constructed container, independently of the inputs.
    for (name, payload), member in zip(actual, expected):
        if macho(payload, name) != (member.symbols, member.undefined, member.deployment):
            raise ValueError("aggregate member symbol/deployment identity differs")
        if any(pattern in payload for pattern in FORBIDDEN):
            raise ValueError("aggregate contains forbidden path")
    _toc(archive, expected)
    table = [line for line in _tool(["/usr/bin/ar", "-t", archive]).splitlines()
             if line not in SYMBOL_TABLE_NAMES]
    if table != [m.canonical_name for m in expected]:
        raise ValueError("Apple archive table disagrees with member identity")
    return dict(archive_sha256=sha(regular(archive)), member_count=len(actual),
                architecture="arm64", deployment_target="14.0", toc_verified=True,
                defined_symbols=len({s["symbol"] for m in expected for s in m.symbols}),
                undefined_symbols=sorted({s for m in expected for s in m.undefined}))


def construct_aggregates(project, output):
    """Construct two fresh private archives and write deterministic Task 2 inputs."""
    output = Path(output)
    if not output.is_dir() or output.is_symlink() or any(output.iterdir()):
        raise ValueError("private aggregate directory must be empty")
    components, reports, core, tools = validate_inputs(project)
    members = inspect_members(components)
    decisions = classify_repetitions(members)
    proofs = []
    for name in ("aggregate-one.a", "aggregate-two.a"):
        archive = output / name
        build_aggregate(members, archive)
        proofs.append(verify_aggregate(archive, members))
    if proofs[0] != proofs[1]:
        raise ValueError("fresh aggregate containers differ")
    libtool = Path("/usr/bin/libtool").resolve(strict=True)
    metadata = dict(schema=1, algorithm="ADR-0001 canonical members; LC_ALL=C; Apple libtool -static -D -filelist",
        components=[dict(ordinal=c.ordinal, component=c.slug, **c.provenance) for c in components],
        container=proofs[0], independent_containers=2,
        tool=dict(name="Apple libtool", sha256=sha(regular(libtool)),
                  version=_tool(["/usr/bin/libtool", "-V"]).strip()))
    for name, value in (("aggregate-provenance.json", metadata),
                        ("member-map.json", [m.mapping() for m in members]),
                        ("coalescing-decisions.json", decisions)):
        (output / name).write_bytes(canonical(value))
    return dict(archive=output / "aggregate-one.a", components=components, members=members,
                reports=reports, core=core, tools=tools, provenance=metadata, decisions=decisions)
