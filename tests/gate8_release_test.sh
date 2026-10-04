#!/bin/sh
set -eu
if [ "$#" -ne 0 ]; then
  printf 'usage: tests/gate8_release_test.sh (no arguments)\n' >&2
  exit 64
fi
if [ "${AIRDCCORE_RUN_RELEASE_TESTS:-0}" != 1 ]; then
  printf 'SKIP: set AIRDCCORE_RUN_RELEASE_TESTS=1 for two independent fresh Gate 8 builds\n'
  exit 0
fi
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
exec python3 - "$PROJECT_ROOT" <<'PY'
from pathlib import Path
import sys
project = Path(sys.argv[1])
sys.path.insert(0, str(project / 'scripts/lib'))
from release_verify import gate_main
raise SystemExit(gate_main(project))
PY
