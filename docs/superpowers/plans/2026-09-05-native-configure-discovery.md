# Native Configure Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a deterministic, configure-only native macOS ARM64 discovery workflow and a reviewed Gate 2 report without compiling AirDC++ Core.

**Architecture:** Extend the stable `scripts/build` entry point with an explicit `--configure-only` mode backed by a focused POSIX shell library. The workflow records host and Homebrew discovery, preserves the first unmodified upstream configure attempt, then configures through a tracked top-level CMake wrapper and ARM64 toolchain into ignored `Build/airdcpp-core`; hermetic tests replace Homebrew, CMake, and Xcode tools with fixtures, while an opt-in live test produces normalized Gate 2 evidence.

**Tech Stack:** POSIX `/bin/sh`, CMake, Ninja, Git, Apple `xcrun`/Apple Clang/libc++, Homebrew discovery, pkg-config, and shell integration tests with no third-party test framework.

**Spec:** `docs/superpowers/specs/2026-09-04-airdc-core-macos-design.md`

## Global Constraints

- Implement Phase 2, **Native dependency and configure discovery**, and no later phase.
- Upstream is the ignored, non-submodule checkout `Source/airdcpp-core` from `https://github.com/airdcpp/airdcpp-core.git` at exact commit `55d51ceb817ec006d4ec844d9e3788e1b0ccc352`.
- `Source` is reserved for AirDC++ Core. Do not add third-party sources; future third-party source reconstruction belongs under ignored top-level `Dependencies`.
- Configure out of tree at `Build/airdcpp-core`; raw evidence belongs at `Build/gate2/raw`; package-resolution and host logs belong under `Build/gate2`.
- Configure `Release`, `BUILD_SHARED_LIBS=OFF`, `CMAKE_OSX_ARCHITECTURES=arm64`, Apple Clang/libc++ defaults, `CMAKE_CXX_STANDARD=20`, and explicit `ENABLE_NATPMP=OFF` and `ENABLE_TBB=OFF` for the deterministic Gate 2 baseline.
- Use `13.0` as the provisional broad-compatibility Gate 2 deployment target. Record it as a Phase 3 compile-validation candidate, not a final release minimum; do not add legacy compatibility patches merely to lower it.
- Homebrew is discovery-only and is not a publication contract. Tracked files must contain logical formula names and normalized `<HOMEBREW_PREFIX>` paths, never a machine-local prefix such as `/opt/homebrew`.
- Required host formulae for this phase are `cmake`, `ninja`, `pkgconf`, and `python@3.14`. Required dependency formulae are `boost`, `bzip2`, `zlib`, `openssl@3`, `miniupnpc`, `leveldb`, `libmaxminddb`, `snappy`, and `libiconv`.
- `Threads` is supplied by the native Apple platform. Do not install or add `WebSocket++`, `nlohmann-json`, npm, Boost `system`, `libnatpmp`, or TBB without new configure evidence and explicit review.
- `libnatpmp` and `tbb` remain recorded optional observations. They are not installation prerequisites because the Gate 2 baseline disables both features explicitly.
- Later execution may install only missing required formulae, only after explicit `--install-missing` consent. Ordinary configure-only execution must never install, upgrade, unlink, or remove packages.
- Preserve the unmodified pinned upstream configure command, stdout/stderr, exit status, upstream HEAD, and cleanliness before applying wrapper adaptations. Re-inspect `Source/airdcpp-core/CMakeLists.txt` immediately before proposing any patch.
- Prefer wrapper/module fixes. Add no upstream patch unless an unmodified failure proves it necessary and the wrapper cannot correct it; a patch requires its own failing test, evidence, deterministic application, and review.
- Gate 2 ends at successful CMake generation. Do not invoke `cmake --build`, Ninja, a compiler on core sources, archive creation, symbol/link closure, `Dist`, packaging, source-built dependencies, release work, Objective-C++, Swift/SPM, AppKit, or applications.
- Both hermetic and live reruns must be idempotent. Upstream HEAD, origin, tracked/staged/untracked state, and the two allowed ignored generated paths must remain unchanged by configure-only work.
- All failures are nonzero and actionable, naming the failed phase, relevant log, and corrective command. Do not capture secrets or broad environment dumps.
- Parent work stays on `feature/native-configure-discovery`, created from `develop`; execution does not create `master` or merge directly.

---

## Verified planning observations

The plan was written after read-only verification on 2026-09-05:

- host: `arm64`, Xcode `26.6` (`17F113`), Apple Clang `21.0.0`, Python `3.14.3`, Homebrew prefix `/opt/homebrew`;
- installed: `libiconv 1.18`, `miniupnpc 2.3.3`, `openssl@3 3.6.1`, `pkgconf 2.5.1`, `python@3.14 3.14.3_1`;
- not installed: `cmake`, `ninja`, `boost`, `bzip2`, `zlib`, `leveldb`, `libmaxminddb`, `snappy`, `libnatpmp`, `tbb`;
- pinned upstream native lookups: BZip2, ZLIB, OpenSSL, miniupnpc, leveldb, maxminddb, Boost `regex`/`thread`, static-build Snappy, Threads, and Iconv;
- pinned upstream gaps to test rather than assume: missing includes for `CheckFunctionExists` and `CheckIncludeFiles`, parent-provided resource/config/version variables, and package/config target-name compatibility;
- `unofficial-minizip` is inside the upstream `WIN32` branch and is not a native macOS prerequisite.

## Planned file map

| File | Responsibility |
| --- | --- |
| `config/native-discovery.env` | Inert, prefix-free Gate 2 policy and exact formula inventory |
| `scripts/lib/native-discovery.sh` | Strict policy parser, host/formula inventory, safe install calculation, normalized evidence helpers |
| `scripts/build` | Stable entry point; Phase 2 supports only `--configure-only`, with optional explicit `--install-missing` |
| `CMakeLists.txt` | Native wrapper that supplies standalone check modules, parent variables, and the upstream subdirectory |
| `cmake/toolchains/macos-arm64.cmake` | Resolve `xcrun` Apple compilers and enforce ARM64/deployment policy |
| `cmake/modules/Findmaxminddb.cmake` | Conditional evidence-backed adapter, created only if the live trace proves Homebrew metadata lacks upstream's requested target |
| `tests/native_discovery_test.sh` | Hermetic policy, host inventory, formula detection, normalization, and install-consent tests |
| `tests/configure_test.sh` | Hermetic raw/wrapper configure orchestration, idempotence, source-cleanliness, and no-compile tests |
| `tests/gate2_configure_test.sh` | Opt-in live raw-first plus wrapped configure Gate 2 |
| `docs/gate2-native-configure-report.md` | Reviewed, normalized host/package/configure evidence |
| `README.md` | Configure-only user entry point and Phase 2 status |
| `docs/dependencies.md` | Discovery-only Homebrew inventory and transition boundary |
| `docs/build-and-release.md` | Gate 2 command, output boundary, and no-compile scope |

## Command contract

Public commands:

```bash
./scripts/build --configure-only
./scripts/build --configure-only --install-missing
AIRDCCORE_RUN_GATE2=1 ./tests/gate2_configure_test.sh
```

`--configure-only` checks prerequisites and configures without installing or compiling. `--install-missing` is the only package-mutation consent and may pass only the currently missing required allowlisted formulae to one `brew install` invocation. No arguments, unknown arguments, `--install-missing` without `--configure-only`, and every non-configure build mode exit `64` with usage text until Phase 3.

Stable evidence paths:

```text
Build/gate2/host-tools.tsv
Build/gate2/homebrew-formulae.tsv
Build/gate2/raw/configure.command
Build/gate2/raw/configure.log
Build/gate2/raw/configure.status
Build/gate2/package-resolution.tsv
Build/gate2/wrapped-configure.log
Build/gate2/wrapped-configure.status
Build/airdcpp-core/
```

Each TSV is sorted by its first field and uses tabs. Status files contain one decimal exit code plus a newline. `configure.command` is a shell-escaped diagnostic record, not an executable script. Reruns replace these known files atomically through sibling `.tmp.$$` files and never append stale evidence.

### Task 1: Add strict native-discovery policy and normalized host inventory

**Files:**
- Create: `config/native-discovery.env`
- Create: `scripts/lib/native-discovery.sh`
- Create: `tests/native_discovery_test.sh`
- Modify: `tests/test_helper.sh`

**Interfaces:**
- Consumes: Phase 1 `PROJECT_ROOT` convention and `tests/test_helper.sh` assertions.
- Produces: `load_native_discovery_config PATH`; `validate_native_host`; `write_host_inventory OUTPUT`; `normalize_evidence INPUT OUTPUT`; exported `DISCOVERY_*` policy values.

- [ ] **Step 1: Extend hermetic test helpers with executable fixtures**

Add these helpers to `tests/test_helper.sh`:

```sh
assert_not_contains() {
  haystack=$1
  needle=$2
  label=$3
  case "$haystack" in
    *"$needle"*) fail "$label: unexpected output containing [$needle]" ;;
    *) ;;
  esac
}

write_executable() {
  executable_path=$1
  shift
  mkdir -p "$(dirname -- "$executable_path")"
  printf '%s\n' "$@" > "$executable_path"
  chmod +x "$executable_path"
}
```

- [ ] **Step 2: Write the failing policy and host-inventory tests**

Create executable `tests/native_discovery_test.sh`. It must create a temporary case root, copy the production policy/library, and prepend fixture executables for `uname`, `xcodebuild`, `xcrun`, `python3`, and `brew`. The fixture outputs are:

```text
uname -m                              -> arm64
xcodebuild -version                   -> Xcode 26.6 / Build version 17F113
xcrun --find clang                    -> /Fixture/Xcode/usr/bin/clang
xcrun --find clang++                  -> /Fixture/Xcode/usr/bin/clang++
xcrun clang --version                 -> Apple clang version 21.0.0
python3 --version                     -> Python 3.14.3
brew --prefix                         -> /Fixture/Homebrew
brew --version                        -> Homebrew 5.0.0
brew list --versions FORMULA          -> fixture table or exit 1
```

Exercise these exact cases:

```sh
load_native_discovery_config "$CASE_ROOT/config/native-discovery.env"
assert_eq "$DISCOVERY_BUILD_TYPE" Release "build type"
assert_eq "$DISCOVERY_ARCHITECTURE" arm64 "architecture"
assert_eq "$DISCOVERY_CXX_STANDARD" 20 "C++ standard"
assert_eq "$DISCOVERY_DEPLOYMENT_TARGET" 13.0 "deployment target"
assert_eq "$DISCOVERY_ENABLE_NATPMP" OFF "NAT-PMP policy"
assert_eq "$DISCOVERY_ENABLE_TBB" OFF "TBB policy"
validate_native_host
write_host_inventory "$CASE_ROOT/Build/gate2/host-tools.tsv"
assert_contains "$(cat "$CASE_ROOT/Build/gate2/host-tools.tsv")" 'architecture\tarm64' "host architecture"
assert_contains "$(cat "$CASE_ROOT/Build/gate2/host-tools.tsv")" 'compiler_id\tAppleClang' "compiler identity"
```

Also assert that duplicate/unknown/missing keys, whitespace-bearing values, non-ARM64 hosts, a non-Apple compiler, missing `xcrun`, and a config containing `HOMEBREW_PREFIX=/opt/homebrew` fail without creating `Build`. Feed a fixture log containing the case root, `/Users/example`, and `/Fixture/Homebrew`; assert `normalize_evidence` replaces the case root and Homebrew prefix with `<PROJECT_ROOT>` and `<HOMEBREW_PREFIX>` and rejects the unrelated home path rather than tracking it.

- [ ] **Step 3: Run the focused test to verify RED**

Run: `rtk ./tests/native_discovery_test.sh`

Expected: FAIL because `config/native-discovery.env` and `scripts/lib/native-discovery.sh` do not exist.

- [ ] **Step 4: Add the inert discovery policy**

Create `config/native-discovery.env` with exactly:

```text
DISCOVERY_BUILD_TYPE=Release
DISCOVERY_ARCHITECTURE=arm64
DISCOVERY_CXX_STANDARD=20
DISCOVERY_DEPLOYMENT_TARGET=13.0
DISCOVERY_ENABLE_NATPMP=OFF
DISCOVERY_ENABLE_TBB=OFF
DISCOVERY_HOST_FORMULAE=cmake,ninja,pkgconf,python@3.14
DISCOVERY_DEPENDENCY_FORMULAE=boost,bzip2,zlib,openssl@3,miniupnpc,leveldb,libmaxminddb,snappy,libiconv
DISCOVERY_OPTIONAL_FORMULAE=libnatpmp,tbb
```

The parser must allow only these nine keys, reject duplicates, require every key once, validate fixed enumerations and comma-separated formula tokens with `^[A-Za-z0-9@+._-][A-Za-z0-9@+._,-]*$`, and never source or evaluate the file.

- [ ] **Step 5: Implement host validation and evidence normalization**

Create `scripts/lib/native-discovery.sh` with these focused parser and validation mechanics (the inventory writer uses sibling temporary files and `LC_ALL=C sort` before `mv`):

```sh
discovery_error() { printf 'build: error: %s\n' "$*" >&2; }
discovery_die() { discovery_error "$*"; exit 1; }

validate_formula_csv() {
  [ -n "$1" ] && printf '%s\n' "$1" |
    grep -Eq '^[A-Za-z0-9@+._-]+(,[A-Za-z0-9@+._-]+)*$'
}

load_native_discovery_config() {
  discovery_config=$1
  [ -f "$discovery_config" ] || { discovery_error "missing file: $discovery_config"; return 1; }
  seen_keys=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; *=*) key=${line%%=*}; value=${line#*=} ;;
      *) discovery_error "malformed line: $line"; return 1 ;; esac
    case ",$seen_keys," in *",$key,"*) discovery_error "duplicate key: $key"; return 1 ;; esac
    case "$key" in
      DISCOVERY_BUILD_TYPE) DISCOVERY_BUILD_TYPE=$value ;;
      DISCOVERY_ARCHITECTURE) DISCOVERY_ARCHITECTURE=$value ;;
      DISCOVERY_CXX_STANDARD) DISCOVERY_CXX_STANDARD=$value ;;
      DISCOVERY_DEPLOYMENT_TARGET) DISCOVERY_DEPLOYMENT_TARGET=$value ;;
      DISCOVERY_ENABLE_NATPMP) DISCOVERY_ENABLE_NATPMP=$value ;;
      DISCOVERY_ENABLE_TBB) DISCOVERY_ENABLE_TBB=$value ;;
      DISCOVERY_HOST_FORMULAE) DISCOVERY_HOST_FORMULAE=$value ;;
      DISCOVERY_DEPENDENCY_FORMULAE) DISCOVERY_DEPENDENCY_FORMULAE=$value ;;
      DISCOVERY_OPTIONAL_FORMULAE) DISCOVERY_OPTIONAL_FORMULAE=$value ;;
      *) discovery_error "unknown key: $key"; return 1 ;;
    esac
    seen_keys=${seen_keys:+$seen_keys,}$key
  done < "$discovery_config"
  [ "$seen_keys" = 'DISCOVERY_BUILD_TYPE,DISCOVERY_ARCHITECTURE,DISCOVERY_CXX_STANDARD,DISCOVERY_DEPLOYMENT_TARGET,DISCOVERY_ENABLE_NATPMP,DISCOVERY_ENABLE_TBB,DISCOVERY_HOST_FORMULAE,DISCOVERY_DEPENDENCY_FORMULAE,DISCOVERY_OPTIONAL_FORMULAE' ] || {
    discovery_error 'missing or out-of-order native discovery keys'; return 1;
  }
  [ "$DISCOVERY_BUILD_TYPE" = Release ] && [ "$DISCOVERY_ARCHITECTURE" = arm64 ] &&
    [ "$DISCOVERY_CXX_STANDARD" = 20 ] && [ "$DISCOVERY_DEPLOYMENT_TARGET" = 13.0 ] &&
    [ "$DISCOVERY_ENABLE_NATPMP" = OFF ] && [ "$DISCOVERY_ENABLE_TBB" = OFF ] || {
      discovery_error 'invalid fixed native discovery policy'; return 1;
    }
  validate_formula_csv "$DISCOVERY_HOST_FORMULAE" &&
    validate_formula_csv "$DISCOVERY_DEPENDENCY_FORMULAE" &&
    validate_formula_csv "$DISCOVERY_OPTIONAL_FORMULAE" || {
      discovery_error 'invalid formula inventory'; return 1;
    }
}

validate_native_host() {
  DISCOVERY_HOST_ARCH=$(uname -m) || discovery_die 'uname failed'
  [ "$DISCOVERY_HOST_ARCH" = arm64 ] || discovery_die "host architecture must be arm64"
  DISCOVERY_XCODE=$(xcodebuild -version) || discovery_die 'xcodebuild failed'
  DISCOVERY_CC=$(xcrun --find clang) || discovery_die 'xcrun could not resolve clang'
  DISCOVERY_CXX=$(xcrun --find clang++) || discovery_die 'xcrun could not resolve clang++'
  DISCOVERY_CLANG=$(xcrun clang --version) || discovery_die 'clang version probe failed'
  case "$DISCOVERY_CLANG" in 'Apple clang version '*) ;; *) discovery_die 'Apple Clang is required' ;; esac
  DISCOVERY_PYTHON=$(python3 --version) || discovery_die 'Python 3 probe failed'
  DISCOVERY_BREW_PREFIX=$(brew --prefix) || discovery_die 'Homebrew prefix probe failed'
  DISCOVERY_BREW_VERSION=$(brew --version) || discovery_die 'Homebrew version probe failed'
}

write_host_inventory() {
  output=$1; mkdir -p "$(dirname -- "$output")"; temporary=$output.tmp.$$
  {
    printf 'architecture\t%s\n' "$DISCOVERY_HOST_ARCH"
    printf 'compiler_id\tAppleClang\ncompiler_version\t%s\n' "${DISCOVERY_CLANG#Apple clang version }"
    printf 'homebrew_version\t%s\n' "${DISCOVERY_BREW_VERSION#Homebrew }"
    printf 'python_version\t%s\n' "${DISCOVERY_PYTHON#Python }"
    printf 'xcode\t%s\n' "$(printf '%s\n' "$DISCOVERY_XCODE" | tr '\n' ' ')"
  } | LC_ALL=C sort > "$temporary" && mv "$temporary" "$output"
}

sed_pattern() {
  printf '%s\n' "$1" | sed 's/[][\\.*^$|&]/\\&/g'
}

normalize_evidence() {
  input=$1; output=$2; temporary=$output.tmp.$$
  project_pattern=$(sed_pattern "$PROJECT_ROOT")
  brew_pattern=$(sed_pattern "$DISCOVERY_BREW_PREFIX")
  sed "s|$project_pattern|<PROJECT_ROOT>|g; s|$brew_pattern|<HOMEBREW_PREFIX>|g" \
    "$input" > "$temporary"
  if grep -Eq '/Users/|/home/' "$temporary"; then rm -f "$temporary"; discovery_die 'unnormalized home path in evidence'; fi
  mv "$temporary" "$output"
}
```

The `sed_pattern` helper escapes regex and delimiter metacharacters in both replacement inputs; the test fixture must include those characters in its case root. `write_host_inventory` writes sorted logical fields and versions without absolute compiler or Homebrew paths. `normalize_evidence` must additionally fail if the output still contains the exact project root or Brew prefix after substitution.

- [ ] **Step 6: Verify GREEN and commit**

Run:

```bash
rtk ./tests/upstream_config_test.sh
rtk ./tests/update_test.sh
rtk ./tests/native_discovery_test.sh
rtk /bin/sh -n scripts/lib/native-discovery.sh tests/native_discovery_test.sh tests/test_helper.sh
rtk git diff --check
```

Expected: all three suites print `PASS:` and syntax/diff checks exit `0`.

Commit:

```bash
rtk git add config/native-discovery.env scripts/lib/native-discovery.sh tests/native_discovery_test.sh tests/test_helper.sh
rtk git commit -m "feat: record native discovery policy"
```

### Task 2: Detect and install only missing allowlisted Homebrew prerequisites

**Files:**
- Modify: `scripts/lib/native-discovery.sh`
- Create: `scripts/build`
- Modify: `tests/native_discovery_test.sh`

**Interfaces:**
- Consumes: parsed `DISCOVERY_HOST_FORMULAE`, `DISCOVERY_DEPENDENCY_FORMULAE`, and `DISCOVERY_OPTIONAL_FORMULAE`.
- Produces: `formulae_to_lines CSV`; `formula_version FORMULA`; `write_formula_inventory OUTPUT`; `missing_required_formulae`; `install_missing_formulae`; public `scripts/build --configure-only [--install-missing]`.

- [ ] **Step 1: Add failing formula inventory and consent tests**

Extend the fake `brew` fixture to log every invocation and return installed versions for `libiconv`, `miniupnpc`, `openssl@3`, `pkgconf`, and `python@3.14`, while returning `1` for the other required/optional names. Add assertions that:

```sh
missing=$(missing_required_formulae)
assert_eq "$missing" "boost
bzip2
cmake
leveldb
libmaxminddb
ninja
snappy
zlib" "sorted missing required formulae"
write_formula_inventory "$CASE_ROOT/Build/gate2/homebrew-formulae.tsv"
assert_contains "$(cat "$CASE_ROOT/Build/gate2/homebrew-formulae.tsv")" 'libnatpmp\toptional\tmissing' "optional observation"
assert_contains "$(cat "$CASE_ROOT/Build/gate2/homebrew-formulae.tsv")" 'miniupnpc\trequired\t2.3.3' "installed dependency"
```

Invoke `scripts/build --configure-only` and assert it fails with the exact missing list and corrective command, without any `brew install`. Invoke `scripts/build --install-missing` and unknown modes and assert exit `64`. Invoke `scripts/build --configure-only --install-missing`; assert exactly one logged mutation:

```text
install boost bzip2 cmake leveldb libmaxminddb ninja snappy zlib
```

Then make the fixture report all required formulae installed and assert the same command performs no install.

- [ ] **Step 2: Run the focused test to verify RED**

Run: `rtk ./tests/native_discovery_test.sh`

Expected: FAIL because formula inventory functions and `scripts/build` do not exist.

- [ ] **Step 3: Implement deterministic formula classification**

Add the five produced functions to `scripts/lib/native-discovery.sh`. Required output is the sorted union of host and dependency formulae; optional formulae appear in inventory but never in `missing_required_formulae`. Query only `brew list --versions "$formula"`; do not use `brew update`, `brew upgrade`, remote JSON APIs, or dependency expansion. Record the entire returned version string after validating it contains only formula/version tokens.

`install_missing_formulae` must materialize the sorted missing set, return without calling Brew when empty, and otherwise invoke exactly:

```sh
brew install $missing_words
```

Because field splitting is intentional here, validate every formula token before building `missing_words`; no value comes from arbitrary environment input.

- [ ] **Step 4: Add the Phase 2 build entry point**

Create executable `scripts/build` with this option state machine:

```sh
#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$PROJECT_ROOT/scripts/lib/native-discovery.sh"
configure_only=0
install_missing=0
for argument in "$@"; do
  case "$argument" in
    --configure-only) [ "$configure_only" -eq 0 ] || exit 64; configure_only=1 ;;
    --install-missing) [ "$install_missing" -eq 0 ] || exit 64; install_missing=1 ;;
    *) printf 'usage: %s --configure-only [--install-missing]\n' "$0" >&2; exit 64 ;;
  esac
done
[ "$configure_only" -eq 1 ] || { printf 'usage: %s --configure-only [--install-missing]\n' "$0" >&2; exit 64; }

load_native_discovery_config "$PROJECT_ROOT/config/native-discovery.env" || exit 1
validate_native_host
if [ "$install_missing" -eq 1 ]; then install_missing_formulae; fi
missing=$(missing_required_formulae)
[ -z "$missing" ] || discovery_die "missing required Homebrew formulae:\n$missing\nrerun with --configure-only --install-missing after approving installation"
write_host_inventory "$PROJECT_ROOT/Build/gate2/host-tools.tsv"
write_formula_inventory "$PROJECT_ROOT/Build/gate2/homebrew-formulae.tsv"
run_configure_discovery "$PROJECT_ROOT"
```

`run_configure_discovery` is deliberately undefined until Task 3 so the test remains focused on prerequisite behavior.

- [ ] **Step 5: Verify GREEN and commit**

Run the three offline suites and shell syntax. The native-discovery fixture must stop immediately before the undefined configure runner after proving prerequisite behavior; use a test-only sourced function `run_configure_discovery() { return 0; }`, not production branching.

Commit:

```bash
rtk git add scripts/build scripts/lib/native-discovery.sh tests/native_discovery_test.sh
rtk git commit -m "feat: gate configure prerequisites"
```

### Task 3: Preserve raw upstream configure evidence and orchestrate configure-only runs

**Files:**
- Modify: `scripts/lib/native-discovery.sh`
- Modify: `scripts/build`
- Create: `tests/configure_test.sh`

**Interfaces:**
- Consumes: Phase 1 `load_upstream_config`, `checkout_changes`, exact checkout identity, parsed native-discovery policy, and required formula inventory.
- Produces: `validate_configure_source ROOT`; `brew_prefix_paths`; `write_command_record FILE ARGS...`; `run_logged_command LOG STATUS COMMAND...`; `write_package_resolution ROOT OUTPUT`; `run_raw_configure ROOT`; `run_wrapped_configure ROOT`; `assert_configure_scope ROOT`; `run_configure_discovery ROOT`.

- [ ] **Step 1: Create a hermetic configure fixture**

Create executable `tests/configure_test.sh`. Build a case project containing the production scripts/config, a minimal parent Git repository, and an ignored `Source/airdcpp-core` Git fixture at the configured commit. Its fixture `CMakeLists.txt` must fail raw configuration with:

```cmake
cmake_minimum_required(VERSION 3.16)
project(Fixture LANGUAGES C CXX)
CHECK_FUNCTION_EXISTS(posix_fadvise HAVE_POSIX_FADVISE)
```

Provide fake `cmake`, `brew`, `xcrun`, `uname`, `xcodebuild`, and `python3`. Fake CMake must record every argument and:

- fail the source path `Source/airdcpp-core` with `Unknown CMake command CHECK_FUNCTION_EXISTS`;
- succeed only for the parent wrapper source;
- create `CMakeCache.txt` and `build.ninja` in the `-B` directory;
- fail the test immediately if invoked with `--build`;
- write a deterministic package trace containing fixture Homebrew paths.

- [ ] **Step 2: Write failing orchestration and safety assertions**

Assert a run creates all stable evidence paths, preserves raw status `1` and its failure text, then successfully creates `Build/airdcpp-core/CMakeCache.txt`. Assert the wrapped invocation contains exactly:

```text
-G Ninja
-DCMAKE_BUILD_TYPE=Release
-DBUILD_SHARED_LIBS=OFF
-DCMAKE_OSX_ARCHITECTURES=arm64
-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
-DCMAKE_CXX_STANDARD=20
-DCMAKE_CXX_STANDARD_REQUIRED=ON
-DCMAKE_CXX_EXTENSIONS=OFF
-DENABLE_NATPMP=OFF
-DENABLE_TBB=OFF
-DCMAKE_TOOLCHAIN_FILE=<PROJECT_ROOT>/cmake/toolchains/macos-arm64.cmake
```

Run twice and compare checksums of the normalized command/status/inventory files; assert equality. Before and after, compare upstream `HEAD`, origin URLs, `git status --porcelain=v1`, `git diff --cached --quiet`, `git ls-files --others --exclude-standard`, and the content/presence of allowed ignored `version.inc` and `StringDefs.cpp`. Assert no `.o`, `.a`, `.dylib`, `compile_commands.json`, `Dependencies`, or `Dist` path exists and no `cmake --build`/`ninja`/compiler invocation was logged.

Add failing cases for wrong upstream commit, wrong/multiple origins, tracked/staged/untracked/unknown ignored changes, symlinked `Source` or checkout, unresolved `Build`, and a nonzero wrapped configure. Each failure must name the log and corrective action and preserve source/build state outside the validated Gate 2 directories.

- [ ] **Step 3: Run the focused test to verify RED**

Run: `rtk ./tests/configure_test.sh`

Expected: FAIL because the configure runner functions are absent.

- [ ] **Step 4: Implement safe raw-first configure orchestration**

In `validate_configure_source`, reuse Phase 1 parsing/classification by sourcing `scripts/lib/upstream.sh`; require the exact manifest URL/commit, clean detached HEAD, one canonical origin URL, non-symlink parent/checkout, and no unsafe changes. Snapshot allowed generated paths before configuration and verify them byte-for-byte afterward.

`brew_prefix_paths` queries `brew --prefix FORMULA` only for installed required dependency formulae, validates every absolute path is under the current `brew --prefix`, and prints a semicolon-separated list in formula-name order. It also exports a pkg-config search list from each `lib/pkgconfig` and `share/pkgconfig` directory that exists.

`run_logged_command` must write stdout/stderr to a sibling temporary log, capture the real exit code with `set +e`, atomically replace log/status, and return that code. `write_command_record` must render each argument as a single-quoted diagnostic token after rejecting newline and single-quote characters.

`run_raw_configure` removes only validated `Build/gate2/raw/build`, records the unmodified command, and invokes CMake with `-S "$ROOT/Source/airdcpp-core"`, `-B "$ROOT/Build/gate2/raw/build"`, Ninja, toolchain/policy flags, and runtime dependency prefix paths. A raw failure is expected evidence and does not abort; a raw success is recorded without weakening the later wrapper gate.

`run_wrapped_configure` removes only validated `Build/airdcpp-core`, records package discovery using one `cmake --debug-find-pkg=BZip2,ZLIB,OpenSSL,miniupnpc,leveldb,maxminddb,Boost,Snappy,Threads,Iconv` invocation, and requires success. `write_package_resolution` parses only absolute resolved config/library/include paths from that log, requires one logical row for every required package, replaces the validated Brew prefix with `<HOMEBREW_PREFIX>`, and writes sorted `package<TAB>version<TAB>normalized-path` rows; it fails on missing, duplicate, unresolved, project-external non-system, or user-home paths. Map package names to formula-version rows explicitly: `BZip2=bzip2`, `ZLIB=zlib`, `OpenSSL=openssl@3`, `miniupnpc=miniupnpc`, `leveldb=leveldb`, `maxminddb=libmaxminddb`, `Boost=boost`, `Snappy=snappy`, and `Iconv=libiconv`; record `Threads` as version `system` at path `Apple-SDK`. `run_configure_discovery` validates/snapshots source, writes inventories, runs raw then wrapped configure, writes package resolution, calls `assert_configure_scope`, and revalidates every source snapshot.

- [ ] **Step 5: Verify GREEN and commit**

Run all four offline suites, shell syntax, ignore checks for `Build/`, and diff checks.

Commit:

```bash
rtk git add scripts/build scripts/lib/native-discovery.sh tests/configure_test.sh
rtk git commit -m "feat: preserve raw configure discovery"
```

### Task 4: Add the native ARM64 wrapper and toolchain

**Files:**
- Create: `CMakeLists.txt`
- Create: `cmake/toolchains/macos-arm64.cmake`
- Modify: `tests/configure_test.sh`

**Interfaces:**
- Consumes: exact policy flags and runtime `CMAKE_PREFIX_PATH`/`PKG_CONFIG_PATH` assembled by Task 3.
- Produces: wrapper target `airdcpp`; cache contract `AIRDCCORE_GATE2=ON`; wrapper module-search hook; Apple compiler/toolchain validation.

- [ ] **Step 1: Re-inspect the pinned upstream immediately before adaptation**

Run and save evidence under ignored `Build/gate2/upstream-cmake-inspection.txt`:

```bash
rtk git -C Source/airdcpp-core rev-parse HEAD
rtk git -C Source/airdcpp-core status --porcelain=v1 --untracked-files=all
rtk rg -n "CHECK_FUNCTION_EXISTS|CHECK_INCLUDE_FILES|find_package|RESOURCE_DIRECTORY|GLOBAL_CONFIG_DIRECTORY|VERSION|TAG_APPLICATION|APPLICATION_ID" Source/airdcpp-core/CMakeLists.txt
```

Expected: exact pin, no unsafe changes, missing module includes, the verified package lookups, and parent variables. If this evidence differs, stop and revise the plan before adding a patch or adapter.

- [ ] **Step 2: Add failing hermetic wrapper/toolchain assertions**

Extend `tests/configure_test.sh` so the fake CMake reads the wrapper and toolchain files and rejects the invocation unless their required statements are present. This remains offline and does not require CMake to be installed before Task 5. Assert failure before the files exist, then assert the wrapper:

- includes `CheckFunctionExists` and `CheckIncludeFiles` before `add_subdirectory`;
- sets nonempty deterministic `VERSION=0.0.0-gate2`, `TAG_APPLICATION=AirDCCore`, `APPLICATION_ID=com.aibece.airdccore.gate2`, `RESOURCE_DIRECTORY=<binary>/resources`, and `GLOBAL_CONFIG_DIRECTORY=<binary>/config`;
- rejects non-Apple compiler IDs and non-ARM64 architecture;
- prepends a wrapper-owned module directory so a later evidence-backed adapter can be added without editing upstream;
- never writes the upstream source tree.

The fake `xcrun` must resolve fixture `clang`/`clang++` paths. Add negative cases that rewrite the fake CMake compiler identity or architecture result and verify the wrapper contract fails. Real CMake syntax and target validation occur in the Task 5 live gate after prerequisite approval.

- [ ] **Step 3: Run the focused test to verify RED**

Run: `rtk ./tests/configure_test.sh`

Expected: FAIL because the wrapper and toolchain files do not exist.

- [ ] **Step 4: Create the top-level configure-only wrapper**

Create `CMakeLists.txt` with this contract:

```cmake
cmake_minimum_required(VERSION 3.25)
project(AirDCCoreNativeDiscovery LANGUAGES C CXX)

if(NOT AIRDCCORE_GATE2)
  message(FATAL_ERROR "This wrapper currently supports Gate 2 configure discovery only")
endif()
if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "AppleClang")
  message(FATAL_ERROR "Gate 2 requires Apple Clang")
endif()
if(NOT CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
  message(FATAL_ERROR "Gate 2 requires CMAKE_OSX_ARCHITECTURES=arm64")
endif()

include(CheckFunctionExists)
include(CheckIncludeFiles)
list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/modules")
set(VERSION "0.0.0-gate2")
set(TAG_APPLICATION "AirDCCore")
set(APPLICATION_ID "com.aibece.airdccore.gate2")
set(RESOURCE_DIRECTORY "${CMAKE_BINARY_DIR}/resources")
set(GLOBAL_CONFIG_DIRECTORY "${CMAKE_BINARY_DIR}/config")
add_subdirectory(Source/airdcpp-core airdcpp-core)
```

Task 3 must add `-DAIRDCCORE_GATE2=ON` to the wrapped invocation only.

- [ ] **Step 5: Create the native toolchain**

Create `cmake/toolchains/macos-arm64.cmake` that finds `xcrun`, resolves `clang` and `clang++` with `execute_process`, fails on missing/nonzero/empty results, sets `CMAKE_C_COMPILER` and `CMAKE_CXX_COMPILER` as cache file paths before `project()`, and sets `CMAKE_OSX_ARCHITECTURES=arm64`. Require `CMAKE_OSX_DEPLOYMENT_TARGET` from the caller and reject any architecture other than `arm64`; do not add explicit `-stdlib` flags because Apple Clang's libc++ default is the contract.

Do not add find modules or any upstream patch in this task. A later live mismatch must enter the Task 5 review/fix loop with preserved raw package evidence first.

- [ ] **Step 6: Verify GREEN and commit**

Run all offline suites, hermetic wrapper/toolchain fixture coverage, shell syntax, and diff checks. Assert Git tracks no file below `Source`, `Dependencies`, `Build`, or `Dist`.

Commit:

```bash
rtk git add CMakeLists.txt cmake/toolchains/macos-arm64.cmake tests/configure_test.sh scripts/lib/native-discovery.sh
rtk git commit -m "feat: add native configure wrapper"
```

### Task 5: Prove live Gate 2, generate normalized evidence, and document the boundary

**Files:**
- Create: `tests/gate2_configure_test.sh`
- Create: `docs/gate2-native-configure-report.md`
- Conditionally create after live evidence: `cmake/modules/Findmaxminddb.cmake` or another single-package wrapper adapter
- Modify: `scripts/lib/native-discovery.sh`
- Modify: `README.md`
- Modify: `docs/dependencies.md`
- Modify: `docs/build-and-release.md`

**Interfaces:**
- Consumes: `scripts/build --configure-only`, exact Phase 1 checkout, wrapper/toolchain, raw/wrapped logs, and explicit `AIRDCCORE_RUN_GATE2=1` consent.
- Produces: two successful configure-only runs, stable normalized package-resolution evidence, `write_gate2_report ROOT OUTPUT`, and the reviewed Gate 2 report.

- [ ] **Step 1: Write the opt-in live Gate 2 test before any live install/configure**

Create executable `tests/gate2_configure_test.sh`. The consent check must be the first operation after resolving `ROOT`; it must occur before sourcing helpers that create files:

```sh
[ "${AIRDCCORE_RUN_GATE2:-0}" = 1 ] || {
  printf 'FAIL: set AIRDCCORE_RUN_GATE2=1 to run the live Gate 2 configure test\n' >&2
  exit 1
}
```

After consent, validate the parent root, ignored `Source/airdcpp-core` and `Build`, exact manifest/pin/origin, clean detached source, non-symlink paths, and installed prerequisites. Snapshot upstream identity and allowed generated files. Run `scripts/build --configure-only` twice and assert both succeed; compare normalized evidence and `CMakeCache.txt` policy keys across runs.

The first live run is also the first real-CMake validation of the wrapper, toolchain, and imported targets. It must verify that `CMAKE_C_COMPILER_ID` and `CMAKE_CXX_COMPILER_ID` are `AppleClang`, target `airdcpp` exists, all imported targets required by the pinned upstream resolve, and the selected Ninja generator completes generation without invoking a build.

Assert raw evidence exists regardless of raw success/failure, wrapped status is `0`, generator is Ninja, all nine policy flags have exact values, compiler IDs are AppleClang, resolved architecture is arm64, and every required package appears once in `package-resolution.tsv` with version and normalized resolved path. Assert optional `libnatpmp`/`tbb` are recorded as disabled regardless of host installation.

Finally assert upstream snapshots are unchanged; no `.o`, `.a`, `.dylib`, compiler command, Ninja build command, `Dependencies`, or `Dist` exists. Print:

```text
PASS: Gate 2 configured the pinned AirDC++ Core twice for native arm64 without compiling
```

- [ ] **Step 2: Verify opt-in and offline regression before installing anything**

Run:

```bash
rtk ./tests/gate2_configure_test.sh
rtk ./tests/upstream_config_test.sh
rtk ./tests/update_test.sh
rtk ./tests/native_discovery_test.sh
rtk ./tests/configure_test.sh
```

Expected: Gate 2 exits nonzero with the consent message and creates/modifies nothing; all four offline suites print `PASS:` and make no network request.

- [ ] **Step 3: Print the exact missing prerequisite set and request approval**

Run `rtk ./scripts/build --configure-only`.

On the verified planning host, expected missing formulae are:

```text
boost
bzip2
cmake
leveldb
libmaxminddb
ninja
snappy
zlib
```

If the set differs, record the current sorted set; do not add packages outside the configured allowlist. Before the mutating command, request explicit user approval to run:

```bash
rtk ./scripts/build --configure-only --install-missing
```

This command may install only the reported missing required formulae. A refusal or Homebrew failure stops Gate 2 without weakening checks.

- [ ] **Step 4: Run and preserve the unmodified upstream configure attempt**

Immediately before configuration, repeat the Task 4 upstream CMake inspection and source snapshots. Run the approved install command if needed, then run:

```bash
rtk ./scripts/build --configure-only
```

Expected raw evidence on the pinned snapshot includes the unmodified source command and either success or the known `CHECK_FUNCTION_EXISTS`/`CHECK_INCLUDE_FILES` standalone failure. Do not edit upstream. If the raw failure differs, stop and review the log before changing the wrapper, module adapters, flags, or dependency set.

- [ ] **Step 5: Resolve live wrapper mismatches only through evidence-backed fix loops**

If the wrapped configure fails, classify the exact failure:

- missing configured required formula: correct the prerequisite allowlist only when upstream `find_package` evidence names it;
- target-name/config mismatch: add the smallest wrapper-side `Find<Package>.cmake` that creates exactly the upstream-requested target from validated CMake/pkg-config metadata;
- missing parent variable/check module: set/include it in the top-level wrapper;
- upstream defect not correctable from the wrapper: stop, re-inspect the pinned file, add a failing hermetic test and deterministic patch proposal under `cmake/patches/airdcpp-core`, and require user/reviewer approval before applying it.

Never add WebSocket++, nlohmann-json, npm, Boost `system`, source-built dependencies, or compile flags without direct log evidence. Repeat the focused RED/GREEN test and task review after each accepted change.

For the currently anticipated `maxminddb` mismatch, create `cmake/modules/Findmaxminddb.cmake` only if the live trace proves the installed `libmaxminddb` formula does not supply the requested CMake config/target. The minimal accepted adapter is:

```cmake
find_package(PkgConfig REQUIRED)
pkg_check_modules(PC_MAXMINDDB REQUIRED IMPORTED_TARGET libmaxminddb)
if(NOT TARGET maxminddb::maxminddb)
  add_library(maxminddb::maxminddb INTERFACE IMPORTED)
  target_link_libraries(maxminddb::maxminddb INTERFACE PkgConfig::PC_MAXMINDDB)
endif()
set(maxminddb_FOUND TRUE)
```

Before accepting it, add a hermetic failing case that reproduces the exact target/config mismatch, verify RED, add only this module, then verify GREEN and commit the test, module, and reportable evidence together with `feat: adapt evidenced maxminddb discovery`. If live discovery already supplies the target, do not create or commit this file.

- [ ] **Step 6: Generate the tracked Gate 2 report deterministically**

Implement `write_gate2_report ROOT OUTPUT` in `scripts/lib/native-discovery.sh`. Generate `docs/gate2-native-configure-report.md` from a fixed template/order containing:

- exact upstream URL and commit;
- host architecture, Xcode build, Apple Clang, Python, Homebrew version;
- required/optional formula table with exact installed versions;
- normalized package resolution paths using `<HOMEBREW_PREFIX>` and `<PROJECT_ROOT>`;
- raw command/status/failure summary and raw log path;
- wrapped command/status and exact policy values;
- module/parent-variable/package mismatches and wrapper fixes;
- NAT-PMP/TBB observed availability and explicit disabled baseline;
- deployment target `13.0`, why it favors broad supported compatibility without a legacy patch, and the requirement for Phase 3 compile validation before it becomes final;
- two-run idempotence comparison;
- upstream cleanliness and no-compile/no-`Dist` assertions;
- unresolved Phase 3 questions.

The report generator must fail if any input contains an unresolved absolute project, home, or Homebrew path, a missing version/resolution, a placeholder marker, or a nonzero wrapped status. Re-running it with identical evidence must produce byte-identical output.

- [ ] **Step 7: Run live Gate 2 twice and verify GREEN**

Run:

```bash
AIRDCCORE_RUN_GATE2=1 rtk ./tests/gate2_configure_test.sh
rtk ./scripts/build --configure-only
rtk git diff --no-index docs/gate2-native-configure-report.md docs/gate2-native-configure-report.md
```

Expected: Gate 2 prints its exact `PASS:` line; the additional configure is idempotent; the report is unchanged when regenerated. Network is not required after Homebrew prerequisites are installed and Phase 1 source exists.

- [ ] **Step 8: Update operator documentation**

Update `README.md` to advertise only `./scripts/build --configure-only`, its optional explicit install flag, and the Gate 2 test. Update `docs/dependencies.md` with the exact discovery-only formula inventory, optional-disabled policy, and the rule that Homebrew paths cannot become publication inputs. Update `docs/build-and-release.md` to mark Gate 2 configure discovery implemented, link `docs/gate2-native-configure-report.md`, and state explicitly that compilation, link closure, `Dist`, and packaging remain pending.

- [ ] **Step 9: Run final Phase 2 verification**

Run:

```bash
rtk ./tests/upstream_config_test.sh
rtk ./tests/update_test.sh
rtk ./tests/native_discovery_test.sh
rtk ./tests/configure_test.sh
AIRDCCORE_RUN_GATE2=1 rtk ./tests/gate2_configure_test.sh
rtk /bin/sh -n scripts/update scripts/build scripts/lib/upstream.sh scripts/lib/native-discovery.sh tests/test_helper.sh tests/upstream_config_test.sh tests/update_test.sh tests/native_discovery_test.sh tests/configure_test.sh tests/gate2_configure_test.sh
rtk git -C Source/airdcpp-core rev-parse HEAD
rtk git -C Source/airdcpp-core status --porcelain=v1 --untracked-files=all
rtk git check-ignore -v Source/airdcpp-core/ Build/airdcpp-core/ Dependencies/ Dist/
rtk git ls-files Source Dependencies Build Dist
rtk find Build -type f \( -name '*.o' -o -name '*.a' -o -name '*.dylib' \)
rtk rg -n '/Users/|/home/|/opt/homebrew' config CMakeLists.txt cmake scripts tests docs/gate2-native-configure-report.md
rtk git diff --check develop...HEAD
rtk git status --short --branch
```

Expected:

- all four offline suites and live Gate 2 print `PASS:`;
- upstream HEAD is exactly `55d51ceb817ec006d4ec844d9e3788e1b0ccc352`, origin remains canonical, and no unsafe/changed generated content appears;
- ignored paths match parent policy and no files under `Source`, `Dependencies`, `Build`, or `Dist` are tracked;
- no object, archive, or dynamic library exists under `Build`;
- the absolute-path scan returns no tracked machine-local prefix (fixtures may use literal `/Fixture/Homebrew`, never a real prefix);
- syntax and diff checks exit `0`; and
- branch is clean on `feature/native-configure-discovery`.

- [ ] **Step 10: Commit Gate 2 evidence and documentation**

Commit only tracked Phase 2 evidence and docs:

```bash
rtk git add tests/gate2_configure_test.sh scripts/lib/native-discovery.sh docs/gate2-native-configure-report.md README.md docs/dependencies.md docs/build-and-release.md
rtk git commit -m "test: prove native configure discovery gate"
```

- [ ] **Step 11: Review without merging or starting Phase 3**

Run:

```bash
rtk git log --oneline --decorate develop..HEAD
rtk git diff --stat develop...HEAD
rtk git status --short --branch
```

Expected: the five planned task commits, plus any separately reviewed evidence-backed adapter/patch commits, on `feature/native-configure-discovery`; a clean tracked worktree with ignored `Source`/`Build` evidence; a reviewed Gate 2 configure report; no merge to `develop`; and no Phase 3 compilation or publication work. Hand the branch to the requested review workflow and create a pull request only after implementation and Gate 2 verification are accepted.
