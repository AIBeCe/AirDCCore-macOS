# Build and release gates

This is a concise operator-oriented phase map. The full contract is in [the design spec](superpowers/specs/2026-09-04-airdc-core-macos-design.md).

Acquisition, native configure-only discovery, an unpackaged ARM64 static Core build, and external-consumer link discovery are implemented. Distribution-shape selection, pinned dependency builds, packaging, and release workflows remain deferred.

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

Gate 3 is **not** a link or release gate. The archive contains unresolved external references, and its Homebrew-sourced dependencies include dylibs. The upstream `HashStore.cpp:404` warning and possible key-length bounds issue remain open publication risks.

## Gate 4 operator contract

After Gate 3 has produced and verified the current archive, run:

```sh
./scripts/build --link-consumer
AIRDCCORE_RUN_LINK_TESTS=1 ./tests/gate4_consumer_link_test.sh
```

`--link-consumer` validates the pinned checkout and Gate 3 evidence, stages a hash-bound header tree and byte-identical archive, and compiles a standalone C++20 smoke executable. It does not invoke the Core build target. The archive is force-loaded so every Core object participates. A Core-only link must fail with unresolved symbols; the Homebrew-assisted candidate is reduced through two one-at-a-time omission passes to a stable seven-item logical interface. Commands, logs, attempts, manifests, omission results, normalized link items, binary inspection, and runtime output remain ignored below `Build/airdcpp-core/link-interface`.

The live gate refuses unless `AIRDCCORE_RUN_LINK_TESTS=1`. It independently verifies source and archive identity, the staged manifest, expected Core-only failure, exact omission fixed point, ordered link interface, ARM64 Mach-O executable, real Core symbols, runtime commit identity, and absence of worktree/home/absolute Source or Build paths. `AIRDCCORE_RUN_LINK_TESTS=1 ./tests/gate4_contract_test.sh` exercises rejection paths against copied evidence. The [Gate 4 report](reports/2026-09-21-gate-4-consumer-link.md) records the measured result.

Hard stop: Gate 4 does not create a distributable, choose one-versus-many archive layout, pin Homebrew dependencies, prove macOS 14 compatibility, or authorize Phase 5. `Dependencies` and `Dist` remain absent.

## Release evidence

A releasable `Dist` must include machine-readable provenance and link-interface metadata, SHA-256 checksums, and all required notices. Verification must exercise `file`, `lipo`, `nm` or equivalent Apple tooling, plus a fresh C++ consumer that compiles and links without using the source or build trees.
