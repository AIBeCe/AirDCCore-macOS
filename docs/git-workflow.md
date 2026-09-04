# GitFlow policy

The parent AirDCCore-macOS repository uses full GitFlow. This policy does not change or govern the ignored nested AirDC++ Core checkout.

## Long-lived branches

- `develop` is the integration branch. The documentation baseline starts here, and completed feature and bugfix work returns here.
- `master` is the production/release branch. It contains only released states. Because this repository begins with design work, `master` is intentionally not populated until the first proper release.

Direct routine development on either long-lived branch is prohibited after bootstrap. Pull requests or reviewed merges should enforce the flow when a remote is introduced.

## Branch families

| Family | Base | Merge targets | Purpose |
| --- | --- | --- | --- |
| `feature/*` | `develop` | `develop` | Planned new capability, normally one design phase or a coherent part of one phase |
| `bugfix/*` | `develop` | `develop` | Non-production defects found during ongoing development |
| `release/*` | `develop` | `master` and `develop` | Release stabilization, metadata, documentation, and verification; no unrelated features |
| `hotfix/*` | `master` | `master` and `develop` | Urgent correction to the currently released production state |

Feature and bugfix branches are deleted after their reviewed merge to `develop`. Release and hotfix merges to `master` receive an annotated release tag on the resulting production commit; the same fixes are merged back to `develop` so the lines do not diverge. A release/hotfix merge must never omit the merge-back even when it requires conflict resolution.

Every new feature starts on a `feature/*` branch created from `develop` and merges back into `develop` only after its completion gate passes. This is the normal workflow for all future feature implementation; direct feature work on `develop` is not permitted.

Release tags use `vMAJOR.MINOR.PATCH`. A tag identifies this distribution project's released state; exact upstream and dependency pins inside that state remain the source identities.

## Relationship to phase gates

Future implementation starts from `develop` on a narrowly scoped `feature/*` branch. A phase may merge into `develop` only after its gate in [the design spec](superpowers/specs/2026-09-04-airdc-core-macos-design.md) passes and evidence is committed. Failed or incomplete phases remain off `develop` unless a clearly labeled documentation-only investigation is intentionally retained.

When all initial distribution gates pass, create `release/*` from `develop` and permit only stabilization and release evidence. For the first release only, create `master` at the exact accepted release-branch tip, add the release tag there, and merge the release result back into `develop`; this is the bootstrap equivalent of the normal release merge because no production branch exists yet. Every later release merges `release/*` into the existing `master` and `develop`, with the tag on the resulting `master` commit. Production defects thereafter use `hotfix/*` from `master` with the same tag-and-merge-back discipline.

Downloaded content under `Source/airdcpp-core`, `Dependencies`, `Build`, and `Dist` is ignored and must not enter any branch.
