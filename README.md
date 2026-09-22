# AirDCCore-macOS

AirDCCore-macOS is the source-acquisition, build, packaging, and verification project for a reproducible AirDC++ Core static distribution targeting macOS on Apple Silicon (`arm64`) only.

Upstream acquisition, Phase 2 native configure-only discovery, the Phase 3 native `arm64` static Core build, Phase 4 external-consumer link discovery, and the Phase 5 distribution-shape decision are complete. The [accepted ADR](docs/decisions/0001-aggregate-static-distribution.md) selects one future aggregate `Dist/lib/libairdcpp.a`; no aggregate or distribution exists yet. Pinned dependency builds, packaging, and `Dist` remain outside the implemented workflow.

The authoritative design is [docs/superpowers/specs/2026-09-04-airdc-core-macos-design.md](docs/superpowers/specs/2026-09-04-airdc-core-macos-design.md). Shorter operational summaries live in:

- [docs/architecture.md](docs/architecture.md)
- [docs/build-and-release.md](docs/build-and-release.md)
- [docs/dependencies.md](docs/dependencies.md)
- [docs/git-workflow.md](docs/git-workflow.md)
- [docs/upstream-policy.md](docs/upstream-policy.md)

## Inspected upstream snapshot

- Repository: <https://github.com/airdcpp/airdcpp-core>
- Inspected commit: [`55d51ceb817ec006d4ec844d9e3788e1b0ccc352`](https://github.com/airdcpp/airdcpp-core/commit/55d51ceb817ec006d4ec844d9e3788e1b0ccc352)
- Inspection date: 2026-09-04
- Local checkout: `Source/airdcpp-core` (downloaded and ignored by this parent repository)

## Scope boundary

This repository will eventually produce headers, static library artifacts, provenance, dependency metadata, checksums, and licenses under `Dist`. It will not contain Objective-C++, Swift, Swift Package Manager integration, AppKit, application architecture, or client UI. Those concerns belong to later projects.

The [reviewed Gate 2 report](docs/reports/2026-09-05-gate-2-native-configure.md) records measured configuration evidence. The [Gate 3 report](docs/reports/2026-09-20-gate-3-arm64-core-build.md) records the amended compiled archive and member-level ARM64 checks. The [Gate 4 report](docs/reports/2026-09-21-gate-4-consumer-link.md) records the real external consumer, fixed-point link interface, runtime evidence, and remaining publication limits. [ADR 0001](docs/decisions/0001-aggregate-static-distribution.md) turns that evidence into the Gate 5 publication-shape contract.

Parent-repository work follows full GitFlow. `develop` is the integration branch and contains this baseline; `master` is reserved for production releases and will be created by the first release flow rather than seeded with design work.

## Upstream acquisition

Run `./scripts/update` from any directory to acquire or validate the pinned AirDC++ Core checkout. The command reads `config/upstream.env`, accepts no arguments, and leaves a correct checkout detached at the exact configured commit.

The command refuses dirty, symlinked, non-Git, unignored, or wrong-origin destinations. A correct checkout is a no-op and does not contact the network. Run offline tests with `./tests/upstream_config_test.sh` and `./tests/update_test.sh`.

## Native configure-only discovery

```sh
./scripts/update
./scripts/build --configure-only
AIRDCCORE_RUN_CONFIGURE_TESTS=1 ./tests/gate2_configure_test.sh
```

The first command reconstructs or validates pinned Source; the second configures only; the third opts into the real Gate 2 check and validates the tracked report. Run on native macOS arm64 with Xcode and the [recorded Homebrew formulas](docs/dependencies.md). Homebrew inputs are discovery-only, not publication dependencies. Evidence stays under `Build/airdcpp-core`; no Core target is compiled, no `Dependencies` or `Dist` is created, and Phase 3 compilation remains outside this command. See the [operator contract](docs/build-and-release.md) for evidence reuse and the hard stop.

## Native static Core build (Phase 3)

```sh
./scripts/update
./scripts/build --build-core
AIRDCCORE_RUN_BUILD_TESTS=1 ./tests/gate3_core_build_test.sh
```

This separate mode builds only the `airdcpp` target under `Build/airdcpp-core/core-release`; it preserves command, input, failure-attempt, and archive-inspection evidence. The current candidate is `core-release/upstream/libairdcpp.a`, with 130 ARM64 object members. The opt-in gate checks the already-built archive and does not compile it again. It does not create `Dist`. See the [Gate 3 report](docs/reports/2026-09-20-gate-3-arm64-core-build.md) for the compiler failure, reviewed adapters, deterministic source-path policy, warnings, and precise limits.

## External consumer link discovery (Phase 4)

```sh
./scripts/update
./scripts/build --build-core
./scripts/build --link-consumer
AIRDCCORE_RUN_LINK_TESTS=1 ./tests/gate4_consumer_link_test.sh
```

`--link-consumer` reuses an already-verified Gate 3 candidate; it does not rebuild Core. It stages headers and the archive below ignored `Build/airdcpp-core/link-interface`, force-loads every Core object into a standalone C++20 executable, measures the dependency fixed point, and runs the consumer. The live gate independently checks the bound inputs, ARM64 executable, real Core symbols, omission matrix, runtime identity, and path-leak boundary. No distributable output, `Dependencies`, or `Dist` is created. See the [Gate 4 report](docs/reports/2026-09-21-gate-4-consumer-link.md).

## Distribution-shape decision (Phase 5)

```sh
./tests/gate5_distribution_shape_test.sh
```

Gate 5 is a tracked decision, not a packaging command. The accepted shape is one future aggregate `Dist/lib/libairdcpp.a` containing Core plus the pinned non-system static closure measured at Gate 4. macOS SDK Iconv, libc++, and libSystem remain external and machine-readable. The gate validates the ADR and verifies that `Dependencies` and `Dist` have not been created. Phase 6 must now reconstruct and validate every non-system ingredient before aggregation can begin.
