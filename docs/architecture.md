# Architecture summary

This document is a navigation aid. The authoritative requirements and rationale are in [the design spec](superpowers/specs/2026-09-04-airdc-core-macos-design.md).

## Responsibility

AirDCCore-macOS has one responsibility: turn an exact AirDC++ Core revision and exact dependency inputs into a static, inspectable, reproducible macOS `arm64` distribution.

The intended flow is:

```text
versioned pins + tracked patches
             |
             v
  update -> Source + Dependencies
             |
             v
  build -> Build/prefix + build trees
             |
             v
  package -> Dist/include + Dist/lib + metadata + licenses
             |
             v
  verify -> binary inspection + real consumer smoke link + reproducibility checks
```

`Source` is reserved for AirDC++ Core. Third-party dependency sources belong in `Dependencies`. Neither downloaded sources nor generated outputs are parent-repository content; they are reconstructed from tracked pins and scripts.

## Stable interface

The stable user-facing entry points are `scripts/update`, `scripts/build`, `scripts/verify`, and `scripts/clean`. Acquisition plus `scripts/build --configure-only`, `--build-core`, `--link-consumer`, `--build-dependencies`, `--build-reproducible-core`, and `--link-reproducible-consumer` are implemented. The distribution shape is decided; aggregation, packaging, the final verification entry point, and cleaning remain deferred.

`Dist` is the only published output boundary. Consumers must not depend on `Build`, Homebrew paths, or the upstream checkout.

## Platform invariant

All compiled artifacts must be Apple Clang/libc++ Release artifacts containing only the Mach-O `arm64` architecture. x86_64 and universal output are explicitly unsupported.

## Implemented Phase 2 flow

```text
scripts/build -> scripts/lib/configure.sh -> wrapper/toolchain -> unmodified Source
```

The wrapper nests the pinned checkout without patching it, supplies missing parent check modules/contracts, and applies Release/static Core/C++20/arm64/libc++/deployment-14.0 policy. Homebrew package adapters are narrow discovery shims; imported dependencies may be shared libraries even though Core policy is static.

All raw configure output, inventory, cache, summary, and compiler/check probes live below `Build/airdcpp-core`. Historical unmodified and wrapper-only attempts are immutable; reruns refresh only the final release configuration and host inventory. Only the [normalized Gate 2 report](reports/2026-09-05-gate-2-native-configure.md) is tracked. Scope snapshots reject source mutation, outside-output changes, Core build products, and `Dependencies`/`Dist` creation. Generating `build.ninja` does not execute it.

## Implemented Phase 3 and Phase 4 flow

```text
Source/airdcpp-core -> wrapper policy -> core-release/libairdcpp.a
                                              |
                                              v
tracked smoke-test <- staged headers + archive <- link-interface
                                              |
                                              v
                           force-loaded ARM64 executable + closure evidence
```

Phase 3 applies the fixed Apple Clang/Release/C++20/arm64/deployment-14.0 policy and a deterministic source prefix-map without editing upstream. It produces an ignored archive plus independently regenerated member, symbol, string, table, and checksum evidence.

Phase 4 copies only validated headers and the exact archive into an ignored stage. Its standalone CMake project never imports upstream CMake. It first proves the force-loaded Core archive is not self-contained, then measures direct and transitive dependencies through two omission passes and runs the resulting executable. The [Gate 4 report](reports/2026-09-21-gate-4-consumer-link.md) is the tracked result. This flow does not turn current Homebrew paths into publication dependencies.

## Accepted Phase 5 distribution boundary

[ADR 0001](decisions/0001-aggregate-static-distribution.md) selects one future `Dist/lib/libairdcpp.a`. It will contain uniquely named objects from Core, BZip2, zlib, OpenSSL SSL/Crypto, miniupnpc, LevelDB, MaxMindDB, and Snappy. The public archive is accompanied by per-component provenance, checksum, member-mapping, and license metadata; flattening the link interface must not flatten attribution.

SDK Iconv remains an explicit external consumer input; libc++ and libSystem remain implicit Apple toolchain load commands. Gate 4 measured no required Apple framework. `Dist` consumers may not discover Homebrew or link private component archives from `Build`. Phase 6 must reconstruct and validate the static component inputs before the deterministic aggregate construction contract can be implemented.

## Phase 6 isolation and provenance

The [Phase 6 spec](superpowers/specs/2026-09-23-reproducible-dependency-inputs-design.md) owns the lock and interfaces. `scripts/update --dependencies` validates canonical data and tracked patches before acquiring ignored `Dependencies`. Each adapter builds privately below `Build/dependencies/<name>` and atomically publishes one validated `Build/prefix/<name>`. Snappy precedes LevelDB; its accepted manifest enters the downstream fingerprint. Matching lock/source/adapter/helper/tool identities and prefix/evidence hashes make dependency builds unchanged no-ops. Retries preserve prior attempts.

Core uses explicit roots and records imported-target resolution below `Build/airdcpp-core/reproducible-release`. The consumer stages validated headers/Core, force-loads all Core objects, measures omissions, and compares its physical static closure with ADR 0001 below `Build/airdcpp-core/reproducible-link-interface`. Boost remains build-only; any new physical Boost input or Apple framework blocks acceptance pending ADR review.

Core compiles a private manifest-verified tracked-file stage, preserving the original checkout. The reviewed three-file patch provides bounded Tiger-tree key copying, fixed version-command authority, and a constant IPv6-maximum address buffer. Pinned epoch 1774518197/count-zero metadata avoids wall-clock or mutable Git history; strict warnings remain enabled. Original/patched/generated source manifests and patch pre/postimages bind the archive and staged public headers. The consumer validates this provenance and both real tag/full-commit APIs. Failed native generation, HashStore and VLA attempts remain retained; no source restoration or warning suppression is inferred.

The live gate confines its process tree with the macOS sandbox and proves outbound refusal before execution. Core/consumer snapshots exclude only their own output directory; every other project writer, including local log writers, must stop during execution. Raw evidence stays ignored; normalized facts and evidence-relative hashes enter the tracked report. Gate 6 acceptance remains pending until native evidence and report checks pass. Phase 7 still owns aggregation, symbol collision/coalescing analysis, member mapping, packaging, and two-clean-build reproducibility.
