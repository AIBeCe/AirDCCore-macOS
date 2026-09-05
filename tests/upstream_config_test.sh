#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
. "$ROOT/scripts/lib/upstream.sh"

WORK=$(new_temp_dir)
trap 'rm -rf -- "$WORK"' 0 1 2 15
COMMIT=55d51ceb817ec006d4ec844d9e3788e1b0ccc352
URL=https://github.com/airdcpp/airdcpp-core.git
write_config() { printf '%s\n' "$@" > "$WORK/upstream.env"; }

write_config "# identity" "AIRDCPP_CORE_URL=$URL" "AIRDCPP_CORE_COMMIT=$COMMIT"
load_upstream_config "$WORK/upstream.env"
assert_eq "$AIRDCPP_CORE_URL" "$URL" "URL"
assert_eq "$AIRDCPP_CORE_COMMIT" "$COMMIT" "commit"

for invalid in missing_url missing_commit duplicate unknown short_commit scheme spaced_url malformed; do
  case "$invalid" in
    missing_url) write_config "AIRDCPP_CORE_COMMIT=$COMMIT" ;;
    missing_commit) write_config "AIRDCPP_CORE_URL=$URL" ;;
    duplicate) write_config "AIRDCPP_CORE_URL=$URL" "AIRDCPP_CORE_URL=$URL" "AIRDCPP_CORE_COMMIT=$COMMIT" ;;
    unknown) write_config "AIRDCPP_CORE_URL=$URL" "AIRDCPP_CORE_COMMIT=$COMMIT" "EXTRA=value" ;;
    short_commit) write_config "AIRDCPP_CORE_URL=$URL" "AIRDCPP_CORE_COMMIT=55d51ceb" ;;
    scheme) write_config "AIRDCPP_CORE_URL=ssh://example.invalid/core.git" "AIRDCPP_CORE_COMMIT=$COMMIT" ;;
    spaced_url) write_config "AIRDCPP_CORE_URL=https://example.invalid/core repo.git" "AIRDCPP_CORE_COMMIT=$COMMIT" ;;
    malformed) write_config "AIRDCPP_CORE_URL=$URL" "not-an-assignment" "AIRDCPP_CORE_COMMIT=$COMMIT" ;;
  esac
  if output=$(load_upstream_config "$WORK/upstream.env" 2>&1); then
    fail "$invalid unexpectedly succeeded"
  fi
  assert_contains "$output" "upstream config:" "$invalid diagnostic"
done

MARKER=$WORK/must-not-exist
write_config "AIRDCPP_CORE_URL=\$(touch $MARKER)" "AIRDCPP_CORE_COMMIT=$COMMIT"
if load_upstream_config "$WORK/upstream.env" >/dev/null 2>&1; then
  fail "executable value unexpectedly succeeded"
fi
assert_file_absent "$MARKER"
printf 'PASS: upstream manifest parser\n'
