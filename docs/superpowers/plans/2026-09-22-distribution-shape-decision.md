# Aggregate Static Distribution Decision Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Complete Gate 5 by recording and independently validating the evidence-backed decision to publish one aggregate ARM64 static archive while preserving component provenance and an explicit Apple system-link contract.

**Architecture:** Gate 5 is a tracked decision layer only. An accepted ADR binds the future `Dist/lib/libairdcpp.a` contents to the Gate 4 closure, defines a deterministic collision-safe construction algorithm, and assigns dependency pinning/static reconstruction to Phase 6. A small offline gate validates the decision's required clauses and proves that Phase 5 creates no generated dependency, build, or distribution output.

**Tech Stack:** Markdown ADR, POSIX shell decision gate, GitFlow.

**Source evidence:** `docs/reports/2026-09-21-gate-4-consumer-link.md` and Gate 5 in `docs/superpowers/specs/2026-09-04-airdc-core-macos-design.md`.

## Constraints

- Work only on `feature/distribution-shape-decision`, based on merged Phase 4 `develop` commit `46a82ec4510efdf193d0fbb4a51e289e3261a53d`.
- Choose exactly one of the three shapes permitted by design section 11.2.
- Do not build dependencies, create an aggregate archive, create `Dependencies` or `Dist`, implement packaging, or begin Phase 6.
- Do not invent final dependency versions, checksums, licenses, deployment compatibility, or static-build flags; Phase 6 must measure and pin them.
- Preserve the Phase 3 archive and Phase 4 ignored evidence unchanged.
- Keep Project 2 out of scope; its Objective-C++/SPM boundary is a downstream constraint, not implementation authorization.

### Task 1: Gate 5 decision contract

**Files:**
- Create: `tests/gate5_distribution_shape_test.sh`

- [ ] Write a failing offline test requiring an accepted ADR at `docs/decisions/0001-aggregate-static-distribution.md`.
- [ ] Require exact clauses for the chosen artifact path, component inventory, system-link boundary, deterministic construction method, collision rejection, license/provenance obligations, Phase 6 handoff, rejected alternatives, and explicit non-claims.
- [ ] Require the Gate 4 report and measured Core/archive identities to remain referenced.
- [ ] Require `Source`, `Dependencies`, `Build`, and `Dist` to remain untracked, and require `Dependencies`/`Dist` to be absent.
- [ ] Run RED; the only failure must be the missing ADR.

### Task 2: Accepted aggregate-archive ADR and operator documentation

**Files:**
- Create: `docs/decisions/0001-aggregate-static-distribution.md`
- Modify: `docs/decisions/README.md`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/build-and-release.md`
- Modify: `docs/dependencies.md`

- [ ] Record `Accepted` status and the Gate 4 evidence that drove the choice.
- [ ] Select future `Dist/lib/libairdcpp.a` containing Core plus pinned static BZip2, zlib, OpenSSL SSL/Crypto, miniupnpc, LevelDB, MaxMindDB, and Snappy objects.
- [ ] Keep SDK/system Iconv, libc++, and libSystem external and machine-readable; record that Gate 4 found no Apple framework requirement.
- [ ] Define construction as: validate static ARM64 inputs; enumerate objects in declared component order; reject duplicate global definitions; extract into component/ordinal namespaces; rename members uniquely; generate a byte-sorted file list; run Apple `libtool -static -D -filelist`; regenerate the table of contents; and independently verify members, symbols, path leakage, and repeatability.
- [ ] Require per-component manifest/checksum/license records even though `Dist/lib` publishes one archive.
- [ ] Reject separate public dependency archives because they leak order/transitive complexity to Project 2; reject CMake/pkg-config-wrapped multiple archives because that interface does not align with the later SPM boundary.
- [ ] State that Gate 5 does not prove static dependency availability, macOS 14 compatibility, licensing completeness, aggregate feasibility, or reproducibility; those are blocking Phase 6–8 gates.
- [ ] Update concise docs and remove statements that the shape is undecided.
- [ ] Run Gate 5 GREEN and `git diff --check develop`.

### Task 3: Review and GitFlow completion

- [ ] Run the full offline Phase 1–5 regression suite.
- [ ] Request one independent read-only review focused on evidence fidelity, component completeness, deterministic construction, licensing boundaries, downstream constraint use, and the Phase 5 hard stop.
- [ ] Fix Important/Critical findings with a focused test-first pass; fix low-risk Minor findings or record rationale.
- [ ] Commit the Gate 5 decision on the feature branch.
- [ ] Stop before Phase 6 and present GitFlow integration choices.

## Gate 5 acceptance

Gate 5 passes when the accepted ADR names the exact future aggregate contents, consumer system-link boundary, deterministic construction method, collision policy, license/provenance obligations, and rejected alternatives; the independent decision test passes; no packaging/build output is created; and review has no unresolved Important or Critical finding.
