#!/usr/bin/env python3
"""Command evidence and pkg-config relocation for the network adapters."""

import json
from pathlib import Path
import subprocess
import sys


def main():
    operation, *args = sys.argv[1:]
    if operation == "run":
        purpose, *argv = args
        print(json.dumps({"type": "command", "purpose": purpose, "argv": argv}), flush=True)
        try:
            result = subprocess.run(argv)
            status = result.returncode if result.returncode >= 0 else 128 - result.returncode
        except OSError as error:
            print(f"network adapter: {error}", file=sys.stderr)
            status = 127 if isinstance(error, FileNotFoundError) else 126
        print(json.dumps({"type": "status", "purpose": purpose, "status": status}), flush=True)
        return status
    if operation == "prune-docs":
        source, installed = map(Path, args)
        if not source.is_dir() or source.is_symlink():
            raise ValueError("missing regular upstream documentation directory")
        # Remove only upstream-installed documentation. Unexpected files fail
        # closed at rmdir; no recursive deletion of the staging tree is used.
        for entry in sorted(source.rglob("*"), reverse=True):
            destination = installed / entry.relative_to(source)
            if entry.is_file() and not entry.is_symlink():
                if not destination.is_file() or destination.is_symlink():
                    raise ValueError(f"missing regular installed documentation: {destination.name}")
                destination.unlink()
            elif entry.is_dir() and not entry.is_symlink():
                destination.rmdir()
            else:
                raise ValueError("unsafe upstream documentation entry")
        installed.rmdir()
        while installed.parent.name in ("man", "share"):
            installed = installed.parent
            installed.rmdir()
        return 0
    if operation == "relocate-pc":
        replacements = {"prefix": "${pcfiledir}/../..", "exec_prefix": "${prefix}",
                        "libdir": "${prefix}/lib", "includedir": "${prefix}/include"}
        for argument in args:
            path = Path(argument)
            if not path.is_file() or path.is_symlink():
                raise ValueError(f"missing regular pkg-config metadata: {path.name}")
            lines = path.read_text().splitlines()
            seen = set()
            relocated = []
            for line in lines:
                key, separator, _ = line.partition("=")
                if separator and key in replacements:
                    if key in seen:
                        raise ValueError(f"duplicate pkg-config variable: {key}")
                    seen.add(key)
                    line = key + "=" + replacements[key]
                # The pinned miniupnpc template quotes these variable options.
                # pkg-config already escapes interpolated path values; the
                # quotes add a second escape layer for prefixes with spaces.
                if line.startswith(("Libs:", "Libs.private:", "Cflags:")):
                    line = line.replace('-L"${libdir}"', '-L${libdir}')
                    line = line.replace('-I"${includedir}"', '-I${includedir}')
                relocated.append(line)
            if not {"prefix", "libdir", "includedir"}.issubset(seen):
                raise ValueError(f"missing pkg-config path variables: {path.name}")
            path.write_text("\n".join(relocated) + "\n")
        return 0
    raise ValueError(f"unknown network adapter operation: {operation}")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as error:
        print(f"network adapter: {error}", file=sys.stderr)
        sys.exit(2)
