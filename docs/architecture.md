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

The future user-facing entry points are `scripts/update`, `scripts/build`, `scripts/verify`, and `scripts/clean`. Their names and responsibilities are stable; their implementation is deferred.

`Dist` is the only published output boundary. Consumers must not depend on `Build`, Homebrew paths, or the upstream checkout.

## Platform invariant

All compiled artifacts must be Apple Clang/libc++ Release artifacts containing only the Mach-O `arm64` architecture. x86_64 and universal output are explicitly unsupported.
