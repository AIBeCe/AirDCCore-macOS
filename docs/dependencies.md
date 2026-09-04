# Dependency policy and inspected snapshot

The authoritative dependency strategy is in [the design spec](superpowers/specs/2026-09-04-airdc-core-macos-design.md). This page records the concise current snapshot for future investigation.

## Verified direct CMake dependencies

At inspected AirDC++ Core commit `55d51ceb817ec006d4ec844d9e3788e1b0ccc352`, the single upstream `CMakeLists.txt` declares:

| Class | Packages |
| --- | --- |
| Required | BZip2, ZLIB, OpenSSL, miniupnpc, leveldb, maxminddb, Boost 1.70+ components `regex` and `thread` |
| Required for a static build | Snappy |
| Required for a native non-Windows build | Threads and Iconv |
| Optional, probed when enabled | natpmp; TBB |

The non-Windows defaults are `BUILD_CORE_MODULES=OFF`, `ENABLE_NATPMP=ON`, and `ENABLE_TBB=ON`. NAT-PMP and TBB are used only if their package lookup succeeds.

Boost `system`, nlohmann-json, WebSocket++, and npm are not direct dependencies declared by the inspected core CMake. They must not be added to the core distribution merely because broader AirDC++ products publish them as prerequisites. They may enter the recorded link closure only if a real build or downstream smoke link proves they are needed.

As of the 2026-09-04 design review, the [official Homebrew formula page](https://formulae.brew.sh/formula/websocketpp) labels WebSocket++ disabled. It is therefore a known pinned-source candidate if later evidence brings it into this project's link or public-header closure; its disabled formula is not evidence that the current core needs it.

## Strategy

Homebrew is preferred for host tools and first-build discovery. It is not an acceptable invisible runtime contract for a published `Dist`. Each non-system link input must eventually be one of:

- a pinned source build reconstructed from a version, URL, and checksum or commit;
- a pinned, integrity-checked packaged archive whose provenance and license are recorded; or
- a deliberately external system/SDK library documented in the link-interface metadata.

Source dependencies belong in top-level `Dependencies`, never under `Source`. The entire downloaded directory is ignored and reconstructed from `config/dependencies.lock`.

## Evidence still required

The first ARM64 link-closure experiment must determine dependency versions, static/shared availability, archive link order, Apple frameworks/system libraries, whether Boost thread introduces Boost system, and whether optional NAT-PMP/TBB are part of the supported feature set. WebSocket++ source acquisition remains deferred unless later evidence makes it a core dependency.
