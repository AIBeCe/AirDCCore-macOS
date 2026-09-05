#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
PIN=55d51ceb817ec006d4ec844d9e3788e1b0ccc352
CHECKOUT=$ROOT/Source/airdcpp-core
WORK=$(new_temp_dir)
. "$ROOT/scripts/lib/upstream.sh"
ORIGINAL=$WORK/original-airdcpp-core
FIRST=$WORK/first-reconstruction
completed=0

[ "${AIRDCCORE_RUN_NETWORK_TESTS:-0}" = 1 ] ||
  fail "set AIRDCCORE_RUN_NETWORK_TESTS=1 to run the real upstream Gate 1 test"
[ "$(git -C "$ROOT" rev-parse --show-toplevel)" = "$ROOT" ] || fail "project root validation failed"
git -C "$ROOT" check-ignore -q -- Source/airdcpp-core/ || fail "Source/airdcpp-core is not ignored"
[ ! -L "$CHECKOUT" ] || fail "refusing symlinked checkout"

restore_on_failure() {
  [ "$completed" -eq 1 ] && return 0
  if [ -d "$ORIGINAL/.git" ]; then
    rm -rf -- "$CHECKOUT"
    mv "$ORIGINAL" "$CHECKOUT"
  elif [ -d "$FIRST/.git" ] && [ ! -e "$CHECKOUT" ]; then
    mv "$FIRST" "$CHECKOUT"
  fi
}
trap restore_on_failure 0 1 2 15

if [ -e "$CHECKOUT" ]; then
  [ -d "$CHECKOUT/.git" ] || fail "existing checkout is not a Git repository"
  [ -z "$(checkout_changes "$CHECKOUT")" ] || fail "existing checkout has unsafe local changes"
  mv "$CHECKOUT" "$ORIGINAL"
fi

first_output=$("$ROOT/scripts/update")
assert_contains "$first_output" "acquired AirDC++ Core at $PIN" "first reconstruction"
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$PIN" "first reconstruction HEAD"
mv "$CHECKOUT" "$FIRST"

second_output=$("$ROOT/scripts/update")
assert_contains "$second_output" "acquired AirDC++ Core at $PIN" "second reconstruction"
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$PIN" "second reconstruction HEAD"

before_head=$(git -C "$CHECKOUT" rev-parse HEAD)
before_status=$(git -C "$CHECKOUT" status --porcelain=v1 --untracked-files=all)
before_origin=$(git -C "$CHECKOUT" remote get-url --all origin)
no_op_output=$("$ROOT/scripts/update")
assert_contains "$no_op_output" "no update required" "post-reconstruction no-op"
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$before_head" "no-op HEAD"
assert_eq "$(git -C "$CHECKOUT" status --porcelain=v1 --untracked-files=all)" "$before_status" "no-op status"
assert_eq "$(git -C "$CHECKOUT" remote get-url --all origin)" "$before_origin" "no-op origin"

completed=1
trap - 0 1 2 15
rm -rf -- "$WORK"
printf 'PASS: Gate 1 reconstructed twice at %s and the next update was a no-op\n' "$PIN"
