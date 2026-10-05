# Phase 8 release verification implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Preserve worker/reviewer ownership per AGENTS.md.

**Goal:** Establish the original Gate 8 without weakening previously accepted input or package validation.

**Architecture:** Keep private evidence unchanged; normalize only public Core identity. Reuse public package verification and existing build entry points in two fresh independent roots. Rehearse releases locally, not in production refs.

**Tech Stack:** Python 3, POSIX scripts, Git, Apple Clang/Xcode, existing pinned dependency adapters.

**Spec:** `docs/superpowers/specs/2026-10-04-release-verification-design.md`, original design sections 13–16 and 19.

## Global Constraints

- arm64 only; Release; macOS deployment target 14.0; C++20/libc++; NAT-PMP/TBB OFF.
- Upstream commit `55d51ceb817ec006d4ec844d9e3788e1b0ccc352`; existing dependency lock and byte checks stay authoritative.
- Preserve Phase 6 private files/validators and existing native outputs; no Homebrew publication dependency.
- Exact full-package byte equality; no unapproved semantic fallback.
- GitFlow feature starts from develop; no real release/master/tag/publication in a rehearsal.
- Tests before implementation; focused verification and full suite; small commits; independent spec and quality review.

## Review Focus

- Relocation must not erase non-path source/tool/input drift (Task 1).
- Rehashed tampered packages still fail public verification (Tasks 1–2).
- Clean must preserve tracked and dirty source files and reject symlink escape (Task 2).
- A failed/incomplete clean run cannot earn a passing receipt or comparison (Task 2).
- Rehearsal refs must remain outside the real repository (Tasks 2–3).

### Task 1: Path-independent published Core identity

**Files:** Create `scripts/lib/public_core_identity.py`, `tests/public_core_identity_test.py`; modify `scripts/lib/distribution_aggregate.py`, `scripts/lib/distribution_package.py`, relevant distribution tests, `config/packaging-core-policy.json`.

**Interfaces:** Consumes validated private Core evidence; produces a normalized public Core fingerprint. Private Core provenance and validators are unchanged. Schema 2 policy pins the normalized fingerprint; exact artifact/tool/source/flag checks remain.

- [x] Write behavior tests: relocated staging authority produces equal public digest; source/generator/tool/implementation changes do not; wrong private digest/stage identity rejected; actual schema-2 package flow preserves binding.
- [x] Run tests and observe RED before implementation.
- [x] Implement exact normalization defined in spec, integrate only public identity construction/validation, derive schema-2 pin from accepted preserved evidence.
- [x] Run focused tests and full `python3 -m unittest discover -s tests -p '*_test.py'`; do not rebuild preserved inputs or replace Dist.
- [x] Commit; report RED/GREEN and immutable old-output preservation evidence; independent task review PASS.

### Task 2: Verify/clean entry points and Gate 8 driver

**Files:** Create `scripts/verify`, `scripts/clean`, `scripts/lib/release_verify.py`, `scripts/lib/clean_generated.py`, `scripts/lib/release_rehearsal.py`, `tests/release_verify_test.py`, `tests/clean_generated_test.py`, `tests/release_rehearsal_test.py`, `tests/gate8_release_test.sh`; update operator docs.

**Interfaces:** Public verify delegates to complete existing verification; clean operates on its own project root only. Gate 8 drives existing update/build/package entry points in fresh tracked Git checkouts and writes bound receipts outside their scope. Rehearsal uses only owned disposable repository refs.

- [x] Write tests for CLI exit/error behavior, package drift failure, dirty-source/track preservation, top-level symlink rejection before mutation, failed run/partial receipt rejection, exact inventory difference rejection, release bootstrap/tag/merge-back behavior and real-ref preservation.
- [x] Observe RED; implement minimal driver/entry points per spec, no new build framework. Avoid duplicating package verifier logic.
- [x] Run focused tests and full Python regression suite. Test clean against disposable fixtures, never authoritative native outputs.
- [x] Commit; independently review spec and quality to PASS.

### Task 3: Two clean builds, measured release rehearsal and Gate 8 report

**Files:** Update this plan and operator docs; create `docs/reports/2026-10-04-gate-8-release-verification.md`.

**Interfaces:** Consumes frozen reviewed Task 1–2 implementation and Gate 8 driver; produces retained native run receipts, complete fourteen-criterion acceptance map and reviewed Gate 8 verdict.

- [x] Correct the native retry2 driver-order blocker: both input/Core/private-consumer passes precede both package/verify passes, preserving the existing Dist-absence policy and all fourteen commands. Regression verification and scoped independent review are required before freezing the corrected implementation.
- [ ] Freeze code; run opt-in Gate 8 in two fresh independent roots, acquisition through packaging/verification; repeat safe update/build and compare exact complete package inventories.
- [ ] Diagnose only blockers; do not loosen archive/input policy to mask mismatches. Record any material new conflict for Root.
- [ ] Run isolated GitFlow rehearsal and cleanup safety tests; independent public verification and regression.
- [ ] Record exact commands/statuses, root ownership/clean start, pins/tool/OS identity, original/private versus normalized Core fingerprints, full Dist comparison and limits.
- [ ] Independently review Task 3 evidence and whole phase. Gate 8 only PASS if its measurable criteria are genuinely established. Commit completion docs, integrate via GitFlow and push only after PASS. If external state or release authorization prevents PASS, report exact remaining requirement without claiming completion.
