#!/usr/bin/env python3
"""Run one adapter command and emit reversible JSON command/status evidence."""
import json
import subprocess
import sys

purpose, *argv = sys.argv[1:]
if not argv:
    raise SystemExit("command runner: missing command")
print(json.dumps({"type": "command", "purpose": purpose, "argv": argv}, ensure_ascii=False), flush=True)
completed = subprocess.run(argv)
print(json.dumps({"type": "status", "purpose": purpose, "status": completed.returncode}), flush=True)
raise SystemExit(completed.returncode)
