# Native Dependency and Configure Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a reviewed, deterministic, configure-only ARM64 Release path for the pinned AirDC++ Core source, with explicit Homebrew discovery evidence and no core compilation.

**Architecture:** Extend the stable `scripts/build` entry point with a single Phase 2 mode, `--configure-only`, and keep host validation, formula discovery, evidence capture, and CMake invocation in a focused shell library. A tracked top-level CMake wrapper supplies project policy and missing check-module context to the unmodified pinned source, while narrowly scoped `Find` modules bridge only package/config mismatches proven by preserved configure logs. Generated logs and build trees stay below ignored `Build/airdcpp-core`; a normalized reviewed Gate 2 report is tracked under `docs/reports`.

**Tech Stack:** POSIX shell, CMake, Ninja, Apple Clang/libc++, Git, Python 3, Homebrew discovery packages, shell fixture tests

**Spec:** `docs/superpowers/specs/2026-09-04-airdc-core-macos-design.md`

## Global Constraints

- Host platform: macOS on Apple Silicon.
- Target architecture: Mach-O `arm64` only.
- Compiler/runtime: Apple Clang with libc++.
- Configuration: Release.
- Upstream source: `https://github.com/airdcpp/airdcpp-core.git` at full commit `55d51ceb817ec006d4ec844d9e3788e1b0ccc352`.
- Source checkout: ignored `Source/airdcpp-core`, detached at the configured commit, with no Git submodule and no vendored copy.
- Third-party sources: ignored top-level `Dependencies`; Phase 2 does not populate it or introduce `config/dependencies.lock`.
- Build workspace: ignored `Build`; all configure trees and raw evidence live under `Build/airdcpp-core`.
- Published boundary: ignored/generated `Dist`; Phase 2 must neither create nor modify it.
- Stable user-facing commands remain `update`, `build`, `verify`, and `clean`; this phase adds only `scripts/build --configure-only`.
- Homebrew is permitted for host tools and first configure discovery only, never as the final publication contract.
- Required formula inputs for discovery are `cmake`, `ninja`, `boost`, `bzip2`, `zlib`, `openssl@3`, `miniupnpc`, `leveldb`, `libmaxminddb`, `snappy`, `libiconv`, `pkgconf`, and `python@3.14`.
- Native SDK `Threads` remains a system interface; SDK copies of BZip2, ZLIB, OpenSSL, or Iconv do not silently replace controlled Homebrew discovery inputs.
- `ENABLE_NATPMP=OFF` and `ENABLE_TBB=OFF` are explicit for the deterministic Phase 2 result; the preserved unmodified attempt records their upstream default-ON probing while `libnatpmp` and `tbb` are absent.
- Do not add Boost `system`, WebSocket++, nlohmann-json, npm, or any other package not declared by the pinned upstream CMake.
- Configure policy is `BUILD_SHARED_LIBS=OFF`, `CMAKE_BUILD_TYPE=Release`, `CMAKE_OSX_ARCHITECTURES=arm64`, libc++ defaults, `CMAKE_CXX_STANDARD=20`, `CMAKE_CXX_EXTENSIONS=OFF`, and deployment target `14.0`.
- Deployment target `14.0` is a Gate 2 discovery choice favoring broad compatibility without legacy-specific source patches; the report must distinguish compiler acceptance from final dependency-binary compatibility, which is not proved until later build and inspection gates.
- Wrapper adaptation is preferred. An upstream patch is prohibited in this plan; if final configure evidence proves one unavoidable, stop Phase 2, re-inspect the pinned upstream CMake, and request a separately reviewed plan change before adding a patch.
- Configure only: no `cmake --build`, direct `ninja`, AirDC++ Core object compilation/linking, archive creation, `libairdcpp.a`, packaging, smoke consumer, or release work. CMake's compiler-identification and `Check*` configure probes are permitted and must be distinguished from building the `airdcpp` target.
- Parent upstream cleanliness may include only `airdcpp/core/version.inc` and `airdcpp/core/localization/StringDefs.cpp`; configure is expected to create neither file and must not change any other upstream path.
- Parent-repository work follows full GitFlow on `feature/native-configure-discovery` from `origin/develop`; never commit this work directly to `develop` and do not create `master`.
- When Codex executes this plan, every interactive external command is run through `rtk` as required by `AGENTS.md`; shell and CMake blocks that define tracked file contents remain literal source code.

## Planning Evidence and Locked File Map

The planning host was verified on 2026-09-05 as `arm64`, macOS 26.5.1, Xcode 26.6 build 17F113, Apple Clang 21.0.0, macOS SDK 26.5, Python 3.14.3, Homebrew 6.0.14 at `/opt/homebrew`. Installed discovery formulas were `libiconv 1.18`, `miniupnpc 2.3.3`, `openssl@3 3.6.1`, `pkgconf 2.5.1`, and `python@3.14 3.14.3_1`. Required formulas not present were `cmake`, `ninja`, `boost`, `bzip2`, `zlib`, `leveldb`, `libmaxminddb`, and `snappy`; optional `libnatpmp` and `tbb` were also absent and must not be installed for the OFF/OFF Phase 2 policy.

The pinned upstream has one `CMakeLists.txt`. It invokes `CHECK_FUNCTION_EXISTS` and `CHECK_INCLUDE_FILES` without including their CMake modules, uses parent-style `VERSION`, `TAG_APPLICATION`, `APPLICATION_ID`, `RESOURCE_DIRECTORY`, `GLOBAL_CONFIG_DIRECTORY`, and `PROJECT_NAME_GLOBAL`, and requests `miniupnpc` and `maxminddb` packages whose observed Homebrew discovery boundary requires focused adapters. The already-installed `miniupnpc 2.3.3` contains headers, static/shared libraries, and `miniupnpc.pc`, but no CMake package config. These facts justify the following files without modifying upstream:

| Path | Responsibility |
| --- | --- |
| `scripts/build` | Stable user entry point; accepts only `--configure-only` in Phase 2 and never invokes a build. |
| `scripts/lib/configure.sh` | Host/compiler validation, formula inventory, upstream invariants, path construction, one-time evidence preservation, and configure invocation helpers. |
| `CMakeLists.txt` | Top-level policy wrapper; validates Apple Clang and fixed configure policy, defines parent-style values, includes check modules, adds the unmodified pinned source. |
| `cmake/toolchains/macos-arm64.cmake` | Resolves `xcrun` Apple compilers and fixes SDK, `arm64`, deployment target 14.0, and libc++ policy. |
| `cmake/modules/AirDCCorePolicy.cmake` | Small testable CMake functions for compiler and cache-invariant rejection plus imported-target evidence. |
| `cmake/modules/Findminiupnpc.cmake` | Bridges the observed pkg-config/header/library Homebrew layout to `miniupnpc::miniupnpc`. |
| `cmake/modules/Findmaxminddb.cmake` | Bridges pkg-config/header/library discovery to `maxminddb::maxminddb`. |
| `tests/configure_helpers_test.sh` | Hermetic shell tests for formula checks, inventory normalization, upstream validation, and path construction. |
| `tests/cmake_wrapper_test.sh` | Local CMake fixture tests for wrapper variables, policy rejection, architecture, standard, options, and no AirDC++ Core target build. |
| `tests/find_modules_test.sh` | Local fake-prefix tests for both imported-target adapters. |
| `tests/build_configure_test.sh` | Hermetic fake-tool integration tests for `scripts/build --configure-only`, first-attempt preservation, reruns, failures, and scope. |
| `tests/fixtures/configure-upstream/CMakeLists.txt` | Minimal nested upstream surrogate that asserts wrapper-supplied commands and parent values without third-party packages. |
| `tests/gate2_configure_test.sh` | Explicitly enabled real-host Gate 2 test; validates the final cache/evidence and proves no AirDC++ Core target build or scope leakage. |
| `docs/reports/2026-09-05-gate-2-native-configure.md` | Reviewed, normalized record of exact commands, versions, paths, failures, adaptations, warnings, and final result. |
| `README.md` | Adds the configure-only operator command and Phase 2 boundary. |
| `docs/architecture.md` | Records wrapper/helper ownership and configure data flow. |
| `docs/dependencies.md` | Records observed discovery formula versions/paths and OFF optional-feature policy without promising publication inputs. |
| `docs/build-and-release.md` | Documents Gate 2 invocation, evidence location, and explicit no-compile boundary. |

---

### Task 1: Configure Discovery Shell Contracts and Prerequisite Gate

**Files:**
- Create: `scripts/lib/configure.sh`
- Create: `tests/configure_helpers_test.sh`
- Modify: `tests/test_helper.sh`

**Interfaces:**
- Consumes: `load_upstream_config(path)` and `checkout_changes(checkout)` from `scripts/lib/upstream.sh`; `config/upstream.env`; executable tools supplied through `PATH`.
- Produces: `required_formulae() -> newline-delimited names`, `missing_required_formulae() -> newline-delimited names`, `assert_supported_host()`, `validate_configure_checkout(project_root, checkout, expected_commit)`, `dependency_cmake_prefix_path() -> semicolon-delimited prefixes`, `dependency_pkg_config_path() -> colon-delimited directories`, `write_host_inventory(output_path)`, and `configure_die(message) -> exit 1`.

- [ ] **Step 1: Extend the test helper with exact line and directory assertions**

Add these functions to `tests/test_helper.sh`:

```sh
assert_not_contains() {
  haystack=$1
  needle=$2
  label=$3
  case "$haystack" in
    *"$needle"*) fail "$label: unexpected output containing [$needle]" ;;
  esac
}

assert_dir_absent() { [ ! -d "$1" ] || fail "expected absent directory: $1"; }

assert_line() {
  file=$1
  line=$2
  label=$3
  grep -Fqx -- "$line" "$file" || fail "$label: missing exact line [$line] in $file"
}
```

- [ ] **Step 2: Write the failing hermetic helper tests**

Create `tests/configure_helpers_test.sh`. Its fake `uname`, `sw_vers`, `xcodebuild`, `xcrun`, `brew`, `cmake`, `ninja`, and `python3` commands must return fixed values. Cover these exact cases:

```sh
#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
. "$ROOT/scripts/lib/upstream.sh"
. "$ROOT/scripts/lib/configure.sh"

WORK=$(new_temp_dir)
trap 'rm -rf -- "$WORK"' 0 1 2 15
FAKE_BIN=$WORK/bin
mkdir -p "$FAKE_BIN" "$WORK/project/Source/airdcpp-core/.git"

write_fake() {
  tool=$1
  shift
  printf '%s\n' '#!/bin/sh' "$@" > "$FAKE_BIN/$tool"
  chmod +x "$FAKE_BIN/$tool"
}

write_fake uname \
  'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) exit 64 ;; esac'
write_fake sw_vers \
  'printf "ProductName:\tmacOS\nProductVersion:\t26.5.1\nBuildVersion:\t25F80\n"'
write_fake xcodebuild \
  'printf "Xcode 26.6\nBuild version 17F113\n"'
write_fake xcrun \
  'case "$*" in' \
  '  "clang --version") echo "Apple clang version 21.0.0 (clang-2100.1.1.101)" ;;' \
  '  "--find clang") echo /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang ;;' \
  '  "--find clang++") echo /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++ ;;' \
  '  "--sdk macosx --show-sdk-path") echo /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk ;;' \
  '  "--sdk macosx --show-sdk-version") echo 26.5 ;;' \
  '  *) exit 64 ;;' \
  'esac'
write_fake cmake 'echo "cmake version 3.31.6"'
write_fake ninja 'echo 1.12.1'
write_fake python3 'echo "Python 3.14.3"'
write_fake brew \
  'case "$1:$2" in' \
  '  --prefix:) echo /opt/homebrew ;;' \
  '  --prefix:*) echo "/opt/homebrew/opt/$2" ;;' \
  '  --version:) echo "Homebrew 6.0.14" ;;' \
  '  list:--versions)' \
  '    case "$3" in cmake|snappy) exit 1 ;; miniupnpc) echo "miniupnpc 2.3.3" ;; *) echo "$3 1.0.0" ;; esac ;;' \
  '  *) exit 64 ;;' \
  'esac'

missing=$(PATH="$FAKE_BIN:$PATH" missing_required_formulae)
assert_eq "$missing" "cmake
snappy" "missing formula order"

prefixes=$(PATH="$FAKE_BIN:$PATH" dependency_cmake_prefix_path)
assert_contains "$prefixes" "/opt/homebrew/opt/boost" "Boost prefix"
assert_contains "$prefixes" "/opt/homebrew/opt/libiconv" "Iconv prefix"
assert_not_contains "$prefixes" "libnatpmp" "NAT-PMP is not required"
assert_not_contains "$prefixes" "tbb" "TBB is not required"

PROJECT_ROOT=$WORK/project PATH="$FAKE_BIN:$PATH" \
  write_host_inventory "$WORK/project/Build/airdcpp-core/inventory.txt"
cp "$WORK/project/Build/airdcpp-core/inventory.txt" "$WORK/inventory.txt"
assert_line "$WORK/inventory.txt" "host.arch=arm64" "host architecture"
assert_line "$WORK/inventory.txt" "cmake.version=3.31.6" "CMake version"
assert_line "$WORK/inventory.txt" "formula.miniupnpc=2.3.3" "formula version"
assert_not_contains "$(cat "$WORK/inventory.txt")" "$WORK" "inventory temp-path leakage"

printf 'PASS: configure discovery helpers\n'
```

Run `chmod +x tests/configure_helpers_test.sh` after creating the file.

Also cover non-`arm64` host rejection, non-Darwin rejection, non-Apple `xcrun clang --version` rejection, missing formula diagnostics, a wrong upstream commit, staged/tracked/untracked upstream changes, allowed generated paths, a symlinked checkout, and output refusal outside `Build/airdcpp-core`.

- [ ] **Step 3: Run the helper test to verify it fails**

Run: `./tests/configure_helpers_test.sh`

Expected: FAIL while sourcing missing `scripts/lib/configure.sh`.

- [ ] **Step 4: Implement the minimal shell helper contract**

Create `scripts/lib/configure.sh` with strict, data-only discovery. Use this formula set and keep optional packages out of it:

```sh
#!/bin/sh

configure_die() {
  printf 'build: error: configure discovery: %s\n' "$*" >&2
  exit 1
}

required_formulae() {
  printf '%s\n' cmake ninja boost bzip2 zlib openssl@3 miniupnpc \
    leveldb libmaxminddb snappy libiconv pkgconf python@3.14
}

missing_required_formulae() {
  required_formulae | while IFS= read -r formula; do
    HOMEBREW_NO_AUTO_UPDATE=1 brew list --versions "$formula" >/dev/null 2>&1 ||
      printf '%s\n' "$formula"
  done
}

assert_supported_host() {
  [ "$(uname -s)" = Darwin ] || configure_die "macOS is required"
  [ "$(uname -m)" = arm64 ] || configure_die "arm64 host is required"
  clang_version=$(xcrun clang --version 2>/dev/null) || configure_die "xcrun Apple Clang is unavailable"
  case "$clang_version" in
    Apple\ clang\ version*) ;;
    *) configure_die "xcrun did not resolve Apple Clang" ;;
  esac
}
```

Implement `validate_configure_checkout` by rejecting symlinks, requiring `.git`, exact detached `HEAD`, configured origin, and `checkout_changes` output empty. For Phase 2, even the two known generated files are only tolerated if they already exist; record them in inventory and prove their contents and mtimes do not change across configure.

Implement path functions from `brew --prefix <formula>`, preserving `required_formulae` order and de-duplicating identical paths. `write_host_inventory` writes sorted `key=value` lines for OS, architecture, Xcode/build, Apple Clang, SDK path/version, Git, Python, Homebrew, CMake, Ninja, each required formula version, each formula prefix, and `optional.libnatpmp=absent|<version>` / `optional.tbb=absent|<version>`. It refuses paths outside `$PROJECT_ROOT/Build/airdcpp-core` and records no environment dump, timestamp, username, home directory, or secret-bearing values.

- [ ] **Step 5: Run the helper tests to verify they pass**

Run: `./tests/configure_helpers_test.sh`

Expected: `PASS: configure discovery helpers`.

- [ ] **Step 6: Re-run the existing Phase 1 offline tests**

Run: `./tests/upstream_config_test.sh && ./tests/update_test.sh`

Expected: both scripts print `PASS` and the parent status remains clean except for Task 1 files.

- [ ] **Step 7: Commit the shell contract**

```bash
git add scripts/lib/configure.sh tests/configure_helpers_test.sh tests/test_helper.sh
git commit -m "test: define configure discovery prerequisites"
```

---

### Task 2: Preserve the Unmodified Attempt and Establish ARM64 Wrapper Policy

**Files:**
- Create: `CMakeLists.txt`
- Create: `cmake/toolchains/macos-arm64.cmake`
- Create: `cmake/modules/AirDCCorePolicy.cmake`
- Create: `tests/cmake_wrapper_test.sh`
- Create: `tests/fixtures/configure-upstream/CMakeLists.txt`
- Evidence only, ignored: `Build/airdcpp-core/evidence/host-inventory.txt`
- Evidence only, ignored: `Build/airdcpp-core/unmodified/{command.txt,configure.log,exit-code.txt,inputs.txt}`
- Evidence only, ignored: `Build/airdcpp-core/wrapper-baseline/{command.txt,configure.log,exit-code.txt}`

**Interfaces:**
- Consumes: Task 1 host/formula helpers, Homebrew formula prefixes, `Source/airdcpp-core`, and `/usr/bin/xcrun`.
- Produces: `cmake/toolchains/macos-arm64.cmake`; CMake functions `airdcpp_require_apple_clang()`, `airdcpp_require_value(name, actual, expected)`, and `airdcpp_record_target(target, output)`; wrapper cache input `AIRDCPP_CORE_SOURCE_DIR:PATH`.

- [ ] **Step 1: Run the prerequisite gate and install only the missing required formulas**

Run the Task 1 helper and compare its output with the verified planning snapshot:

```bash
missing=$(sh -c '. ./scripts/lib/configure.sh; missing_required_formulae')
printf '%s\n' "$missing"
```

Expected on the recorded host:

```text
cmake
ninja
boost
bzip2
zlib
leveldb
libmaxminddb
snappy
```

After confirming that exact list, run:

```bash
HOMEBREW_NO_AUTO_UPDATE=1 brew install cmake ninja boost bzip2 zlib leveldb libmaxminddb snappy
```

Do not install `libnatpmp`, `tbb`, WebSocket++, nlohmann-json, npm, or Boost system separately. Re-run `missing_required_formulae`; expected output is empty. Package installation changes the host, not the repository, and creates no commit.

- [ ] **Step 2: Capture deterministic host inventory before any configure**

Load the helper and run:

```bash
. ./scripts/lib/configure.sh
PROJECT_ROOT=$PWD
export PROJECT_ROOT
mkdir -p Build/airdcpp-core/evidence
write_host_inventory "$PROJECT_ROOT/Build/airdcpp-core/evidence/host-inventory.txt"
```

Expected: sorted inventory contains exact versions and resolved prefixes for all required formulas, explicitly says optional `libnatpmp` and `tbb` are absent, and contains no `/Users/` path.

- [ ] **Step 3: Preserve the first unmodified standalone configure attempt**

Create only `Build/airdcpp-core/unmodified`, record the literal normalized command in `command.txt`, and run the pinned source directly with no wrapper, no local module path, and no source edits:

```bash
cmake -S Source/airdcpp-core -B Build/airdcpp-core/unmodified -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_CXX_STANDARD=20 \
  -DCMAKE_CXX_EXTENSIONS=OFF \
  -DCMAKE_FIND_DEBUG_MODE=ON
```

Do not pass `ENABLE_NATPMP` or `ENABLE_TBB` to this command: omitting them preserves upstream's default-ON behavior for the first observation. Capture combined stdout/stderr in `configure.log`, write the numeric status to `exit-code.txt`, and write upstream commit, SHA-256 of upstream `CMakeLists.txt`, pre-configure status, post-configure status, and the two generated-file fingerprints to `inputs.txt`. Expected first defect: an unknown `CHECK_FUNCTION_EXISTS` or `CHECK_INCLUDE_FILES` command caused by the absent CMake module includes. Also record CMake's ordering warning if it reports upstream `project()` before `cmake_minimum_required()`. Preserve this directory unchanged for the rest of Gate 2 even if the command succeeds earlier or fails differently.

- [ ] **Step 4: Write the failing CMake wrapper tests**

Create `tests/fixtures/configure-upstream/CMakeLists.txt` as a nested project that calls both check commands, asserts all parent variables are non-empty, asserts Release/static/C++20/arm64/14.0/OFF/OFF values, and declares `add_library(airdcpp INTERFACE)`.

Create `tests/cmake_wrapper_test.sh` with these cases:

```sh
cmake -S "$ROOT" -B "$WORK/good" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/cmake/toolchains/macos-arm64.cmake" \
  -DAIRDCPP_CORE_SOURCE_DIR="$ROOT/tests/fixtures/configure-upstream"
assert_line "$WORK/good/airdcpp-configure-summary.txt" "compiler.id=AppleClang" "compiler"
assert_line "$WORK/good/airdcpp-configure-summary.txt" "architecture=arm64" "architecture"
assert_line "$WORK/good/airdcpp-configure-summary.txt" "deployment_target=14.0" "deployment target"
assert_line "$WORK/good/airdcpp-configure-summary.txt" "cxx_standard=20" "language standard"
assert_line "$WORK/good/airdcpp-configure-summary.txt" "enable_natpmp=OFF" "NAT-PMP policy"
assert_line "$WORK/good/airdcpp-configure-summary.txt" "enable_tbb=OFF" "TBB policy"

if cmake -S "$ROOT" -B "$WORK/wrong-mode" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/cmake/toolchains/macos-arm64.cmake" \
  -DAIRDCPP_CORE_SOURCE_DIR="$ROOT/tests/fixtures/configure-upstream" \
  -DCMAKE_BUILD_TYPE=Debug >"$WORK/wrong-mode.log" 2>&1; then
  fail "Debug configure unexpectedly succeeded"
fi
assert_contains "$(cat "$WORK/wrong-mode.log")" "CMAKE_BUILD_TYPE must be Release" "Release rejection"
```

Add matching negative cases for `x86_64`, shared libraries, and C++17. Add successful diagnostic cases for deployment targets `13.0` and `15.0` and for explicitly enabled NAT-PMP/TBB; these values are allowed only for isolated evidence probes, while the stable script always supplies `14.0` and OFF/OFF. Test `airdcpp_require_apple_clang()` in CMake script mode with injected `GNU`/`Clang` IDs and require the exact `Apple Clang is required` diagnostic. Finally scan `CMakeLists.txt` and the toolchain for compiler/link flags outside the declared policy.

Run `chmod +x tests/cmake_wrapper_test.sh` after creating the file.

- [ ] **Step 5: Run the wrapper test to verify it fails**

Run: `./tests/cmake_wrapper_test.sh`

Expected: FAIL because the wrapper/toolchain/policy module do not exist.

- [ ] **Step 6: Implement the toolchain and testable policy functions**

Create `cmake/toolchains/macos-arm64.cmake`:

```cmake
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR arm64)

execute_process(COMMAND /usr/bin/xcrun --find clang
  OUTPUT_VARIABLE AIRDCCORE_APPLE_CLANG OUTPUT_STRIP_TRAILING_WHITESPACE
  COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND /usr/bin/xcrun --find clang++
  OUTPUT_VARIABLE AIRDCCORE_APPLE_CLANGXX OUTPUT_STRIP_TRAILING_WHITESPACE
  COMMAND_ERROR_IS_FATAL ANY)

set(CMAKE_C_COMPILER "${AIRDCCORE_APPLE_CLANG}" CACHE FILEPATH "Apple Clang C compiler")
set(CMAKE_CXX_COMPILER "${AIRDCCORE_APPLE_CLANGXX}" CACHE FILEPATH "Apple Clang C++ compiler")
set(CMAKE_OSX_SYSROOT macosx CACHE STRING "macOS SDK")
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "Supported architecture")
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0 CACHE STRING "Discovery deployment target")
```

Do not add a `-stdlib` flag: Apple Clang's native libc++ default is the policy. Record `CMAKE_CXX_IMPLICIT_LINK_LIBRARIES` and the compiler identity in the summary as the evidence, and reject non-Apple compilers.

Create `cmake/modules/AirDCCorePolicy.cmake`. `airdcpp_require_apple_clang()` rejects unless both `CMAKE_C_COMPILER_ID` and `CMAKE_CXX_COMPILER_ID` equal `AppleClang`; `airdcpp_require_value` emits `FATAL_ERROR "<name> must be <expected>; got <actual>"`; `airdcpp_record_target` appends target existence, type, imported location/configurations, include directories, and interface libraries in stable field order.

- [ ] **Step 7: Implement the top-level wrapper**

Create `CMakeLists.txt` with this policy order:

```cmake
cmake_minimum_required(VERSION 3.25)
project(AirDCCoreMacOS LANGUAGES C CXX)

list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/modules")
include(AirDCCorePolicy)
airdcpp_require_apple_clang()

set(CMAKE_BUILD_TYPE Release CACHE STRING "Single-config discovery mode")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static libraries")
set(CMAKE_CXX_STANDARD 20 CACHE STRING "Required C++ standard")
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(ENABLE_NATPMP OFF CACHE BOOL "Deterministic Phase 2 NAT-PMP policy")
set(ENABLE_TBB OFF CACHE BOOL "Deterministic Phase 2 TBB policy")

airdcpp_require_value(CMAKE_BUILD_TYPE "${CMAKE_BUILD_TYPE}" Release)
airdcpp_require_value(BUILD_SHARED_LIBS "${BUILD_SHARED_LIBS}" OFF)
airdcpp_require_value(CMAKE_OSX_ARCHITECTURES "${CMAKE_OSX_ARCHITECTURES}" arm64)
airdcpp_require_value(CMAKE_CXX_STANDARD "${CMAKE_CXX_STANDARD}" 20)

if(NOT CMAKE_OSX_DEPLOYMENT_TARGET MATCHES "^(13\\.0|14\\.0|15\\.0)$")
  message(FATAL_ERROR "deployment target must be one of 13.0, 14.0, or 15.0")
endif()

include(CheckFunctionExists)
include(CheckIncludeFiles)

set(VERSION 0.0.0 CACHE STRING "Configure-only upstream target version")
set(TAG_APPLICATION AirDCCore-macOS CACHE STRING "Configure-only application name")
set(APPLICATION_ID org.airdcpp.core.macos.configure CACHE STRING "Configure-only application identifier")
set(RESOURCE_DIRECTORY share/airdcpp CACHE STRING "Runtime resource contract")
set(GLOBAL_CONFIG_DIRECTORY "Library/Application Support/AirDC++" CACHE STRING "Runtime config contract")
set(PROJECT_NAME_GLOBAL AirDCCore CACHE STRING "Parent project name")
set(AIRDCPP_CORE_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/Source/airdcpp-core" CACHE PATH "Pinned source checkout")

add_subdirectory("${AIRDCPP_CORE_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/upstream")
```

After `add_subdirectory`, generate `airdcpp-configure-summary.txt` with compiler IDs/paths, SDK, architecture, target, build type, language standard/extensions, shared/static mode, optional flags, upstream source path, and parent-style values. Record required imported targets in this exact order: `BZip2::BZip2`, `ZLIB::ZLIB`, `OpenSSL::SSL`, `OpenSSL::Crypto`, `miniupnpc::miniupnpc`, `leveldb::leveldb`, `maxminddb::maxminddb`, `Boost::thread`, `Boost::regex`, `Snappy::snappy`, `Threads::Threads`, `Iconv::Iconv`.

- [ ] **Step 8: Run wrapper tests, then capture the wrapper-only package failure**

Run: `./tests/cmake_wrapper_test.sh`

Expected: `PASS: ARM64 CMake wrapper policy`.

Then configure the real pinned source with the wrapper but temporarily move no files and supply no package adapters beyond the not-yet-created module files. Use the same fixed flags, Homebrew prefix list, explicit BZip2/ZLIB/OpenSSL/Iconv hints, and `CMAKE_FIND_DEBUG_MODE=ON`; capture it under `Build/airdcpp-core/wrapper-baseline`. Expected: check functions now execute and configuration advances to an exact package mismatch, with `miniupnpc` expected first because its installed formula has no CMake config. Preserve the literal command, complete log, and numeric status.

- [ ] **Step 9: Verify no upstream mutation and commit wrapper policy**

Run:

```bash
git -C Source/airdcpp-core status --porcelain=v1 --untracked-files=all
git diff --check
```

Expected: upstream status and generated-file fingerprints match the pre-configure record; parent diff check passes.

```bash
git add CMakeLists.txt cmake/toolchains/macos-arm64.cmake \
  cmake/modules/AirDCCorePolicy.cmake tests/cmake_wrapper_test.sh \
  tests/fixtures/configure-upstream/CMakeLists.txt
git commit -m "feat: establish ARM64 configure wrapper"
```

---

### Task 3: Add Evidence-Backed Homebrew Package Adapters

**Files:**
- Create: `cmake/modules/Findminiupnpc.cmake`
- Create: `cmake/modules/Findmaxminddb.cmake`
- Create: `tests/find_modules_test.sh`
- Modify: `CMakeLists.txt`
- Evidence only, ignored: `Build/airdcpp-core/release/{configure.log,CMakeCache.txt,airdcpp-configure-summary.txt}`

**Interfaces:**
- Consumes: CMake's `FindPackageHandleStandardArgs`, optional `PkgConfig`, formula prefix hints, and wrapper target-evidence function.
- Produces: imported targets `miniupnpc::miniupnpc` and `maxminddb::maxminddb`, each with one resolved include directory, one resolved library, and optional discovered version.

- [ ] **Step 1: Re-inspect the exact package failure and formula layouts**

Run:

```bash
grep -E 'Could not find|Config.cmake|cmake|pkgconfig|miniupnpc|maxminddb' \
  Build/airdcpp-core/wrapper-baseline/configure.log
find "$(brew --prefix miniupnpc)" -maxdepth 4 -type f -print
find "$(brew --prefix libmaxminddb)" -maxdepth 4 -type f -print
```

Expected: the log and layouts justify only the two adapter files in this task. If a different required package still cannot resolve from the explicit formula prefix/root hints, Gate 2 is blocked: retain the log, stop implementation, and request a plan amendment instead of adding an unreviewed module or upstream patch.

- [ ] **Step 2: Write failing fake-prefix tests for both modules**

Create `tests/find_modules_test.sh`. For each package, create a temporary prefix with the exact header and an empty archive produced by `ar -cr`, then create a small CMake fixture that sets `CMAKE_MODULE_PATH` to the repository modules, calls `find_package(<name> REQUIRED)`, and rejects unless the namespaced target has the expected imported location and include directory.

Use these package expectations:

```text
miniupnpc header: include/miniupnpc/miniupnpc.h
miniupnpc library: lib/libminiupnpc.a
miniupnpc target: miniupnpc::miniupnpc
maxminddb header: include/maxminddb.h
maxminddb library: lib/libmaxminddb.a
maxminddb target: maxminddb::maxminddb
```

Also test missing header, missing library, paths containing spaces, and repeated `find_package` calls.

Run `chmod +x tests/find_modules_test.sh` after creating the file.

- [ ] **Step 3: Run the module tests to verify they fail**

Run: `./tests/find_modules_test.sh`

Expected: FAIL because both `Find` modules are absent.

- [ ] **Step 4: Implement the two minimal `Find` modules**

Each module must use this exact structure with its package-specific names:

```cmake
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
  pkg_check_modules(PC_MINIUPNPC QUIET miniupnpc)
endif()

find_path(miniupnpc_INCLUDE_DIR
  NAMES miniupnpc/miniupnpc.h
  HINTS ${PC_MINIUPNPC_INCLUDE_DIRS})
find_library(miniupnpc_LIBRARY
  NAMES miniupnpc
  HINTS ${PC_MINIUPNPC_LIBRARY_DIRS})

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(miniupnpc
  REQUIRED_VARS miniupnpc_INCLUDE_DIR miniupnpc_LIBRARY
  VERSION_VAR PC_MINIUPNPC_VERSION)

if(miniupnpc_FOUND AND NOT TARGET miniupnpc::miniupnpc)
  add_library(miniupnpc::miniupnpc UNKNOWN IMPORTED)
  set_target_properties(miniupnpc::miniupnpc PROPERTIES
    IMPORTED_LOCATION "${miniupnpc_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${miniupnpc_INCLUDE_DIR}")
endif()

mark_as_advanced(miniupnpc_INCLUDE_DIR miniupnpc_LIBRARY)
```

Use `PC_MAXMINDDB`, pkg-config module `libmaxminddb`, header `maxminddb.h`, library name `maxminddb`, and target `maxminddb::maxminddb` in the second module. Do not encode `/opt/homebrew`, a Cellar version, or a user path in either tracked module.

- [ ] **Step 5: Run adapter tests and wrapper fixture tests**

Run: `./tests/find_modules_test.sh && ./tests/cmake_wrapper_test.sh`

Expected: both scripts print `PASS`.

- [ ] **Step 6: Configure the real pinned source through the final wrapper**

Use `Build/airdcpp-core/release`, `--fresh`, Ninja, the tracked toolchain, the deterministic policy flags, a semicolon-delimited prefix list from required formulas, a colon-delimited `PKG_CONFIG_PATH`, and explicit Homebrew paths for modules that otherwise prefer SDK copies:

```bash
. ./scripts/lib/configure.sh
CMAKE_PREFIX_PATH=$(dependency_cmake_prefix_path)
PKG_CONFIG_PATH=$(dependency_pkg_config_path)
export CMAKE_PREFIX_PATH PKG_CONFIG_PATH
PKG_CONFIG_PATH="$PKG_CONFIG_PATH" cmake --fresh \
  -S . -B Build/airdcpp-core/release -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/macos-arm64.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_CXX_STANDARD=20 \
  -DCMAKE_CXX_EXTENSIONS=OFF \
  -DENABLE_NATPMP=OFF \
  -DENABLE_TBB=OFF \
  -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH" \
  -DBZIP2_ROOT="$(brew --prefix bzip2)" \
  -DZLIB_ROOT="$(brew --prefix zlib)" \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" \
  -DIconv_INCLUDE_DIR="$(brew --prefix libiconv)/include" \
  -DIconv_LIBRARY="$(brew --prefix libiconv)/lib/libiconv.dylib" \
  -DCMAKE_FIND_DEBUG_MODE=ON
```

The shell helper computes both environment variables rather than trusting ambient values. Expected: configure exits 0, creates Ninja configuration only, records all imported targets and paths, uses Apple Clang, and does not compile or link the core.

- [ ] **Step 7: Inspect deployment-target and optional-feature evidence**

Run configure-only probes in separate ignored directories for deployment targets `13.0`, `14.0`, and `15.0`, always with NAT-PMP/TBB OFF. Record compiler-test acceptance and package resolution for each. Keep `14.0` as the reviewed Phase 2 target because it is the declared broad-compatibility baseline and requires no legacy-specific patch; explicitly note that Homebrew bottle minimum OS compatibility is not accepted as a final publication guarantee.

Create one additional ignored wrapper probe at `Build/airdcpp-core/optional-on` using the exact final command except `-DENABLE_NATPMP=ON -DENABLE_TBB=ON`. Expected with the recorded host inventory: configure remains nonfatal, `natpmp` and TBB are reported not found, `Mapper_NATPMP.cpp` is removed, and neither `HAVE_NATPMP_H` nor `HAVE_INTEL_TBB` appears. Compare that evidence with the source-inspected upstream defaults and the final OFF/OFF log; final configure must not search for or resolve `libnatpmp` or `TBB::tbb`.

- [ ] **Step 8: Commit package adapters**

```bash
git add cmake/modules/Findminiupnpc.cmake cmake/modules/Findmaxminddb.cmake \
  tests/find_modules_test.sh CMakeLists.txt
git commit -m "feat: adapt Homebrew configure packages"
```

---

### Task 4: Implement the Stable Configure-Only Build Entry Point

**Files:**
- Create: `scripts/build`
- Create: `tests/build_configure_test.sh`
- Modify: `scripts/lib/configure.sh`

**Interfaces:**
- Consumes: Task 1 helper functions, top-level wrapper/toolchain, exact upstream checkout, and Homebrew package prefixes.
- Produces: command `scripts/build --configure-only`; ignored evidence directories `Build/airdcpp-core/unmodified` and `Build/airdcpp-core/release`; exit 0 only for a successful deterministic final configure.

- [ ] **Step 1: Write failing entry-point integration tests with fake tools**

Create `tests/build_configure_test.sh` around a temporary case project copied from tracked files. Fake `cmake` must log every argument, create a minimal `CMakeCache.txt` and `airdcpp-configure-summary.txt`, return 1 for the direct upstream source, and return 0 for the wrapper source. Cover:

```sh
if output=$("$CASE_ROOT/scripts/build" 2>&1); then fail "missing mode succeeded"; fi
assert_contains "$output" "usage: scripts/build --configure-only" "usage"

if output=$("$CASE_ROOT/scripts/build" --compile 2>&1); then fail "compile mode succeeded"; fi
assert_contains "$output" "Phase 2 supports only --configure-only" "scope diagnostic"

output=$(PATH="$FAKE_BIN:$PATH" "$CASE_ROOT/scripts/build" --configure-only)
assert_contains "$output" "preserved unmodified configure status 1" "first attempt"
assert_contains "$output" "configure-only Gate 2 candidate succeeded" "final configure"
assert_file_present "$CASE_ROOT/Build/airdcpp-core/unmodified/configure.log"
assert_file_present "$CASE_ROOT/Build/airdcpp-core/release/CMakeCache.txt"
assert_dir_absent "$CASE_ROOT/Dist"
assert_file_absent "$CASE_ROOT/Build/airdcpp-core/release/libairdcpp.a"
```

Build the fake CMake command with this exact dispatcher so the test proves source selection and invocation count without configuring or compiling:

```sh
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'case "${1:-}" in --version) echo "cmake version 3.31.6"; exit 0 ;; -N) cat "$3/CMakeCache.txt"; exit 0 ;; esac' \
  'printf "%s\n" "$*" >> "$FAKE_CMAKE_CALLS"' \
  'case " $* " in *" --build "*) echo "forbidden build invocation" >&2; exit 97 ;; esac' \
  'source_dir=' \
  'build_dir=' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in -S) source_dir=$2; shift 2 ;; -B) build_dir=$2; shift 2 ;; *) shift ;; esac' \
  'done' \
  'mkdir -p "$build_dir"' \
  'case "$source_dir" in' \
  '  */Source/airdcpp-core) echo "unknown CMake command CHECK_FUNCTION_EXISTS"; exit 1 ;;' \
  '  *)' \
  '    printf "CMAKE_BUILD_TYPE:STRING=Release\n" > "$build_dir/CMakeCache.txt"' \
  '    printf "architecture=arm64\ndeployment_target=14.0\nbuild_shared_libs=OFF\n" > "$build_dir/airdcpp-configure-summary.txt" ;;' \
  'esac' > "$FAKE_BIN/cmake"
chmod +x "$FAKE_BIN/cmake"

for forbidden_tool in ninja clang clang++ ar libtool; do
  printf '%s\n' '#!/bin/sh' 'echo "forbidden Phase 3 tool invocation" >&2' 'exit 97' \
    > "$FAKE_BIN/$forbidden_tool"
  chmod +x "$FAKE_BIN/$forbidden_tool"
done
```

Run `chmod +x tests/build_configure_test.sh` after creating the test. Run `chmod +x scripts/build` immediately after adding the entry point in Step 4 so its executable bit is part of the implementation commit.

Run the command a second time. Assert the unmodified log checksum is identical, its command is not invoked twice, final configure uses `--fresh`, and inventory lines remain stable. Add failure cases for missing formulas, wrong commit, dirty upstream, non-Apple compiler, a failed final configure, a symlinked `Build/airdcpp-core`, and pre-existing `Dist`. A pre-existing `Dist` must remain byte-for-byte untouched. Make fake `cmake` fail if any argument is `--build`; make fake `ninja`, `clang`, `clang++`, `ar`, or `libtool` fail immediately if invoked.

- [ ] **Step 2: Run the entry-point tests to verify they fail**

Run: `./tests/build_configure_test.sh`

Expected: FAIL because `scripts/build` does not exist.

- [ ] **Step 3: Add evidence-preservation helpers**

Extend `scripts/lib/configure.sh` with:

```text
capture_unmodified_configure(project_root, checkout, evidence_dir, cmake_prefix_path, pkg_config_path)
run_wrapper_configure(project_root, output_dir, cmake_prefix_path, pkg_config_path)
assert_configure_scope(project_root, before_parent_status, before_upstream_state)
```

`capture_unmodified_configure` creates the directory only if absent, writes normalized command/input/status files atomically, captures combined output, and never converts the expected diagnostic failure into overall script failure. If the directory already has all four files and its `inputs.txt` matches upstream commit, upstream `CMakeLists.txt` SHA-256, CMake version, formula inventory checksum, architecture, and deployment target, print a reuse message and do not overwrite it. If it is partial or its inputs differ, fail with the exact instruction `archive or remove Build/airdcpp-core/unmodified before recapturing changed inputs`.

`run_wrapper_configure` validates that the output is a real directory below `Build/airdcpp-core`, invokes CMake with `--fresh` and the exact Task 3 flags, saves combined output and a normalized literal command, then runs `cmake -N -LA` into `cache.txt`. It must not invoke any build tool.

`assert_configure_scope` compares parent Git status, upstream `HEAD`, origin, tracked/staged/untracked/unknown-ignored state, and known-generated-file fingerprints. It rejects any new `Dependencies` or `Dist` path and any file outside `Build/airdcpp-core` except tracked files already part of the implementation.

- [ ] **Step 4: Implement `scripts/build --configure-only`**

Use this control flow:

```sh
#!/bin/sh
set -eu

if [ "$#" -ne 1 ] || [ "$1" != --configure-only ]; then
  printf 'usage: scripts/build --configure-only\n' >&2
  printf 'build: error: Phase 2 supports only --configure-only\n' >&2
  exit 64
fi

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CHECKOUT=$PROJECT_ROOT/Source/airdcpp-core
BUILD_ROOT=$PROJECT_ROOT/Build/airdcpp-core
. "$PROJECT_ROOT/scripts/lib/upstream.sh"
. "$PROJECT_ROOT/scripts/lib/configure.sh"

load_upstream_config "$PROJECT_ROOT/config/upstream.env" || exit 1
assert_supported_host
validate_configure_checkout "$PROJECT_ROOT" "$CHECKOUT" "$AIRDCPP_CORE_COMMIT"

missing=$(missing_required_formulae)
[ -z "$missing" ] || configure_die "missing required Homebrew formulae:\n$missing\ninstall only these names with brew install"

[ ! -L "$PROJECT_ROOT/Build" ] || configure_die "refusing symlinked Build directory"
mkdir -p "$PROJECT_ROOT/Build"
[ ! -e "$BUILD_ROOT" ] || [ -d "$BUILD_ROOT" ] || configure_die "Build/airdcpp-core is not a directory"
[ ! -L "$BUILD_ROOT" ] || configure_die "refusing symlinked Build/airdcpp-core"
mkdir -p "$BUILD_ROOT/evidence"

before_parent_status=$(git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all)
before_upstream_state=$(git -C "$CHECKOUT" status --porcelain=v1 --untracked-files=all)
cmake_prefix_path=$(dependency_cmake_prefix_path)
pkg_config_path=$(dependency_pkg_config_path)

write_host_inventory "$BUILD_ROOT/evidence/host-inventory.txt"
capture_unmodified_configure "$PROJECT_ROOT" "$CHECKOUT" \
  "$BUILD_ROOT/unmodified" "$cmake_prefix_path" "$pkg_config_path"
run_wrapper_configure "$PROJECT_ROOT" "$BUILD_ROOT/release" \
  "$cmake_prefix_path" "$pkg_config_path"
assert_configure_scope "$PROJECT_ROOT" "$before_parent_status" "$before_upstream_state"

printf 'build: configure-only Gate 2 candidate succeeded; no AirDC++ Core compilation was invoked\n'
```

Before CMake runs, print source commit, compiler path/version, architecture, deployment target, Release/static/C++20/libc++ policy, NAT-PMP/TBB flags, Homebrew prefix, formula versions, build mode, and evidence paths. On final failure, report the failed phase, exact log path, and corrective action. On success, print `build: configure-only Gate 2 candidate succeeded; no compilation was invoked`.

- [ ] **Step 5: Run hermetic entry-point and all offline tests**

Run:

```bash
./tests/build_configure_test.sh
./tests/configure_helpers_test.sh
./tests/cmake_wrapper_test.sh
./tests/find_modules_test.sh
./tests/upstream_config_test.sh
./tests/update_test.sh
```

Expected: every script prints `PASS`; no test contacts the network or Homebrew API, no `Dist` exists, and no core artifact exists.

- [ ] **Step 6: Commit configure orchestration**

```bash
git add scripts/build scripts/lib/configure.sh tests/build_configure_test.sh
git commit -m "feat: add configure-only build orchestration"
```

---

### Task 5: Exercise and Lock the Real Gate 2 Test

**Files:**
- Create: `tests/gate2_configure_test.sh`
- Evidence only, ignored: `Build/airdcpp-core/evidence/*`
- Evidence only, ignored: `Build/airdcpp-core/unmodified/*`
- Evidence only, ignored: `Build/airdcpp-core/release/*`

**Interfaces:**
- Consumes: `AIRDCCORE_RUN_CONFIGURE_TESTS=1`, the real installed formula set, pinned upstream checkout, and `scripts/build --configure-only`.
- Produces: one real configure-only Gate 2 assertion with no AirDC++ Core target build, package installation, or publication side effects.

- [ ] **Step 1: Write the opt-in Gate 2 test before relying on the real configure**

Create `tests/gate2_configure_test.sh` with this contract:

```sh
#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
. "$ROOT/scripts/lib/upstream.sh"

[ "${AIRDCCORE_RUN_CONFIGURE_TESTS:-0}" = 1 ] ||
  fail "set AIRDCCORE_RUN_CONFIGURE_TESTS=1 to run the real Gate 2 configure test"

CHECKOUT=$ROOT/Source/airdcpp-core
BEFORE_PARENT=$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)
BEFORE_UPSTREAM=$(git -C "$CHECKOUT" status --porcelain=v1 --untracked-files=all)

output=$("$ROOT/scripts/build" --configure-only)
assert_contains "$output" "no compilation was invoked" "configure-only success"
assert_line "$ROOT/Build/airdcpp-core/release/airdcpp-configure-summary.txt" \
  "architecture=arm64" "configured architecture"
assert_line "$ROOT/Build/airdcpp-core/release/airdcpp-configure-summary.txt" \
  "deployment_target=14.0" "configured target"
assert_line "$ROOT/Build/airdcpp-core/release/airdcpp-configure-summary.txt" \
  "build_shared_libs=OFF" "static policy"
assert_file_absent "$ROOT/Build/airdcpp-core/release/libairdcpp.a"
assert_dir_absent "$ROOT/Dist"
assert_dir_absent "$ROOT/Dependencies"
assert_eq "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" \
  "$BEFORE_PARENT" "parent status"
assert_eq "$(git -C "$CHECKOUT" status --porcelain=v1 --untracked-files=all)" \
  "$BEFORE_UPSTREAM" "upstream status"

printf 'PASS: Gate 2 configured pinned AirDC++ Core without compilation\n'
```

Extend it to assert exact upstream commit/origin, AppleClang IDs, C++20, libc++, Release, NAT-PMP/TBB OFF, all required target evidence, Homebrew resolved paths, first-attempt log immutability across a second run, and absence of AirDC++ Core `.o`, `.a`, `.dylib`, Ninja invocation logs, `Dist`, and `Dependencies` output. Permit only CMake's own compiler-identification and `Check*` probe products below `CMakeFiles`; `build.ninja` itself is an expected configure file, while executing Ninja is forbidden.

Run `chmod +x tests/gate2_configure_test.sh` after creating the file.

- [ ] **Step 2: Verify the opt-in guard fails safely**

Run: `./tests/gate2_configure_test.sh`

Expected: FAIL with the exact enablement instruction and no changed files.

- [ ] **Step 3: Run the real Gate 2 configure twice**

Run:

```bash
AIRDCCORE_RUN_CONFIGURE_TESTS=1 ./tests/gate2_configure_test.sh
AIRDCCORE_RUN_CONFIGURE_TESTS=1 ./tests/gate2_configure_test.sh
```

Expected: both runs print `PASS`; the unmodified evidence checksum is unchanged; final configure is safely refreshed; no AirDC++ Core target compile command runs; parent and upstream state are unchanged.

- [ ] **Step 4: Inspect exact package resolution and warnings**

Run:

```bash
cmake -N -LA Build/airdcpp-core/release
grep -E 'AIRDCCORE|_DIR:|_LIBRARY:|_INCLUDE_DIR:|AppleClang|arm64|14\.0|NATPMP|TBB' \
  Build/airdcpp-core/release/configure.log
find Build/airdcpp-core/release/upstream -type f \
  \( -name '*.o' -o -name '*.a' -o -name '*.dylib' \)
```

Expected: every required package path is explainable by the recorded Homebrew prefix or selected SDK Threads interface; compiler/policy fields match; AirDC++ Core artifact search prints nothing. CMake compiler/check-probe products may exist outside the upstream target directory. Classify each warning as accepted discovery evidence or a Gate 2 blocker. Do not suppress a warning merely to make the report green.

- [ ] **Step 5: Commit the real gate test**

```bash
git add tests/gate2_configure_test.sh
git commit -m "test: lock configure-only Gate 2"
```

---

### Task 6: Publish the Reviewed Gate 2 Report and Operator Documentation

**Files:**
- Create: `docs/reports/2026-09-05-gate-2-native-configure.md`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/dependencies.md`
- Modify: `docs/build-and-release.md`

**Interfaces:**
- Consumes: preserved raw logs, final cache/summary, real Gate 2 test results, and the authoritative design.
- Produces: a reviewable normalized evidence record and documented `scripts/build --configure-only` operator contract.

- [ ] **Step 1: Write a failing report-contract check**

Add a report validation section to `tests/gate2_configure_test.sh` that requires these exact headings and assertions:

```text
## Scope and result
## Source identity and cleanliness
## Host and tool inventory
## Homebrew formula inventory
## Unmodified upstream configure
## Wrapper-only configure
## Adaptations and evidence
## Final deterministic configure
## Deployment target decision
## Optional NAT-PMP and TBB behavior
## Package resolution
## Warnings and failures
## Rerun and scope verification
## Gate 2 review decision
```

Reject the report if it contains `/Users/`, claims that `Dist` or `libairdcpp.a` was produced, makes an AirDC++ Core compile-success claim, uses `ENABLE_NATPMP=ON` in the final-command section, uses `ENABLE_TBB=ON` in the final-command section, or claims package resolution for WebSocket++, nlohmann-json, npm, or Boost system. Allow optional ON values only in the clearly labeled unmodified and optional-probe sections, and require explicit statements that `Dist` and `libairdcpp.a` are absent.

- [ ] **Step 2: Run the report check to verify it fails**

Run: `AIRDCCORE_RUN_CONFIGURE_TESTS=1 ./tests/gate2_configure_test.sh`

Expected: FAIL because the tracked Gate 2 report is absent.

- [ ] **Step 3: Create the reviewed Gate 2 report from raw evidence**

Create `docs/reports/2026-09-05-gate-2-native-configure.md` with every required heading. Include:

- exact upstream URL and full commit;
- exact normalized commands using `$PROJECT_ROOT` rather than a user-home path;
- macOS, architecture, Xcode/build, Apple Clang, SDK, Git, Python, Homebrew, CMake, and Ninja versions;
- each required/optional formula version or explicit absence and its `/opt/homebrew/opt/<formula>` resolution;
- unmodified exit code, first fatal diagnostic, warnings, default NAT-PMP/TBB observations, and the log SHA-256;
- wrapper-only exit code and exact package/config mismatch;
- a table mapping each wrapper/module adaptation to the prior evidence that justified it;
- final exit code 0, cache/summary fields, imported-target locations/interfaces, package-config paths, warnings, and explicit no-compile proof;
- deployment probes for 13.0, 14.0, and 15.0 plus the reviewed 14.0 selection and its limitations;
- final NAT-PMP/TBB OFF evidence and statement that optional formula absence cannot alter the final configuration;
- parent/upstream before-and-after status, generated-file fingerprints, idempotent second-run evidence, and absence of `Dependencies`, `Dist`, objects, archives, and shared libraries;
- an explicit Gate 2 review decision. Mark Gate 2 accepted only when final configure and every scope assertion pass; otherwise mark it blocked and do not proceed to Phase 3.

Do not copy broad environment dumps, timestamps, usernames, `/Users/...` paths, secrets, or unreviewed raw logs into the tracked report.

- [ ] **Step 4: Update concise operator documentation**

Update `README.md` with:

```text
./scripts/update
./scripts/build --configure-only
AIRDCCORE_RUN_CONFIGURE_TESTS=1 ./tests/gate2_configure_test.sh
```

State that the first command reconstructs source, the second configures only, the third exercises the real Gate 2 check, Homebrew inputs are discovery-only, and Phase 3 compilation remains outside the command.

Update `docs/architecture.md` with the flow `scripts/build -> scripts/lib/configure.sh -> wrapper/toolchain -> unmodified Source`, with all raw output below `Build/airdcpp-core` and only the normalized report tracked.

Update `docs/dependencies.md` with the exact Gate 2 formula inventory, resolved paths, explicit NAT-PMP/TBB OFF policy, and a warning that no Phase 2 formula becomes a publication dependency or `Dependencies` source pin.

Update `docs/build-and-release.md` with Gate 2 commands, enablement variable, expected report path, configure-only guarantees, and the hard stop before Phase 3.

- [ ] **Step 5: Run the report check and complete regression suite**

Run:

```bash
AIRDCCORE_RUN_CONFIGURE_TESTS=1 ./tests/gate2_configure_test.sh
./tests/build_configure_test.sh
./tests/configure_helpers_test.sh
./tests/cmake_wrapper_test.sh
./tests/find_modules_test.sh
./tests/upstream_config_test.sh
./tests/update_test.sh
```

Expected: all tests print `PASS`; real configure remains compile-free.

- [ ] **Step 6: Commit Gate 2 evidence and documentation**

```bash
git add docs/reports/2026-09-05-gate-2-native-configure.md README.md \
  docs/architecture.md docs/dependencies.md docs/build-and-release.md \
  tests/gate2_configure_test.sh
git commit -m "docs: record native configure discovery gate"
```

---

### Task 7: Final Phase 2 Review and Branch Verification

**Files:**
- Modify only if review finds a defect: files created or changed in Tasks 1-6

**Interfaces:**
- Consumes: authoritative spec, all Phase 2 commits, tracked report, ignored raw evidence, and GitFlow branch state.
- Produces: a clean, reviewable `feature/native-configure-discovery` branch that stops before Phase 3.

- [ ] **Step 1: Review every Phase 2 and Gate 2 requirement against evidence**

Use a checklist mapping each requirement to a file, test, and report section: host inventory; required package installation; unmodified attempt; missing modules; parent variables; package mismatches; C++20; deployment candidates/choice; NAT-PMP/TBB behavior; wrapper preference; Apple Clang rejection; ARM64/Release/static/libc++ policy; output isolation; exact paths; upstream cleanliness; rerun safety; actionable failures; report review; no Phase 3.

Expected: every row has one concrete implementation path, one passing assertion, and one report reference. Fix any uncovered requirement before continuing.

- [ ] **Step 2: Scan for placeholders and interface drift**

Run:

```bash
rg -n 'TBD|TODO|implement later|fill in|appropriate error|similar to' \
  CMakeLists.txt cmake scripts tests README.md docs
rg -n 'configure_only|configure-only|AIRDCPP_CORE_SOURCE_DIR|ENABLE_NATPMP|ENABLE_TBB' \
  CMakeLists.txt cmake scripts tests README.md docs
```

Expected: no planning placeholders; all command names, cache variables, flags, helper names, and evidence paths match this plan exactly. Existing upstream prose that legitimately contains one scanned word must be manually classified rather than edited without cause.

- [ ] **Step 3: Prove scope boundaries mechanically**

Run:

```bash
rg -n 'cmake[[:space:]]+--build|(^|[[:space:]])ninja([[:space:]]|$)|libtool|(^|/)ar([[:space:]]|$)' scripts tests
find Build/airdcpp-core/release/upstream -type f \
  \( -name '*.o' -o -name '*.a' -o -name '*.dylib' \)
git ls-files Source Dependencies Build Dist
git status --short --ignored
```

Expected: production scripts contain no AirDC++ Core build invocation; test occurrences are only explicit fail-fast sentinels; upstream-target artifact search and tracked generated-path search print nothing; ignored output is confined to approved paths. CMake's own compiler/check probes are configure evidence, not Phase 3 output.

- [ ] **Step 4: Run Markdown, link, whitespace, and diff checks**

Run:

```bash
git diff --check origin/develop...HEAD
rg -n '\[[^]]+\]\([^)]*\)' README.md docs
test -f docs/superpowers/specs/2026-09-04-airdc-core-macos-design.md
test -f docs/reports/2026-09-05-gate-2-native-configure.md
```

Manually resolve every relative documentation link from its containing directory. Expected: no whitespace errors, broken local links, or references to files outside the locked file map.

- [ ] **Step 5: Run final offline and opt-in verification**

Run:

```bash
./tests/upstream_config_test.sh
./tests/update_test.sh
./tests/configure_helpers_test.sh
./tests/cmake_wrapper_test.sh
./tests/find_modules_test.sh
./tests/build_configure_test.sh
AIRDCCORE_RUN_CONFIGURE_TESTS=1 ./tests/gate2_configure_test.sh
```

Expected: every test prints `PASS`; no AirDC++ Core target build or package installation occurs during test execution; the real Gate 2 test performs configure only.

- [ ] **Step 6: Review branch history and make one correction commit only if needed**

Run:

```bash
git status --short --branch
git log --oneline --decorate origin/develop..HEAD
git diff --stat origin/develop...HEAD
```

Expected logical commits, in order:

```text
test: define configure discovery prerequisites
feat: establish ARM64 configure wrapper
feat: adapt Homebrew configure packages
feat: add configure-only build orchestration
test: lock configure-only Gate 2
docs: record native configure discovery gate
```

If review fixes were required, commit them as:

```bash
git add CMakeLists.txt scripts/build scripts/lib/configure.sh \
  cmake/toolchains/macos-arm64.cmake cmake/modules/AirDCCorePolicy.cmake \
  cmake/modules/Findminiupnpc.cmake cmake/modules/Findmaxminddb.cmake \
  tests/test_helper.sh tests/configure_helpers_test.sh tests/cmake_wrapper_test.sh \
  tests/find_modules_test.sh tests/build_configure_test.sh tests/gate2_configure_test.sh \
  tests/fixtures/configure-upstream/CMakeLists.txt README.md docs/architecture.md \
  docs/dependencies.md docs/build-and-release.md \
  docs/reports/2026-09-05-gate-2-native-configure.md
git commit -m "fix: close native configure review gaps"
```

Expected final status: clean `feature/native-configure-discovery`, based on `origin/develop`, with no `master` creation and no Phase 3 artifacts or commits.
