# AirDCCore-macOS

AirDCCore-macOS is the source-acquisition, build, packaging, and verification project for a reproducible AirDC++ Core static distribution targeting macOS on Apple Silicon (`arm64`) only.

Phase 1 upstream acquisition is implemented and covered by its configuration and verification tests. Build scripts beyond acquisition, wrappers, patches, dependency builds, the smoke test, and `Dist` remain intentionally unimplemented.

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

The next step is user review of the design spec before planning later phases. Those phases must not begin until that review is approved.

Parent-repository work follows full GitFlow. `develop` is the integration branch and contains this baseline; `master` is reserved for production releases and will be created by the first release flow rather than seeded with design work.

## Upstream acquisition

Run `./scripts/update` from any directory to acquire or validate the pinned AirDC++ Core checkout. The command reads `config/upstream.env`, accepts no arguments, and leaves a correct checkout detached at the exact configured commit.

The command refuses dirty, symlinked, non-Git, unignored, or wrong-origin destinations. A correct checkout is a no-op and does not contact the network. Run offline tests with `./tests/upstream_config_test.sh` and `./tests/update_test.sh`.
