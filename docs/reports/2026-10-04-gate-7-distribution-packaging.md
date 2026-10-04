# Gate 7 — native ARM64 distribution packaging

Date: 2026-10-04. Native Gate 7: PASS. Independent Task 3 review and local
integration remain required; this report does not authorize Phase 8 or release.

## Measured public boundary

The package contains one aggregate archive, 16,431 total files, enabled macOS
Core headers/generated material, complete accepted external include trees,
eleven notice/license files, checksums and canonical provenance. The aggregate
contains 1,315 members in ADR 0001's nine-component order. All copied material
remains bound to accepted source/prefix manifests and immutable lock authority.

The compiler used was Apple Clang 21.0.0 (clang-2100.1.1.101), canonical binary
SHA-256 `7def90dd8829726686213a747fc5bff1583df933dae5edc55d755479e0bfe00a`,
with the directly discovered Apple macOS SDK 26.5. The public consumer uses
C++20/libc++, Release optimization, arm64 and deployment target 14.0. It does
not discover Homebrew tools or use private Core/dependency build interfaces.

All 245 Core `.h` files are reached by the syntax/preprocessor probe. The
measured public closure comprises 1,513 Dist header dependencies. TBB and
MSVC-only includes remain inactive under macOS feature guards. `StringDefs.h`
is an enum fragment included inside `ResourceManager` (public header line 71),
not a standalone global header. `pubkey.h` defines an `UpdateManager` static
member; its probe first includes `UpdateManager.h`, matching upstream
`UpdateManager.cpp` line 38. Both fragments retain byte-identical contents.
The all-header probe is syntax-only and is never linked as an object; the
separate identity consumer includes stdinc/version without duplicating pubkey
definitions. Modules and non-Windows `ZipFile.h` remain excluded per the
accepted target inventory, not from a smoke-only guess.

The actual Apple link map covers every one of the 1,315 aggregate members.
All 19,821 unique original external definitions resolve in the executable,
including common storage and weak/coalesced symbols. Apple ld may localize
private-external C++ weak definitions; `nm -Uj` observes their final defined
symbols without confusing final visibility with source classification. The
original member flags/coalescing decisions remain separate public records.
Default libtool TOC semantics still omit common storage entries; force-loading
and measured resolution prove them rather than assuming the TOC indexed them.

Runtime identity: tag `0.0.0`, commit
`55d51ceb817ec006d4ec844d9e3788e1b0ccc352`. Actual Mach-O policy is arm64,
minimum target 14.0. The only load commands are `/usr/lib/libiconv.2.dylib`,
`/usr/lib/libc++.1.dylib`, and `/usr/lib/libSystem.B.dylib`. Iconv is linked
explicitly from the SDK; libc++/libSystem are implicit, and no frameworks or
non-system dylibs are loaded. The 399 final system imports are measured from
the linked executable, not inferred from the union of per-member references.
That union remains accurately labeled `member_undefined_references`.

## Gate checklist and evidence

| Criterion | Result and evidence |
|---|---|
| Ordered accepted pins/archive checksums/platform policy | PASS; immutable lock, Core policy and public prefix archive-row binding plus actual Mach-O inspection |
| Member map and strong/weak collision policy | PASS; complete 1,315-member map and actual flag/payload-bound coalescing inventory; strong/unclassified failures tested |
| Two fresh deterministic containers | PASS; Task 1 two-container construction evidence, repeated in each package operation |
| Complete headers/archive/metadata/checksums/notices | PASS; 16,431-file exact inventory, accepted header/license manifests and authenticated original notices |
| Relocated public consumer and system boundary | PASS; guarded closure, every member force-loaded, real runtime identity and load/import evidence, zero private input reads |
| Deterministic complete reruns | PASS; two default package operations produced byte-identical complete checksum inventories |
| Negative behavior and existing-output preservation | PASS; rehashed pending proof, missing original license, archive drift; focused missing/pin/tool/flag/CPU/header/unsafe-target/rollback tests |
| Regression and independent review | 229 Python tests PASS; historical shell results below; independent review pending |

Command: `AIRDCCORE_RUN_DISTRIBUTION_TESTS=1 ./tests/gate7_distribution_test.sh`.
Elapsed time: 204.158 s. Private evidence:
`/private/tmp/airdc-gate7-f70fcasm/` contains first/second checksum inventories,
relocated Dist, consumer commands/statuses, runtime and Mach-O inspection,
actual link map, proof and gate receipt. The gate audit denied Python opens
under Source/Dependencies/Build; compiler descendants separately deny private
project and Homebrew inputs. Measured dependency paths are restricted to Dist
and the directly selected Apple SDK/toolchain. Private read count: zero.

Published hashes:

- Aggregate: `3e6b1d2be3e7d29e80b19a38633df7d3c9229730f25f1a50abf4f64b588462bb`.
- Manifest: `d8494e1d1140253833dd48baef1b8a471f5152fe9ad4e2efcd8b769d602806a1`.
- Consumer proof: `10284ef664abbe3ed952e16b1f9dcfd18d9c24d73d4703c6f8418d4105dea99e`.
- Checksums: `a6b29a25a7269b6654a656bcfed4d9f0db0d97ceb7cee371da8c68b318a7e127`.

Public proof binds only archive/header/probe inputs. No volatile UUIDs,
relocation paths, wall-clock times, private logs or executables are published.
Fresh `scripts/package --verify DIST` recomputes the measured proof. Internal
structural checks still require completed bound proof and inspect actual
archive/member/symbol policy, without unnecessarily recompiling a candidate.
Checksums provide integrity, not a package signature.

## Verification and nonclaims

`python3 -m unittest discover -s tests -p '*_test.py'`: **229 PASS**, 111.750 s.
Focused consumer: 8 PASS, 11.187 s; package: 19 PASS, 35.151 s; gate process
contract: 2 PASS. Tests use actual Apple compiler/linker objects and runtime,
not a mocked consumer. Historical Gate 5 passed in isolated tracked-only
checkout `/private/tmp/airdc-gate5-regression-vSAJoj/tree` with no generated
inputs/output; active Phase 6 data and Dist were preserved.

Historical fixture batch: **13 scripts PASS**, 582.321 s: upstream_config,
update, configure_helpers, build_configure, cmake_wrapper, find_modules,
build_core, link_consumer, link_adapters, smoke_consumer, reproducible_core,
reproducible_consumer, and `gate6_contract_test.sh --self-test`. These exercised
offline fixtures, not new live Phase 6 acceptance/builds. With isolated Gate 5,
all fourteen requested historical script invocations passed.

Fresh proof-only invocation after the final confinement update also passed:
`AIRDCCORE_RUN_DISTRIBUTION_TESTS=1 ./tests/gate7_distribution_test.sh --verify
/private/tmp/airdc-gate7-f70fcasm/relocated/Dist`, 48.284 s, zero private reads,
same public hashes. Evidence `/private/tmp/airdc-gate7-0k27do2z/`.
`git diff --check` passes; no Source/Dependencies/Build/Dist paths are tracked.

Final independent Task 3 and whole-phase review: **spec PASS; quality PASS**,
no blocking findings. Root repeated the complete Gate 7 on implementation
commit `0569d28`: **PASS**, 194.039 s, zero private-input reads, identical
two-run inventories and published hashes, all three negative cases rejected.
Final evidence is retained at `/private/tmp/airdc-gate7-lrsjgm3h/`; review
reports are retained in the phase's ignored execution workspace. Local
GitFlow integration is separately recorded in Git history after these checks.

This is not two complete clean source/dependency/Core rebuilds, runtime testing
on an actual macOS 14 installation, complete license/legal review, signed or
notarized release readiness, tagging or publication. Those remain Phase 8.
No Phase 6 helper or accepted input/evidence was changed. No unrelated hardening,
new dependency, Swift/Objective-C++/app integration or push is included.
