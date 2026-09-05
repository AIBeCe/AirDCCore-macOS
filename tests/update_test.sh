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
assert_eq "$(git -C "$CASE_ROOT/Source/airdcpp-core" status --porcelain=v1 --untracked-files=all)" "" \
  "acquisition leaves clean checkout"

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

REAL_GIT=$(command -v git)
RACE_BIN=$WORK/race-bin
create_race_wrappers "$RACE_BIN"

new_case
RACE_MARKER_COPY=$WORK/copied-owner-marker
if output=$(RACE_MODE=cleanup RACE_REAL_GIT="$REAL_GIT" RACE_MARKER_COPY="$RACE_MARKER_COPY" \
  RACE_CHECKOUT_DIR="$CASE_ROOT/Source/airdcpp-core" PATH="$RACE_BIN:$PATH" \
  "$CASE_ROOT/scripts/update" 2>&1); then
  fail "marker-preserving checkout replacement succeeded"
fi
assert_contains "$output" "checkout path changed during acquisition" "marker-preserving checkout replacement failure"
assert_file_present "$CASE_ROOT/Source/airdcpp-core/replacement"

new_case
RACE_OUTSIDE_DIR=$CASE_ROOT/outside
mkdir -p "$RACE_OUTSIDE_DIR"
if output=$(RACE_MODE=publication RACE_REAL_GIT="$REAL_GIT" RACE_OUTSIDE_DIR="$RACE_OUTSIDE_DIR" \
  RACE_CHECKOUT_DIR="$CASE_ROOT/Source/airdcpp-core" PATH="$RACE_BIN:$PATH" \
  "$CASE_ROOT/scripts/update" 2>&1); then
  fail "post-reservation publication replacement succeeded"
fi
assert_contains "$output" "checkout path changed during acquisition" "publication replacement failure"
[ -L "$CASE_ROOT/Source/airdcpp-core" ] || fail "publication replacement symlink was changed"
assert_eq "$(find "$RACE_OUTSIDE_DIR" -mindepth 1 -maxdepth 1 -print)" "" "publication replacement outside directory"

new_case
"$CASE_ROOT/scripts/update" >/dev/null
mv "$WORK/fixture/remote.git" "$WORK/fixture/remote.offline"
output=$("$CASE_ROOT/scripts/update")
assert_contains "$output" "no update required" "offline exact-checkout no-op"
assert_eq "$(git -C "$CASE_ROOT/Source/airdcpp-core" rev-parse HEAD)" "$FIXTURE_PIN" "no-op HEAD"
mv "$WORK/fixture/remote.offline" "$WORK/fixture/remote.git"

new_case
"$CASE_ROOT/scripts/update" >/dev/null
git -C "$CASE_ROOT/Source/airdcpp-core" switch -q -c local-at-pin
output=$("$CASE_ROOT/scripts/update")
assert_contains "$output" "normalized AirDC++ Core to detached HEAD" "detach normalization"
if git -C "$CASE_ROOT/Source/airdcpp-core" symbolic-ref -q HEAD >/dev/null; then
  fail "checkout remained attached to a branch"
fi

new_case
"$CASE_ROOT/scripts/update" >/dev/null
printf 'dirty\n' >> "$CASE_ROOT/Source/airdcpp-core/state.txt"
before=$(git -C "$CASE_ROOT/Source/airdcpp-core" rev-parse HEAD)
if output=$("$CASE_ROOT/scripts/update" 2>&1); then fail "modified checkout succeeded"; fi
assert_contains "$output" "checkout has unsafe local changes" "modified checkout"
assert_eq "$(git -C "$CASE_ROOT/Source/airdcpp-core" rev-parse HEAD)" "$before" "dirty HEAD preserved"
assert_eq "$(tail -n 1 "$CASE_ROOT/Source/airdcpp-core/state.txt")" "dirty" "dirty content preserved"

new_case
"$CASE_ROOT/scripts/update" >/dev/null
printf 'staged\n' >> "$CASE_ROOT/Source/airdcpp-core/state.txt"
git -C "$CASE_ROOT/Source/airdcpp-core" add state.txt
before=$(git -C "$CASE_ROOT/Source/airdcpp-core" rev-parse HEAD)
if output=$("$CASE_ROOT/scripts/update" 2>&1); then fail "staged checkout succeeded"; fi
assert_contains "$output" "<staged changes>" "staged diagnostic"
assert_eq "$(git -C "$CASE_ROOT/Source/airdcpp-core" rev-parse HEAD)" "$before" "staged HEAD preserved"
assert_eq "$(git -C "$CASE_ROOT/Source/airdcpp-core" diff --cached --name-only)" "state.txt" "staged index preserved"

new_case
"$CASE_ROOT/scripts/update" >/dev/null
printf 'untracked\n' > "$CASE_ROOT/Source/airdcpp-core/local.txt"
if output=$("$CASE_ROOT/scripts/update" 2>&1); then fail "untracked checkout succeeded"; fi
assert_contains "$output" "local.txt" "untracked diagnostic"
assert_file_present "$CASE_ROOT/Source/airdcpp-core/local.txt"

new_case
"$CASE_ROOT/scripts/update" >/dev/null
git -C "$CASE_ROOT/Source/airdcpp-core" remote set-url origin file://$WORK/wrong.git
before=$(git -C "$CASE_ROOT/Source/airdcpp-core" rev-parse HEAD)
if output=$("$CASE_ROOT/scripts/update" 2>&1); then fail "wrong origin succeeded"; fi
assert_contains "$output" "origin URL does not match configured upstream" "wrong origin"
assert_eq "$(git -C "$CASE_ROOT/Source/airdcpp-core" remote get-url origin)" "file://$WORK/wrong.git" "origin preserved"
assert_eq "$(git -C "$CASE_ROOT/Source/airdcpp-core" rev-parse HEAD)" "$before" "wrong-origin HEAD preserved"

new_case
printf 'AIRDCPP_CORE_URL=%s\nAIRDCPP_CORE_COMMIT=%s\n' "$FIXTURE_URL" "$FIXTURE_LATER" > "$CASE_ROOT/config/upstream.env"
"$CASE_ROOT/scripts/update" >/dev/null
mkdir -p "$CASE_ROOT/Source/airdcpp-core/airdcpp/core/localization"
printf 'generated\n' > "$CASE_ROOT/Source/airdcpp-core/airdcpp/core/version.inc"
printf 'generated\n' > "$CASE_ROOT/Source/airdcpp-core/airdcpp/core/localization/StringDefs.cpp"
printf 'AIRDCPP_CORE_URL=%s\nAIRDCPP_CORE_COMMIT=%s\n' "$FIXTURE_URL" "$FIXTURE_PIN" > "$CASE_ROOT/config/upstream.env"
output=$("$CASE_ROOT/scripts/update")
assert_contains "$output" "updated AirDC++ Core from $FIXTURE_LATER to $FIXTURE_PIN" "convergence"
assert_eq "$(git -C "$CASE_ROOT/Source/airdcpp-core" rev-parse HEAD)" "$FIXTURE_PIN" "converged HEAD"
assert_file_absent "$CASE_ROOT/Source/airdcpp-core/airdcpp/core/version.inc"
assert_file_absent "$CASE_ROOT/Source/airdcpp-core/airdcpp/core/localization/StringDefs.cpp"

new_case
printf 'AIRDCPP_CORE_URL=%s\nAIRDCPP_CORE_COMMIT=%s\n' "$FIXTURE_URL" "$FIXTURE_LATER" > "$CASE_ROOT/config/upstream.env"
"$CASE_ROOT/scripts/update" >/dev/null
old_head=$(git -C "$CASE_ROOT/Source/airdcpp-core" rev-parse HEAD)
mv "$WORK/fixture/remote.git" "$WORK/fixture/remote.offline"
printf 'AIRDCPP_CORE_URL=%s\nAIRDCPP_CORE_COMMIT=%s\n' "$FIXTURE_URL" "$FIXTURE_PIN" > "$CASE_ROOT/config/upstream.env"
if output=$("$CASE_ROOT/scripts/update" 2>&1); then fail "fetch failure succeeded"; fi
assert_contains "$output" "failed to fetch pinned commit" "existing fetch failure"
assert_eq "$(git -C "$CASE_ROOT/Source/airdcpp-core" rev-parse HEAD)" "$old_head" "fetch-failure HEAD"
assert_eq "$(git -C "$CASE_ROOT/Source/airdcpp-core" status --porcelain=v1 --untracked-files=all)" "" "fetch-failure worktree"
mv "$WORK/fixture/remote.offline" "$WORK/fixture/remote.git"

new_case
"$CASE_ROOT/scripts/update" >/dev/null
mkdir -p "$CASE_ROOT/Source/airdcpp-core/airdcpp/core"
printf 'generated\n' > "$CASE_ROOT/Source/airdcpp-core/airdcpp/core/version.inc"
output=$("$CASE_ROOT/scripts/update")
assert_contains "$output" "no update required" "known generated file allowed"
assert_file_present "$CASE_ROOT/Source/airdcpp-core/airdcpp/core/version.inc"

new_case
"$CASE_ROOT/scripts/update" >/dev/null
printf 'unknown\n' > "$CASE_ROOT/Source/airdcpp-core/EN_Example.xml"
if output=$("$CASE_ROOT/scripts/update" 2>&1); then fail "unknown ignored file succeeded"; fi
assert_contains "$output" "EN_Example.xml" "unknown ignored diagnostic"
assert_file_present "$CASE_ROOT/Source/airdcpp-core/EN_Example.xml"
printf 'PASS: upstream update workflow\n'
