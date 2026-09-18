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

The stable user-facing entry points are `scripts/update`, `scripts/build`, `scripts/verify`, and `scripts/clean`. Acquisition and `scripts/build --configure-only` are implemented; compilation, verification, and cleaning entry-point workflows remain deferred.

`Dist` is the only published output boundary. Consumers must not depend on `Build`, Homebrew paths, or the upstream checkout.

## Platform invariant

All compiled artifacts must be Apple Clang/libc++ Release artifacts containing only the Mach-O `arm64` architecture. x86_64 and universal output are explicitly unsupported.

## Implemented Phase 2 flow

```text
scripts/build -> scripts/lib/configure.sh -> wrapper/toolchain -> unmodified Source
```

The wrapper nests the pinned checkout without patching it, supplies missing parent check modules/contracts, and applies Release/static Core/C++20/arm64/libc++/deployment-14.0 policy. Homebrew package adapters are narrow discovery shims; imported dependencies may be shared libraries even though Core policy is static.

All raw configure output, inventory, cache, summary, and compiler/check probes live below `Build/airdcpp-core`. Historical unmodified and wrapper-only attempts are immutable; reruns refresh only the final release configuration and host inventory. Only the [normalized Gate 2 report](reports/2026-09-05-gate-2-native-configure.md) is tracked. Scope snapshots reject source mutation, outside-output changes, Core build products, and `Dependencies`/`Dist` creation. Generating `build.ninja` does not execute it. The flow stops before Phase 3 compilation and does not implement the future publication flow above.
