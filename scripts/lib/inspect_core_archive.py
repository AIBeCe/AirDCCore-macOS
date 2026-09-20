#!/usr/bin/env python3
"""Verify every object in a Darwin ar archive is a thin arm64 Mach-O object."""

import hashlib
import os
import subprocess
import sys
import tempfile
from pathlib import Path


AR_MAGIC = b"!<arch>\n"
AR_HEADER_SIZE = 60
SYMBOL_TABLE_NAMES = {"__.SYMDEF", "__.SYMDEF SORTED", "__.SYMDEF_64", "__.SYMDEF_64 SORTED", "/", "/SYM64/", "//"}


def archive_members(archive: Path):
    content = archive.read_bytes()
    if not content.startswith(AR_MAGIC):
        raise ValueError("missing ar archive magic")

    offset = len(AR_MAGIC)
    while offset < len(content):
        if len(content) - offset < AR_HEADER_SIZE:
            raise ValueError(f"truncated ar header at offset {offset}")
        header = content[offset:offset + AR_HEADER_SIZE]
        if header[58:60] != b"`\n":
            raise ValueError(f"invalid ar header trailer at offset {offset}")
        try:
            size_text = header[48:58].decode("ascii").strip()
            if not size_text.isdecimal():
                raise ValueError("non-decimal ar member length")
            size = int(size_text)
            name_field = header[:16].decode("ascii").strip()
        except UnicodeDecodeError as error:
            raise ValueError(f"non-ASCII ar header at offset {offset}") from error
        offset += AR_HEADER_SIZE
        if offset + size > len(content):
            raise ValueError(f"truncated ar member at offset {offset}")
        payload = content[offset:offset + size]
        offset += size
        if size % 2:
            if offset >= len(content) or content[offset:offset + 1] != b"\n":
                raise ValueError(f"missing ar member padding at offset {offset}")
            offset += 1

        if name_field.startswith("#1/"):
            length_text = name_field[3:]
            if not length_text.isdecimal() or int(length_text) > len(payload):
                raise ValueError("invalid BSD extended ar member name")
            name_length = int(length_text)
            try:
                name = payload[:name_length].rstrip(b"\0").decode("utf-8")
            except UnicodeDecodeError as error:
                raise ValueError("non-UTF-8 ar member name") from error
            payload = payload[name_length:]
        else:
            name = name_field
            if name.endswith("/") and name not in SYMBOL_TABLE_NAMES:
                name = name[:-1]

        if not name or "\t" in name or "\n" in name:
            raise ValueError("empty or report-unsafe ar member name")
        if name not in SYMBOL_TABLE_NAMES:
            yield name, payload


def run_tool(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"{' '.join(args[:2])} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout


def validate_report_path(path: Path, archive: Path):
    if path == archive or path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"unsafe report path: {path}")
    if not path.parent.is_dir():
        raise ValueError(f"report parent is not a directory: {path.parent}")
    for parent in (path.parent, *path.parent.parents):
        if parent.is_symlink():
            raise ValueError(f"symlinked report parent: {parent}")


def publish_report(path: Path, data: str):
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(data)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def inspect(archive: Path, members_report: Path, symbols_report: Path):
    if not archive.is_file() or archive.is_symlink():
        raise ValueError(f"archive is not a regular file: {archive}")
    if members_report == symbols_report:
        raise ValueError("member and symbol report paths must differ")
    validate_report_path(members_report, archive)
    validate_report_path(symbols_report, archive)

    rows = []
    with tempfile.TemporaryDirectory(prefix="airdc-core-members-") as directory:
        for ordinal, (name, payload) in enumerate(archive_members(archive), start=1):
            member_path = Path(directory) / f"member-{ordinal:06d}.o"
            member_path.write_bytes(payload)
            kind = run_tool(["/usr/bin/file", "-b", str(member_path)]).strip()
            architectures = run_tool(["/usr/bin/lipo", "-archs", str(member_path)]).strip()
            if "Mach-O 64-bit object" not in kind or architectures != "arm64":
                raise ValueError(f"member {ordinal} ({name}) is not arm64 Mach-O: {kind}; {architectures}")
            rows.append(f"{ordinal}\t{name}\t{hashlib.sha256(payload).hexdigest()}\tarm64\n")

    if not rows:
        raise ValueError("archive has zero object members")
    symbols = run_tool(["xcrun", "nm", "-g", str(archive)])
    validate_report_path(members_report, archive)
    validate_report_path(symbols_report, archive)
    publish_report(members_report, "".join(rows))
    publish_report(symbols_report, symbols)


def main():
    if len(sys.argv) != 4:
        print("usage: inspect_core_archive.py ARCHIVE MEMBERS_TSV SYMBOLS_TXT", file=sys.stderr)
        return 64
    try:
        inspect(*(Path(argument) for argument in sys.argv[1:]))
    except (OSError, ValueError) as error:
        print(f"archive-inspect: error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
