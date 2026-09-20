# Build and release gates

This is a concise operator-oriented phase map. The full contract is in [the design spec](superpowers/specs/2026-09-04-airdc-core-macos-design.md).

Acquisition, native configure-only discovery, and an unpackaged ARM64 static Core build are implemented. Consumer linking, packaging, and release workflows remain deferred.

## Required sequence

1. **Acquire:** fetch the versioned upstream URL, verify the exact commit, and leave the checkout in a known state.
2. **Discover:** use Homebrew-assisted host tooling and dependency discovery for native configure-only feasibility evidence; stop before Core compilation.
3. **Build core:** configure Release with Apple Clang/libc++, `BUILD_SHARED_LIBS=OFF`, and `CMAKE_OSX_ARCHITECTURES=arm64`.
4. **Close the link:** inspect unresolved symbols and link a real external C++ program. Record every required archive, framework, and system library.
5. **Choose distribution shape:** decide from evidence whether `Dist/lib` contains one archive, multiple archives plus an explicit link interface, or an aggregate artifact.
6. **Reproduce dependencies:** replace mutable Homebrew runtime assumptions with pinned source builds or pinned packaged archives wherever publication requires it.
7. **Package:** stage headers, libraries, metadata, checksums, and license material into `Dist` only after all preceding gates pass.
8. **Verify and release:** run architecture, symbol, header, link, provenance, cleanliness, and two-clean-build reproducibility checks.

Gate 1 is exercised by `tests/gate1_network_test.sh`. It is network-opt-in because it moves a validated clean checkout aside, reconstructs the canonical checkout twice, and retains the second verified reconstruction. Offline safety and failure paths are covered by `tests/upstream_config_test.sh` and `tests/update_test.sh`.

No later phase may conceal a failed earlier gate with an undocumented patch or manually copied local artifact.

## Gate 2 operator contract

On native macOS arm64 with Xcode/Apple Clang and the [required discovery formulas](dependencies.md), run:

```sh
./scripts/update
./scripts/build --configure-only
AIRDCCORE_RUN_CONFIGURE_TESTS=1 ./tests/gate2_configure_test.sh
```

`update` reconstructs or validates exact detached Source. In `--configure-only` mode, `build` refuses unsupported arguments, invalid/dirty source, unsafe output paths, missing required formulas, or outside-scope mutation. It sets Release/static Core/C++20/arm64/libc++/deployment-14.0 and explicit NAT-PMP/TBB OFF. Homebrew inputs remain discovery-only. CMake compiler identification/ABI/check probes are permitted; no Core target, direct Ninja build, archive, or packaging operation is invoked.

The real gate requires `AIRDCCORE_RUN_CONFIGURE_TESTS=1`; without it, refusal precedes configure. Its expected tracked evidence path is [docs/reports/2026-09-05-gate-2-native-configure.md](reports/2026-09-05-gate-2-native-configure.md). The gate checks report headings/claim boundaries as well as exact source/compiler/policy/imported-target resolution, immutable raw captures, before/after filesystem state, and absence of Core products, Ninja invocation logs, `Dependencies`, and `Dist`.

Raw output stays below `Build/airdcpp-core`: current `unmodified` is a full-schema standalone capture on the measured host, `wrapper-baseline` is the preserved earlier wrapper-only attempt, `evidence` holds host inventory, and `release` holds the refreshed final command/log/cache/summary/graph. The original narrow-schema standalone capture and its legacy reuse sidecar remain byte-for-byte preserved under the fingerprint-keyed ignored `evidence-history/first-observation-…` directory documented in the [report](reports/2026-09-05-gate-2-native-configure.md). A complete matching canonical unmodified record is reused, never overwritten; partial or changed input evidence is refused and requires a separately reviewed, non-destructive archive before intentional recapture. Reruns use `--fresh` for release and must leave Source and all outside-output content unchanged. Raw evidence is ignored, not published as tracked logs.

Hard stop: Gate 2 success is configuration evidence only. Do not proceed to Phase 3 compilation or create `libairdcpp.a`, `Dependencies`, or `Dist` as part of these commands. Consumer linking, binary/runtime compatibility, pinned inputs, packaging, and release approval require their own later gates.

## Gate 3 operator contract

On native macOS `arm64`, after `./scripts/update`, run `./scripts/build --build-core`. This mode uses a separate `Build/airdcpp-core/core-release` tree, configures the pinned upstream source with the fixed Gate 2 policy, and invokes only CMake target `airdcpp`. The archive candidate is `core-release/upstream/libairdcpp.a`; raw commands, logs, statuses, host inventory, and member/symbol reports stay ignored under `core-release`. Any prior attempt, failed or successful, is hash-checked and retained under `core-release/attempts/` before a retry overwrites current logs. A clean first build needs no failed-attempt record. Reruns reject drift in the recorded host/toolchain inventory (excluding the two expected generated-source states), missing or unsafe previous evidence, and changed fixed build inputs. It neither installs nor publishes `Dist` or `Dependencies`.

After a successful build, run `AIRDCCORE_RUN_BUILD_TESTS=1 ./tests/gate3_core_build_test.sh`. Without the variable, the live gate refuses immediately. It verifies source identity, build/configure policy and evidence, each archive object via an independent read-only reinspection, the archive-level `file`/`lipo`/`nm` results, generated-file and Git boundaries, and absence of `Dist`. `AIRDCCORE_RUN_BUILD_TESTS=1 ./tests/gate3_contract_test.sh` tests rejection paths against copied evidence without mutating the real archive. The [Gate 3 report](reports/2026-09-20-gate-3-arm64-core-build.md) gives measured results and the first-attempt correction.

Gate 3 is **not** a link or release gate. The archive may contain unresolved external references, and its Homebrew-sourced dependencies include dylibs. A real external C++ consumer link, public-header packaging decision, dependency closure, reproducibility, and all distribution work remain later phases. The upstream `HashStore.cpp:404` warning and possible key-length bounds issue remain open publication risks.

## Release evidence

A releasable `Dist` must include machine-readable provenance and link-interface metadata, SHA-256 checksums, and all required notices. Verification must exercise `file`, `lipo`, `nm` or equivalent Apple tooling, plus a fresh C++ consumer that compiles and links without using the source or build trees.
