# Build and release gates

This is a concise operator-oriented phase map. The full contract is in [the design spec](superpowers/specs/2026-09-04-airdc-core-macos-design.md).

Acquisition, native configure discovery, Core and consumer builds, the aggregate distribution decision, and the accepted Phase 6 inputs are implemented. Phase 7 provides validated deterministic packaging and a measured relocated consumer. Phase 8 provides public verification, scoped cleanup, and an opt-in two-clean-build/release-rehearsal driver; its native acceptance passed measured verification and independent review under the approved two-clean-checkouts, same-host criterion. See the [Gate 8 report](reports/2026-10-04-gate-8-release-verification.md) for evidence and limitations.

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

Acquisition may retain uncertain `.publication-*` private attempts when initial cloned-content/descriptor checks fail; cleanup cannot safely claim an unverified inode as its own. Preserve these artifacts and diagnostics for forensic inspection, rather than deleting an unknown concurrent publication winner. Successful source publication verifies bytes and identity through the exclusive rename and checks Git metadata across fixed snapshots. Bounded dependency adapters refuse unsupported ordered options/name mappings, and the strict Phase 6 link audit refuses top-level response files; neither changed flags nor hidden link inputs may be recorded without execution authority.

Reproducible Core uses its owned `source` stage, never edits the original checkout, and applies only the reviewed three-file private patch for bounded hash-key copying, fixed version COMMAND, and the constant IPv6 address buffer. `config/core-reproducible-policy.json` binds patch pre/postimages, pinned epoch 1774518197/count zero and declared version identity. Original/patched/final staged manifests, generator/Python authority, and provenance bind the archive and consumer's staged headers. Strict warnings remain enabled. `tests/core_staging_test.py` exercises staging, generation, tampering, Git replacement authority, directory ownership, and the native IPv4/IPv6 fragment. Failed native probes/builds remain under preserved attempts and external forensic logs.

Historical Gate 3/4 rejection contracts use their explicit live variables and coherent copied historical evidence. The failed early Phase 6 generator changed ignored original `version.inc`, so the active checkout no longer matches Gate 4's historical staged header; that refusal is correct. A disposable tracked-only clone may replay the exact observed historical staged header bytes (SHA-256 `65c2b8b0553cdaa61b54e6ecc6e90cdba308eeeae760f24d22b2623a78a47b3c`) solely in its copied source. Keep the contracts unchanged, preserve active forensic Source/evidence, and record construction and results. Such replay is not current native acceptance or a claim about unavailable immediate pre-failure bytes; Phase 6 validates its current private stage separately.

Without its live variable the gate skips. It validates lock/accepted sources, two dependency builds and unchanged prefix/evidence comparison, every prefix, real Core/consumer, ADR closure, Git/output boundaries, and the tracked normalized report. It fails closed if `/usr/bin/sandbox-exec` is unavailable or the child socket probe does not prove outbound denial and localhost allowance. Its complete process tree uses `(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))`, permitting OpenSSL localhost TLS tests while refusing remote sockets. Offline fixtures exercise descendant confinement, no-op enforcement, report identity/closure drift, twelve criteria, and generated-path refusal.

Reused prefixes also require `Build/gate6/dependency-confinement.json`: it binds the policy/probes, lock and gate/helper code, all eight successful adapter executions, and their input/tool/command/test-log/prefix/license evidence digests. Missing or mismatching attestation causes a safe forced rebuild inside this gate's sandbox before the two normal no-op invocations. Force preserves acceptance/attempt evidence through the existing orchestrator and never bypasses output-drift validation. Stale attestations are retained in hash-named `Build/gate6/confinement-history`; a failed refresh leaves no current acceptance marker. Matching attestations remain unchanged on rerun. The report binds stable status/inspection files; it must not reference volatile Core/consumer scope hashes whose inputs include the report itself.

For an isolated dependency checkpoint, run `AIRDCCORE_RUN_DEPENDENCY_TESTS=1 ./tests/gate6_dependency_build_test.sh --dependencies-only`. It performs the same sandbox probes, bound confinement establishment, two ordinary no-op builds, prefix/source/Git/output checks, then records `Build/gate6/dependency-checkpoint.json` and exits before Core, consumer, and report execution. Its explicit result is “dependency checkpoint only; NOT Gate 6 acceptance.” This permits Core-only preparation to proceed independently; the normal full invocation still requires real Core/consumer and report acceptance.

## Phase 7 packaging operator contract

After the accepted Phase 6 dependency and reproducible Core outputs exist, run:

```sh
./scripts/package
./scripts/package --verify /absolute/path/to/relocated/Dist
AIRDCCORE_RUN_DISTRIBUTION_TESTS=1 ./tests/gate7_distribution_test.sh
```

The default command validates the accepted inputs without rebuilding or
discovering Homebrew dependencies. It constructs two identical fresh containers
with ADR 0001's ordered nine ingredients and Apple libtool, stages the enabled
macOS Core headers and required external include trees, and retains original
license notices. Core modules and Windows-only `ZipFile.h` are excluded by the
pinned target's header policy. Boost headers and their notice are redistributed
without adding a Boost archive. MaxMindDB's original `NOTICE` is authenticated
against its locked source tree; the tracked official GPL text accompanies the
original Core notices preserved in headers.

The candidate contains one `lib/libairdcpp.a`, stable relative provenance,
member mapping, actual Mach-O coalescing decisions, header/license inventories,
and checksums for every file except the checksum file itself. Candidate
validation precedes atomic publication at the fixed project `Dist` target.
Unsafe targets and failed validation preserve an existing distribution.

Core provenance includes its exact tracked upstream URL and a compact declared
compile policy in `config/packaging-core-policy.json`. This packaging-specific
capture binds the accepted Core archive/input fingerprint, compiler, SDK and
construction tool; staging cross-checks normalized observed Ninja flags and
material definition overrides. The successful build log is not verbose, so
Ninja is observed metadata, not an independently immutable compiler transcript.
Changing the accepted Core/tool identity requires a reviewed policy refresh.
Schema 2 pins the path-independent published Core identity: only the validated
private version authority's staging root becomes `$CORE_SOURCE`, and its digest
is rebound inside a copied input document. Private Phase 6 receipts remain
path-sensitive and unchanged. Legacy schema 1 packages require their matching
schema 1 tracked authority; a mixed identity schema is rejected.

`--verify` performs read-only checks of an existing or relocated package,
including its actual object payloads, ARM64/deployment policy, TOC, symbol
decisions, pins, header/license inventory, and checksums. Its authority is the
packaging checkout's tracked `config` and license-source policy; it does not
read `Source`, `Dependencies`, or `Build`. Checksums establish integrity, not
an artifact signature. Recorded per-member undefined references include symbols
resolved by other members; they are not the remaining system link boundary.

Every candidate is copied to a private relocated directory and measured before
publication. The compiler parses all supported macOS Core public headers using
the locked feature guards. `StringDefs.h` is parsed inside `ResourceManager`,
and `pubkey.h` follows `UpdateManager.h`; these contextual fragments remain
staged unchanged. This syntax-only probe is separate from the linked identity
consumer, which force-loads every aggregate member. Compiler processes deny
private project and Homebrew inputs, and measured header dependencies are
restricted to Dist plus the Apple SDK/toolchain.

`metadata/consumer-proof.json` binds the aggregate, complete header inventory
and both probe sources, not metadata containing the proof itself. It records
normalized compiler/SDK identity, public closure, actual link-map member
coverage, runtime Core identity, load commands, resolved source external
definitions (including linker-localized weak definitions), and final system
imports. Private commands/logs/maps/executables are not published. `--verify`
recomputes this real relocated proof; missing/pending/unbound proof cannot pass.

The public link contract remains explicit SDK Iconv with implicit libc++ and
libSystem, and no Apple frameworks. The live gate packages twice, compares
complete published inventory/content, repeats relocated verification, rejects
rehashed tampering, and retains private evidence under `/private/tmp/airdc-gate7-*`.
Without its opt-in variable it skips. `--verify DIST` performs the relocated
verification/negative subset without reconstructing private inputs or claiming
a new two-package comparison. See the [Gate 7 report](reports/2026-10-04-gate-7-distribution-packaging.md).
No Gate 7 result proves Phase 8 minimum-OS runtime or full-clean-build release
reproducibility.

Freeze every other project writer during real Core/consumer modes: their snapshots exclude only their own output. Changing documentation, Git state, sources, another output, or project-local logs violates scope. Save outer stdout/stderr outside the project in a private temporary path; copy durable evidence to ignored `Build/gate6` only between subprocesses or after execution. First capture without a tracked report refuses acceptance after preserving native evidence. Normalize facts, track the report, and rerun; fixtures and incomplete captures cannot establish PASS.

Gate 3/4 copied-evidence tests require `AIRDCCORE_RUN_BUILD_TESTS=1` / `AIRDCCORE_RUN_LINK_TESTS=1`. Run unchanged Gate 5 in a fresh tracked-only checkout with `Dependencies` absent, preserving active artifacts. Preserve needed private attempt/history evidence before intentionally cleaning that checkout.

Phase 6 creates neither `Dist` nor an aggregate. After twelve criteria and independent review pass, Phase 7 owns the ADR aggregate algorithm, strong collisions, weak/coalesced classifications, member mapping, notices/provenance and packaging. Phase 8 owns two-clean-build byte verification. Verification on the recorded host does not prove runtime behavior on an actual macOS 14 installation or release readiness.

## Release evidence

A releasable `Dist` must include machine-readable provenance and link-interface metadata, SHA-256 checksums, and all required notices. Verification must exercise `file`, `lipo`, `nm` or equivalent Apple tooling, plus a fresh C++ consumer that compiles and links without using the source or build trees.

## Gate 8 operator contract

```sh
./scripts/verify                    # verify this checkout's Dist
./scripts/verify /absolute/Dist     # verify a public relocated package
./scripts/clean                     # deliberately remove this checkout's Build and Dist
AIRDCCORE_RUN_RELEASE_TESTS=1 ./tests/gate8_release_test.sh
```

`verify` delegates the complete existing payload, Mach-O, symbols, source pins,
headers, licenses and checksum verification and measures a fresh relocated,
network-denied consumer. It reads public Dist, tracked authority and the declared
Apple SDK/toolchain. Failures exit nonzero with a diagnostic; no private Core or
dependency inputs are rebuilt.

`clean` accepts no target arguments. It verifies its own Git project root,
refuses tracked paths below Build/Dist, and validates both fixed top-level
targets before deleting either. Unsafe roots, top-level symlinks and file
targets fail without deletion. Nested symlinks are unlinked without following
their targets. Source, Dependencies, tracked files and unrelated dirty source
are preserved. Removed Build/Dist content includes private build evidence;
retain any needed receipts first. Tests use disposable projects only.

The Gate 8 experiment accepts no arguments and skips unless explicitly enabled.
Run it from a committed, reviewed implementation; uncommitted inputs are refused.
It freezes one exact Git commit and creates two separately owned tracked-only
checkouts under `/private/tmp/airdc-gate8-*/run-{1,2}/project`, attesting Source,
Dependencies, Build and Dist are initially absent. Each root independently runs
update, locked dependency acquisition/build, reproducible Core, private consumer,
packaging and public verification. No source trees, prefixes or build products
are shared. Build/airdcpp-core is created before the existing Core command needs
its parent; the Phase 6 build implementation is unchanged.

Each run repeats acquisition and dependency build and compares both bytes and
filesystem identities/timestamps to establish a no-op. Both acquisition/build/
Core/private-consumer passes complete before either packaging pass: the private
consumer requires Dist to remain absent. The exact repeated Core archive and
input identities must match before publication. Packaging and public verification
then run twice, comparing the first verified full public inventory with the
second. Across roots, full Dist directories,
file modes and content digests must agree; matching only aggregate archives is
insufficient. Drift fails the experiment without repinning or semantic fallback.

All outer logs, command statuses, input/tool/OS identities, raw private versus
normalized public fingerprints, no-op snapshots and package inventories are
retained outside the checked project roots. Successful and failed roots remain
available for inspection. A failure stops immediately and cannot produce a
passing comparison from a partial receipt. Console progress identifies each
phase and its log. Check the retained failure log and correct the cause before
starting another experiment; never overwrite old evidence to conceal drift.

The driver also exercises feature integration, release-from-develop,
first-master bootstrap, annotated `v0.0.0` rehearsal tagging and release
merge-back in a separately created disposable Git repository. It does not
create production master/tags, push, or publish a release. Receipts identify the
rehearsal repository and explicitly exclude production publication.

A passing experiment proves two fresh tracked-only builds on the measured host.
It does not assert a physically fresh machine, actual macOS 14 execution, or
complete all fourteen release acceptance criteria by itself. Gate 8 acceptance
requires the complete measured criterion map and independent review before
integration; production promotion remains a separate decision.

The recorded experiment at `5dc4699` passed both complete clean-root workflows,
exact full Dist comparison, cleanup tests and isolated release rehearsals. The
user explicitly replaced the fresh-machine criterion on 2026-10-06 with two
independent clean checkouts on a declared supported Xcode/macOS host reconstructing
exact source and dependency inputs from tracked configuration. The retained
same-host evidence meets that revised scope; it does not prove a fresh physical
machine or actual macOS 14 execution. Final revalidation/review precedes feature
integration. See the Gate 8 report in `docs/reports`.
