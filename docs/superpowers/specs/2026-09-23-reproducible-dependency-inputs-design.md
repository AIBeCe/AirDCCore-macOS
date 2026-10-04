# Reproducible Dependency Inputs Design

**Status:** Accepted

**Design date:** 2026-09-23

**Phase:** 6 — Reproducible dependency inputs

**Branch:** `feature/reproducible-dependencies`

## 1. Purpose and success condition

Phase 6 replaces every mutable Homebrew library used during discovery with a pinned, reconstructable source input and an independently verified static ARM64 build. It produces controlled dependency prefixes, a Core candidate built against those prefixes, and a real external consumer linked from the reconstructed static closure.

Gate 6 succeeds only when a clean machine with the declared Apple toolchain and host tools can acquire the locked sources, rebuild the required libraries into `Build/prefix`, rebuild Core without resolving non-system packages from Homebrew, and pass the external consumer checks with complete provenance and license evidence.

Phase 6 does not create the aggregate archive or `Dist`. Aggregate construction belongs to Phase 7 after all component inputs have passed this gate.

## 2. Approved decisions and evidence

This design refines Phase 6 of the [project design](2026-09-04-airdc-core-macos-design.md) and implements the input side of [ADR 0001](../../decisions/0001-aggregate-static-distribution.md). The [Gate 4 report](../../reports/2026-09-21-gate-4-consumer-link.md) is the authority for the measured link closure.

The approved approach is to reconstruct source releases corresponding to the versions already measured at Gate 4, with one deliberate exception: OpenSSL 3.5.8 LTS replaces OpenSSL 3.6.4 because the 3.6 line reaches end of life on 2026-11-01, while the 3.5 LTS line is supported through 2030-04-08 according to the [official OpenSSL source index](https://mirror.openssl-library.org/source/). The complete Core and consumer evidence must be recaptured against 3.5.8; prior OpenSSL 3.6.4 evidence cannot be relabeled.

No dependency uses a Git submodule. Downloaded source, verified download caches, dependency build trees, prefixes, and evidence remain ignored and reconstructable.

## 3. Scope

Phase 6 owns:

- the strict `config/dependencies.lock` schema and canonical serialization;
- safe, checksum-verified acquisition into `Dependencies`;
- component-specific static build adapters;
- component prefixes and build evidence below `Build`;
- a separate reproducible Core build using only the component prefixes and Apple SDK/system inputs;
- a static external-consumer rerun and renewed link-closure evidence;
- license/provenance records sufficient to authorize later packaging; and
- the reviewed Gate 6 report at `docs/reports/2026-09-23-gate-6-reproducible-dependencies.md`.

Phase 6 does not own:

- aggregate archive construction;
- public-header or library packaging;
- `Dist` metadata or checksums;
- Objective-C++, Swift, Swift Package Manager, AppKit, or Project 2;
- runtime GeoIP database content;
- release branches, tags, notarization, or production publication; or
- the Phase 8 two-clean-build release reproducibility claim.

## 4. Dependency boundary

### 4.1 Aggregate components

These sources provide objects for the future aggregate selected by ADR 0001:

| Component | Phase 6 version | Upstream release identity |
| --- | --- | --- |
| AirDC++ Core | pinned commit | `55d51ceb817ec006d4ec844d9e3788e1b0ccc352` in `config/upstream.env` |
| BZip2 | 1.0.8 | [official Sourceware](https://sourceware.org/bzip2/downloads.html) `bzip2-1.0.8.tar.gz` release |
| zlib | 1.3.2 | [official zlib](https://zlib.net/) `zlib-1.3.2.tar.gz` release |
| OpenSSL SSL/Crypto | 3.5.8 LTS | [official OpenSSL](https://mirror.openssl-library.org/source/) `openssl-3.5.8.tar.gz` release |
| miniupnpc | 2.3.3 | [official MiniUPnP](https://www.miniupnp.tuxfamily.org/files/) `miniupnpc-2.3.3.tar.gz` release |
| LevelDB | 1.23 | [Google LevelDB](https://github.com/google/leveldb/releases/tag/1.23) tag `1.23` resolved to its immutable commit |
| libmaxminddb | 1.13.3 | [MaxMind](https://github.com/maxmind/libmaxminddb/releases/tag/1.13.3) named release `libmaxminddb-1.13.3.tar.gz` |
| Snappy | 1.2.2 | [Google Snappy](https://github.com/google/snappy/releases/tag/1.2.2) tag `1.2.2` resolved to its immutable commit |

Source endpoints must be version-specific official upstream locations. Moving `latest`, `current`, branch-head, Homebrew bottle, and GitHub branch-archive URLs are forbidden lock inputs. Archive entries require the exact downloaded-byte SHA-256. Git entries require a full commit and a canonical checkout-tree manifest SHA-256. A tag name is recorded as provenance but is never sufficient identity by itself.

### 4.2 Build-only dependency

Boost 1.90.0 is a pinned build-only input because the inspected Core CMake requires the `regex` and `thread` components. It is acquired from the [official Boost 1.90.0 source archive](https://archives.boost.io/release/1.90.0/source/) and built as required to provide complete imported targets to the Core configure.

Boost objects are not included in the aggregate solely because configure requires Boost. If the rebuilt external consumer establishes a physical Boost link requirement, Gate 6 stops and ADR 0001 must be amended before packaging work begins.

### 4.3 Apple system boundary

SDK Iconv remains the explicit system link input. libc++ and libSystem remain implicit Apple toolchain load commands. Gate 4 measured no required Apple framework. Any newly measured system library or framework is a link-contract change requiring review.

### 4.4 Host tools

Git, curl, CMake, Ninja, Python 3, Perl, Make, pkg-config tooling, Apple Clang, Apple archive tools, and inspection utilities are host tools. They may be supplied by Xcode, macOS, or Homebrew, but their resolved paths and versions are recorded. Host-tool provenance does not permit any non-system header or library to resolve from Homebrew during the reproducible Core or consumer build.

## 5. Canonical dependency lock

`config/dependencies.lock` is canonical UTF-8 JSON with schema version `1`, two-space indentation, lexically sorted object keys, one trailing newline, and no duplicate keys. Dependency records are ordered in build-topological order. A tracked Python helper parses JSON with duplicate-key rejection, validates every field, and verifies that reserialization produces the same bytes. Shell code never evaluates or sources lock content.

Each dependency record contains:

- logical name and exact version;
- role: `aggregate` or `build-only`;
- source kind, official URL, immutable commit when applicable, archive SHA-256 when applicable, and canonical source-tree manifest SHA-256;
- source-derived epoch used for deterministic build inputs and canonical published regular-file and symlink mtimes;
- dependency names and deterministic build order;
- build system and complete ordered configure/build/install option arrays;
- expected installed headers, static archives, package metadata, and forbidden shared outputs;
- SPDX license identity plus exact source license/notice paths;
- ordered tracked patches, each with path and SHA-256; and
- supported architecture, deployment target, build type, C/C++ runtime policy, and linkage type.

An empty patch array means the source is unmodified. No patch entry may be added until an unpatched failure is preserved and the patch is the smallest reviewed correction. The lock binds the patch bytes rather than merely their filenames.

## 6. Filesystem and data flow

```text
config/dependencies.lock
            |
            v
Dependencies/.downloads/           verified source cache
            |
            v
Dependencies/<name>/               immutable extracted checkout
            |
            v
Build/dependencies/<name>/          private build tree and evidence
            |
            v
Build/prefix/<name>/                atomic component prefix
            |
            +------------------+
                               v
Build/airdcpp-core/reproducible-release/
                               |
                               v
Build/airdcpp-core/reproducible-link-interface/
                               |
                               v
tracked Gate 6 report
```

Each component receives its own prefix below `Build/prefix`. There is no merged install tree and no umbrella symlink. Core receives an explicit ordered `CMAKE_PREFIX_PATH` plus exact package roots derived from the lock. This prevents cross-component file replacement and preserves a direct mapping from every installed file to one source input.

Downloaded archive names include the logical name, version, and checksum prefix. Acquisition publishes a cache file or extracted tree only by atomic rename after validation succeeds. Correct cached and extracted inputs make a repeated update an offline no-op.

## 7. Script interfaces

### 7.1 Acquisition

`scripts/update` retains its existing no-argument Core behavior. Phase 6 adds:

```text
scripts/update --dependencies
```

This mode validates the lock, safely reconstructs every dependency, verifies source-tree manifests and licenses, and does not configure, compile, or write below `Build` or `Dist`.

### 7.2 Dependency build

Phase 6 adds:

```text
scripts/build --build-dependencies
```

The command validates all sources before building, then invokes focused adapters in lock order. It builds out of tree, runs the configured upstream validation for each component, validates the staged prefix, and atomically replaces only that component's accepted prefix. A component whose inputs and accepted evidence still match is an idempotent no-op.

### 7.3 Reproducible Core build

Phase 6 adds:

```text
scripts/build --build-reproducible-core
```

This command requires the complete accepted dependency-prefix set. It uses a separate Core build tree and never replaces the Gate 3 candidate or its evidence. All non-system imported targets must resolve under the exact component prefixes. Package registries, user package registries, ambient `PKG_CONFIG_PATH`, and Homebrew library prefixes are excluded from dependency discovery.

### 7.4 Reproducible consumer

Phase 6 adds:

```text
scripts/build --link-reproducible-consumer
```

This command stages the reproducible Core archive and public headers, links the existing real-symbol smoke consumer against the reconstructed static archives and SDK Iconv, runs it, and regenerates the omission and effective-link evidence. It does not construct the aggregate.

## 8. Acquisition safety and idempotence

Before network or filesystem mutation, dependency acquisition validates the project root and rejects symlinked `Dependencies`, cache, destination, temporary, or ancestor paths. Temporary directories are created only below the validated project-controlled dependency root.

Archive inspection occurs before extraction. Acquisition rejects:

- absolute member paths;
- `..` traversal after normalization;
- device, FIFO, or socket entries;
- hard links or symbolic links whose normalized target escapes the extraction root;
- duplicate normalized output paths;
- unexpected multiple top-level roots when one stripped root is declared;
- checksum, file-count, source-tree-manifest, or license-path mismatch; and
- case-folding collisions that would alias on the default macOS filesystem.

Interrupted or failed acquisition leaves the last accepted cache and source tree untouched. Existing source is never silently repaired: an unexpected file, missing file, changed byte, changed link, or wrong Git identity causes refusal and directs the operator to preserve or remove the drift explicitly.

## 9. Static build policy

Every dependency build uses Apple Clang, Release configuration, `arm64`, macOS deployment target `14.0`, and static linkage. C++ dependencies use libc++ through the Apple driver defaults. Shared-library targets, tests requiring mutable network access, examples, command-line applications, and benchmarks are disabled unless one is required to validate the library.

The dependency order is:

1. BZip2;
2. zlib;
3. OpenSSL;
4. miniupnpc;
5. libmaxminddb;
6. Snappy;
7. LevelDB using only the accepted Snappy prefix; and
8. Boost as a build-only prefix.

Each adapter records the exact configure, build, test, and install commands. Available deterministic upstream self-tests run without network access. Each installed library also receives a minimal external compile/link/run check from its installed headers and static archive. An adapter may omit an upstream test only when the preserved evidence proves the test is unusable in this configuration and the Gate 6 report records the compensating check.

The component-prefix validator requires only declared regular files and internal safe links; checks every archive member for ARM64; rejects dylibs and foreign architectures; scans strings and package metadata for source, build, home, and Homebrew leakage; inventories defined and unresolved symbols; verifies license files; and writes a normalized install manifest and output hashes.

## 10. Controlled Core and consumer proof

The reproducible Core configure uses the existing wrapper policies: C++20, Release, Apple Clang/libc++, `arm64`, deployment target `14.0`, static Core, NAT-PMP OFF, and TBB OFF. It adds an exact component-prefix allowlist and disables CMake package registries. Every resolved non-system include path, library, CMake package directory, and pkg-config directory must be inside the declared prefixes.

Native evidence required a reviewed bounded deviation from compiling directly in the pinned checkout. Core now copies only manifest-verified tracked files into its private `reproducible-release/source` stage. Original `Source/airdcpp-core`, immutable dependencies, historical evidence and all other project paths remain unchanged. One tracked policy binds the source commit, original/patched/staged manifests, exact patch bytes and pre/postimages, Python/generator identity, declared version arguments, and final archive. Missing stages or mismatching identities fail closed; the consumer validates this read-only provenance before copying staged public headers.

The sole private Core patch touches exactly three files: `airdcpp/hash/HashStore.cpp` rejects any Tiger-tree database key not exactly 24 bytes before copying into the byte array; `CMakeLists.txt` replaces only the version custom target's `COMMAND` with the fixed wrapper-owned command authority; `airdcpp/util/NetworkUtil.cpp` replaces the variable-length buffer with `char address[INET6_ADDRSTRLEN]`, retaining the selected IPv4/IPv6 length passed to `inet_ntop`. Strict warnings, including `-Werror`, remain enabled. These changes address preserved native failures; they do not modify the original checkout or relax the dependency boundary.

The approved version contract uses pinned commit epoch `1774518197`, tag `0.0.0`, declared commit count `0`, and fixed application identity. Count zero is policy rather than mutable clone depth. Generated `version.inc` is emitted deterministically without remote Git or wall-clock reads; the other declared generated file is hash-verified. The failed native `RULE_LAUNCH_CUSTOM` hypothesis and original generator/HashStore/VLA failures remain evidence, never relabeled as successful. Exact predecessor bytes for the original failed generated artifact were unavailable and are not reconstructed. The consumer calls both actual tag and full-commit APIs, validates both authorities, and prints the commit-based runtime identity.

Host executable paths may point to Homebrew. Non-system compile and link inputs may not. Apple SDK and Xcode paths are allowed and classified separately.

The external consumer repeats Gate 4's force-loaded Core experiment using the reconstructed static inputs. It must compile, link, run, expose the pinned Core identity, and contain no non-system dylib load command. The effective physical link interface is compared with ADR 0001. A new component, Boost archive, Apple framework, or other system input blocks Gate 6 until the ADR is reviewed.

OpenSSL 3.5.8 evidence is new evidence. The prior 3.6.4 command, hashes, and runtime result remain historical and are never overwritten.

## 11. Failure handling and evidence retention

Every command fails closed with the phase, component, failed purpose, preserved log path, and corrective action. No command continues after a failed download, checksum, extraction, source validation, patch, configure, build, test, install, archive inspection, Core resolution check, link, or runtime check.

Each dependency build keeps normalized inputs, host/tool inventory, commands, logs, exit statuses, source and patch identities, install manifest, archive inspection, license inventory, and checksums below `Build/dependencies/<name>/evidence`. Before retrying, an immutable fingerprinted attempt directory captures the prior evidence. A successful retry cannot erase the first failure that justified an adapter or patch.

The live gate confines its complete process tree with a macOS outbound-denying sandbox, permitting localhost for OpenSSL TLS tests. Kernel refusal and loopback probes precede builds. Reused prefixes require an immutable attestation binding every completed adapter, lock, dependency execution authority, tool/input/command/test-log/prefix/license digests. Missing or stale attestation forces a safe all-component rebuild while preserving prior attempts; matching attestation and two ordinary builds prove unchanged reuse. The exact dependency call graph excludes Core-only helpers. The optional dependency-only gate stops before Core/consumer/report and explicitly does not accept Gate 6.

A new prefix is built and validated in a sibling staging directory. Atomic publication happens only after every component check succeeds. Failure leaves the previous accepted prefix byte-for-byte unchanged.

Logs never contain secrets or broad environment dumps. Only the minimum allowlisted environment affecting the build is recorded.

## 12. Test and review strategy

### 12.1 Offline contract tests

Offline tests use local fixture archives and repositories to prove:

- canonical lock parsing and duplicate-key rejection;
- unsupported schema, unknown field, invalid role, invalid checksum, unsafe option, and dependency-cycle rejection;
- checksum-before-extraction ordering;
- traversal, escaping link, device entry, duplicate path, case collision, and unexpected-root rejection;
- interrupted acquisition cleanup and atomic publication;
- correct no-op behavior without network access;
- source drift and license drift refusal;
- per-component prefix isolation and retry preservation;
- build-order enforcement, including Snappy before LevelDB; and
- Homebrew library-resolution and `Dist`-creation refusal.

Build-adapter orchestration tests use controlled fake tools and tiny real ARM64 archives. They do not download upstream sources.

### 12.2 Opt-in live acquisition

The live network gate is explicit:

```sh
AIRDCCORE_RUN_DEPENDENCY_NETWORK_TESTS=1 ./tests/gate6_dependency_acquisition_test.sh
```

It reconstructs every locked source from an empty dependency directory, verifies all identities and licenses, removes the extracted trees while retaining verified cache, reconstructs offline, and proves a final update is a no-op.

Online and offline reconstruction must preserve source manifests, canonical
regular-file and symlink mtimes, and cache contents and mtimes. Populated
directory mtimes are native publication metadata and need not equal the source
epoch or match across reconstruction. Publication performs no subsequent
metadata writes to the published tree. The final no-op comparison includes all
directory and Git metadata mtimes.

### 12.3 Opt-in live build and consumer

The live build gate is explicit:

```sh
AIRDCCORE_RUN_DEPENDENCY_TESTS=1 ./tests/gate6_dependency_build_test.sh
```

It validates every accepted component prefix, rebuilds the reproducible Core candidate, runs the static consumer, compares the measured closure with ADR 0001, checks Git/source/output boundaries, and validates the tracked Gate 6 report.

### 12.4 Review checkpoints

The implementation is divided into independently reviewable checkpoints:

1. lock schema and safe acquisition;
2. leaf C-library adapters;
3. Snappy and LevelDB chain;
4. Boost build-only adapter;
5. controlled Core rebuild and consumer; and
6. Gate 6 report and whole-branch review.

Each checkpoint follows test-first development, receives focused review, and is committed on `feature/reproducible-dependencies`. No checkpoint merges separately into `develop`; a failed final Gate 6 blocks the complete branch merge and Phase 7.

## 13. Gate 6 acceptance criteria

Gate 6 passes only when all of the following are true:

1. The canonical lock validates and contains every required identity, option, patch, expected output, and license path.
2. All locked sources reconstruct safely from an empty dependency directory and again from verified offline cache.
3. Repeated update and build commands are no-ops when inputs and accepted outputs match.
4. Every component prefix is isolated, complete, static, ARM64-only, and bound to deployment target `14.0` by commands plus all available Mach-O build-version evidence.
5. All required upstream and installed-consumer checks pass without network access.
6. The reproducible Core build resolves every non-system package from the declared prefixes and none from Homebrew.
7. The external consumer links entirely from the reconstructed static closure plus SDK Iconv, runs successfully, and exposes the pinned Core identity.
8. The executable has no non-system dylib load command and no source, build, home, or Homebrew path leakage.
9. The renewed link closure matches ADR 0001; otherwise the ADR is amended before acceptance.
10. Every component has reviewed license identity and complete source notice material.
11. Raw evidence remains ignored, the normalized Gate 6 report is tracked, and `Dependencies`, `Build`, and `Dist` remain absent from the Git index.
12. `Dist` and an aggregate archive remain absent.

## 14. Known risks and mitigations

| Risk | Required response |
| --- | --- |
| OpenSSL 3.5.8 changes the measured closure | preserve old evidence, rerun all Core/consumer checks, and amend the ADR if physical inputs change |
| Upstream release archive bytes change or disappear | checksum refusal; use an approved official mirror or immutable commit only through a reviewed lock change |
| Upstream build installs shared artifacts | fail prefix validation; correct the smallest adapter flag rather than delete the dylib afterward |
| Static objects lack uniform deployment load commands | bind policy through recorded compiler/linker flags and inspect every object that exposes build-version metadata; prove the final executable target independently |
| Boost configure requirements exceed the final closure | keep Boost build-only; do not aggregate it without new external-consumer evidence |
| Package metadata reaches Homebrew | reject the prefix or Core resolution evidence; do not sanitize a published artifact after the fact |
| License identity or required notice is unclear | block Gate 6 until source license material and redistribution obligations are reviewed |
| Dependency patch becomes necessary | preserve unpatched failure, add one minimal tracked patch, bind its hash in the lock, and rerun the component from clean source |

## 15. Completion boundary

An accepted Gate 6 makes the dependency and Core inputs eligible for Phase 7 aggregation and packaging. It does not claim that the aggregate is collision-free, byte-reproducible across two clean builds, correctly packaged, or ready for release. Those claims remain assigned to Phases 7 and 8.
