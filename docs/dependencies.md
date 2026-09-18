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

## Gate 2 measured discovery inputs

The [reviewed report](reports/2026-09-05-gate-2-native-configure.md) records this exact formula inventory. Required prefixes form the explicit CMake prefix list; each prefix's `lib/pkgconfig` and `share/pkgconfig` form the pkg-config path.

| Formula | Version | Resolved prefix |
| --- | --- | --- |
| cmake | 4.4.2 | `/opt/homebrew/opt/cmake` |
| ninja | 1.13.2 | `/opt/homebrew/opt/ninja` |
| boost | 1.90.0_1 | `/opt/homebrew/opt/boost` |
| bzip2 | 1.0.8 | `/opt/homebrew/opt/bzip2` |
| zlib | 1.3.2 | `/opt/homebrew/opt/zlib` |
| openssl@3 | 3.6.1 | `/opt/homebrew/opt/openssl@3` |
| miniupnpc | 2.3.3 | `/opt/homebrew/opt/miniupnpc` |
| leveldb | 1.23_2 | `/opt/homebrew/opt/leveldb` |
| libmaxminddb | 1.13.3 | `/opt/homebrew/opt/libmaxminddb` |
| snappy | 1.2.2 | `/opt/homebrew/opt/snappy` |
| libiconv | 1.18 | `/opt/homebrew/opt/libiconv` |
| pkgconf | 2.5.1 | `/opt/homebrew/opt/pkgconf` |
| python@3.14 | 3.14.3_1 | `/opt/homebrew/opt/python@3.14` |
| libnatpmp (optional) | absent | unresolved; `/opt/homebrew/opt/libnatpmp` is not installed |
| tbb (optional) | absent | unresolved; `/opt/homebrew/opt/tbb` is not installed |

Final configure explicitly uses `ENABLE_NATPMP=OFF` and `ENABLE_TBB=OFF`; optional installation/absence cannot select features implicitly. Threads resolves as the selected SDK interface, not a formula. Boost includes/library imports use the corresponding physical Cellar prefix. Several required imports are dylibs; static Core policy does not establish a static dependency closure.

No Phase 2 formula becomes a publication dependency or a `Dependencies` source pin. This inventory is measured host discovery, not `config/dependencies.lock` or final portability proof. Pinned dependency reconstruction and link closure remain later gates.

## Evidence still required

The first ARM64 link-closure experiment must determine dependency versions, static/shared availability, archive link order, Apple frameworks/system libraries, whether Boost thread introduces Boost system, and whether optional NAT-PMP/TBB are part of the supported feature set. WebSocket++ source acquisition remains deferred unless later evidence makes it a core dependency.
