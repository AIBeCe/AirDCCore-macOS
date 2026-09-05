#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
WORK=$(new_temp_dir)
trap 'rm -rf -- "$WORK"' 0 1 2 15
create_remote_fixture "$WORK/fixture"
CASE_NUMBER=0
new_case() {
  CASE_NUMBER=$((CASE_NUMBER + 1))
  CASE_ROOT=$WORK/case-$CASE_NUMBER
  create_case_project "$CASE_ROOT" "$ROOT" "$FIXTURE_URL" "$FIXTURE_PIN"
}

new_case
output=$("$CASE_ROOT/scripts/update")
assert_contains "$output" "acquired AirDC++ Core at $FIXTURE_PIN" "acquisition"
assert_eq "$(git -C "$CASE_ROOT/Source/airdcpp-core" rev-parse HEAD)" "$FIXTURE_PIN" "HEAD"
if git -C "$CASE_ROOT/Source/airdcpp-core" symbolic-ref -q HEAD >/dev/null; then
  fail "acquired checkout is not detached"
fi
assert_eq "$(git -C "$CASE_ROOT/Source/airdcpp-core" remote get-url origin)" "$FIXTURE_URL" "origin"

new_case
printf '' > "$CASE_ROOT/.gitignore"
if output=$("$CASE_ROOT/scripts/update" 2>&1); then fail "unignored target succeeded"; fi
assert_contains "$output" "must be ignored by the parent repository" "ignore guard"
assert_file_absent "$CASE_ROOT/Source/airdcpp-core"

new_case
printf 'AIRDCPP_CORE_URL=file://%s/absent.git\nAIRDCPP_CORE_COMMIT=%s\n' \
  "$WORK" "$FIXTURE_PIN" > "$CASE_ROOT/config/upstream.env"
if output=$("$CASE_ROOT/scripts/update" 2>&1); then fail "unreachable remote succeeded"; fi
assert_contains "$output" "failed to fetch pinned commit" "network failure"
assert_file_absent "$CASE_ROOT/Source/airdcpp-core"
assert_eq "$(find "$CASE_ROOT/Source" -maxdepth 1 -name '.airdcpp-core.update.*' -print)" "" "staging cleanup"

new_case
mkdir -p "$CASE_ROOT/Source/airdcpp-core"
printf 'preserve\n' > "$CASE_ROOT/Source/airdcpp-core/marker"
if output=$("$CASE_ROOT/scripts/update" 2>&1); then fail "non-Git target succeeded"; fi
assert_contains "$output" "exists but is not an AirDC++ Core Git checkout" "non-Git target"
assert_file_present "$CASE_ROOT/Source/airdcpp-core/marker"

new_case
ln -s "$WORK/fixture/seed" "$CASE_ROOT/Source/airdcpp-core"
if output=$("$CASE_ROOT/scripts/update" 2>&1); then fail "symlink target succeeded"; fi
assert_contains "$output" "refusing symlinked checkout path" "symlink guard"

new_case
if output=$("$CASE_ROOT/scripts/update" unexpected 2>&1); then fail "argument succeeded"; fi
assert_contains "$output" "usage:" "argument rejection"

new_case
output=$(CDPATH= cd -- "$WORK" && "$CASE_ROOT/scripts/update")
assert_contains "$output" "acquired AirDC++ Core at $FIXTURE_PIN" "other working directory"
printf 'PASS: missing checkout acquisition and cleanup\n'
