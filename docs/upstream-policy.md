# Upstream and patch policy

The authoritative policy is in [the design spec](superpowers/specs/2026-09-04-airdc-core-macos-design.md).

## Source identity

AirDC++ Core is acquired from `https://github.com/airdcpp/airdcpp-core.git` at an exact full commit recorded in future `config/upstream.env`. Branch names are informational and must never be the reproducibility boundary.

The design inspection used:

- commit: `55d51ceb817ec006d4ec844d9e3788e1b0ccc352`
- branch at inspection: `master`
- exact tree: <https://github.com/airdcpp/airdcpp-core/tree/55d51ceb817ec006d4ec844d9e3788e1b0ccc352>
- exact CMake input: <https://github.com/airdcpp/airdcpp-core/blob/55d51ceb817ec006d4ec844d9e3788e1b0ccc352/CMakeLists.txt>
- exact archive form: <https://github.com/airdcpp/airdcpp-core/archive/55d51ceb817ec006d4ec844d9e3788e1b0ccc352.tar.gz>

## Checkout rules

`Source/airdcpp-core` is a disposable, ignored checkout. The future update workflow must fetch the configured commit, verify `HEAD`, reject unapproved local changes, and be safe to rerun. It must not use Git submodules or commit upstream files into this parent repository.

Upstream generation currently writes ignored `airdcpp/core/version.inc` and `airdcpp/core/localization/StringDefs.cpp` into the checkout. Build and clean workflows must account for those known generated files without masking unrelated modifications.

## Patch rules

No patch is justified by the design inspection alone. Future patches are allowed only after the unmodified pinned source has been inspected and an ARM64 feasibility attempt has produced a reproducible failure or packaging gap.

Every patch must:

- live under `cmake/patches/airdcpp-core` or the matching dependency directory;
- state the upstream commit and reason;
- apply deterministically and fail loudly when context changes;
- have a verification step that demonstrates its need and effect; and
- be reviewed for upstream submission when generally useful.

Updating the upstream pin is a deliberate change: inspect CMake and license changes, refresh patches, rebuild from clean state, rerun the smoke link, compare link closure, and review provenance before accepting the update.

## Phase 1 command contract

`scripts/update` reads, but never evaluates, `config/upstream.env`. It accepts no arguments and resolves the project root from its own location. Missing checkouts are fetched in a validated reserved temporary acquisition directory at the final checkout path; after the exact commit is verified, that directory is retained as the checkout.

Existing checkouts must be non-symlink Git repositories with exactly the configured `origin`. Tracked, staged, untracked, or unknown ignored content blocks mutation. The two upstream-generated files `airdcpp/core/version.inc` and `airdcpp/core/localization/StringDefs.cpp` are allowed; they are removed only when changing commits to prevent stale generated state.

A clean checkout at another commit fetches and detaches at the pin. A checkout already detached at the pin exits without network access or state changes. Fetch failure leaves an existing HEAD/worktree intact and removes only a validated reserved acquisition directory when acquisition began from a missing destination.

Run `AIRDCCORE_RUN_NETWORK_TESTS=1 ./tests/gate1_network_test.sh` to reconstruct the canonical checkout twice, verify the pin both times, and prove the next update is a no-op.
