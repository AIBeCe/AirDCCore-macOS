# First ARM64 Static Core Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify an unpackaged, native macOS `arm64` Release `libairdcpp.a` from the exact pinned AirDC++ Core commit, without changing Gate 2 evidence or claiming a complete consumer link.

**Architecture:** Add a `scripts/build --build-core` mode that reuses the reviewed wrapper configuration in a separate `Build/airdcpp-core/core-release` tree and invokes only CMake's `airdcpp` target. Keep raw command, log, host, source, and archive-member evidence below that tree. An opt-in Gate 3 test verifies a first build from an absent core tree, every archive member's architecture, source boundaries, and the absence of `Dist`; it does not link an external consumer.

**Tech Stack:** POSIX shell, CMake/Ninja, Apple Clang/libc++, Python 3 standard library, Apple `file`/`lipo`/`nm`, Homebrew discovery inputs.

**Spec:** `docs/superpowers/specs/2026-09-04-airdc-core-macos-design.md` sections 9–10, 13.1, 15–16 (Phase 3 and Gate 3). The reviewed Gate 2 baseline is `docs/reports/2026-09-05-gate-2-native-configure.md`.

## Global Constraints

- Work on `feature/arm64-static-core-build`, forked from the verified local `develop` merge `bf176b2`; no direct feature work on `develop`, no push or production branch.
- Source URL `https://github.com/airdcpp/airdcpp-core.git`, exact commit `55d51ceb817ec006d4ec844d9e3788e1b0ccc352`, detached and clean except the two documented generated files.
- Native Apple Silicon macOS; Apple Clang and libc++; `arm64`, Release, C++20 required, C++ extensions OFF, `BUILD_SHARED_LIBS=OFF`, deployment target `14.0`, `ENABLE_NATPMP=OFF`, `ENABLE_TBB=OFF`.
- Homebrew formulas are first-build discovery inputs only. Do not claim static or reproducible dependency closure from this archive.
- Keep `scripts/build --configure-only`, its tests, and all existing `Build/airdcpp-core/{unmodified,evidence-history,wrapper-baseline,release,deployment-*,optional-on}` evidence intact. Core output is **only** `Build/airdcpp-core/core-release`; do not run the Phase 2 live gate after building Core in this same checkout, because its intentional no-Core-artifact assertion must then fail.
- No `Dependencies`, `Dist`, installed headers, aggregate archive, external smoke consumer, final link interface, package pins, release, or Phase 4 work.
- Inspect the pinned upstream `CMakeLists.txt` and actual first failure before any upstream patch. Prefer a narrow wrapper fix. A failure not covered by this plan stops execution for a reviewed, evidence-backed amendment; do not improvise a broad patch.

## Review Focus

1. A pre-existing symlink in `Build`, `Build/airdcpp-core`, or `core-release` must fail before CMake writes through it (Task 1 test).
2. Wrong source commit, changed origin, or unapproved source file must fail before configuration/build (Task 1 test).
3. A failed `cmake --build` must keep its command, log, and exit status, never print success, and never publish `Dist` (Task 1 test).
4. Duplicate archive member names must each be inspected independently; an x86_64 member or malformed archive must fail Gate 3 (Task 3 tests).
5. A rerun must not overwrite the historical Gate 2 raw capture or silently accept a different build tool/formula inventory (Tasks 1 and 4 tests).

---

### Task 1: Separate core-build entry point and hermetic contract

**Files:** Modify `scripts/build`; create `scripts/lib/core_build.sh`, `tests/build_core_test.sh`; modify `tests/build_configure_test.sh` only where the old single-mode usage assertion must change.

**Interfaces:** `scripts/build --configure-only` remains the current operation. `scripts/build --build-core` takes no other arguments, sources `scripts/lib/upstream.sh` and `scripts/lib/configure.sh`, and writes only under `Build/airdcpp-core/core-release`. Its successful archive path is `core-release/upstream/libairdcpp.a`; CMake's configured Ninja graph already names that target and path. `scripts/lib/core_build.sh` is the single owner of the build-mode preflight, command/log/status capture, and postconditions.

- [ ] **Step 1: Write failing CLI tests.** In `tests/build_core_test.sh`, follow the isolated fixture/fake-tool setup in `tests/build_configure_test.sh`. Assert `--build-core` dispatches one wrapper configure and one `cmake --build ... --target airdcpp --config Release --parallel 2`; its output tree is `core-release`, not `release`; `--configure-only` still runs; unknown and extra arguments fail. Before putting fake tools on `PATH`, make a tiny real arm64 archive fixture with `xcrun clang -c -arch arm64` and `/usr/bin/libtool -static`; fake `cmake --build` copies it to `core-release/upstream/libairdcpp.a` only on its success path. This keeps the test valid after Task 3 adds real archive inspection. A minimal central assertion is:

```sh
output=$(PATH="$FAKE_BIN:$PATH" "$CASE_ROOT/scripts/build" --build-core)
assert_contains "$output" 'build: core archive candidate=' 'core mode result'
assert_contains "$(cat "$FAKE_CMAKE_CALLS")" '--target airdcpp --config Release --parallel 2' 'target-only build'
assert_file_present "$CASE_ROOT/Build/airdcpp-core/core-release/upstream/libairdcpp.a"
assert_file_absent "$CASE_ROOT/Build/airdcpp-core/release/upstream/libairdcpp.a"
assert_dir_absent "$CASE_ROOT/Dist"
```

  Add separate cases for a symlinked core output, wrong pinned `HEAD`, changed origin, an unexpected ignored source file, failed fake build (preserved nonzero `build-exit-code.txt` and `build.log`), a second invocation that leaves Gate 2 capture file hashes unchanged, and changed CMake/formula inventory rejected before rerun. In the existing configure test, keep unknown-mode rejection but update its expected usage text to list both supported modes.

- [ ] **Step 2: Run RED.** Run `./tests/build_core_test.sh` and `./tests/build_configure_test.sh`. Expect the new test to fail because `--build-core` is not yet accepted; the existing suite must identify only the intentionally changed usage assertion.

- [ ] **Step 3: Implement the smallest dispatch and build path.** Keep the existing configure-only body in `scripts/build`. Resolve `PROJECT_ROOT` before an early exact-argument dispatch to `scripts/lib/core_build.sh`. In the new script, use the existing `load_upstream_config`, `assert_supported_host`, `validate_configure_checkout`, `missing_required_formulae`, `dependency_cmake_prefix_path`, `dependency_pkg_config_path`, `prepare_inventory_output`, `write_host_inventory`, and `run_wrapper_configure` helpers. Reject symlinked output components and any existing `Dist` or `Dependencies` before work. On the first invocation require `core-release` absent and write `first-build-state.txt` recording that precondition; on a rerun require that marker plus an unchanged `build-inputs.txt` of exact source pin, CMake version, formula-inventory SHA-256, and fixed target policy (exclude the two generated-file hashes so a successful rerun is possible). Record parent outside-Build state via `configure_tree_snapshot` and preserve an independent SHA-256/metadata/symlink manifest of all existing `Build/airdcpp-core` siblings except `core-release`; compare both after build even if CMake fails. Revalidate source identity after build with explicit checked `git` commands: detached `HEAD`, exact origin, clean tracked/staged diff, no nonignored untracked files, and ignored files limited to the two known generated paths. Do not rely solely on `checkout_changes`, whose command-error path is not the Phase 3 proof, or use `assert_configure_scope`, which intentionally rejects these generated files in Phase 2.

```sh
CORE_OUTPUT=$PROJECT_ROOT/Build/airdcpp-core/core-release
prepare_inventory_output "$CORE_OUTPUT/build-command.txt"
write_host_inventory "$CORE_OUTPUT/host-inventory.txt"
run_wrapper_configure "$PROJECT_ROOT" "$CORE_OUTPUT" "$cmake_prefix_path" "$pkg_config_path"
set -- cmake --build "$CORE_OUTPUT" --target airdcpp --config Release --parallel 2
configure_literal_command "$@" > "$CORE_OUTPUT/build-command.txt"
build_status=0
"$@" > "$CORE_OUTPUT/build.log" 2>&1 || build_status=$?
printf '%s\n' "$build_status" > "$CORE_OUTPUT/build-exit-code.txt"
[ "$build_status" -eq 0 ] || configure_die "Core build failed; log: $CORE_OUTPUT/build.log"
archive=$CORE_OUTPUT/upstream/libairdcpp.a
[ -f "$archive" ] && [ ! -L "$archive" ] && [ -s "$archive" ] ||
  configure_die "Core target exited successfully without a regular nonempty archive: $archive"
```

  The actual implementation must use the same fail-closed, symlink-safe output preparation pattern as `prepare_inventory_output` for every evidence file, including `build.log` and `build-exit-code.txt`; this excerpt shows command ordering, not permission to redirect through an unchecked path. Build status and post-build scope checks must run on failure too. Do not replace or weaken the existing configure-only safeguards.

- [ ] **Step 4: Run GREEN and full offline regression.** Run `./tests/build_core_test.sh` plus the six existing offline suites: `tests/upstream_config_test.sh`, `tests/update_test.sh`, `tests/configure_helpers_test.sh`, `tests/cmake_wrapper_test.sh`, `tests/find_modules_test.sh`, and `tests/build_configure_test.sh`. All must exit 0. Verify `git diff --check` and that `git ls-files Source Dependencies Build Dist` is empty.

- [ ] **Step 5: Commit.** `git add scripts/build scripts/lib/core_build.sh tests/build_core_test.sh tests/build_configure_test.sh && git commit -m 'feat: add isolated ARM64 core build mode'`.

### Task 2: First native compile attempt and failure classification

**Files:** No predetermined production-code edit. Preserve ignored `Build/airdcpp-core/core-release/{command.txt,configure.log,cache.txt,build-command.txt,build.log,build-exit-code.txt,host-inventory.txt}`; create `docs/reports/2026-09-20-gate-3-arm64-core-build.md` only after a successful, verified candidate. A necessary wrapper correction must be separately tested and committed under Task 1's TDD rule before repeating this task.

**Interfaces:** Input is `scripts/update` plus `scripts/build --build-core`; output is either a preserved first failure with an explicit stop, or `Build/airdcpp-core/core-release/upstream/libairdcpp.a` for Task 3. The `Source` checkout is ignored and is reconstructed inside this feature worktree, never copied from another worktree.

- [ ] **Step 1: Record preflight evidence.** Confirm native `uname -m` is `arm64`, `xcrun clang --version` begins `Apple clang`, the feature branch is clean, `Source/airdcpp-core` is absent or exact/allowed-clean, and `core-release` is absent for the first attempt. Run `./scripts/update`; record the exact commit and origin. Confirm `first-build-state.txt` will record the absent output and capture SHA-256/metadata manifests of existing Gate 2 evidence directories if present (record `absent` otherwise). Do not remove, archive, or rewrite any of them.

- [ ] **Step 2: Run the first build exactly once.** Execute `./scripts/build --build-core` with output recorded by the script. On failure, retain its first `configure.log` or `build.log` and status, identify the first causal compiler/configure diagnostic and the source/CMake line, and STOP. Add a narrowly scoped regression test and update this plan before a fix; never edit `Source/airdcpp-core` in place or mask the failure with a copied object or manually assembled archive.

- [ ] **Step 3: If the command succeeds, check the actual target.** Confirm `build-exit-code.txt` is `0`, the archive is a regular nonempty file at `core-release/upstream/libairdcpp.a`, and `core-release/.ninja_log` documents an executed build. Record `shasum -a 256` and `ar -t` output as ignored raw evidence. Do not infer a complete dependency link from an archive build.

#### First-attempt checkpoint — 2026-09-20

Steps 1–2 ran. Configuration succeeded; compilation failed at `HashStore.cpp:404` because Homebrew LevelDB exports `-Werror` to Core and Apple Clang 21 diagnoses a `memcpy` into non-trivially-copyable `TTHValue`. The raw log and nonzero exit are preserved; see `docs/reports/2026-09-20-phase-3-first-build-failure.md`. Task 2 is stopped, not complete. No retry or source edit is authorized by this checkpoint alone.

### Task 2A: Isolate dependency warning policy and preserve attempts

**Status:** Approved by the user on 2026-09-20. This is limited to the measured LevelDB export and first-attempt evidence. It does not declare the upstream `memcpy` safe.

**Files:** Modify wrapper `CMakeLists.txt` and `scripts/lib/core_build.sh`; add focused regressions in `tests/cmake_wrapper_test.sh` and `tests/build_core_test.sh`; update the failure report with the reviewed decision. No direct edit under `Source/airdcpp-core`.

- [ ] **Step 1: Write RED tests.** A nested CMake fixture must demonstrate that `leveldb::leveldb` exports `-Werror;-Wthread-safety` and that the wrapper removes only the exact `-Werror` element from the imported target after upstream discovery. The compiled Core command must retain `-Wthread-safety`. A build-mode fixture with a failed first attempt must prove a rerun preserves configure command/log/cache, build command/log/status, host inventory, and their SHA-256 hashes in a non-symlinked, uniquely numbered `core-release/attempts/` record **before reconfiguration or inventory rewrite**. Reject malformed/symlinked attempt paths. Existing configure-only and source-boundary tests must remain green.
- [ ] **Step 2: Implement the narrow adapter.** After `add_subdirectory` has discovered `leveldb::leveldb`, inspect `INTERFACE_COMPILE_OPTIONS`; remove only an exact `-Werror` list element from that imported target for this wrapper build, leaving all other options untouched. Fail with a clear diagnostic if the target or expected option shape is inconsistent with measured inputs; do not set global warning suppression or edit Homebrew files. In the build script, copy and hash-check the previous attempt's raw evidence before any rerun can overwrite it, and fail closed on pre-existing symlinks or conflicting archive names.
- [ ] **Step 3: Verify offline and commit the adapter.** Run the new RED/GREEN tests and all six pre-existing offline suites; inspect generated compile-command flags in the controlled fixture. Check `git diff --check`, no tracked `Source`/`Build`/`Dist`/`Dependencies`, and commit the narrow code/test change separately.
- [ ] **Step 4: One measured native retry.** Verify the original `build.log` still hashes to `991e7429ba6c3622e1dbc8c27fcc3ce530749d80d0803ee6c76ea0a283e14ce8`, the source pin and formula inventory are unchanged, and the preserved attempt is recoverable. Run `./scripts/build --build-core` once. If another fatal compile error appears, preserve that attempt and stop for a new evidence-backed amendment. If the archive builds, resume Task 2 Step 3 and Tasks 3–4. The `HashStore.cpp:404` warning and possible unchecked database-key length remain explicit publication risks; Gate 3 is archive feasibility, not a safety or release approval.

### Task 3: Member-by-member archive architecture inspector

**Files:** Create `scripts/lib/inspect_core_archive.py`, `tests/archive_inspect_test.py`; modify `scripts/lib/core_build.sh` to call the inspector after successful compilation. The inspector writes `core-release/archive-members.tsv` and `core-release/archive-symbols.txt` through validated output paths.

**Interfaces:** `python3 scripts/lib/inspect_core_archive.py ARCHIVE MEMBERS_TSV SYMBOLS_TXT` exits nonzero for malformed/empty archives, a non-Mach-O member, a member whose `lipo -archs` is not exactly `arm64`, or failing `file`/`lipo`/`nm`. It emits one row per object member in archive order: ordinal, archive member name, SHA-256, and `arm64`. Archive symbol inventory is discovery data, not the Phase 4 closure decision.

- [ ] **Step 1: Write RED parser tests.** `tests/archive_inspect_test.py` builds small Darwin archives from tiny `int a(void){return 1;}`/`int b(void){return 2;}` C files using `xcrun clang -c -arch arm64` and `/usr/bin/libtool -static`. Assert two rows for two members, including duplicate basenames from different source directories. Create an x86_64 object with `-arch x86_64` and assert rejection; also assert rejection for a truncated `!<arch>\n` archive and an empty archive. Assert failures leave no misleading successful report. Run only on native macOS with Xcode; the script's first diagnostic must explain that requirement.

```python
subprocess.run(["xcrun", "clang", "-c", "-arch", "arm64", str(source), "-o", str(obj)], check=True)
subprocess.run(["/usr/bin/libtool", "-static", "-o", str(archive), str(obj)], check=True)
result = subprocess.run(["python3", str(inspector), str(archive), str(members), str(symbols)], capture_output=True, text=True)
self.assertEqual(result.returncode, 0, result.stderr)
self.assertEqual(len(members.read_text().splitlines()), 2)
```

- [ ] **Step 2: Run RED.** Run `python3 -m unittest tests/archive_inspect_test.py -v`; expect failure because the inspector does not exist.

- [ ] **Step 3: Implement archive parsing and tool checks.** Parse the standard `!<arch>\n` magic and each 60-byte ar header, require the trailing `` `\n`` marker and valid decimal length, account for even-byte padding, and handle BSD `#1/<length>` extended names plus archive symbol-table members. Extract each object payload into a uniquely numbered temporary file; never extract by basename because duplicates can overwrite. For each object run `/usr/bin/file -b` and `/usr/bin/lipo -archs`, requiring Mach-O object and exactly `arm64`; run `xcrun nm -g` on the archive and preserve its full output. Fail closed on command errors or zero object members. Atomically publish reports only after every member passes. Do not change or reassemble the archive.

```python
with tempfile.TemporaryDirectory(prefix="airdc-core-members-") as work:
    for ordinal, (name, payload) in enumerate(read_ar_members(archive), start=1):
        member_path = Path(work) / f"member-{ordinal:06d}.o"
        member_path.write_bytes(payload)
        kind = subprocess.run(["/usr/bin/file", "-b", str(member_path)], check=True, text=True, capture_output=True).stdout.strip()
        archs = subprocess.run(["/usr/bin/lipo", "-archs", str(member_path)], check=True, text=True, capture_output=True).stdout.strip()
        if "Mach-O 64-bit object" not in kind or archs != "arm64":
            raise ValueError(f"member {ordinal} ({name}) is not arm64 Mach-O: {kind}; {archs}")
```

- [ ] **Step 4: Run GREEN and regressions.** Run `python3 -m unittest tests/archive_inspect_test.py -v`, `./tests/build_core_test.sh`, and all six pre-existing offline suites. Verify that `file` identifies the archive as an ar archive and that member-row count equals the parsed object count. If an actual Core member fails, preserve raw evidence and stop for an evidence-backed correction.

- [ ] **Step 5: Commit.** `git add scripts/lib/inspect_core_archive.py scripts/lib/core_build.sh tests/archive_inspect_test.py && git commit -m 'test: verify every static core archive member is ARM64'`.

### Task 4: Opt-in live Gate 3 and reviewed report

**Files:** Create `tests/gate3_core_build_test.sh`, `docs/reports/2026-09-20-gate-3-arm64-core-build.md`; modify `docs/build-and-release.md`, `README.md`, and `docs/dependencies.md` only to document the verified first build and its limits.

**Interfaces:** `AIRDCCORE_RUN_BUILD_TESTS=1 ./tests/gate3_core_build_test.sh` is the live acceptance entry point. Without the variable it must refuse before changing Source or Build. It requires the exact checkout and the previously produced, inspected archive; it does not delete the build tree or rebuild hidden dependencies. To prove a first clean build, its report must cite the Task 2 pre-build absence snapshot and build-command/status evidence. A second fresh worktree can repeat Task 2 if the first-build provenance is missing.

- [ ] **Step 1: Write RED gate assertions.** Require the enablement variable; exact source commit/origin and allowed generated-file set; `core-release` command/configure/build logs and zero exit; cache/summary `arm64`, Release, C++20, extensions OFF, static Core, deployment 14.0, NAT-PMP/TBB OFF; `archive-members.tsv` nonempty with all rows `arm64`; actual `file`, `lipo`, and `nm` checks; no `Dependencies` or `Dist`; no tracked generated paths. Compare parent outside-Build/source identity and historical Gate 2 evidence against recorded before-snapshots. Test a wrong pin, missing archive, tampered member report, and disabled opt-in with fixture or copied evidence, not by destroying the real first build.

```sh
[ "${AIRDCCORE_RUN_BUILD_TESTS:-0}" = 1 ] || fail 'set AIRDCCORE_RUN_BUILD_TESTS=1 for live Gate 3'
assert_line "$BUILD/airdcpp-configure-summary.txt" 'architecture=arm64' 'architecture'
assert_line "$BUILD/airdcpp-configure-summary.txt" 'build_type=Release' 'configuration'
assert_line "$BUILD/airdcpp-configure-summary.txt" 'enable_natpmp=OFF' 'NAT-PMP policy'
assert_line "$BUILD/airdcpp-configure-summary.txt" 'enable_tbb=OFF' 'TBB policy'
assert_line "$BUILD/build-exit-code.txt" '0' 'build status'
```

- [ ] **Step 2: Run RED.** Before adding the report and gate implementation, run the new test against a controlled fixture; it must fail for the missing required evidence rather than merely for a shell syntax error.

- [ ] **Step 3: Implement gate and report from measured facts.** The tracked report must include host/Xcode/Apple Clang/CMake/Python/Homebrew versions; exact pin and source status; full normalized configure/build commands; first attempt exit/log path and any reviewed correction; archive path, byte size, SHA-256, member count and architecture inspection method; generated-file hashes; required target resolutions; preserved Gate 2 evidence hashes; test commands/results; warnings; explicit limitations. Use `$PROJECT_ROOT` and normalized formula prefixes in tracked prose, not a user-home absolute path. State that the archive may retain unresolved references and that no final consumer, runtime, dependency pin, or distribution has been proven.

- [ ] **Step 4: Run GREEN and complete acceptance.** Run six pre-existing offline suites, `./tests/build_core_test.sh`, `python3 -m unittest tests/archive_inspect_test.py -v`, and the opt-in live Gate 3 test. Run `git diff --check`, inspect `git status --ignored --short` for generated scope, and verify `git ls-files Source Dependencies Build Dist` emits nothing. Do not run the opt-in Gate 2 test in this now-compiled checkout. A reviewer checks the complete feature diff and Gate 3 report against the spec and raw evidence; a failed review blocks merge.

- [ ] **Step 5: Commit and stop at Gate 3.** Commit the gate/report/docs on `feature/arm64-static-core-build`. Leave `Build/airdcpp-core/core-release` ignored and intact for inspection. Present local merge / PR / keep-branch GitFlow options; do not merge, push, tag, package, or begin Phase 4 without the user's choice.

## Plan self-check and stop conditions

- Gate 3 acceptance is only an un-packaged static Core archive whose every object is `arm64`, with a controlled source commit and recorded tool/dependency inputs. It does **not** require a linked external executable; that is Phase 4.
- Tasks 1–4 cover the spec's Phase 3 build, architecture/member inspection, source control, command/dependency evidence, and reviewed gate report. Homebrew remains discovery-only and `Dist` remains absent.
- A real compile error, an unexpected generated file, a failed architecture inspection, a changed Homebrew/tool input that invalidates the attempt, or a mutation of historical evidence is a stop condition. Preserve the failing log and revise the specific task from evidence before making any fix.
