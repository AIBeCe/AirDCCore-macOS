# Phase 7 implementation plan

**Goal:** Pass existing Gate 7 with a complete relocated ARM64 static package.
**Architecture:** Dedicated packaging entry point consumes read-only accepted
Phase 6 inputs; deterministic aggregation and staged publication preserve
component provenance and the ADR 0001 public link boundary.
**Tech:** Python 3 standard library, POSIX shell, Apple Clang/libtool/Mach-O.
**Spec:** `../specs/2026-10-04-distribution-packaging-design.md`.
**Execution:** Complete phase authorized; one persistent implementation owner
and an independent persistent reviewer. Small verified commits as appropriate.

## Global Constraints

Follow ADR 0001's exact ordered nine ingredients and canonical member naming.
Publish one `Dist/lib/libairdcpp.a`; Iconv explicit, libc++/libSystem implicit,
no Apple frameworks. Release/arm64/C++20/libc++/macOS 14; NAT-PMP and TBB OFF.
Do not change Phase 6 build/acquisition interfaces, lock, or accepted outputs.
Do not reopen completed tasks or fix unrelated hardening/style observations.
Generated distribution/build outputs remain ignored. No push or release.
Phase 8 full clean-build comparisons remain out of scope.

## Review Focus

Review actual accepted-input binding rather than trusting recorded hashes;
symbol classification and weak-vs-strong semantics; duplicate member handling;
header closure and generated-header authority; notices for redistributed
headers; canonical metadata and checksums; existing-output preservation;
relocated force-loaded consumer and measured system boundary. Nonblocking
findings are recorded for Phase 8, not silently added to this gate.

### Task 1: Validated packaging inputs and deterministic aggregate

**Files:** New focused module(s) under `scripts/lib`, packaging unit tests.
**Interfaces:** Produces ordered validated components, member map, symbol
decisions, aggregate bytes, and deterministic provenance for Task 2. Reuses
`inspect_core_archive.archive_members` and applicable Phase 6 validators.

1. Read existing lock, Core source validator, dependency evidence manifests,
   tool inventory, ADR, and real member/symbol data before implementing.
2. Write and observe failing behavioral tests for pin/hash/policy drift,
   duplicate strong symbols, unclassified coalescing, duplicate original member
   names, safe normalization, ordering, and independent aggregate inspection.
3. Implement minimal validated-input and Mach-O symbol/member handling.
4. Construct two private aggregates from accepted inputs with Apple libtool;
   verify member identities, TOC, ARM64/deployment, paths and equal hashes.
5. Run focused tests; record evidence and commit the checkpoint.

### Task 2: Complete distribution and verification interface

**Files:** `scripts/package`, focused packaging helper(s), packaging tests;
relevant operator/architecture documentation only.
**Interfaces:** Consumes Task 1's validated provenance and member map; produces
the documented Dist contract and verification-only interface for Task 3.

1. Inspect actual Core and external public header includes and original license
   notices. Define exact staged closure without private source reach-back.
2. Write and observe failing tests for missing headers/notices, checksum or
   metadata tampering, undeclared files, unsafe targets, failed candidate
   preservation, and deterministic reruns.
3. Implement candidate header/license staging, stable manifest/link metadata,
   all-file checksums, validation-only mode and safe publication.
4. Run focused tests and the project's existing Python regression suite;
   verify tracked/ignored boundaries and commit the checkpoint.

### Task 3: Relocated consumer, Gate 7 evidence and independent review

**Files:** `tests/gate7_distribution_test.sh`, supporting focused tests,
`docs/reports/2026-10-04-gate-7-distribution-packaging.md`, operator docs,
this plan's completion record.
**Interfaces:** Consumes only Task 2 Dist for the public consumer. Private gate
evidence lives under Build or private temporary directories, not Dist metadata.

1. Write and observe failing gate/consumer tests using genuine compiler/tool
   behavior; prevent source/build/dependency/Homebrew include or link inputs.
2. Relocate Dist, compile public header probes and a real C++20 identity
   consumer, force-load aggregate, link SDK Iconv, run and inspect load commands.
3. Run package twice, compare complete published content, exercise tampering
   failures, and rerun relevant historical regressions without changing Phase 6.
4. Write the evidence-backed report with explicit Gate 7 checklist/nonclaims.
5. Independent reviewer inspects implementation, tests, and evidence; fix only
   blocking in-scope findings through the same worker/reviewer pair.
6. Fresh Gate 7 and regression verification before final commit/integration.
   Stop when Gate 7 passes; no automatic Phase 8 start.

## Execution record

- Phase 6 baseline: `ae44251656fb07cfe1f77a6a577e588df1f42e1c`.
- Approved phase scope and continuous execution: 2026-10-04.
- Task 1: complete; validated ingredients, Mach-O member/symbol policy, two
  byte-identical aggregate constructions; independent spec/quality PASS.
  Commits `87108e0`, `5b60a01`.
- Task 2: complete; byte-bound headers/notices/provenance, verification-only
  contract and atomic publication/rollback; I1/I2 and independent spec/quality
  PASS. Commits `2fe8507`, `f6bfea6`.
- Task 3: complete; independent Task 3 and whole-phase spec/quality PASS, no
  blocking findings. Implementation commit `0569d28`; 229 Python regressions
  and fourteen historical script invocations PASS.
  Public proof binds archive/header/probe inputs without checksum recursion;
  fresh verification compiles/links/runs from relocated Dist only. Both
  contextual header fragments retain original bytes and documented context.
  Root's fresh complete Gate 7 PASS (194.039 s), with identical published hashes,
  zero private-input reads and all negative cases rejected. Final implementation
  tree clean; generated outputs untracked/ignored. Local GitFlow integration
  follows this completion checkpoint; no Phase 8 start or remote publication.

All three Phase 7 tasks and Gate 7 are complete. The independent review reports
are retained in the phase's ignored execution workspace. Richer per-file
preservation receipt formatting was nonblocking and deferred; this gate proves
same-input deterministic aggregate construction and package reruns, not Phase 8
full clean-build reproducibility, minimum-OS runtime or release readiness.
