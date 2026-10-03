#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
exec python3 "$repo/tests/dependency_network_fixtures.py"
