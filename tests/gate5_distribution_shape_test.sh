#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"

ADR=$ROOT/docs/decisions/0001-aggregate-static-distribution.md

assert_file_present "$ADR"

assert_line "$ADR" '# ADR 0001: Aggregate static distribution' 'ADR title'
assert_line "$ADR" '**Status:** Accepted' 'ADR status'
assert_line "$ADR" '**Decision date:** 2026-09-22' 'ADR date'
assert_line "$ADR" '**Gate 4 Core SHA-256:** `f345fe0e5fc7bbf289642e5a8846795f0e0d177288505419b0ba96cc23367441`' 'measured Core identity'
assert_line "$ADR" '**Published library:** `Dist/lib/libairdcpp.a`' 'published aggregate path'

expected_components=$(cat <<'EOF'
- AirDC++ Core
- BZip2
- zlib
- OpenSSL SSL
- OpenSSL Crypto
- miniupnpc
- LevelDB
- MaxMindDB
- Snappy
EOF
)
actual_components=$(awk '
  /^### Aggregate component inventory$/ { capture = 1; next }
  /^##/ && capture { exit }
  capture && /^- / { print }
' "$ADR")
assert_eq "$actual_components" "$expected_components" 'exact ordered aggregate component inventory'

expected_system_links=$(cat <<'EOF'
- explicit SDK link input: Iconv from the selected macOS SDK
- implicit toolchain load command: libc++ from the selected macOS toolchain/SDK
- implicit toolchain load command: libSystem from the selected macOS SDK
- measured Apple framework requirement: none
EOF
)
actual_system_links=$(awk '
  /^### External Apple system-link inventory$/ { capture = 1; next }
  /^##/ && capture { exit }
  capture && /^- / { print }
' "$ADR")
assert_eq "$actual_system_links" "$expected_system_links" 'exact classified Apple system-link inventory'

for clause in \
  'declared component order' \
  'reject duplicate strong external definitions' \
  'inventory every repeated weak or coalesced definition' \
  'evidence-bound coalescing decision' \
  'NN-component-slug--NNNN-original-member-name' \
  'original archive member-table order' \
  'component-and-ordinal namespace' \
  'byte-sorted file list' \
  'LC_ALL=C' \
  '/usr/bin/libtool -static -D -filelist' \
  'two clean aggregate builds'
do
  grep -Fq -- "$clause" "$ADR" || fail "deterministic construction: missing [$clause]"
done

for obligation in \
  'exact source URL and immutable revision' \
  'source and archive SHA-256 checksums' \
  'build flags and patches' \
  'license identity and redistributed notices' \
  'aggregate member-to-component mapping'
do
  grep -Fq -- "$obligation" "$ADR" || fail "provenance obligation: missing [$obligation]"
done

for heading in \
  '## Rejected alternative: separate public archives' \
  '## Rejected alternative: multiple archives behind CMake or pkg-config' \
  '## Phase 6 handoff and non-claims'
do
  assert_line "$ADR" "$heading" "ADR section $heading"
done

grep -Fq -- '../reports/2026-09-21-gate-4-consumer-link.md' "$ADR" || fail 'ADR must link the Gate 4 report'
grep -Fq -- '../superpowers/specs/2026-09-04-airdc-core-macos-design.md' "$ADR" || fail 'ADR must link the design spec'

tracked_outputs=$(git -C "$ROOT" ls-files Source Dependencies Build Dist)
assert_eq "$tracked_outputs" '' 'generated inputs and outputs must remain untracked'
assert_file_absent "$ROOT/Dependencies"
assert_file_absent "$ROOT/Dist"
[ ! -L "$ROOT/Dependencies" ] || fail 'Dependencies must not be a dangling symlink'
[ ! -L "$ROOT/Dist" ] || fail 'Dist must not be a dangling symlink'

printf '%s\n' 'PASS: Gate 5 accepted aggregate static distribution decision without packaging'
