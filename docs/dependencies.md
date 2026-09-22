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

The [reviewed report](reports/2026-09-05-gate-2-native-configure.md) records this current-host formula inventory (SHA-256 `7245d0f1b75d587823e0dd102187f4aef22e3e3fc4fd5ab73457353657bc18d1`). Required prefixes form the explicit CMake prefix list; each prefix's `lib/pkgconfig` and `share/pkgconfig` form the pkg-config path. The original CMake 4.4.2/inventory observation is retained separately in ignored evidence history; the table below describes the new canonical capture.

| Formula | Version | Resolved prefix |
| --- | --- | --- |
| cmake | 4.4.3 | `/opt/homebrew/opt/cmake` |
| ninja | 1.13.2 | `/opt/homebrew/opt/ninja` |
| boost | 1.90.0_1 | `/opt/homebrew/opt/boost` |
| bzip2 | 1.0.8 | `/opt/homebrew/opt/bzip2` |
| zlib | 1.3.2 | `/opt/homebrew/opt/zlib` |
| openssl@3 | 3.6.4 3.6.1 | `/opt/homebrew/opt/openssl@3` |
| miniupnpc | 2.3.3 | `/opt/homebrew/opt/miniupnpc` |
| leveldb | 1.23_2 | `/opt/homebrew/opt/leveldb` |
| libmaxminddb | 1.13.3 | `/opt/homebrew/opt/libmaxminddb` |
| snappy | 1.2.2 | `/opt/homebrew/opt/snappy` |
| libiconv | 1.18 | `/opt/homebrew/opt/libiconv` |
| pkgconf | 2.5.1 | `/opt/homebrew/opt/pkgconf` |
| python@3.14 | 3.14.7 3.14.3_1 | `/opt/homebrew/opt/python@3.14` |
| libnatpmp (optional) | absent | unresolved; `/opt/homebrew/opt/libnatpmp` is not installed |
| tbb (optional) | absent | unresolved; `/opt/homebrew/opt/tbb` is not installed |

Final configure explicitly uses `ENABLE_NATPMP=OFF` and `ENABLE_TBB=OFF`; optional installation/absence cannot select features implicitly. Threads resolves as the selected SDK interface, not a formula. Boost includes/library imports use the corresponding physical Cellar prefix. The current cache reports OpenSSL 3.6.4 through the selected opt prefix. Several required imports are dylibs; static Core policy does not establish a static dependency closure.

No Phase 2 formula becomes a publication dependency or a `Dependencies` source pin. This inventory is measured host discovery, not `config/dependencies.lock` or final portability proof. Pinned dependency reconstruction and link closure remain later gates.

## Gate 3 build observation

The ARM64 static Core build used the same measured Homebrew formula inventory (SHA-256 `7245d0f1b75d587823e0dd102187f4aef22e3e3fc4fd5ab73457353657bc18d1`). The [Gate 3 report](reports/2026-09-20-gate-3-arm64-core-build.md) records the amended 13,202,392-byte archive, exact source pin, all 130 ARM64 object checks, and current imported-target locations. A static `libairdcpp.a` does not absorb these imported libraries.

Homebrew LevelDB 1.23_2 exports `-Werror;-Wthread-safety` as its CMake target's compile interface. The Phase 3 wrapper removes only that transitive `-Werror`; the remaining upstream `HashStore.cpp:404` warning and its possible unchecked database-key length are **not** resolved by this adapter.

## Gate 4 measured link closure

The [Gate 4 report](reports/2026-09-21-gate-4-consumer-link.md) records a real all-member force-loaded external consumer. The stable direct logical items are BZip2, ZLIB, OpenSSL SSL, miniupnpc, LevelDB, MaxMindDB, and system Iconv. OpenSSL Crypto and Snappy remain physical transitive link items supplied by retained targets; Boost thread/regex and Threads are not direct fixed-point items for this consumer. No Apple framework was required.

The measured physical interface still contains Homebrew BZip2 plus Homebrew zlib, OpenSSL, miniupnpc, LevelDB, MaxMindDB, and Snappy. The archive was compiled against the macOS iconv ABI, so Gate 4 uses the active SDK `libiconv.tbd` and the executable loads `/usr/lib/libiconv.2.dylib`; Homebrew GNU libiconv is not the correct ABI for this candidate. A narrow adapter also maps LevelDB's incomplete plain `snappy` metadata to the exact `Snappy::snappy` target.

The Homebrew objects and dylibs emit linker warnings because they were built for macOS 26.0 while the consumer deployment target is 14.0. They prove discovery and link closure only. Phase 6 must pin or rebuild every non-system input and establish the intended minimum-macOS policy before publication.

## Gate 5 distribution decision and evidence still required

[ADR 0001](decisions/0001-aggregate-static-distribution.md) selects a single future aggregate archive. Its non-system component set is Core, BZip2, zlib, OpenSSL SSL and Crypto, miniupnpc, LevelDB, MaxMindDB, and Snappy. SDK Iconv remains an explicit external link input; libc++ and libSystem remain implicit Apple toolchain load commands. Gate 4 measured no Apple framework requirement.

Phase 6 must determine pinned source/package inputs, static availability, checksums, licenses, build flags and patches, minimum-macOS compatibility, canonical component/member ordering, duplicate strong-symbol rejection, and weak/coalesced-symbol classification for that exact closure. The Homebrew inventory remains discovery evidence only. NAT-PMP and TBB remain deliberately OFF; WebSocket++ source acquisition remains deferred unless later evidence makes it a Core dependency.
