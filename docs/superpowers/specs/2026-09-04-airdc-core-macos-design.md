# AirDCCore-macOS architectural design

Status: design baseline awaiting user review
Date: 2026-09-04
Authority: this document is the authoritative project design; shorter documents summarize it but do not override it

## 1. Executive summary

AirDCCore-macOS is Project 1 in a three-project chain. Its single responsibility is to acquire an exact AirDC++ Core revision and produce a static, reproducible, verifiable distribution for macOS on Apple Silicon (`arm64`) only. It owns upstream acquisition, dependency reconstruction, build orchestration, packaging, provenance, and verification. It does not own language bridges or an application.

The recommended implementation strategy is staged and hybrid:

1. use Homebrew to supply host tools and accelerate a first native ARM64 feasibility build;
2. experimentally close the final link interface rather than assuming `libairdcpp.a` is self-contained;
3. decide the shape of `Dist` from that evidence; and
4. replace mutable Homebrew publication dependencies with pinned source builds or integrity-checked packaged archives wherever reproducibility and downstream linking require them.

The design milestone creates documentation and repository policy only. It does not implement build scripts, CMake wrappers, patches, dependency builds, smoke-test code, or a static library.

## 2. Purpose, goals, and non-goals

### 2.1 Purpose

Provide one durable, inspectable boundary between changing upstream C++ sources and future macOS consumers:

```text
exact source inputs -> controlled Apple toolchain build -> verified Dist contract
```

### 2.2 Goals

- Pin AirDC++ Core by canonical Git URL and full commit, with no submodules.
- Build Release artifacts with Apple Clang and libc++ for `arm64` only.
- Discover and record the complete final link closure for a real external consumer.
- Make all non-system publication inputs reconstructible and integrity checked.
- Preserve public headers with their include hierarchy.
- Publish libraries, metadata, checksums, provenance, and required licenses under `Dist`.
- Detect wrong architectures, missing symbols, undeclared link inputs, stale outputs, dirty source state, and non-reproducible results.
- Keep stable user-facing commands: `update`, `build`, `verify`, and `clean`.
- Leave documentation precise enough that later Codex sessions can implement one gated phase at a time.

### 2.3 Non-goals

- x86_64 or universal binaries.
- Objective-C, Objective-C++, Swift, Swift Package Manager, AppKit, MVVM-C, client behavior, or UI.
- Implementing Project 2 (`AirDCObjC`) or Project 3 (the macOS client).
- Forking AirDC++ Core or committing its source into this parent repository.
- Creating a general cross-platform build system.
- Declaring an XCFramework, SwiftPM binary target, or application-facing API contract.
- Assuming one archive is preferable before link evidence exists.
- Treating a developer's current Homebrew prefix as a distributable dependency boundary.

## 3. Fixed constraints and terminology

- **Host platform:** macOS on Apple Silicon.
- **Target architecture:** Mach-O `arm64` only.
- **Compiler/runtime:** Apple Clang with libc++.
- **Configuration:** Release.
- **Upstream source:** AirDC++ Core from `https://github.com/airdcpp/airdcpp-core.git`.
- **Source checkout:** ignored `Source/airdcpp-core`.
- **Third-party sources:** ignored top-level `Dependencies`.
- **Build workspace:** ignored `Build`.
- **Published boundary:** ignored/generated `Dist`.
- **Tracked inputs:** documentation, pins, lock data, wrappers, patches, smoke-test sources, and license/provenance rules.
- **Reproducible:** the same tracked inputs and declared toolchain produce semantically identical output, and the implementation must attempt bit-for-bit identity after normalizing known archive metadata. Any accepted non-identical bytes require documented evidence and a semantic comparison.

## 4. Upstream inspection record

This section records verified facts from a read-only inspection of the current public upstream checkout. Design proposals and unresolved questions are in later sections.

### 4.1 Exact snapshot and source URLs

| Field | Inspected value |
| --- | --- |
| Inspection date | 2026-09-04 |
| Git repository | `https://github.com/airdcpp/airdcpp-core.git` |
| Full commit | `55d51ceb817ec006d4ec844d9e3788e1b0ccc352` |
| Local branch | `master`, tracking `origin/master` |
| Commit subject | `Clang: fix a few build warnings` |
| Commit author date | 2026-03-26 11:43:17 +0200 |
| Upstream tags | none present in the inspected clone |
| Git submodules | none |

Exact source references:

- repository: <https://github.com/airdcpp/airdcpp-core>
- commit: <https://github.com/airdcpp/airdcpp-core/commit/55d51ceb817ec006d4ec844d9e3788e1b0ccc352>
- tree: <https://github.com/airdcpp/airdcpp-core/tree/55d51ceb817ec006d4ec844d9e3788e1b0ccc352>
- CMake input: <https://github.com/airdcpp/airdcpp-core/blob/55d51ceb817ec006d4ec844d9e3788e1b0ccc352/CMakeLists.txt>
- archive representation of the exact commit: <https://github.com/airdcpp/airdcpp-core/archive/55d51ceb817ec006d4ec844d9e3788e1b0ccc352.tar.gz>

The checkout used for inspection is `Source/airdcpp-core`, per user direction. It remains ignored by the parent repository.

### 4.2 Verified CMake organization

The inspected repository has one CMake file: top-level `CMakeLists.txt`. It declares target `airdcpp` with `add_library` and relies on `BUILD_SHARED_LIBS` to choose the library kind. A future static build must therefore set `BUILD_SHARED_LIBS=OFF` explicitly.

Source and headers are collected recursively with globs. On non-Windows platforms, upstream excludes core modules by default, removes Windows-only source, removes the ZIP implementation, and disables client-updater code. The non-Windows default for `BUILD_CORE_MODULES` is `OFF`.

The current direct package lookups and target links are:

| Condition | Verified package/target behavior |
| --- | --- |
| Always required | BZip2 (`BZip2::BZip2`), ZLIB (`ZLIB::ZLIB`), OpenSSL (`OpenSSL::SSL`, `OpenSSL::Crypto`), miniupnpc (`miniupnpc::miniupnpc`), leveldb (`leveldb::leveldb`), maxminddb (`maxminddb::maxminddb`), Boost 1.70+ `thread` and `regex` |
| `BUILD_SHARED_LIBS=OFF` | Snappy is required and `Snappy::snappy` is appended |
| Native non-Windows build | Threads and Iconv are required and appended when not cross-compiling |
| `ENABLE_NATPMP=ON` | natpmp is searched without `REQUIRED`; its mapper source is retained and linked only when found |
| `ENABLE_TBB=ON` | TBB is searched without `REQUIRED`; `TBB::tbb` and `HAVE_INTEL_TBB` are added only when found |

On non-Windows, both `ENABLE_NATPMP` and `ENABLE_TBB` default to `ON`. Optional discovery therefore changes features and link closure based on the host unless the wrapper supplies explicit policy values.

The inspected core CMake does **not** find or link Boost `system`, nlohmann-json, WebSocket++, or npm. These are not current direct core dependencies. A dependency used by a broader AirDC++ product is not automatically part of this project's core distribution.

The official Homebrew formula page reported WebSocket++ as disabled on the inspection date: <https://formulae.brew.sh/formula/websocketpp>. This makes pinned source the expected acquisition path if later core link/header evidence requires it, but the formula status does not override the verified fact that the current core CMake does not declare it.

### 4.3 Verified build and packaging behavior

- Python 3 is a build-time host requirement. Upstream locates `python3`/`python` and invokes two generation scripts.
- `scripts/generate_version.py` creates `airdcpp/core/version.inc`; its inputs include `VERSION`, `TAG_APPLICATION`, and `APPLICATION_ID`, which are referenced but not assigned in the core CMake file.
- `scripts/generate_stringdefs.py` creates `airdcpp/core/localization/StringDefs.cpp`.
- Both generated files are written into and ignored by the upstream checkout. Idempotence checks must distinguish these expected files from unauthorized source modifications.
- The core sources use C++ ranges, while the inspected CMake file does not set `CMAKE_CXX_STANDARD` or target compile features. C++20 is the evidence-based starting setting, but the first build gate must prove the complete standard/toolchain contract.
- The file invokes `CHECK_FUNCTION_EXISTS` and `CHECK_INCLUDE_FILES` without including their CMake modules in this repository. It also consumes parent-style variables such as resource/config directories. A wrapper or minimal upstream patch may be needed for standalone configuration, but no patch is justified until a real configure attempt captures the failure.
- `target_precompile_headers` exposes `airdcpp/stdinc.h` as `PUBLIC`, so consumer compile behavior and public dependency headers require smoke-test validation.
- Upstream installation handles a shared target when `BUILD_SHARED_LIBS` is true and optionally installs developer headers. It does not define a complete static target install/export/package configuration for this use case.
- No top-level license file is present in the inspected repository, although source headers inspected include GPL version 3-or-later notices. Release work must establish and stage authoritative license text and dependency notices before publication.

### 4.4 What inspection did not prove

Static inspection does not prove that the project configures or compiles standalone on macOS, which exact package versions work, which unresolved symbols survive in the archive, which libraries/frameworks a final executable must link, or whether output is reproducible. Those are explicit implementation gates, not facts to infer from package names.

## 5. Considered build and dependency approaches

### 5.1 Recommended: staged hybrid

Use Homebrew for host tools and the first feasibility build, then convert each publication-relevant input to a pinned source build or pinned archive when evidence shows it must travel with, or be declared by, `Dist`.

Advantages:

- fastest route to current macOS/Apple Clang failure evidence;
- avoids prematurely building dependencies the core does not actually need;
- produces an evidence-backed link interface before packaging choices become expensive;
- permits gradual hardening into reproducibility; and
- isolates problematic or unavailable formulae in `Dependencies` without forcing all packages into one mechanism.

Costs:

- the discovery build is not itself a release build;
- two dependency modes must be clearly distinguished in logs and metadata; and
- transition criteria from Homebrew to pinned inputs must be enforced.

### 5.2 Homebrew throughout

Use Homebrew for tools and all libraries, and package only `libairdcpp.a` plus headers.

This is convenient for one machine but rejected as the distribution strategy. Formula revisions, bottle rebuilds, prefixes, linkage type, and installed versions can change independently of this repository. It would also push undeclared dependency availability onto downstream consumers and make archive provenance incomplete.

### 5.3 Build every dependency from pinned source immediately

Pin and compile the entire published prerequisite list before attempting AirDC++ Core.

This offers strong input control but is rejected as the starting approach. It spends effort on items the current core does not declare, increases patch/toolchain surface, and risks encoding an imagined dependency graph. It remains the appropriate end state for individual libraries when the link-closure and distribution gates prove that source-built artifacts are necessary.

## 6. Proposed architecture and data flow

### 6.1 Component boundaries

| Component | Responsibility | Depends on | Must not do |
| --- | --- | --- | --- |
| `config` | Declare exact upstream and dependency identities | reviewed pins and checksums | contain machine-local prefixes |
| `scripts/update` | Reconstruct and verify source checkouts | config, Git/network | build or package |
| dependency helpers | Reconstruct only dependencies proven necessary | dependency lock, patches | hide unpinned downloads |
| top-level CMake/toolchain | Adapt the pinned source to one native ARM64 build | source, controlled prefix, Apple toolchain | define downstream app behavior |
| `scripts/build` | Orchestrate dependency and core build stages | acquired inputs | publish unverified `Dist` |
| packaging stage | Copy normalized public outputs and provenance | successful build and link-closure decision | reach back to arbitrary Homebrew paths |
| `scripts/verify` | Independently inspect and consume `Dist` | only `Dist`, smoke-test source, Apple tools | accept Build/Source include or library leakage |
| `scripts/clean` | Remove known generated state safely | explicit project paths | delete tracked inputs or unrelated source changes |

### 6.2 Data flow

```text
config/upstream.env -------------------------+
config/dependencies.lock ----------------+   |
tracked patches ----------------------+  |   |
                                      v  v   v
scripts/update -----------------> Source + Dependencies
                                      |
                                      v
Homebrew discovery or pinned dependency builds
                                      |
                                      v
                           Build/dependencies
                           Build/prefix
                                      |
                                      v
top-level CMake wrapper -------> Build/airdcpp-core
                                      |
                                      v
                         link-closure evidence
                                      |
                         distribution-shape ADR
                                      |
                                      v
                  Dist/include + Dist/lib
                  Dist/metadata + Dist/licenses
                                      |
                                      v
               isolated smoke-test + binary inspection
```

`Dist` may only depend on declared contents of `Dist` and intentionally external macOS SDK interfaces recorded in metadata. `verify` must make accidental source, build-prefix, and Homebrew leakage observable.

## 7. Exact proposed repository tree

The following is the target structure. At the design baseline, only documentation, `.gitignore`, the ignored inspection checkout, and Git metadata exist; the remaining entries are future implementation.

```text
AirDCCore-macOS/
├── .gitignore                              # tracked repository policy
├── README.md                               # tracked concise entry point
├── CMakeLists.txt                          # tracked future wrapper/orchestrator
├── docs/                                   # tracked durable documentation
│   ├── architecture.md
│   ├── build-and-release.md
│   ├── dependencies.md
│   ├── git-workflow.md
│   ├── upstream-policy.md
│   ├── decisions/                          # tracked evidence-backed ADRs
│   │   └── README.md
│   └── superpowers/
│       └── specs/
│           └── 2026-09-04-airdc-core-macos-design.md
├── config/                                 # tracked reproducibility inputs
│   ├── upstream.env
│   └── dependencies.lock
├── cmake/                                  # tracked build integration
│   ├── toolchains/
│   │   └── macos-arm64.cmake
│   └── patches/
│       ├── airdcpp-core/
│       └── dependencies/
├── scripts/                                # tracked stable entry points
│   ├── update
│   ├── build
│   ├── verify
│   ├── clean
│   └── dependencies/                       # optional, only if evidence warrants
├── smoke-test/                             # tracked external C++ consumer
│   ├── CMakeLists.txt
│   └── main.cpp
├── LICENSES/                               # tracked source license/notices as required
├── Source/
│   └── airdcpp-core/                       # ignored downloaded Git checkout
├── Dependencies/                           # ignored reconstructed dependency sources
├── Build/
│   ├── airdcpp-core/                       # ignored core build tree
│   ├── dependencies/                       # ignored dependency build trees
│   └── prefix/                             # ignored controlled install/search prefix
└── Dist/
    ├── include/                            # ignored/generated public header tree
    ├── lib/                                # ignored/generated static artifact set
    ├── metadata/                           # ignored/generated provenance/link/checksums
    └── licenses/                           # ignored/generated release license set
```

### 7.1 Tracked versus reconstructed content

Tracked content expresses intent: docs, pins, checksums, wrappers, patches, smoke-test sources, and license source material. Downloaded upstream/dependency trees and all build/distribution outputs are ignored.

The parent repository must never stage `Source/airdcpp-core` as a nested repository, submodule, or vendor snapshot. A future release is reproducible because config reconstructs the exact source, not because generated files are committed.

`LICENSES` and `Dist/licenses` have different roles. `LICENSES` holds reviewed license inputs or notices that this project must preserve; `Dist/licenses` is the generated release subset and may include license files copied from pinned dependencies.

## 8. Version, acquisition, and update policy

### 8.1 Upstream manifest contract

Future `config/upstream.env` must be a small, shell-safe data file containing at least:

```text
AIRDCPP_CORE_URL=https://github.com/airdcpp/airdcpp-core.git
AIRDCPP_CORE_COMMIT=55d51ceb817ec006d4ec844d9e3788e1b0ccc352
```

If archive acquisition is supported, it must also pin the exact archive URL and SHA-256. The full commit remains canonical. The implementation must parse an allowlisted key/value format rather than executing arbitrary configuration as shell code.

### 8.2 Update behavior

`scripts/update` will:

1. validate configuration before network or filesystem mutation;
2. initialize or reuse the ignored checkout without creating a submodule;
3. fetch only from the declared canonical URL;
4. verify that the commit exists and check out its detached exact tree;
5. verify `HEAD` equals the full configured commit;
6. report or reject unapproved local changes; and
7. succeed without changing results when rerun with the same pins.

Generated `version.inc` and `StringDefs.cpp` require explicit handling because upstream writes them into its checkout. Cleanliness logic must allow only these known generated paths after a build, while update should still begin from a controlled state.

### 8.3 Update review gate

Changing the upstream commit requires a review of CMake, source/platform conditionals, public headers, generated files, license notices, dependency lookups, patches, final link closure, and smoke-test behavior. A green compile alone is insufficient.

## 9. Dependency policy

### 9.1 Classification

Each dependency is one of:

- **host tool:** used to acquire/build/inspect but not linked, such as Git, CMake, Python 3, and likely Ninja;
- **Apple SDK/system interface:** supplied by the selected macOS/Xcode toolchain and explicitly recorded;
- **core direct dependency:** found or linked by inspected upstream CMake;
- **transitive link dependency:** proven by imported-target metadata, unresolved symbols, or smoke linking;
- **optional feature dependency:** present only under an explicit feature policy; or
- **irrelevant broader-product dependency:** published elsewhere but not used by this core build.

### 9.2 Lock requirements

Future `config/dependencies.lock` must record, per non-system dependency: logical name, version, source URL, commit or archive SHA-256, build options, patch-set identity, license identifier/path, expected architecture, and expected linkage type. The format must be deterministic and machine-readable or strictly parseable.

Dependencies that Homebrew cannot or should not supply for release belong in `Dependencies`; no third-party tree belongs under `Source`. Entire third-party trees should be committed only if reliable fetching, licensing, or release constraints make reconstruction impossible and a separate decision record approves the exception.

### 9.3 Homebrew boundary

The first feasibility build may discover packages through the active Apple Silicon Homebrew prefix. Logs must capture formula versions and resolved paths. Those paths must not appear in the final distribution contract.

Before release, each Homebrew-discovered library must be dispositioned as pinned source, pinned archive, or intentionally external SDK/system interface. A release verification must fail if a non-system `Dist` artifact or smoke link resolves against an undeclared Homebrew path.

### 9.4 Optional features

NAT-PMP and TBB cannot remain environment-dependent. The first build may test upstream defaults, but the supported release feature set must explicitly set `ENABLE_NATPMP` and `ENABLE_TBB`, record the decision, and verify the resulting compile definitions and link interface.

## 10. macOS ARM64 build design

### 10.1 Toolchain invariants

The wrapper/toolchain must resolve the active Xcode developer tools and use `xcrun`-provided Apple Clang. It must explicitly set:

- Release configuration;
- `BUILD_SHARED_LIBS=OFF`;
- `CMAKE_OSX_ARCHITECTURES=arm64`;
- libc++ through the Apple toolchain defaults, rejecting non-Apple compilers;
- one reviewed macOS deployment target;
- an explicit C++ language standard, starting with C++20 because current source uses ranges; and
- a controlled dependency search prefix ahead of ambient package locations for reproducible mode.

The exact minimum macOS deployment target and validated Xcode/Apple Clang range are intentionally unresolved until the first feasibility build records evidence. They must be selected and written to config/metadata before packaging, not inherited silently from the machine.

### 10.2 Upstream adaptation rule

Prefer a top-level wrapper that sets policy, includes required CMake check modules, provides explicit application/resource variables, and adds the pinned upstream source. Patch upstream only when a wrapper cannot provide correct behavior or an upstream defect is demonstrated.

Potential gaps observed in static inspection are test hypotheses, not patch authorization. The first configure attempt must preserve logs and first try the pinned source without source changes.

### 10.3 Output isolation

Core and dependency builds are always out of tree. Dependencies install to `Build/prefix`, and the core build uses `Build/airdcpp-core`. Only a packaging step may write `Dist`. Build scripts must print the effective source commit, toolchain, architecture, deployment target, configuration, feature flags, dependency prefix, and build mode before compiling.

## 11. Link-closure experiment and distribution-shape decision

A static archive stores object code; it does not absorb all libraries referenced by those objects. Therefore `libairdcpp.a` must be treated as incomplete until a real final executable link succeeds with an enumerated interface.

### 11.1 Required evidence

After the first successful ARM64 core build:

1. inspect archive members and architectures;
2. list defined and undefined symbols with `nm` or equivalent;
3. inspect imported CMake targets and actual link command lines;
4. compile a consumer from installed/staged headers, outside the upstream build tree;
5. link it incrementally against explicit archives/frameworks/system libraries;
6. run it far enough to exercise a minimal, deterministic core initialization path that requires no network; and
7. record the minimal successful ordered link set and any required public compile definitions.

The smoke test must be designed after public initialization APIs are inspected; a header-only `main` or a link that never references a core symbol does not qualify.

### 11.2 Allowed distribution shapes

The decision gate will choose exactly one:

- **one core archive plus separate dependency archives and an explicit ordered link interface;** clearest provenance and easiest component replacement, but more consumer integration;
- **an aggregate static archive plus metadata describing its ingredients and remaining system links;** simpler file-level consumption, but duplicate members, archive flattening, license boundaries, and symbol collisions require careful verification; or
- **a packaged artifact containing multiple archives behind generated CMake/pkg-config metadata;** preserves components and gives C++ consumers a link target, but may not map directly to later SPM needs.

No shape is preselected. The ADR must use smoke-link evidence, downstream portability, licensing, duplicate-symbol risk, deterministic archive behavior, and Project 2's eventual import constraints without implementing Project 2.

## 12. Dist contract and provenance

Regardless of archive shape, a completed `Dist` contains:

- `include/airdcpp/...` preserving the public include hierarchy and required generated headers;
- `lib/...` containing only reviewed ARM64 static artifacts;
- `metadata/manifest.json` describing upstream commit, dependency pins, feature flags, toolchain, deployment target, C++ standard, and artifact inventory;
- `metadata/link-interface.json` listing archive order, required Apple frameworks/system libraries, compile definitions, and consumer requirements;
- `metadata/checksums.sha256` covering every published file except the checksum file itself; and
- `licenses/...` containing the upstream and dependency license/notice set.

Metadata serialization and archive creation must be deterministic. Volatile wall-clock timestamps, absolute workspace paths, Homebrew prefixes, and random ordering are forbidden in reproducible artifacts. When time identity is required, use a declared source-derived epoch and record the rule.

## 13. Verification design

`scripts/verify` is an independent release gate, not a continuation of a successful build. It must fail nonzero with actionable diagnostics.

### 13.1 Architecture and format

- Run `file` on every library and linked smoke executable.
- Run `lipo -info` or equivalent on Mach-O members/products.
- Prove that every compiled object is `arm64` and that no x86_64 or universal slice exists.
- Prove every published library is static and contains no accidental shared-library payload.

Because a Unix archive is not necessarily itself a Mach-O file, verification may need to enumerate/extract members into a temporary directory and inspect each object. It must clean that temporary directory safely.

### 13.2 Symbols and link interface

- Use `nm` or equivalent to prove expected core symbols are defined.
- Inventory unresolved symbols and reconcile them with the declared link interface.
- Reject unexpected unresolved symbols or link inputs.
- Ensure optional feature symbols/definitions match the recorded policy.

### 13.3 Headers and real consumer test

- Configure the smoke test without adding `Source` or `Build` include paths.
- Compile against `Dist/include` with the declared C++ standard and definitions.
- Link only against `Dist/lib` plus explicitly declared Apple SDK/system libraries.
- Reference and exercise a real core symbol so missing archive members or dependencies cause failure.
- Run the executable without network access or mutable user-state requirements.

### 13.4 Provenance and leakage

- Recompute checksums and validate the manifest inventory.
- Verify all pins, feature flags, architectures, and toolchain values are present.
- Scan artifacts, link commands, and metadata for absolute workspace, user-home, build-prefix, and Homebrew paths.
- Confirm every distributed component has required license material.
- Confirm the parent Git index contains no downloaded source or generated output.

### 13.5 Idempotence and reproducibility

- Run `update` twice and prove the second run makes no meaningful change.
- Run `build` twice without cleaning and prove it does not corrupt or drift outputs.
- Run two builds from separately cleaned `Source`, `Dependencies`, `Build`, and `Dist` state using the same pins and declared toolchain.
- Compare normalized inventories and SHA-256 checksums.
- If bytes differ, identify the exact cause, normalize it where possible, and document any accepted semantic comparison before release can pass.

## 14. Error handling and observability

All scripts must use strict error behavior, validate paths before mutation, and report the failed phase, command purpose, relevant log path, and corrective action. They must not continue after a failed fetch, checksum, patch, configure, build, packaging, or verification step.

Machine-readable evidence should accompany concise console output. Logs belong under `Build` and are not published unless selected provenance is normalized into `Dist/metadata`. Secrets and broad environment dumps must never be captured.

`clean` may remove only explicit generated directories and the two known upstream-generated files after validating the project root. It must never operate on an unresolved variable, home directory, filesystem root, or unrelated dirty upstream content.

## 15. Git and GitFlow policy

- The parent repository tracks source-of-truth inputs, not reconstructed sources or outputs.
- No Git submodules.
- `Source/airdcpp-core`, `Dependencies`, `Build`, and `Dist` remain ignored.
- Patches and lock changes are reviewed together with the pin or failure evidence that motivates them.
- Generated files are not committed merely to make a local build pass.
- Each implementation phase should be a focused commit that leaves its gate verifiable.
- Release tags identify this wrapper/distribution project and must not substitute for upstream/dependency pins.

The parent repository uses full GitFlow:

| Branch | Base | Required merge targets | Role |
| --- | --- | --- | --- |
| `develop` | bootstrap branch | long-lived | Integration; this documentation baseline starts here |
| `master` | first accepted `release/*` | long-lived | Production/release states only; no design baseline or routine development |
| `feature/*` | `develop` | `develop` | New planned capability, preferably one gated phase or smaller coherent slice |
| `bugfix/*` | `develop` | `develop` | Development-line defect correction |
| `release/*` | `develop` | `master` and `develop` | Release stabilization and verification; tag the resulting `master` commit |
| `hotfix/*` | `master` | `master` and `develop` | Urgent released-line correction; tag the resulting `master` commit |

At repository bootstrap, only `develop` is populated. `master` must not be manufactured from the design baseline. For the first release only, create `master` at the exact accepted `release/*` tip, tag it, and merge the release result back to `develop`; this is the bootstrap equivalent of the normal release merge because no production branch exists yet. Later release and hotfix branches merge into the existing `master` and `develop`. Release and hotfix tags use annotated `vMAJOR.MINOR.PATCH` tags on `master`. Their changes must be merged back to `develop`, even when conflict resolution is required. Feature/bugfix branches merge only after the relevant phase gate passes and are then deleted.

Every new feature must start on a `feature/*` branch created from `develop` and merge back into `develop` when complete and gate-verified. This is the normal implementation workflow for all future feature work; direct feature implementation on `develop` is prohibited.

The detailed operator policy is [docs/git-workflow.md](../../git-workflow.md).

## 16. Phased implementation plan and gates

This section decomposes future work; it is not authorization to implement it in this milestone.

### Phase 0 — Design baseline

Deliver this spec, supporting docs, ignore policy, exact upstream inspection record, and an ignored inspection checkout.

**Gate 0:** documents are self-consistent, parent Git excludes the checkout, and only baseline files are committed.

### Phase 1 — Reproducible upstream acquisition

Implement `config/upstream.env` and `scripts/update`, including exact-commit verification, safe dirty-state behavior, and idempotence tests.

**Gate 1:** delete/reconstruct the checkout twice; both results resolve to the configured commit and the second update is a no-op.

### Phase 2 — Native dependency and configure discovery

Record host tools, establish the ARM64 CMake toolchain/wrapper, use Homebrew-assisted packages, and attempt an unmodified upstream configure. Capture missing modules, variables, package-config mismatches, language standard, deployment-target candidates, and optional feature behavior.

**Gate 2:** produce a reviewed configure report. Any wrapper adaptation or patch has evidence and deterministic application. Upstream CMake must be re-inspected before a patch is added.

### Phase 3 — First ARM64 static core build

Build un-packaged `libairdcpp.a` in Release with explicit Apple Clang, libc++, C++ standard, deployment target, architecture, and feature flags.

**Gate 3:** the archive builds from clean state; every member is ARM64; the upstream commit remains controlled; full commands and dependency resolutions are recorded.

### Phase 4 — Transitive dependency discovery

Implement a minimal real consumer, inspect symbols/link commands, and determine the minimal complete link interface including archive order and Apple SDK/system libraries.

**Gate 4:** a clean external smoke executable compiles, links, and runs; its full link closure is documented and repeatable. No source/build path leakage is allowed.

### Phase 5 — Distribution-shape decision

Compare the three permitted artifact shapes using Gate 4 evidence and record the choice in `docs/decisions`.

**Gate 5:** the ADR identifies archive contents, consumer link contract, license implications, deterministic construction method, and rejected alternatives. No packaging starts without it.

### Phase 6 — Reproducible dependency inputs

Implement `dependencies.lock` and only the dependency helpers needed to reconstruct Gate 5's distribution. Pin source/archive identities, checksums, flags, patches, and licenses; eliminate publication reliance on mutable Homebrew artifacts.

**Gate 6:** dependencies rebuild from clean state into `Build/prefix`, match ARM64/deployment-target policy, and have complete provenance/license records.

### Phase 7 — Packaging

Stage the chosen archives, public headers, generated headers, deterministic metadata, checksums, and licenses into `Dist`.

**Gate 7:** `Dist` is complete without source/build/Homebrew reach-back and conforms to the documented file and link contract.

### Phase 8 — Independent verification and release rehearsal

Implement the full verify workflow, clean safety, two-clean-build comparison, and a release rehearsal.

**Gate 8:** all measurable acceptance criteria pass twice from clean inputs. Only then is the static distribution releasable.

Each phase should be planned and executed as a separate Codex task unless its work proves trivially small. Implementation work starts from `develop` on a `feature/*` branch; a failed gate blocks both later phases and merge to `develop`. The initial production publication is stabilized on `release/*`, promoted to `master` under the first-release bootstrap rule, merged back to `develop`, and tagged on `master`.

## 17. Risks and mitigations

| Risk | Impact | Mitigation/gate |
| --- | --- | --- |
| Upstream CMake assumes a parent project | standalone configure failure or implicit values | Gate 2 starts unmodified, then prefers wrapper adaptation with captured evidence |
| Static archive hides transitive requirements | downstream link failures | Gate 4 real consumer link and symbol reconciliation |
| Optional packages change feature set by machine | non-repeatable behavior/ABI | explicit NAT-PMP/TBB policy before Gate 3 release path |
| Homebrew revisions or shared-only packages drift | unreproducible or nonportable Dist | discovery-only boundary and Gate 6 pinned inputs |
| Mixed architectures enter archives | runtime/link rejection | member-level `file`/`lipo` checks in Gates 3 and 8 |
| Public headers leak dependency requirements | downstream compile failures | external header compile and link test |
| Upstream generation dirties checkout | false cleanliness failures or stale sources | allowlist two known generated paths; clean/rebuild checks |
| Aggregate archive causes duplicate members/symbols | incorrect or order-sensitive linking | defer shape; verify inventory and symbols in Gate 5/8 |
| Missing upstream license file | incomplete distribution compliance | establish authoritative license source before Gate 6/7; block release without it |
| Deployment target is inherited accidentally | consumers fail on older macOS | explicit target in toolchain, dependency builds, and metadata |
| Absolute local paths leak into output | non-reproducibility/privacy | artifact and metadata scans plus prefix-map/normalization if evidence requires |
| Upstream globs silently change source set | upgrade drift | inspect source inventory and CMake on every pin update |

## 18. Explicit open questions and resolution points

These items are unresolved by design because they require build evidence. They are not placeholders.

1. **Minimum macOS deployment target:** select at Gate 2 based on supported product policy, Xcode SDK, and dependency compatibility; record it before Gate 3.
2. **Validated Apple Clang/Xcode range:** establish during Gates 2–3 and record in metadata; do not claim broader support than tested.
3. **NAT-PMP and TBB release policy:** benchmark/validate availability and consumer consequences, then make both flags explicit before Gate 3 is accepted.
4. **Final `Dist/lib` shape:** decide only at Gate 5 from real link evidence.
5. **Exact transitive archives/frameworks and order:** discover at Gate 4. Boost system, among others, is neither assumed nor excluded if symbol evidence proves it.
6. **Pinned dependency versions and acquisition mode:** derive from the first successful build, compatibility evidence, static availability, licensing, and reproducibility work at Gate 6.
7. **Need for upstream patches:** permit only after Gate 2 demonstrates that wrapper configuration cannot solve a captured problem cleanly.
8. **Authoritative AirDC++ Core license artifact:** establish before packaging. Source headers indicate GPL-3.0-or-later, but the inspected repository does not contain a root license file.
9. **Strength of reproducibility:** pursue bit-for-bit output; document and approve a narrower normalized/semantic comparison only for a proven toolchain source of nondeterminism.

## 19. Measurable acceptance criteria

The project is complete for its initial distribution milestone only when all of the following are true:

1. Two independent clean checkouts on a declared supported Xcode/macOS host reconstruct exact source and dependency inputs from tracked configuration.
2. `scripts/update` verifies the full upstream commit and is idempotent.
3. `scripts/build` uses Apple Clang/libc++, Release, one explicit deployment target, and `arm64` only.
4. Every non-system dependency is pinned by commit or version plus integrity hash and has recorded license provenance.
5. Every object in every published static archive is verified as ARM64, with no x86_64/universal slice.
6. `Dist/include` contains the preserved public include hierarchy and all required generated headers.
7. A clean external C++ smoke test references a real AirDC++ Core symbol, compiles only from `Dist/include`, links only from `Dist/lib` plus declared Apple SDK/system inputs, and runs successfully.
8. `nm`-based defined/undefined symbol evidence agrees with `metadata/link-interface.json`.
9. `manifest.json`, link-interface metadata, checksums, and license material cover every published artifact.
10. No published file or required consumer command depends on `Source`, `Dependencies`, `Build`, a user home path, or an undeclared Homebrew prefix.
11. Repeating update/build without cleaning is safe, and two clean builds from identical declared inputs match under the approved reproducibility rule.
12. `scripts/clean` removes only validated generated content and preserves tracked files and unrelated dirty source work.
13. The parent Git repository contains no downloaded source, dependency tree, build product, or generated `Dist` artifact.
14. All phase gates and the distribution-shape ADR are reviewed and committed through the documented GitFlow; production output exists only on a tagged `master` release.

## 20. Design completion boundary

This design baseline stops after documentation review and commit. The next user decision is whether this specification accurately captures the intended project. Only after explicit approval should a separate task invoke the implementation-planning workflow, beginning with Phase 1 rather than attempting all phases at once.
