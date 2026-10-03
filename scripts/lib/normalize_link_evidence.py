#!/usr/bin/env python3
"""Normalize one verbose Apple Clang link command into ordered link evidence."""

from __future__ import annotations

import argparse
import os
import re
import shlex
import sys
import tempfile
from pathlib import Path


OMISSION_HEADER = "pass\tordinal\tlogical\tclassification\tbuild_exit"


def adr_expected_rows(adr: str, sdk_iconv_relative: str) -> list[tuple[str, str]]:
    """Read the accepted inventories; do not derive policy from observed linkage."""
    def inventory(heading: str) -> list[str]:
        parts = adr.split('### '+heading+'\n')
        if len(parts) != 2:
            fail('link contract differs from ADR 0001: missing or duplicate inventory')
        section = parts[1].split('\n##', 1)[0]
        return [line[2:] for line in section.splitlines() if line.startswith('- ')]

    components = {
        'AirDC++ Core': ('core', 'stage/lib/libairdcpp.a'),
        'BZip2': ('component:bzip2', 'lib/libbz2.a'),
        'zlib': ('component:zlib', 'lib/libz.a'),
        'OpenSSL SSL': ('component:openssl', 'lib/libssl.a'),
        'OpenSSL Crypto': ('component:openssl', 'lib/libcrypto.a'),
        'miniupnpc': ('component:miniupnpc', 'lib/libminiupnpc.a'),
        'LevelDB': ('component:leveldb', 'lib/libleveldb.a'),
        'MaxMindDB': ('component:libmaxminddb', 'lib/libmaxminddb.a'),
        'Snappy': ('component:snappy', 'lib/libsnappy.a'),
    }
    declared = inventory('Aggregate component inventory')
    if len(declared) != len(set(declared)) or set(declared) != set(components):
        fail('link contract differs from ADR 0001: unreviewed aggregate inventory')
    if inventory('External Apple system-link inventory') != [
        'explicit SDK link input: Iconv from the selected macOS SDK',
        'implicit toolchain load command: libc++ from the selected macOS toolchain/SDK',
        'implicit toolchain load command: libSystem from the selected macOS SDK',
        'measured Apple framework requirement: none',
    ]:
        fail('link contract differs from ADR 0001: unreviewed system inventory')
    return [components[label] for label in declared] + [('apple-sdk', sdk_iconv_relative)]


def assert_adr_closure(rows: list[tuple[str, str]], adr: str, sdk_iconv_relative: str) -> None:
    if rows != adr_expected_rows(adr, sdk_iconv_relative):
        fail('link contract differs from ADR 0001')


def classify_runtime_defaults(strings: str, defaults: dict[str, str]) -> tuple[list[str], list[str]]:
    """Bound the approved OpenSSL runtime directory defaults without permitting provenance."""
    observed = sorted(set(re.findall(r'/usr/local/[^\s"\x00]+', strings)))
    rejected = [path for path in observed if '..' in Path(path).parts or not any(
        path == base or (key == 'OPENSSLDIR' and path.startswith(base+'/'))
        for key, base in defaults.items())]
    return observed, rejected


def fail(message: str) -> None:
    raise ValueError(message)


def validate_omissions(path: Path) -> None:
    if not path.is_file() or path.is_symlink():
        fail(f"omission evidence is not a regular file: {path}")
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != OMISSION_HEADER:
        fail("omission evidence has an invalid header")
    expected: dict[int, int] = {1: 1, 2: 1}
    seen: set[tuple[int, str]] = set()
    for line_number, line in enumerate(lines[1:], start=2):
        fields = line.split("\t")
        if len(fields) != 5:
            fail(f"omission row {line_number} must have five tab-separated fields")
        pass_text, ordinal_text, logical, classification, status_text = fields
        try:
            pass_number = int(pass_text)
            ordinal = int(ordinal_text)
            status = int(status_text)
        except ValueError as error:
            fail(f"omission row {line_number} has a non-integer field")
            raise AssertionError from error
        if pass_number not in (1, 2):
            fail(f"omission row {line_number} has an unsupported pass")
        if ordinal != expected[pass_number]:
            fail(f"omission pass {pass_number} is not sequential")
        expected[pass_number] += 1
        if not logical or (pass_number, logical) in seen:
            fail(f"omission row {line_number} has an empty or duplicate logical name")
        seen.add((pass_number, logical))
        if classification not in ("required", "transitive"):
            fail(f"omission row {line_number} has an invalid classification")
        if classification == "required" and status == 0:
            fail(f"omission row {line_number} marks a successful link as required")
        if classification == "transitive" and status != 0:
            fail(f"omission row {line_number} marks a failed link as transitive")


def normalize_path(value: str, project_root: Path) -> str:
    root = str(project_root)
    if value == root:
        return "$PROJECT_ROOT"
    if value.startswith(root + os.sep):
        return "$PROJECT_ROOT/" + value[len(root) + 1 :]
    return value


def classify_library(value: str, project_root: Path, prefixes: dict[str, Path] | None = None) -> tuple[str, str]:
    if Path(value).name == "libairdcpp.a" and "/stage/lib/" in value:
        if prefixes is not None:
            expected = project_root / 'Build/airdcpp-core/reproducible-link-interface/stage/lib/libairdcpp.a'
            if Path(value) != expected or not expected.is_file() or expected.is_symlink():
                fail(f'unclassified link input: {value}')
        return "core", "stage/lib/libairdcpp.a"
    if prefixes is not None:
        path = Path(value)
        if not path.is_absolute():
            fail(f'unclassified link input: {value}')
        try:
            real = path.resolve(strict=True)
        except OSError:
            fail(f'unclassified link input: {value}')
        for name, prefix in prefixes.items():
            if real.is_relative_to(prefix):
                return ('apple-sdk' if name == 'apple-sdk' else 'component:'+name,
                        real.relative_to(prefix).as_posix())
        fail(f'unclassified link input: {value}')
    return "library", normalize_path(value, project_root)


def parse_link_command(command: str, project_root: Path,
                       prefixes: dict[str, Path] | None = None) -> list[tuple[str, str]]:
    try:
        arguments = shlex.split(command, posix=True)
    except ValueError as error:
        fail(f"malformed link command: {error}")
    if not arguments:
        fail("link command is empty")

    rows: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()

    def append(kind: str, value: str) -> None:
        row = (kind, value)
        if row not in seen:
            seen.add(row)
            rows.append(row)

    def bundled_linker_options(argument: str) -> None:
        # Apple Clang forwards every comma-separated member to ld. Strict
        # evidence must inspect the complete bundle, not its first option.
        options = argument[4:].split(',')
        position = 0
        while position < len(options):
            option = options[position]
            if option in ('-search_paths_first', '-headerpad_max_install_names', '-dead_strip'):
                position += 1
                continue
            if option in ('-force_load', '-framework'):
                if position+1 >= len(options) or not options[position+1] or options[position+1].startswith('-'):
                    fail(f'malformed bundled linker option: {argument}')
                value = options[position+1]
                if option == '-force_load':
                    append(*classify_library(value, project_root, prefixes))
                else:
                    append('framework', value)
                position += 2
                continue
            if option.startswith('-l') and len(option) > 2:
                append('system', option)
            elif option.endswith(('.a', '.dylib', '.tbd')) and not option.startswith('-'):
                append(*classify_library(option, project_root, prefixes))
            else:
                # Response files, weak/re-export inputs and unknown forms
                # require explicit review rather than silently disappearing.
                fail(f'unsupported bundled linker option: {option!r}')
            position += 1

    index = 1
    while index < len(arguments):
        argument = arguments[index]
        if prefixes is not None and argument.startswith('-Wl,'):
            bundled_linker_options(argument)
            index += 1
            continue
        if argument == "-o":
            if index + 1 >= len(arguments):
                fail("link command has -o without an output")
            index += 2
            continue
        if argument == "-framework":
            if index + 1 >= len(arguments) or arguments[index + 1].startswith("-"):
                fail("link command has a malformed framework pair")
            append("framework", arguments[index + 1])
            index += 2
            continue
        if argument.startswith("-Wl,-framework,"):
            framework = argument[len("-Wl,-framework,") :]
            if not framework:
                fail("link command has an empty framework name")
            append("framework", framework)
            index += 1
            continue
        if argument.startswith("-Wl,-force_load,"):
            archive = argument[len("-Wl,-force_load,") :]
            if not archive:
                fail("link command has force_load without an archive")
            append(*classify_library(archive, project_root, prefixes))
            index += 1
            continue
        if argument == "-Xlinker" and index + 3 < len(arguments) and arguments[index + 1] == "-force_load" and arguments[index + 2] == "-Xlinker":
            append(*classify_library(arguments[index + 3], project_root, prefixes))
            index += 4
            continue
        if argument.startswith("-l") and len(argument) > 2:
            append("system", argument)
            index += 1
            continue
        if argument.startswith('-Wl,-l'):
            append('system', argument[4:])
            index += 1
            continue
        if argument.endswith(".tbd"):
            if prefixes is None:
                append("system", normalize_path(argument, project_root))
            else:
                append(*classify_library(argument, project_root, prefixes))
            index += 1
            continue
        if argument.endswith((".a", ".dylib")):
            append(*classify_library(argument, project_root, prefixes))
        elif argument.endswith('.framework'):
            append('framework', argument)
        index += 1

    if not rows:
        fail("link command contains no link interface items")
    return rows


def validate_output(path: Path) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        fail(f"unsafe output path: {path}")
    if not path.parent.is_dir() or path.parent.is_symlink():
        fail(f"output parent is not a real directory: {path.parent}")


def publish(path: Path, rows: list[tuple[str, str]]) -> None:
    data = "".join(f"{ordinal}\t{kind}\t{value}\n" for ordinal, (kind, value) in enumerate(rows, start=1))
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(data)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", required=True, type=Path)
    parser.add_argument("--command", required=True, type=Path)
    parser.add_argument("--omissions", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--allowed-prefix", action='append', default=[])
    arguments = parser.parse_args()
    try:
        root = Path(os.path.abspath(arguments.project_root))
        if not root.is_dir():
            fail(f"project root is not a directory: {root}")
        if not arguments.command.is_file() or arguments.command.is_symlink():
            fail(f"link command is not a regular file: {arguments.command}")
        command_lines = [line for line in arguments.command.read_text(encoding="utf-8").splitlines() if line.strip()]
        if len(command_lines) != 1:
            fail("link command evidence must contain exactly one nonempty line")
        validate_omissions(arguments.omissions)
        prefixes = allowed_prefixes(arguments.allowed_prefix) if arguments.allowed_prefix else None
        rows = parse_link_command(command_lines[0], root, prefixes)
        validate_output(arguments.output)
        publish(arguments.output, rows)
    except (OSError, ValueError) as error:
        print(f"link-evidence: error: {error}", file=sys.stderr)
        return 1
    return 0


def allowed_prefixes(values: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        name, separator, path_text = value.partition('=')
        path = Path(path_text)
        if not separator or not re.fullmatch(r'[a-z][a-z0-9-]*', name) or not path.is_absolute():
            fail(f'invalid allowed prefix: {value}')
        if name in result or not path.is_dir():
            fail(f'duplicate or missing allowed prefix: {value}')
        real = path.resolve(strict=True)
        if any(real.is_relative_to(existing) or existing.is_relative_to(real) for existing in result.values()):
            fail('overlapping allowed prefixes')
        result[name] = real
    return result


if __name__ == "__main__":
    sys.exit(main())
