# Gate 8 — independent verification and release rehearsal

Updated: 2026-10-06. Native two-root experiment: PASS. Gate 8: PASS under the
explicitly revised criterion 1; physical-machine testing is not claimed.

The user explicitly approved the following replacement on 2026-10-06:
"Two independent clean checkouts on a declared supported Xcode/macOS host
reconstruct exact source and dependency inputs from tracked configuration."
The original fresh-machine requirement was not met and is not claimed.
This approved scope change removes that acceptance gap; no other criterion,
archive pin, build policy or verification requirement changes.

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
remain unchanged. Both independent fresh native builds and their reruns passed.

The approved command-order correction is committed as
`5dc469927c3c0b897f1f572eba2ee0bef516840a`: both private-consumer passes precede
publication, preserving the existing Dist-absence guard and all fourteen commands.
Its regression reproduced the native failure before the fix; 12 focused tests
and all 257 Python regressions passed (145.992 s). Independent scoped spec and
quality review passed. No archive, dependency, tool or source policy was repinned.

## Native evidence

Command: `AIRDCCORE_RUN_RELEASE_TESTS=1 ./tests/gate8_release_test.sh`.
Frozen implementation: `5dc469927c3c0b897f1f572eba2ee0bef516840a`;
tracked implementation inventory SHA-256:
`0e09a1c35c5a52da0bca7e99e9308021e49dceb4add3ad3999b087c64224f422`.
Retained evidence: `/private/tmp/airdc-gate8-5csn72qj`.
Its `run-1/project` and `run-2/project` are separately owned tracked-only clones,
with no shared inputs/products. Source, Dependencies, Build and Dist were absent
before either acquired its pinned inputs. Each passed all fourteen commands:

```text
update -> dependencies -> dependency-build -> core -> private-consumer
repeat-update -> repeat-dependencies -> repeat-dependency-build
repeat-core -> repeat-private-consumer
package -> verify -> repeat-package -> repeat-verify
```

Both update passes verified upstream `55d51ceb817ec006d4ec844d9e3788e1b0ccc352`.
Both dependency acquisitions verified lock SHA-256
`d4a4b7a5f7bdc7f6a7e9076db9fa4113a5771c2000c72abf06b70c164230cddd`.
Acquisition/dependency-build reruns preserved content and filesystem metadata.
Each Core rerun matched its archive and private/public input identities.
All four public verifications compiled, force-loaded, linked and ran a fresh
relocated confined consumer. Each package has 16,431 files and 1,315 archive members.
Root independently reran `compare_receipts`, recomputing receipt/log/input bindings
and complete inventories: PASS, including exact cross-root byte equality.

| Bound result | SHA-256 |
|---|---|
| Core ingredient archive, both roots and reruns | `085b179a33c9298c07554f5eac2159d531cc0208af718d2d4958f86507bfec93` |
| Public aggregate archive, both roots and reruns | `3e6b1d2be3e7d29e80b19a38633df7d3c9229730f25f1a50abf4f64b588462bb` |
| Complete public inventory, both roots and reruns | `218a6ea42e382b5db2444f70c9bd807a7b11180d882ebf71e16563c0001a7bdf` |
| Run 1 private Core fingerprint | `2ecd7183e492e4d8788a334803dfcc7342754089e1696f7ee6414d68b1cfcf51` |
| Run 2 private Core fingerprint | `3dbd089bd7090e1791d9b7b251c181fbf88303265cbbf3b8012aa789210f319d` |
| Run 1 private version authority | `ad72697e160e94346f311bee207685d0bde72b5e9317ddce05d3bfc759bb7195` |
| Run 2 private version authority | `2dbf43fb957b6cfd6eb06c677da49b08b207f44515bb17b8e662dc1497428537` |
| Top-level receipt | `4ce4a76ad734012938cd4d8c39bef4812217bdaee52963e8fbdc4ef61a28d86e` |
| Run 1 receipt | `9c090c364bb94d24ae5860dad7d4db86c6a8c80b2da33e5a5510417ba6c4e49a` |
| Run 2 receipt | `978b549a827d85fe67dc203506766959c4732de85d40b580c2aec23a4903a946` |

Raw fingerprints differ because their verified staging roots differ; the shared
normalized public fingerprint above preserves all non-path identity fields.
The host was macOS 26.5.1 (25F80), arm64, SDK 26.5, Apple Clang 21.0.0,
CMake 4.4.3, Ninja 1.13.2 and Python 3.14.7. Exact executable identities and
invocation aliases are bound in each receipt. Build policy remains Release,
arm64, macOS deployment target 14.0, C++20/libc++, NAT-PMP and TBB OFF.

Against each fresh implementation, `clean_generated_test.py` passed all six
real-process safety fixtures. Independent disposable GitFlow rehearsals passed
first-master bootstrap, annotated `v0.0.0` tag identity and merge-back; source
refs remained unchanged. None created production refs or published a release.
External supplement logs and hashes:

| Log under `/private/tmp/` | SHA-256 |
|---|---|
| `phase8-corrected-run1-clean-fixtures.log` | `8a68d603ddf75a7f848ba235a116d7ab28282154178a8541dfbccd320fb65b86` |
| `phase8-corrected-run2-clean-fixtures.log` | `477c59ef80efa31127618f67173c31bc22f430a206d550901b78cb510bf96162` |
| `phase8-corrected-run1-rehearsal.log` | `694ec117a56c8aaf48416b79787836cfc09424a06334482bddffd232cae77742` |
| `phase8-corrected-run2-rehearsal.log` | `a92f66d54d396142fe787c24cb6b07d2988cbef57a73615fb3768aa0276c211b` |

The driver also completed its own separate disposable rehearsal, bound in the
top-level receipt. Accepted distributions and all failed-attempt evidence remain
in their original locations; original Phase 6/7 native trees were not rebuilt.

## Retained failures and limitations

1. `/private/tmp/airdc-gate8-1s611mlg`: pinned miniupnpc acquisition timed out.
   Read-only URL probes subsequently succeeded; no pin or downloader policy changed.
2. `/private/tmp/airdc-gate8-kom4a5u8`: Core configure/build succeeded, but the
   exact scope guard rejected deletion of thirteen empty dependency directories.
   No file/link change was observed. An isolated copied-root native preconfigure
   probe (`/private/tmp/airdc-preconfigure-probe-CLe4bkir`) observed 6,076 external
   command boundaries, preserved all thirteen identities and passed scope checks.
   The cause remains unresolved. Later strict runs passed; no guard was relaxed
   and no causal fix is claimed. Record this finding for later investigation.
3. `/private/tmp/airdc-gate8-vjyzlhva`: repeated private-consumer linking correctly
   refused an existing Dist. The approved ordering correction fixed this driver
   error; the fixture now enforces the actual production precondition.

## Acceptance map

The original design section 19 is the binding fourteen-criterion contract.
The native driver PASS is not by itself an unconditional Gate 8 verdict.
Criterion 1 below uses the user's explicit 2026-10-06 replacement; the retained
evidence satisfies its independent clean-checkout requirement.

| Criterion | Required evidence | Result |
|---|---|---|
| 1. Two independent clean checkouts reconstruct declared inputs on a supported host | Two separately owned tracked-only roots independently acquired and verified all pinned inputs | PASS under explicitly revised criterion |
| 2. Exact and idempotent upstream update | Pinned commit verified twice in each root, with no-op snapshots | PASS on measured host |
| 3. Explicit native static build policy | Actual configured/compiler/object evidence and four public verifications | PASS on measured host |
| 4. Locked dependency identities/licenses | Independently acquired and validated all eight locked sources/prefixes/licenses | PASS on measured host |
| 5. Every public object thin arm64 | Four complete actual archive/member inspections | PASS on measured host |
| 6. Complete public/generated headers | Four verified package/header closures and external consumer compilations | PASS on measured host |
| 7. Genuine external consumer | Four fresh relocated force-loaded compile/link/run verifications | PASS on measured host |
| 8. Symbol/link interface agreement | Complete definition/import/member-link coverage and load-command validation | PASS on measured host |
| 9. Complete metadata/checksums/notices | Full inventory/digest/license/provenance validation four times | PASS on measured host |
| 10. No private or Homebrew reach-back | Four confined public consumers and artifact/header/metadata checks | PASS on measured host |
| 11. Rerun safety and exact clean-build equality | Core identities and exact full Dist inventories match; acquisition/build no-ops | PASS on measured host |
| 12. Safe cleanup | All six real-process safety fixtures pass independently against both implementations | PASS on measured host |
| 13. No generated material tracked | Bound clean-start/index/status checks in both roots and feature | PASS |
| 14. GitFlow and release-only production policy | Scoped reviews and isolated rehearsals passed; feature integration follows Gate 8 acceptance | PASS for policy/rehearsal; no production release claimed |

## Claims boundary

The measured host is macOS 26.5.1 (25F80), with selected macOS SDK 26.5.
Clean independent project roots on this host are not a second physical machine
or proof of execution on macOS 14. Object deployment metadata is checked
separately from actual runtime evidence. A rehearsal tag does not designate a
real release. No legal-compliance, notarization, signing or application
integration conclusion follows from passing a static-library verification.

## Completion and release boundary

Task 3 native execution, equality comparison, cleanup fixtures and rehearsals
are complete. Independent implementation/spec/quality and native evidence/report
accuracy review: PASS, with no additional blocking findings. The user's explicit
2026-10-06 criterion replacement is recorded above and in both design documents.
Final revalidation on 2026-10-06 passed: `compare_receipts` independently
recomputed both full receipt bindings and exact inventories; `scripts/verify`
performed another genuine relocated force-loaded public consumer; the full
Python suite passed all 257 tests in 278.208 s. Logs are retained outside the
project as `/private/tmp/phase8-final-comparison.log`,
`/private/tmp/phase8-final-public-verify.log` and
`/private/tmp/phase8-final-regression.log`.
The same independent reviewer approved the exact acceptance-policy wording and
confirmed the retained native evidence satisfies the revised criterion.
Final independent spec, evidence and documentation review: PASS, with no blocking
findings. Gate 8 and Task 3 acceptance are complete; no implementation or
acceptance work remains. Normal GitFlow handoff integrates this accepted feature,
verifies the merged checkout and pushes develop.
Actual production promotion, release tagging and release publication remain
separate decisions; none is authorized by this acceptance change.
