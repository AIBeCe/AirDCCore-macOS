# External Consumer Link Interface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove and document the minimal complete macOS ARM64 link interface for the Phase 3 `libairdcpp.a` by compiling, force-loading, linking, and running a real external C++ consumer.

**Architecture:** Add a tracked `smoke-test` project that consumes only a staged header tree and copied Core archive, never the upstream CMake target. A new `scripts/build --link-consumer` mode stages those inputs under the ignored `Build/airdcpp-core/link-interface` tree, preserves a Core-only failing link, resolves the candidate Homebrew-assisted dependency closure through explicit imported targets, tests one-at-a-time omissions to prove the minimal interface, and records normalized evidence. An opt-in Gate 4 independently validates the executable, runtime result, architecture, closure evidence, and absence of path leakage without rebuilding Core or creating `Dist`.

**Tech Stack:** POSIX shell, CMake 3.25+, Ninja, Apple Clang/libc++, C++20, Apple `nm`/`otool`/`file`/`lipo`, Python 3 only where structured archive/symbol parsing is clearer than shell.

**Spec:** `docs/superpowers/specs/2026-09-04-airdc-core-macos-design.md`, especially sections 9–11, 13.2–13.4, 15, and Phase 4/Gate 4 in section 16.

## Global Constraints

- Work only on `feature/consumer-link-interface`, created from merged local `develop`; do not edit `develop`, create `master`, push, package, or begin Phase 5.
- Keep the pinned upstream URL and commit unchanged: `https://github.com/airdcpp/airdcpp-core.git` at `55d51ceb817ec006d4ec844d9e3788e1b0ccc352`.
- Preserve the Phase 3 candidate and its evidence. Do not rebuild Core unless an evidence-backed amendment is approved after a failed Gate 4 experiment.
- Use Apple Clang/libc++, Release, C++20 with extensions OFF, `arm64`, deployment target `14.0`, `BUILD_SHARED_LIBS=OFF`, `ENABLE_NATPMP=OFF`, and `ENABLE_TBB=OFF`.
- The consumer must reference a real out-of-line AirDC++ Core symbol, force-load all Core archive members for closure discovery, run without network or mutable user state, and fail if the Core archive is omitted.
- The consumer may use Homebrew packages only as Phase 4 discovery inputs. It must not create `Dependencies` or `Dist`, decide the Phase 5 distribution shape, or claim release reproducibility.
- Tracked smoke sources, tests, scripts, reports, and normalized metadata may be committed. `Source`, `Build`, the staged headers/archive, executable, raw logs, and dependency binaries remain ignored.
- Raw ignored evidence may contain machine paths needed to reproduce the link. The tracked report and normalized closure file must replace the worktree root with `$PROJECT_ROOT`; the executable and its load commands must contain no `Source`, `Build`, user-home, or worktree path.
- Any first real-link failure not predicted by this plan is preserved verbatim and stops execution for a reviewed amendment; do not guess through linker errors.

## File Structure

- `smoke-test/main.cpp`: deterministic external consumer; calls `dcpp::getVersionTag()` and prints one normalized line.
- `smoke-test/CMakeLists.txt`: standalone consumer project; imports a staged `libairdcpp.a`, finds the explicit candidate packages, applies `-force_load`, and supports one named omission for closure tests.
- `scripts/lib/link_consumer.sh`: validates Gate 3 inputs, stages headers/archive, runs Core-only/full/omission configurations, executes the binary, and writes raw evidence.
- `scripts/lib/normalize_link_evidence.py`: parses the successful verbose link line and omission results into stable ordered TSV evidence with project-root normalization.
- `scripts/build`: dispatches exact `--link-consumer` mode without changing prior modes.
- `tests/smoke_consumer_test.sh`: fixture-backed compile/link/run and real-symbol contract tests.
- `tests/link_consumer_test.sh`: offline orchestration, staging, failure preservation, omission, scope, and symlink tests.
- `tests/link_evidence_test.py`: parser ordering, normalization, malformed-input, and duplicate-item tests.
- `tests/gate4_consumer_link_test.sh`: opt-in read-only verification of the actual Gate 4 candidate.
- `tests/gate4_contract_test.sh`: copied-evidence rejection tests that never mutate real evidence.
- `docs/reports/2026-09-21-gate-4-consumer-link.md`: measured link closure, runtime result, dependency disposition, warnings, and explicit limits.
- `README.md`, `docs/architecture.md`, `docs/build-and-release.md`, `docs/dependencies.md`: operator entry point and Phase 4 status.

## Review Focus

1. A consumer that compiles but never pulls Core object code must fail the test contract; the successful executable must contain the `dcpp::getVersionTag()` reference path and fail when the Core archive is omitted.
2. A dependency hidden transitively by another imported target must not be claimed as a direct requirement; one-at-a-time omission results and the final verbose link command must agree.
3. A stale or substituted Phase 3 archive/header tree must be rejected before linking; staged manifests must bind the upstream commit, archive SHA-256, and every staged header hash.
4. Symlinked `Source`, `Build`, link-interface, stage, evidence, or executable paths must be rejected before any copy, configure, link, or run action.
5. Absolute worktree, user-home, `Source`, or `Build` strings in the executable/load commands or normalized closure must fail Gate 4; raw ignored logs remain explicitly outside this normalized contract.

---

### Task 1: Standalone real-symbol smoke consumer

**Files:**
- Create: `smoke-test/main.cpp`
- Create: `smoke-test/CMakeLists.txt`
- Create: `tests/smoke_consumer_test.sh`

**Interfaces:**
- Consumes: staged include root passed as `AIRDCCORE_INCLUDE_DIR`, staged archive passed as `AIRDCCORE_LIBRARY`, tracked module root passed as `AIRDCCORE_MODULE_DIR`, optional omission name `AIRDCCORE_OMIT_LINK_ITEM`.
- Produces: CMake target `airdcpp-smoke`; stdout contract `AirDC++ Core <nonempty-version>\n`; CMake cache entries containing the selected Core inputs and omission.

- [ ] **Step 1: Write the failing fixture-backed smoke test.**

Create `tests/smoke_consumer_test.sh` with a temporary staged include tree defining the real public signature, a fixture static archive defining it, and assertions that standalone CMake/Ninja can compile, link, and run the tracked source:

```sh
mkdir -p "$WORK/stage/include/airdcpp/core" "$WORK/stage/lib"
printf '%s\n' '#pragma once' '#include <string>' 'using std::string;' \
  > "$WORK/stage/include/airdcpp/stdinc.h"
printf '%s\n' '#pragma once' \
  'namespace dcpp { string getVersionTag() noexcept; }' \
  > "$WORK/stage/include/airdcpp/core/version.h"
printf '%s\n' '#include <string>' \
  'namespace dcpp { std::string getVersionTag() noexcept { return "fixture"; } }' \
  > "$WORK/version.cpp"
xcrun clang++ -std=c++20 -arch arm64 -c "$WORK/version.cpp" -o "$WORK/version.o"
/usr/bin/libtool -static -o "$WORK/stage/lib/libairdcpp.a" "$WORK/version.o"
cmake -S "$ROOT/smoke-test" -B "$WORK/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DAIRDCCORE_INCLUDE_DIR="$WORK/stage/include" \
  -DAIRDCCORE_LIBRARY="$WORK/stage/lib/libairdcpp.a" \
  -DAIRDCCORE_TEST_LINK_ITEMS=fixture
cmake --build "$WORK/build" --verbose
assert_eq "$("$WORK/build/airdcpp-smoke")" 'AirDC++ Core fixture' 'smoke output'
```

Add negative cases for an absent archive, a symlinked archive, non-ARM64 CMake architecture, missing staged `airdcpp/stdinc.h`, and a fixture archive without `dcpp::getVersionTag()`.

- [ ] **Step 2: Run RED and confirm the missing project is the cause.**

Run: `./tests/smoke_consumer_test.sh`

Expected: FAIL because `smoke-test/CMakeLists.txt` and `smoke-test/main.cpp` do not exist.

- [ ] **Step 3: Implement the minimal deterministic consumer source.**

Create `smoke-test/main.cpp`:

```cpp
#include <airdcpp/stdinc.h>
#include <airdcpp/core/version.h>

#include <iostream>
#include <string>

int main() {
    const std::string version = dcpp::getVersionTag();
    if (version.empty()) {
        std::cerr << "AirDC++ Core version is empty\n";
        return 1;
    }
    std::cout << "AirDC++ Core " << version << '\n';
    return 0;
}
```

Create `smoke-test/CMakeLists.txt` as a standalone project. Require all inputs to be absolute, regular, non-symlinked paths; reject architecture other than exactly `arm64`; create imported target `AirDCCore::Core`; apply `target_link_options(airdcpp-smoke PRIVATE "LINKER:-force_load,$<TARGET_FILE:AirDCCore::Core>")`; link the explicit dependency target list unless its logical name equals `AIRDCCORE_OMIT_LINK_ITEM`. `AIRDCCORE_TEST_LINK_ITEMS=fixture` must skip package discovery only for the isolated fixture and still link the imported Core archive.

- [ ] **Step 4: Run GREEN and prove the symbol is not header-only.**

Run: `./tests/smoke_consumer_test.sh`

Expected: PASS; the no-Core and no-symbol cases fail during link, and the valid fixture prints exactly `AirDC++ Core fixture`.

- [ ] **Step 5: Commit the standalone consumer.**

```sh
git add smoke-test/main.cpp smoke-test/CMakeLists.txt tests/smoke_consumer_test.sh
git commit -m "test: add real-symbol external Core consumer"
```

### Task 2: Safe staging and `--link-consumer` orchestration

**Files:**
- Create: `scripts/lib/link_consumer.sh`
- Modify: `scripts/build`
- Create: `tests/link_consumer_test.sh`

**Interfaces:**
- Consumes: Phase 3 `core-release` evidence, pinned checkout, `smoke-test`, and the configuration helpers in `scripts/lib/configure.sh`.
- Produces: ignored `Build/airdcpp-core/link-interface/stage`, `core-only`, `full`, `omissions`, `run`, `header-manifest.sha256`, `input-manifest.txt`, and exact status/log files.

- [ ] **Step 1: Write failing orchestration tests using fake tools and a real tiny ARM64 archive.**

In `tests/link_consumer_test.sh`, copy tracked files into isolated cases, construct a detached pinned fixture checkout with `airdcpp/core/version.h`, and create a Gate 3-shaped candidate. Assert:

```sh
output=$(PATH="$FAKE_BIN:$PATH" "$CASE_ROOT/scripts/build" --link-consumer)
assert_contains "$output" 'build: mode=link-consumer' 'mode banner'
assert_file_present "$CASE_ROOT/Build/airdcpp-core/link-interface/stage/include/airdcpp/core/version.h"
assert_file_present "$CASE_ROOT/Build/airdcpp-core/link-interface/stage/lib/libairdcpp.a"
assert_file_present "$CASE_ROOT/Build/airdcpp-core/link-interface/header-manifest.sha256"
assert_dir_absent "$CASE_ROOT/Dist"
assert_dir_absent "$CASE_ROOT/Dependencies"
```

Add cases proving rejection of wrong upstream HEAD/origin, changed archive hash/member report, missing Gate 3 evidence, symlinked `Source`, `Build`, `Build/airdcpp-core`, `link-interface`, stage header/archive/output, and mutation of a Gate 2/Core sibling. Assert a rerun with identical inputs preserves the previous attempt under a sequential hash-checked attempt directory before replacing current logs.

- [ ] **Step 2: Run RED and confirm the unsupported mode is the cause.**

Run: `./tests/link_consumer_test.sh`

Expected: FAIL with `unsupported build mode: --link-consumer`.

- [ ] **Step 3: Add exact dispatch and safe validation.**

Extend the usage to `scripts/build (--configure-only|--build-core|--link-consumer)` and dispatch only exact `--link-consumer` to `/bin/sh "$PROJECT_ROOT/scripts/lib/link_consumer.sh" "$PROJECT_ROOT"`.

In `link_consumer.sh`, source `upstream.sh` and `configure.sh`; validate the native host, pin/origin/detached checkout, clean upstream with only the two known generated files, no symlinked ancestor/output component, absent `Dist`/`Dependencies`, successful Gate 3 status, current archive SHA/member report, and unchanged parent/Core-sibling snapshots. Use an allowlist to stage all regular non-symlinked files matching `airdcpp/**/*.h` plus required generated `*.inc`, excluding `airdcpp/modules/**`; preserve paths below `stage/include`. Copy the candidate archive to `stage/lib/libairdcpp.a`, then hash every staged file in sorted relative-path order.

Write `input-manifest.txt` with exactly:

```text
upstream.commit=<configured full commit>
core.archive.sha256=<measured digest>
core.members.sha256=<measured digest>
headers.manifest.sha256=<measured digest>
architecture=arm64
deployment_target=14.0
build_type=Release
cxx_standard=20
enable_natpmp=OFF
enable_tbb=OFF
```

- [ ] **Step 4: Add deterministic attempt preservation and command capture.**

For each `core-only`, `full`, and omission case, capture `configure-command.txt`, `configure.log`, `configure-exit-code.txt`, `build-command.txt`, `build.log`, and `build-exit-code.txt`. Before a rerun, require every expected file to be regular/non-symlinked, build a complete SHA-256 manifest, atomically move the prior record into `attempts/0001`, `0002`, and so on, and reject gaps, extra files, or digest changes. Scope checks run on success and failure.

- [ ] **Step 5: Run GREEN and the existing offline regression suite.**

Run:

```sh
./tests/link_consumer_test.sh
for test_script in tests/upstream_config_test.sh tests/update_test.sh \
  tests/configure_helpers_test.sh tests/cmake_wrapper_test.sh \
  tests/find_modules_test.sh tests/build_configure_test.sh \
  tests/build_core_test.sh tests/smoke_consumer_test.sh; do
  "$test_script"
done
python3 -m unittest tests/archive_inspect_test.py -v
```

Expected: all PASS; no live Core rebuild or consumer link occurs in offline tests.

- [ ] **Step 6: Commit staging/orchestration.**

```sh
git add scripts/build scripts/lib/link_consumer.sh tests/link_consumer_test.sh
git commit -m "feat: stage isolated Core consumer inputs"
```

### Task 3: Measured link-closure discovery and normalized evidence

**Files:**
- Modify: `scripts/lib/link_consumer.sh`
- Create: `scripts/lib/normalize_link_evidence.py`
- Create: `tests/link_evidence_test.py`
- Modify: `tests/link_consumer_test.sh`

**Interfaces:**
- Consumes: staged inputs from Task 2; logical candidate order `BZip2`, `ZLIB`, `OpenSSLSSL`, `OpenSSLCrypto`, `miniupnpc`, `leveldb`, `maxminddb`, `BoostThread`, `BoostRegex`, `Snappy`, `Threads`, `Iconv`.
- Produces: `core-undefined.txt`, `link-command.raw.txt`, `link-interface.tsv`, `omission-results.tsv`, `otool-load-commands.txt`, `binary-file.txt`, `binary-arch.txt`, and runnable `full/airdcpp-smoke`.

- [ ] **Step 1: Write parser and orchestration RED tests.**

In `tests/link_evidence_test.py`, feed a fixture verbose link command containing quoted paths with spaces, repeated transitive libraries, `-framework` pairs, `-lSystem`, and project-root paths. Require normalized ordered rows:

```text
1\tcore\tstage/lib/libairdcpp.a
2\tlibrary\t/opt/homebrew/opt/bzip2/lib/libbz2.a
3\tframework\tCoreFoundation
4\tsystem\t-lSystem
```

Assert duplicate physical libraries collapse to their first effective position, malformed framework pairs fail without publishing output, and `$PROJECT_ROOT` replaces the exact project root only (not similarly prefixed paths). In `tests/link_consumer_test.sh`, require the fake Core-only force-load to exit nonzero and remain preserved, the full case to succeed, each logical omission to emit one row, and a second minimization pass to use only items whose omission failed.

- [ ] **Step 2: Run RED and confirm missing evidence logic.**

Run:

```sh
python3 -m unittest tests/link_evidence_test.py -v
./tests/link_consumer_test.sh
```

Expected: FAIL because the normalizer and closure loop do not exist.

- [ ] **Step 3: Implement Core-only, full, and omission experiments.**

The first actual link must configure the smoke project with Core force-load and no dependency targets, then build once. Require a nonzero linker exit and at least one undefined-symbol diagnostic; if it succeeds or fails for another reason, preserve evidence and stop for review.

Configure the full candidate with the twelve explicit imported targets in upstream order. Use `find_package` through the same controlled prefixes/modules as Gate 3, but do not `add_subdirectory` or include any upstream CMake file. Build with verbose Ninja output so the exact Apple Clang link command is captured. Run one isolated configure/link per logical omission. Record `required` only when that omission fails specifically with unresolved symbols; record `transitive` when omission succeeds because another retained target supplies it; reject configuration, architecture, path, or tool failures rather than classifying them.

After the first omission pass, rebuild from a list containing only `required` items plus targets proven to supply `transitive` items. Repeat omissions against that reduced list. The fixed-point list is the Gate 4 candidate; preserve its exact order and fail if another pass changes the classification.

- [ ] **Step 4: Implement stable evidence normalization and runtime inspection.**

`normalize_link_evidence.py` accepts `--project-root`, `--command`, `--omissions`, and `--output`. Parse arguments without shell evaluation, pair `-framework` with its following name, retain archive/library/system order, normalize only the exact project root, and publish atomically after complete validation. The shell driver additionally records:

```sh
xcrun nm -u "$CORE_ARCHIVE" | LC_ALL=C sort -u > core-undefined.txt
/usr/bin/file -b full/airdcpp-smoke > binary-file.txt
/usr/bin/lipo -archs full/airdcpp-smoke > binary-arch.txt
/usr/bin/otool -L full/airdcpp-smoke > otool-load-commands.txt
full/airdcpp-smoke > run/stdout.txt 2> run/stderr.txt
printf '%s\n' "$?" > run/exit-code.txt
```

Require `arm64`, exit `0`, empty stderr, stdout beginning with `AirDC++ Core ` and a nonempty suffix, and no `Source`, `Build`, worktree root, or user-home string in `strings` output or `otool` load commands. Record Homebrew dylibs as Phase 4 discovery dependencies, not acceptable final `Dist` inputs.

- [ ] **Step 5: Run unit/offline GREEN.**

Run:

```sh
python3 -m unittest tests/link_evidence_test.py -v
./tests/link_consumer_test.sh
./tests/smoke_consumer_test.sh
```

Expected: all PASS, including fixed-point ordering and every Review Focus failure.

- [ ] **Step 6: Run the real link experiment and stop on unexpected evidence.**

Pre-check the archive hash equals `f345fe0e5fc7bbf289642e5a8846795f0e0d177288505419b0ba96cc23367441`, produced by the approved source-prefix-map Gate 3 amendment. The previous candidate hash `0bc3cc3c9a4424bbceb0bd2c1682e963ecd388b0bacc6acb3c0575aaa8e464e7` remains preserved under Gate 3 attempt evidence. Then run:

```sh
./scripts/build --link-consumer
```

Expected: Core-only force-load fails solely with unresolved symbols; the full and fixed-point links succeed; the executable is `arm64`, runs without network, and produces the declared output. If any assumption differs, preserve raw evidence, write a short failure report under `docs/reports`, and stop for an approved plan amendment before retrying.

- [ ] **Step 7: Commit measured closure implementation.**

```sh
git add scripts/lib/link_consumer.sh scripts/lib/normalize_link_evidence.py \
  tests/link_consumer_test.sh tests/link_evidence_test.py
git commit -m "feat: discover external Core link closure"
```

### Task 4: Gate 4 acceptance, report, and operator documentation

**Files:**
- Create: `tests/gate4_consumer_link_test.sh`
- Create: `tests/gate4_contract_test.sh`
- Create: `docs/reports/2026-09-21-gate-4-consumer-link.md`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/build-and-release.md`
- Modify: `docs/dependencies.md`

**Interfaces:**
- Consumes: actual ignored Gate 4 evidence and executable from Task 3.
- Produces: reviewed Gate 4 decision and stable operator commands; no package, `Dist`, dependency lock, or distribution-shape ADR.

- [ ] **Step 1: Write the opt-in live gate and copied-evidence RED contract.**

`tests/gate4_consumer_link_test.sh` must refuse before inspection unless `AIRDCCORE_RUN_LINK_TESTS=1`. Once enabled it independently verifies pin/origin/clean source, Phase 3 archive/member hashes, staged manifest, Core-only unresolved-symbol failure, fixed-point omission matrix, exact normalized closure, regular non-symlinked executable, `file`/`lipo` arm64, `otool -L`, real-symbol presence, runtime output/status, absence of `Dist`/`Dependencies`, no tracked generated paths, and unchanged parent/source/Gate 2/Gate 3 snapshots.

`tests/gate4_contract_test.sh` copies evidence into `/private/tmp`, then proves rejection of: disabled opt-in, wrong pin, changed archive, missing staged header, malformed omission row, reordered normalized link item, x86_64 executable, wrong runtime output, injected artifact path leak, and mutation during verification.

- [ ] **Step 2: Run RED and confirm only the missing tracked report blocks the live gate after syntax checks.**

Run:

```sh
sh -n tests/gate4_consumer_link_test.sh tests/gate4_contract_test.sh
AIRDCCORE_RUN_LINK_TESTS=1 ./tests/gate4_consumer_link_test.sh
```

Expected: syntax passes; live gate fails because `docs/reports/2026-09-21-gate-4-consumer-link.md` is absent.

- [ ] **Step 3: Write the measured report and concise documentation.**

The report records exact source/archive identity, staged header count/hash, smoke source and invoked symbol, Core-only unresolved-symbol result, full and fixed-point commands with `$PROJECT_ROOT` normalization, omission matrix, final ordered link interface, frameworks/system libraries, executable format/architecture/hash, `otool` load commands, stdout/status, Homebrew paths requiring Phase 6 disposition, warnings, and explicit non-claims. State that Gate 4 does not choose an artifact shape, pin dependencies, package headers/libraries, create `Dist`, prove two-clean-build reproducibility, or resolve the `HashStore.cpp:404` safety issue.

Update operator docs with:

```sh
./scripts/update
./scripts/build --build-core
./scripts/build --link-consumer
AIRDCCORE_RUN_LINK_TESTS=1 ./tests/gate4_consumer_link_test.sh
```

Explain that an already-verified Gate 3 candidate is reused; `--link-consumer` does not rebuild Core and creates no distributable output.

- [ ] **Step 4: Run complete GREEN verification.**

Run:

```sh
for test_script in tests/upstream_config_test.sh tests/update_test.sh \
  tests/configure_helpers_test.sh tests/cmake_wrapper_test.sh \
  tests/find_modules_test.sh tests/build_configure_test.sh \
  tests/build_core_test.sh tests/smoke_consumer_test.sh \
  tests/link_consumer_test.sh; do
  "$test_script"
done
python3 -m unittest tests/archive_inspect_test.py tests/link_evidence_test.py -v
AIRDCCORE_RUN_BUILD_TESTS=1 ./tests/gate3_core_build_test.sh
AIRDCCORE_RUN_LINK_TESTS=1 ./tests/gate4_consumer_link_test.sh
AIRDCCORE_RUN_LINK_TESTS=1 ./tests/gate4_contract_test.sh
git diff --check
git ls-files Source Dependencies Build Dist
```

Expected: all suites PASS; final command prints nothing. Inspect `git status --ignored --short` and require ignored output only under approved `Source`, `Build`, Python cache, and SDD ledger paths.

- [ ] **Step 5: Request one independent whole-branch review.**

Review `develop..feature/consumer-link-interface` against the spec, raw evidence, and these points: externality of the consumer, all-member force-load, omission fixed point, path-leak scan, source/evidence immutability, runtime determinism, and strict Phase 4 boundary. Important or Critical findings receive one TDD fix pass and full verification; Minor findings are either fixed if low risk or recorded with rationale.

- [ ] **Step 6: Commit Gate 4 and stop before Phase 5.**

```sh
git add README.md docs/architecture.md docs/build-and-release.md \
  docs/dependencies.md docs/reports/2026-09-21-gate-4-consumer-link.md \
  tests/gate4_consumer_link_test.sh tests/gate4_contract_test.sh
git commit -m "test: complete external consumer link gate"
```

Present the GitFlow choices for local merge, PR, or preserving the branch. Do not merge, push, create an ADR, select a distribution shape, or start Phase 5 without the user's explicit choice.

## Self-Review Result

- Spec coverage: all Phase 4 requirements map to Tasks 1–4: real public symbol, staged headers, external link, all-member closure, incremental/omission discovery, exact ordering, runtime execution, framework/system evidence, leakage checks, report, and hard stop before Phase 5.
- Scope: the plan is one gated subsystem. Phase 5 artifact-shape selection, Phase 6 dependency pinning, Phase 7 packaging, and Phase 8 release verification remain separate plans.
- Type/interface consistency: `AIRDCCORE_INCLUDE_DIR`, `AIRDCCORE_LIBRARY`, `AIRDCCORE_MODULE_DIR`, `AIRDCCORE_OMIT_LINK_ITEM`, `AIRDCCORE_TEST_LINK_ITEMS`, output tree names, and evidence filenames are identical across producer and consumer tasks.
- Review Focus coverage: real-symbol omission is in Task 1; transitive omission/fixed-point behavior in Task 3; stale inputs and symlinks in Task 2; path leakage in Tasks 3–4.
- Placeholder scan: the plan contains no unresolved implementation values; measured dependency classifications are intentionally produced by the first controlled experiment and must not be invented in advance.
