# Build and release gates

This is a concise operator-oriented phase map. The full contract is in [the design spec](superpowers/specs/2026-09-04-airdc-core-macos-design.md).

Acquisition, native configure-only discovery, an unpackaged ARM64 static Core build, external-consumer discovery, the distribution decision, and Phase 6 dependency/Core/consumer modes are implemented. Gate 6 native acceptance is pending; aggregation, packaging, and release remain deferred.

## Required sequence

1. **Acquire:** fetch the versioned upstream URL, verify the exact commit, and leave the checkout in a known state.
2. **Discover:** use Homebrew-assisted host tooling and dependency discovery for native configure-only feasibility evidence; stop before Core compilation.
3. **Build core:** configure Release with Apple Clang/libc++, `BUILD_SHARED_LIBS=OFF`, and `CMAKE_OSX_ARCHITECTURES=arm64`.
4. **Close the link:** inspect unresolved symbols and link a real external C++ program. Record every required archive, framework, and system library.
5. **Choose distribution shape:** accepted — publish one aggregate `Dist/lib/libairdcpp.a` with per-component metadata and an explicit Apple system-link interface.
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

## Gate 5 operator contract

Run the offline decision gate:

```sh
./tests/gate5_distribution_shape_test.sh
```

The gate validates [ADR 0001](decisions/0001-aggregate-static-distribution.md): exact aggregate contents, explicit-versus-implicit SDK/system link modes, deterministic strong-collision-safe construction with classified weak/coalesced definitions, per-component provenance and licenses, rejected alternatives, and Phase 6 non-claims. It also verifies that source/build/distribution paths remain untracked and that neither `Dependencies` nor `Dist` exists or is a symlink.

Hard stop: Gate 5 is documentation and contract evidence only. It does not download or build dependencies, create the aggregate, prove minimum-macOS compatibility, complete license review, package headers, or create `Dist`. Phase 6 starts with pinned reconstruction of the nine non-system components named by the ADR.

## Gate 6 operator contract

Use [both acquisition forms](upstream.md) to validate Core and acquire locked dependencies. `scripts/update --dependencies --offline` requires verified caches. Dependency builds refuse unaccepted source, run deterministic upstream/installed-consumer checks, validate isolated static prefixes, and preserve retries. Reuse requires matching lock/source/adapter/helper/SDK/tool/dependency-manifest fingerprints and accepted prefix/evidence hashes.

```sh
./scripts/build --build-dependencies
./scripts/build --build-reproducible-core
./scripts/build --link-reproducible-consumer
AIRDCCORE_RUN_DEPENDENCY_TESTS=1 ./tests/gate6_dependency_build_test.sh
./tests/gate6_contract_test.sh
./tests/gate6_contract_test.sh --self-test
```

Generated layout is `Dependencies/.downloads` and `Dependencies/<name>` for caches/sources; `Build/dependencies/<name>` for private build/evidence/home/temp directories; `Build/prefix/<name>` for installs; `Build/airdcpp-core/reproducible-release` for Core; `Build/airdcpp-core/reproducible-link-interface` for consumer/omissions; and `Build/gate6` for normalized validation. Candidates are `reproducible-release/upstream/libairdcpp.a` and `reproducible-link-interface/full/airdcpp-smoke`. Component `evidence/adapter.log`, `exit-status.txt`, `error.txt` when present, `inputs.json`, and hash-bound `attempts` explain failures. Core/consumer commands/logs/statuses/resolution/inspection/history remain in their own outputs.

Without its live variable the gate skips. It validates lock/accepted sources, two dependency builds and unchanged prefix/evidence comparison, every prefix, real Core/consumer, ADR closure, Git/output boundaries, and the tracked normalized report. It fails closed if `/usr/bin/sandbox-exec` is unavailable or the child socket probe does not prove outbound denial and localhost allowance. Its complete process tree uses `(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))`, permitting OpenSSL localhost TLS tests while refusing remote sockets. Offline fixtures exercise descendant confinement, no-op enforcement, report identity/closure drift, twelve criteria, and generated-path refusal.

Reused prefixes also require `Build/gate6/dependency-confinement.json`: it binds the policy/probes, lock and gate/helper code, all eight successful adapter executions, and their input/tool/command/test-log/prefix/license evidence digests. Missing or mismatching attestation causes a safe forced rebuild inside this gate's sandbox before the two normal no-op invocations. Force preserves acceptance/attempt evidence through the existing orchestrator and never bypasses output-drift validation. Stale attestations are retained in hash-named `Build/gate6/confinement-history`; a failed refresh leaves no current acceptance marker. Matching attestations remain unchanged on rerun. The report binds stable status/inspection files; it must not reference volatile Core/consumer scope hashes whose inputs include the report itself.

For an isolated dependency checkpoint, run `AIRDCCORE_RUN_DEPENDENCY_TESTS=1 ./tests/gate6_dependency_build_test.sh --dependencies-only`. It performs the same sandbox probes, bound confinement establishment, two ordinary no-op builds, prefix/source/Git/output checks, then records `Build/gate6/dependency-checkpoint.json` and exits before Core, consumer, and report execution. Its explicit result is “dependency checkpoint only; NOT Gate 6 acceptance.” This permits Core-only preparation to proceed independently; the normal full invocation still requires real Core/consumer and report acceptance.

Freeze every other project writer during real Core/consumer modes: their snapshots exclude only their own output. Changing documentation, Git state, sources, another output, or project-local logs violates scope. Save outer stdout/stderr outside the project in a private temporary path; copy durable evidence to ignored `Build/gate6` only between subprocesses or after execution. First capture without a tracked report refuses acceptance after preserving native evidence. Normalize facts, track the report, and rerun; fixtures and incomplete captures cannot establish PASS.

Gate 3/4 copied-evidence tests require `AIRDCCORE_RUN_BUILD_TESTS=1` / `AIRDCCORE_RUN_LINK_TESTS=1`. Run unchanged Gate 5 in a fresh tracked-only checkout with `Dependencies` absent, preserving active artifacts. `scripts/clean` remains deferred; retain caches and attempt/history evidence, and remove only explicitly identified disposable fixtures.

Phase 6 creates neither `Dist` nor an aggregate. After twelve criteria and independent review pass, Phase 7 owns the ADR aggregate algorithm, strong collisions, weak/coalesced classifications, member mapping, notices/provenance, packaging, and two-clean-build checks. Verification on the recorded host does not prove runtime behavior on an actual macOS 14 installation or release readiness.

## Release evidence

A releasable `Dist` must include machine-readable provenance and link-interface metadata, SHA-256 checksums, and all required notices. Verification must exercise `file`, `lipo`, `nm` or equivalent Apple tooling, plus a fresh C++ consumer that compiles and links without using the source or build trees.
