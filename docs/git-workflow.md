# GitFlow policy

The parent AirDCCore-macOS repository uses full GitFlow. This policy does not change or govern the ignored nested AirDC++ Core checkout.

## Long-lived branches

- `develop` is the integration branch. The documentation baseline starts here, and completed feature and bugfix work returns here.
- `main` is the production/release branch. It contains released states after the first release; its existing initial README-only commit is retained as bootstrap history. The production branch name was changed from the original `master` design to `main` by explicit user approval for version 1.0.0.

Direct routine development on either long-lived branch is prohibited after bootstrap. Pull requests or reviewed merges should enforce the flow when a remote is introduced.

## Branch families

| Family | Base | Merge targets | Purpose |
| --- | --- | --- | --- |
| `feature/*` | `develop` | `develop` | Planned new capability, normally one design phase or a coherent part of one phase |
| `bugfix/*` | `develop` | `develop` | Non-production defects found during ongoing development |
| `release/*` | `develop` | `main` and `develop` | Release stabilization, metadata, documentation, and verification; no unrelated features |
| `hotfix/*` | `main` | `main` and `develop` | Urgent correction to the currently released production state |

Feature and bugfix branches are deleted after their reviewed merge to `develop`. Release and hotfix merges to `main` receive an annotated release tag on the resulting production commit; the same fixes are merged back to `develop` so the lines do not diverge. A release/hotfix merge must never omit the merge-back even when it requires conflict resolution.

Every new feature starts on a `feature/*` branch created from `develop` and merges back into `develop` only after its completion gate passes. This is the normal workflow for all future feature implementation; direct feature work on `develop` is not permitted.

Release tags use `vMAJOR.MINOR.PATCH`. A tag identifies this distribution project's released state; exact upstream and dependency pins inside that state remain the source identities.

## Relationship to phase gates

Future implementation starts from `develop` on a narrowly scoped `feature/*` branch. A phase may merge into `develop` only after its gate in [the design spec](superpowers/specs/2026-09-04-airdc-core-macos-design.md) passes and evidence is committed. Failed or incomplete phases remain off `develop` unless a clearly labeled documentation-only investigation is intentionally retained.

When all initial distribution gates pass, create `release/*` from `develop` and permit only stabilization and release evidence. The existing `main` bootstrap and `develop` have unrelated histories. The approved first release merges `release/1.0.0` into `main` with `--allow-unrelated-histories`, preserves both parent histories, resolves the README conflict with the reviewed release README, and receives the annotated `v1.0.0` tag on the resulting `main` commit. Merge that production result back into `develop` to establish shared ancestry. Do not reset or force-push either branch. Later releases use normal release merges into `main` and merge-back to `develop`; production defects use `hotfix/*` from `main` with the same tag-and-merge-back discipline.

Historical design documents and the isolated Gate 8 rehearsal use `master` as their original production name. That rehearsal evidence is preserved; the current operational production policy uses `main`.

Downloaded content under `Source/airdcpp-core`, `Dependencies`, `Build`, and `Dist` is ignored and must not enter any branch.
