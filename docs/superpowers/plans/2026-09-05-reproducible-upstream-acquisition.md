# Reproducible Upstream Acquisition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a safe, deterministic `scripts/update` workflow that reconstructs `Source/airdcpp-core` from the configured canonical URL at exact commit `55d51ceb817ec006d4ec844d9e3788e1b0ccc352` and proves Gate 1 idempotence.

**Architecture:** A non-executable, allowlist-parsed manifest stores upstream identity; a small POSIX shell library owns validation and Git state transitions; and `scripts/update` is the argument-free user entry point. Hermetic shell tests use local temporary Git repositories for all safety and failure paths, while one opt-in network acceptance test reconstructs the real ignored checkout twice and proves the following invocation is a no-op.

**Tech Stack:** POSIX `/bin/sh`, Git, standard macOS command-line utilities (`grep`, `mktemp`, `mv`, `rm`, `find`), and shell integration tests with no third-party test framework.

**Spec:** `docs/superpowers/specs/2026-09-04-airdc-core-macos-design.md`

## Global Constraints

- Implement Phase 1, **Reproducible upstream acquisition**, and no later phase.
- Upstream URL: `https://github.com/airdcpp/airdcpp-core.git`.
- Upstream commit: `55d51ceb817ec006d4ec844d9e3788e1b0ccc352`; no tag exists or is assumed.
- Sole checkout location: ignored `Source/airdcpp-core`; no Git submodule and no parent-repository tracking.
- `scripts/update` takes no arguments, is runnable from any current directory, and resolves the parent project root from its own location.
- Manifest data is parsed as data and is never sourced or evaluated as shell code.
- A dirty, non-Git, symlinked, or wrong-origin checkout is preserved and rejected with a nonzero exit.
- A clean checkout at the wrong commit may converge to the pin only after origin and working-tree safety checks pass.
- A correct detached checkout returns success without fetching or changing checkout state.
- Only `airdcpp/core/version.inc` and `airdcpp/core/localization/StringDefs.cpp` may be ignored as acceptable generated state; other untracked or ignored files block mutation.
- Network/fetch failure leaves an existing HEAD/worktree unchanged and removes only a validated temporary staging directory when the checkout was missing.
- Tests use red-green evidence. Gate 1 reconstructs twice, verifies the exact commit both times, then proves a subsequent update is a no-op.
- Do not add CMake, dependency builds, Apple Clang configuration, ARM64 compilation, packaging, `Dist`, or smoke-test work.
- Parent work stays on `feature/reproducible-upstream-acquisition`; plan execution does not merge to `develop`.
- Project scripts invoke standard tools directly. Codex workers prefix ad hoc terminal commands with `rtk` per `AGENTS.md`; end users run the project-facing commands shown without `rtk`.

---

## Planned file map

| File | Responsibility |
| --- | --- |
| `config/upstream.env` | Tracked, inert two-key manifest for canonical URL and exact commit |
| `scripts/lib/upstream.sh` | Parser, layout checks, checkout classification, acquisition, and convergence functions |
| `scripts/update` | Stable no-argument user command |
| `tests/test_helper.sh` | Assertions and temporary local-Git fixtures |
| `tests/upstream_config_test.sh` | Parser, malformed-input, and injection-resistance tests |
| `tests/update_test.sh` | Hermetic acquisition, safety, failure, convergence, and no-op tests |
| `tests/gate1_network_test.sh` | Explicitly enabled real-upstream reconstruction and idempotence gate |
| `README.md` | User-facing update usage and Phase 1 status |
| `docs/upstream-policy.md` | Implemented state machine, failure rules, and Gate 1 command |
| `docs/build-and-release.md` | Gate 1 evidence without advancing into build phases |

## Command contract

Public invocation:

```bash
./scripts/update
```

It exits `0` only when the checkout is acquired, safely converged, normalized to detached HEAD, or already correct. Arguments are rejected with exit `64`. Other failures are nonzero and start with `update: error:` on stderr.

Stable success messages:

```text
update: acquired AirDC++ Core at 55d51ceb817ec006d4ec844d9e3788e1b0ccc352
update: updated AirDC++ Core from PREVIOUS_FULL_COMMIT to 55d51ceb817ec006d4ec844d9e3788e1b0ccc352
update: normalized AirDC++ Core to detached HEAD at 55d51ceb817ec006d4ec844d9e3788e1b0ccc352
update: AirDC++ Core is already at pinned commit 55d51ceb817ec006d4ec844d9e3788e1b0ccc352; no update required
```

`PREVIOUS_FULL_COMMIT` above denotes the runtime 40-character commit printed by the script. The no-op path executes no fetch, checkout, removal, or remote mutation.

### Task 1: Add the inert upstream manifest and strict parser

**Files:**
- Create: `config/upstream.env`
- Create: `scripts/lib/upstream.sh`
- Create: `tests/test_helper.sh`
- Create: `tests/upstream_config_test.sh`

**Interfaces:**
- Consumes: manifest path passed as `$1` to `load_upstream_config`.
- Produces: `load_upstream_config PATH -> 0|nonzero`, setting `AIRDCPP_CORE_URL` and `AIRDCPP_CORE_COMMIT` on success; `upstream_error MESSAGE -> nonzero`.

- [ ] **Step 1: Create the test helper**

Create `tests/test_helper.sh`:

```sh
#!/bin/sh

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  actual=$1
  expected=$2
  label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected [$expected], got [$actual]"
}

assert_contains() {
  haystack=$1
  needle=$2
  label=$3
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label: expected output containing [$needle], got [$haystack]" ;;
  esac
}

assert_file_absent() { [ ! -e "$1" ] || fail "expected absent path: $1"; }
assert_file_present() { [ -e "$1" ] || fail "expected existing path: $1"; }
new_temp_dir() { mktemp -d "${TMPDIR:-/tmp}/airdc-core-tests.XXXXXX"; }
```

- [ ] **Step 2: Write the failing parser test**

Create executable `tests/upstream_config_test.sh`:

```sh
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
```

Make the test runnable with `chmod +x tests/upstream_config_test.sh`.

- [ ] **Step 3: Run the test to verify red**

Run `./tests/upstream_config_test.sh` (Codex: `rtk ./tests/upstream_config_test.sh`).

Expected: FAIL because `scripts/lib/upstream.sh` does not exist.

- [ ] **Step 4: Add the exact manifest**

Create `config/upstream.env`:

```text
# AirDC++ Core source identity. This file is parsed as data; do not source it.
AIRDCPP_CORE_URL=https://github.com/airdcpp/airdcpp-core.git
AIRDCPP_CORE_COMMIT=55d51ceb817ec006d4ec844d9e3788e1b0ccc352
```

- [ ] **Step 5: Implement the strict parser**

Create `scripts/lib/upstream.sh`:

```sh
#!/bin/sh

upstream_error() {
  printf 'update: error: upstream config: %s\n' "$*" >&2
  return 1
}

load_upstream_config() {
  config_path=$1
  AIRDCPP_CORE_URL=
  AIRDCPP_CORE_COMMIT=
  seen_url=0
  seen_commit=0

  [ -f "$config_path" ] || { upstream_error "missing file: $config_path"; return 1; }
  while IFS= read -r config_line || [ -n "$config_line" ]; do
    case "$config_line" in
      ''|'#'*) continue ;;
      *=*) config_key=${config_line%%=*}; config_value=${config_line#*=} ;;
      *) upstream_error "malformed line: $config_line"; return 1 ;;
    esac
    case "$config_key" in
      AIRDCPP_CORE_URL)
        [ "$seen_url" -eq 0 ] || { upstream_error "duplicate AIRDCPP_CORE_URL"; return 1; }
        AIRDCPP_CORE_URL=$config_value; seen_url=1 ;;
      AIRDCPP_CORE_COMMIT)
        [ "$seen_commit" -eq 0 ] || { upstream_error "duplicate AIRDCPP_CORE_COMMIT"; return 1; }
        AIRDCPP_CORE_COMMIT=$config_value; seen_commit=1 ;;
      *) upstream_error "unknown key: $config_key"; return 1 ;;
    esac
  done < "$config_path"

  [ "$seen_url" -eq 1 ] || { upstream_error "missing AIRDCPP_CORE_URL"; return 1; }
  [ "$seen_commit" -eq 1 ] || { upstream_error "missing AIRDCPP_CORE_COMMIT"; return 1; }
  case "$AIRDCPP_CORE_URL" in
    https://*|file://*) ;;
    *) upstream_error "AIRDCPP_CORE_URL must use https:// or file://"; return 1 ;;
  esac
  if printf '%s\n' "$AIRDCPP_CORE_URL" | grep -Eq '[[:space:]]'; then
    upstream_error "AIRDCPP_CORE_URL must not contain whitespace"
    return 1
  fi
  printf '%s\n' "$AIRDCPP_CORE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || {
    upstream_error "AIRDCPP_CORE_COMMIT must be a full lowercase 40-character hexadecimal commit"
    return 1
  }
}
```

- [ ] **Step 6: Verify green and commit**

Run:

```bash
chmod +x tests/upstream_config_test.sh
./tests/upstream_config_test.sh
git add config/upstream.env scripts/lib/upstream.sh tests/test_helper.sh tests/upstream_config_test.sh
git commit -m "feat: add pinned upstream manifest parser"
```

Expected: `PASS: upstream manifest parser`, then one focused commit.

### Task 2: Acquire a missing checkout safely

**Files:**
- Create: `scripts/update`
- Create: `tests/update_test.sh`
- Modify: `scripts/lib/upstream.sh`
- Modify: `tests/test_helper.sh`

**Interfaces:**
- Consumes: loaded pin, resolved `PROJECT_ROOT`, `SOURCE_DIR`, and `CHECKOUT_DIR`.
- Produces: `validate_project_layout ROOT -> 0|exit`; `acquire_missing_checkout SOURCE CHECKOUT URL COMMIT -> 0|exit`; executable `scripts/update -> 0|nonzero`.

- [ ] **Step 1: Extend the helper with local Git fixtures**

Append to `tests/test_helper.sh`:

```sh
create_remote_fixture() {
  fixture_root=$1
  mkdir -p "$fixture_root/seed"
  git -C "$fixture_root/seed" init -q
  git -C "$fixture_root/seed" config user.name "AirDCCore Tests"
  git -C "$fixture_root/seed" config user.email "tests@example.invalid"
  printf 'pinned\n' > "$fixture_root/seed/state.txt"
  printf '/EN_Example.xml\n/airdcpp/core/version.inc\n/airdcpp/core/localization/StringDefs.cpp\n' \
    > "$fixture_root/seed/.gitignore"
  git -C "$fixture_root/seed" add state.txt .gitignore
  git -C "$fixture_root/seed" commit -q -m "pinned state"
  FIXTURE_PIN=$(git -C "$fixture_root/seed" rev-parse HEAD)
  printf 'later\n' > "$fixture_root/seed/state.txt"
  git -C "$fixture_root/seed" commit -q -am "later state"
  FIXTURE_LATER=$(git -C "$fixture_root/seed" rev-parse HEAD)
  git clone -q --bare "$fixture_root/seed" "$fixture_root/remote.git"
  FIXTURE_URL=file://$fixture_root/remote.git
}

create_case_project() {
  case_root=$1
  repo_root=$2
  fixture_url=$3
  fixture_commit=$4
  mkdir -p "$case_root/config" "$case_root/scripts/lib" "$case_root/Source"
  cp "$repo_root/scripts/update" "$case_root/scripts/update"
  cp "$repo_root/scripts/lib/upstream.sh" "$case_root/scripts/lib/upstream.sh"
  printf '/Source/airdcpp-core/\n' > "$case_root/.gitignore"
  printf 'AIRDCPP_CORE_URL=%s\nAIRDCPP_CORE_COMMIT=%s\n' \
    "$fixture_url" "$fixture_commit" > "$case_root/config/upstream.env"
  git -C "$case_root" init -q
}
```

- [ ] **Step 2: Write failing missing, ignore, network, non-Git, and symlink tests**

Create executable `tests/update_test.sh`:

```sh
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
```

Make the test runnable with `chmod +x tests/update_test.sh`.

- [ ] **Step 3: Run the integration test to verify red**

Run `./tests/update_test.sh` (Codex: `rtk ./tests/update_test.sh`).

Expected: FAIL because `scripts/update` does not exist.

- [ ] **Step 4: Add safe layout and staging functions**

Append to `scripts/lib/upstream.sh`:

```sh
update_die() {
  printf 'update: error: %s\n' "$*" >&2
  exit 1
}

validate_project_layout() {
  project_root=$1
  actual_root=$(git -C "$project_root" rev-parse --show-toplevel 2>/dev/null) ||
    update_die "project root is not a Git repository: $project_root"
  [ "$actual_root" = "$project_root" ] ||
    update_die "script root does not match parent Git root: $project_root"
  mkdir -p "$project_root/Source"
  [ ! -L "$project_root/Source" ] || update_die "refusing symlinked Source directory"
  git -C "$project_root" check-ignore -q -- Source/airdcpp-core ||
    update_die "Source/airdcpp-core must be ignored by the parent repository"
}

cleanup_staging_checkout() {
  if [ -n "${UPDATE_STAGING_DIR:-}" ] && [ -n "${UPDATE_SOURCE_DIR:-}" ]; then
    case "$UPDATE_STAGING_DIR" in
      "$UPDATE_SOURCE_DIR"/.airdcpp-core.update.*) rm -rf -- "$UPDATE_STAGING_DIR" ;;
      *) printf 'update: error: refusing unsafe staging cleanup path: %s\n' "$UPDATE_STAGING_DIR" >&2 ;;
    esac
  fi
}

acquire_missing_checkout() {
  UPDATE_SOURCE_DIR=$1
  checkout_dir=$2
  upstream_url=$3
  upstream_commit=$4
  UPDATE_STAGING_DIR=$UPDATE_SOURCE_DIR/.airdcpp-core.update.$$
  [ ! -e "$UPDATE_STAGING_DIR" ] || update_die "staging path already exists: $UPDATE_STAGING_DIR"
  trap cleanup_staging_checkout 0 1 2 15
  git init -q "$UPDATE_STAGING_DIR" || update_die "failed to initialize staging checkout"
  git -C "$UPDATE_STAGING_DIR" remote add origin "$upstream_url" || update_die "failed to configure upstream origin"
  git -C "$UPDATE_STAGING_DIR" fetch -q --no-tags --depth=1 origin "$upstream_commit" ||
    update_die "failed to fetch pinned commit $upstream_commit from $upstream_url"
  fetched_commit=$(git -C "$UPDATE_STAGING_DIR" rev-parse FETCH_HEAD) || update_die "failed to resolve fetched commit"
  [ "$fetched_commit" = "$upstream_commit" ] || update_die "fetched commit does not match pin $upstream_commit"
  git -C "$UPDATE_STAGING_DIR" checkout -q --detach "$upstream_commit" || update_die "failed to check out pin"
  [ "$(git -C "$UPDATE_STAGING_DIR" rev-parse HEAD)" = "$upstream_commit" ] || update_die "staged HEAD mismatch"
  mv "$UPDATE_STAGING_DIR" "$checkout_dir" || update_die "failed to publish checkout at $checkout_dir"
  UPDATE_STAGING_DIR=
  trap - 0 1 2 15
  printf 'update: acquired AirDC++ Core at %s\n' "$upstream_commit"
}
```

- [ ] **Step 5: Add the stable entry point**

Create executable `scripts/update`:

```sh
#!/bin/sh
set -eu

if [ "$#" -ne 0 ]; then printf 'usage: %s\n' "$0" >&2; exit 64; fi
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CONFIG_PATH=$PROJECT_ROOT/config/upstream.env
SOURCE_DIR=$PROJECT_ROOT/Source
CHECKOUT_DIR=$SOURCE_DIR/airdcpp-core
. "$PROJECT_ROOT/scripts/lib/upstream.sh"

load_upstream_config "$CONFIG_PATH" || exit 1
validate_project_layout "$PROJECT_ROOT"
[ ! -L "$CHECKOUT_DIR" ] || update_die "refusing symlinked checkout path: $CHECKOUT_DIR"
if [ ! -e "$CHECKOUT_DIR" ]; then
  acquire_missing_checkout "$SOURCE_DIR" "$CHECKOUT_DIR" "$AIRDCPP_CORE_URL" "$AIRDCPP_CORE_COMMIT"
  exit 0
fi
[ -d "$CHECKOUT_DIR/.git" ] || update_die "$CHECKOUT_DIR exists but is not an AirDC++ Core Git checkout"
update_die "existing checkout requires identity and cleanliness validation"
```

- [ ] **Step 6: Verify green and commit**

Run:

```bash
chmod +x scripts/update tests/update_test.sh
./tests/upstream_config_test.sh
./tests/update_test.sh
git add scripts/update scripts/lib/upstream.sh tests/test_helper.sh tests/update_test.sh
git commit -m "feat: acquire pinned upstream checkout safely"
```

Expected: both suites print `PASS:`; the failed fetch leaves no checkout or staging directory; then one focused commit.

### Task 3: Protect and converge existing checkouts

**Files:**
- Modify: `scripts/lib/upstream.sh`
- Modify: `scripts/update`
- Modify: `tests/update_test.sh`

**Interfaces:**
- Consumes: existing non-symlink Git checkout plus exact URL/commit.
- Produces: `checkout_changes CHECKOUT -> newline-delimited unsafe paths`; `validate_checkout_origin CHECKOUT URL -> 0|exit`; `update_existing_checkout CHECKOUT URL COMMIT -> 0|exit`.

- [ ] **Step 1: Add failing exact-checkout and detached-normalization tests**

Insert before the final `PASS` in `tests/update_test.sh`:

```sh
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
```

- [ ] **Step 2: Add failing dirty and wrong-origin preservation tests**

Add:

```sh
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
```

- [ ] **Step 3: Add failing convergence and existing-fetch-failure tests**

Add:

```sh
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
```

- [ ] **Step 4: Add failing ignored-file allowlist tests**

Add:

```sh
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
```

- [ ] **Step 5: Run the expanded test to verify red**

Run `./tests/update_test.sh`.

Expected: FAIL on the first existing-checkout case with `existing checkout requires identity and cleanliness validation`.

- [ ] **Step 6: Implement change classification, origin validation, and generated-file cleanup**

Append to `scripts/lib/upstream.sh`:

```sh
checkout_changes() {
  inspected_checkout=$1
  git -C "$inspected_checkout" diff --quiet -- || printf '%s\n' '<modified tracked files>'
  git -C "$inspected_checkout" diff --cached --quiet -- || printf '%s\n' '<staged changes>'
  git -C "$inspected_checkout" ls-files --others --exclude-standard
  git -C "$inspected_checkout" ls-files --others --ignored --exclude-standard |
    while IFS= read -r ignored_path; do
      case "$ignored_path" in
        airdcpp/core/version.inc|airdcpp/core/localization/StringDefs.cpp) ;;
        *) printf '%s\n' "$ignored_path" ;;
      esac
    done
}

validate_checkout_origin() {
  inspected_checkout=$1
  expected_url=$2
  origin_urls=$(git -C "$inspected_checkout" remote get-url --all origin 2>/dev/null) ||
    update_die "checkout has no origin remote"
  [ "$origin_urls" = "$expected_url" ] ||
    update_die "origin URL does not match configured upstream (expected $expected_url)"
}

remove_known_generated_files() {
  inspected_checkout=$1
  rm -f -- "$inspected_checkout/airdcpp/core/version.inc" \
    "$inspected_checkout/airdcpp/core/localization/StringDefs.cpp"
}
```

- [ ] **Step 7: Implement existing-checkout convergence**

Append:

```sh
update_existing_checkout() {
  checkout_dir=$1
  upstream_url=$2
  upstream_commit=$3
  validate_checkout_origin "$checkout_dir" "$upstream_url"
  unsafe_changes=$(checkout_changes "$checkout_dir")
  [ -z "$unsafe_changes" ] || update_die "checkout has unsafe local changes:\n$unsafe_changes"
  current_commit=$(git -C "$checkout_dir" rev-parse HEAD 2>/dev/null) || update_die "failed to resolve checkout HEAD"

  if [ "$current_commit" = "$upstream_commit" ]; then
    if git -C "$checkout_dir" symbolic-ref -q HEAD >/dev/null; then
      git -C "$checkout_dir" checkout -q --detach "$upstream_commit" || update_die "failed to detach at pin"
      printf 'update: normalized AirDC++ Core to detached HEAD at %s\n' "$upstream_commit"
    else
      printf 'update: AirDC++ Core is already at pinned commit %s; no update required\n' "$upstream_commit"
    fi
    return 0
  fi

  git -C "$checkout_dir" fetch -q --no-tags --depth=1 origin "$upstream_commit" ||
    update_die "failed to fetch pinned commit $upstream_commit from $upstream_url"
  fetched_commit=$(git -C "$checkout_dir" rev-parse FETCH_HEAD 2>/dev/null) || update_die "failed to resolve fetched commit"
  [ "$fetched_commit" = "$upstream_commit" ] || update_die "fetched commit does not match pin $upstream_commit"
  remove_known_generated_files "$checkout_dir"
  git -C "$checkout_dir" checkout -q --detach "$upstream_commit" || update_die "failed to check out pin"
  [ "$(git -C "$checkout_dir" rev-parse HEAD)" = "$upstream_commit" ] || update_die "checkout HEAD mismatch"
  [ -z "$(checkout_changes "$checkout_dir")" ] || update_die "checkout is not clean after update"
  printf 'update: updated AirDC++ Core from %s to %s\n' "$current_commit" "$upstream_commit"
}
```

Replace the final `update_die` in `scripts/update` with:

```sh
update_existing_checkout "$CHECKOUT_DIR" "$AIRDCPP_CORE_URL" "$AIRDCPP_CORE_COMMIT"
```

- [ ] **Step 8: Verify green, syntax, ignore behavior, and commit**

Run:

```bash
./tests/upstream_config_test.sh
./tests/update_test.sh
/bin/sh -n scripts/update scripts/lib/upstream.sh tests/test_helper.sh tests/upstream_config_test.sh tests/update_test.sh
git check-ignore -v Source/airdcpp-core
git status --short
git add scripts/update scripts/lib/upstream.sh tests/update_test.sh
git commit -m "feat: converge upstream checkout without data loss"
```

Expected: both suites print `PASS:` (rename the update suite's final line to `PASS: upstream update workflow`), syntax exits `0`, the root ignore rule matches, and one focused commit is created.

### Task 4: Prove Gate 1 against the real upstream and document operation

**Files:**
- Create: `tests/gate1_network_test.sh`
- Modify: `README.md`
- Modify: `docs/upstream-policy.md`
- Modify: `docs/build-and-release.md`

**Interfaces:**
- Consumes: production manifest, `scripts/update`, clean ignored checkout, canonical network access, and `AIRDCCORE_RUN_NETWORK_TESTS=1` consent.
- Produces: two missing-checkout reconstructions at the exact pin followed by a verified no-op; durable operator documentation.

- [ ] **Step 1: Write the opt-in Gate 1 test**

Create executable `tests/gate1_network_test.sh`:

```sh
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
git -C "$ROOT" check-ignore -q -- Source/airdcpp-core || fail "Source/airdcpp-core is not ignored"
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
```

Make the acceptance test runnable with `chmod +x tests/gate1_network_test.sh`.

Safety basis: the test validates root, ignore rule, non-symlink target, and clean checkout first. It moves the original and first reconstruction into a unique temporary directory. Failure restores the original; success retains the second verified reconstruction and removes only that validated temporary directory.

- [ ] **Step 2: Verify the acceptance test is opt-in**

Run `./tests/gate1_network_test.sh`.

Expected: nonzero with `set AIRDCCORE_RUN_NETWORK_TESTS=1`; the existing checkout is untouched.

- [ ] **Step 3: Run offline regression and syntax checks**

Run:

```bash
./tests/upstream_config_test.sh
./tests/update_test.sh
/bin/sh -n scripts/update scripts/lib/upstream.sh tests/test_helper.sh tests/upstream_config_test.sh tests/update_test.sh tests/gate1_network_test.sh
```

Expected: both offline suites print `PASS:`; syntax exits `0`; none accesses GitHub.

- [ ] **Step 4: Run Gate 1 with explicit network consent**

Project-facing command:

```bash
AIRDCCORE_RUN_NETWORK_TESTS=1 ./tests/gate1_network_test.sh
```

Codex command under this repository's RTK policy:

```bash
AIRDCCORE_RUN_NETWORK_TESTS=1 rtk ./tests/gate1_network_test.sh
```

Expected: `PASS: Gate 1 reconstructed twice at 55d51ceb817ec006d4ec844d9e3788e1b0ccc352 and the next update was a no-op`. If sandboxed network access fails, request the required approval and rerun this command; do not weaken the gate.

- [ ] **Step 5: Document user operation in README**

Add:

```markdown
## Upstream acquisition

Run `./scripts/update` from any directory to acquire or validate the pinned AirDC++ Core checkout. The command reads `config/upstream.env`, accepts no arguments, and leaves a correct checkout detached at the exact configured commit.

The command refuses dirty, symlinked, non-Git, unignored, or wrong-origin destinations. A correct checkout is a no-op and does not contact the network. Run offline tests with `./tests/upstream_config_test.sh` and `./tests/update_test.sh`.
```

Do not advertise build, package, or verification commands that do not exist.

- [ ] **Step 6: Document the update state machine**

Add to `docs/upstream-policy.md`:

```markdown
## Phase 1 command contract

`scripts/update` reads, but never evaluates, `config/upstream.env`. It accepts no arguments and resolves the project root from its own location. Missing checkouts are fetched into a validated temporary path and moved into place only after the exact commit is verified.

Existing checkouts must be non-symlink Git repositories with exactly the configured `origin`. Tracked, staged, untracked, or unknown ignored content blocks mutation. The two upstream-generated files `airdcpp/core/version.inc` and `airdcpp/core/localization/StringDefs.cpp` are allowed; they are removed only when changing commits to prevent stale generated state.

A clean checkout at another commit fetches and detaches at the pin. A checkout already detached at the pin exits without network access or state changes. Fetch failure leaves an existing HEAD/worktree intact and removes only a validated temporary staging checkout when acquisition began from a missing destination.

Run `AIRDCCORE_RUN_NETWORK_TESTS=1 ./tests/gate1_network_test.sh` to reconstruct the canonical checkout twice, verify the pin both times, and prove the next update is a no-op.
```

- [ ] **Step 7: Record Gate 1 evidence in the phase map**

Under Acquire in `docs/build-and-release.md`, add:

```markdown
Gate 1 is exercised by `tests/gate1_network_test.sh`. It is network-opt-in because it moves a validated clean checkout aside, reconstructs the canonical checkout twice, and retains the second verified reconstruction. Offline safety and failure paths are covered by `tests/upstream_config_test.sh` and `tests/update_test.sh`.
```

- [ ] **Step 8: Run final Phase 1 verification**

Run:

```bash
./tests/upstream_config_test.sh
./tests/update_test.sh
AIRDCCORE_RUN_NETWORK_TESTS=1 ./tests/gate1_network_test.sh
/bin/sh -n scripts/update scripts/lib/upstream.sh tests/test_helper.sh tests/upstream_config_test.sh tests/update_test.sh tests/gate1_network_test.sh
git check-ignore -v Source/airdcpp-core
git status --short --branch
git diff --check develop...HEAD
```

Expected:

- both offline suites and Gate 1 print `PASS:`;
- Gate 1 reports both exact reconstructions and the following no-op;
- shell syntax exits `0`;
- the root ignore rule matches `Source/airdcpp-core`;
- branch is `feature/reproducible-upstream-acquisition`;
- no Source, CMake, dependency, build, package, or Dist content is tracked; and
- the branch diff has no whitespace errors.

- [ ] **Step 9: Commit acceptance evidence and docs**

```bash
git add tests/gate1_network_test.sh README.md docs/upstream-policy.md docs/build-and-release.md
git commit -m "test: prove reproducible upstream acquisition gate"
```

- [ ] **Step 10: Review without merging or starting Phase 2**

Run:

```bash
git log --oneline --decorate develop..HEAD
git diff --stat develop...HEAD
git status --short --branch
```

Expected: four small logical commits on `feature/reproducible-upstream-acquisition`, a clean tracked worktree with the ignored checkout allowed, and no merge to `develop`. Hand the branch to the requested review workflow; do not start Phase 2.
