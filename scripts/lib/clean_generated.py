"""Fixed-target cleanup reuses descriptor-relative ownership and removal."""
import argparse
import json
from pathlib import Path
import stat
import subprocess
import sys

from dependency_acquire import OwnedDirectory, _identity_at, _remove_at


def clean_generated(project):
    project = Path(project).absolute()
    if project == Path(project.anchor) or project == Path.home():
        raise ValueError("unsafe cleanup project root")
    with OwnedDirectory(project) as owner:
        root = subprocess.check_output(["git", "-C", str(project), "rev-parse", "--show-toplevel"], text=True).strip()
        if Path(root) != project:
            raise ValueError("cleanup must operate at its own Git project root")
        tracked = subprocess.check_output(["git", "-C", str(project), "ls-files", "-z", "--", "Build", "Dist"])
        if tracked:
            raise ValueError("cleanup refuses tracked generated paths")
        targets = {}
        for name in ("Build", "Dist"):
            identity = _identity_at(owner.fd, name)
            if identity is not None and identity[2] != stat.S_IFDIR:
                raise ValueError("unsafe generated top-level target: " + name)
            targets[name] = identity
        owner.check()
        # Validate BOTH targets before the first destructive operation.
        for name, identity in targets.items():
            if _identity_at(owner.fd, name) != identity:
                raise ValueError("generated target changed before cleanup: " + name)
        removed = []
        for name, identity in targets.items():
            if identity is not None:
                owner.check()
                _remove_at(owner.fd, name, expected_identity=identity)
                removed.append(name)
        owner.check()
        return dict(removed=removed)


def main(project, argv=None):
    parser = argparse.ArgumentParser(description="Remove this Git project's generated Build and Dist only.")
    parser.parse_args(argv)
    try:
        print("clean: " + json.dumps(clean_generated(project), sort_keys=True))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("clean: error: " + str(error) + "; inspect the named path before retrying", file=sys.stderr)
        return 1
