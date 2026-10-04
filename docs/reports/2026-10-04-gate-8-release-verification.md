# Gate 8 — independent verification and release rehearsal

Date: 2026-10-04. Status: IN PROGRESS; Gate 8 has not passed.

## Scope and current checkpoints

Phase 7 integration `fe2283c` was pushed to origin/develop before this phase.
Phase 8 starts from that state on `feature/release-verification`.
Design/plan commit `ef6ee31`; approved public identity correction `c6f09fe`.
Task 1 independent spec and quality review: PASS; 236 Python regressions PASS.
Task 2 commits `41e4225` and `bb8d14b`: independent spec and quality review PASS;
20 focused tests and all 256 Python regressions PASS (131.835 s). Verify/clean
entry points, the fresh-run driver and isolated rehearsal are implemented.
Original Source, Dependencies, Build and schema-1 Dist preservation inventories
were identical before and after Task 1. No original native inputs were rebuilt.

The schema-2 public Core fingerprint is
`c0e9b077a666661b6b22f17fc455c7ce8399e2e021655653498d0749a430c871`.
Its private authority remains independently validated; normalization replaces
only the verified version-authority staging-root field before digesting the
copied input document. Exact archive SHA and all source/tool/flag bindings
remain unchanged. Two independent fresh native builds are still required.

## Acceptance map

The original design section 19 is the binding fourteen-criterion contract.
Results below remain pending until recorded native evidence and review exist.

| Criterion | Required evidence | Result |
|---|---|---|
| 1. Reconstruct declared inputs in supported environment | Two fresh tracked-only roots, absent initial source/dependency/build/package trees; independent pinned acquisition and native builds | Pending |
| 2. Exact and idempotent upstream update | Full configured commit, verified source tree; repeated update without meaningful drift in each run | Pending |
| 3. Explicit native static build policy | Actual Apple Clang/libc++ Release arm64 C++20/minos14; optional feature OFF evidence | Pending |
| 4. Locked dependency identities/licenses | Immutable lock and independently reconstructed source/prefix/license evidence for all eight dependencies | Pending |
| 5. Every public object thin arm64 | Complete actual archive/member inspection in each public verification | Pending |
| 6. Complete public/generated headers | Staged manifests plus actual external public header closure in each run | Pending |
| 7. Genuine external consumer | Fresh relocated force-load compile/link/run using only Dist and declared SDK/system inputs | Pending |
| 8. Symbol/link interface agreement | Complete source definition inventory, final system imports, actual member link-map coverage and load commands | Pending |
| 9. Complete metadata/checksums/notices | Exact file inventory and digest recomputation; original license/prefix/source authority checks | Pending |
| 10. No private or Homebrew reach-back | Artifact/metadata scans, measured header dependencies, confined consumer processes | Pending |
| 11. Rerun safety and exact clean-build equality | Repeat acquisition/build/package checks, identical actual full Dist inventories across both fresh builds | Pending |
| 12. Safe cleanup | Real process tests preserving tracked/dirty source; unsafe root/target and symlink rejection | Pending |
| 13. No generated material tracked | Git index checks for Source/Dependencies/Build/Dist in phase and fresh roots | Pending |
| 14. Reviewed GitFlow and release-only production state | Phase reviews/integration; isolated first-release bootstrap, annotated tag and merge-back rehearsal; no real production refs/publication | Pending |

## Claims boundary

The measured host is macOS 26.5.1 (25F80), with selected macOS SDK 26.5.
Clean independent project roots on this host are not a second physical machine
or proof of execution on macOS 14. Object deployment metadata is checked
separately from actual runtime evidence. A rehearsal tag does not designate a
real release. No legal-compliance, notarization, signing or application
integration conclusion follows from passing a static-library verification.

## Remaining work

Task 3 two full fresh native builds and exact comparison, release rehearsal, independent evidence
review, completion documentation, GitFlow integration and push after Gate 8.
