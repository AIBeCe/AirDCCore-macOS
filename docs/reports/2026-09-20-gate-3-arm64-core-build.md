# Gate 3: first native ARM64 static Core archive

**Status:** Candidate built and inspected; the opt-in Gate 3 acceptance test and copied-evidence rejection tests pass. Independent whole-branch review is pending. This is an unpackaged build-feasibility result, not a consumer-link, safety, portability, or release approval. `$PROJECT_ROOT` means the root of the isolated `feature/arm64-static-core-build` worktree. Raw evidence is ignored under `$PROJECT_ROOT/Build/airdcpp-core/core-release`.

## Scope and source identity

- Upstream URL: `https://github.com/airdcpp/airdcpp-core.git`.
- Detached source commit: `55d51ceb817ec006d4ec844d9e3788e1b0ccc352`, read from `config/upstream.env` and verified against `Source/airdcpp-core` before and after compilation. No tracked/staged or nonignored untracked source changes occurred. The only ignored generated source files are listed below.
- Feature branch: `feature/arm64-static-core-build`, based on the local Phase 2 `develop` merge `bf176b2`; no direct `develop` edit, merge, push, release branch, or `Dist` publication occurred.
- Before the first attempt, `Source/airdcpp-core` and `Build/airdcpp-core` were absent in this worktree; `./scripts/update` reconstructed the exact checkout. `first-build-state.txt` records `core-release.preexisting=absent`. There were no historical Gate 2 output siblings in this worktree, so a Gate 2 evidence hash list is **absent**, not silently substituted with another worktree's files. The build script compared its initial and final parent/outside-Build and preserved-sibling snapshots on each attempt; those snapshots were not persisted as separate files.

## Host and tool inputs

| Input | Measured value |
| --- | --- |
| Host | macOS 26.5.1, native `arm64`, Darwin build 25F80 |
| Xcode | 26.6, build 17F113 |
| Compiler | Apple Clang 21.0.0 (`clang-2100.1.1.101`), libc++ |
| SDK | macOS 26.5 |
| CMake / Ninja | 4.4.3 / 1.13.2 |
| Homebrew / Python | 7.0.4 / 3.14.7 |
| Formula inventory SHA-256 | `7245d0f1b75d587823e0dd102187f4aef22e3e3fc4fd5ab73457353657bc18d1` |

The exact formula versions and prefixes are in ignored `host-inventory.txt`; [the dependency policy](../dependencies.md) records them as Homebrew discovery inputs, not final distributable dependencies. The fixed build policy was Release, `arm64`, C++20 with extensions OFF, `BUILD_SHARED_LIBS=OFF`, deployment target 14.0, and NAT-PMP/TBB OFF. `CMakeCache.txt` and `airdcpp-configure-summary.txt` record that policy.

## Commands and first-attempt correction

`./scripts/build --build-core` ran wrapper configuration from `$PROJECT_ROOT` with the following literal command (the tracked report normalizes the root and preserves formula opt prefixes):

```text
'cmake' '--fresh' '-S' '.' '-B' 'Build/airdcpp-core/core-release' '-G' 'Ninja' '-DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/macos-arm64.cmake' '-DCMAKE_BUILD_TYPE=Release' '-DBUILD_SHARED_LIBS=OFF' '-DCMAKE_OSX_ARCHITECTURES=arm64' '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0' '-DCMAKE_CXX_STANDARD=20' '-DCMAKE_CXX_EXTENSIONS=OFF' '-DENABLE_NATPMP=OFF' '-DENABLE_TBB=OFF' '-DCMAKE_PREFIX_PATH=/opt/homebrew/opt/cmake;/opt/homebrew/opt/ninja;/opt/homebrew/opt/boost;/opt/homebrew/opt/bzip2;/opt/homebrew/opt/zlib;/opt/homebrew/opt/openssl@3;/opt/homebrew/opt/miniupnpc;/opt/homebrew/opt/leveldb;/opt/homebrew/opt/libmaxminddb;/opt/homebrew/opt/snappy;/opt/homebrew/opt/libiconv;/opt/homebrew/opt/pkgconf;/opt/homebrew/opt/python@3.14' '-DBZIP2_ROOT=/opt/homebrew/opt/bzip2' '-DZLIB_ROOT=/opt/homebrew/opt/zlib' '-DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@3' '-DIconv_INCLUDE_DIR=/opt/homebrew/opt/libiconv/include' '-DIconv_LIBRARY=/opt/homebrew/opt/libiconv/lib/libiconv.dylib' '-DCMAKE_FIND_DEBUG_MODE=ON'
'cmake' '--build' '$PROJECT_ROOT/Build/airdcpp-core/core-release' '--target' 'airdcpp' '--config' 'Release' '--parallel' '2'
```

The **first** wrapper configure succeeded, but Core compilation stopped at upstream `HashStore.cpp:404`, where Apple Clang diagnosed `memcpy` into a non-trivially-copyable `TTHValue`. Homebrew LevelDB 1.23_2 exported `-Werror;-Wthread-safety` through `leveldb::leveldb`; the resulting Core command turned the warning into an error. First `build-exit-code.txt` was `1`; raw `configure.log` SHA-256 was `1810cf88a22a249a5c09888d704b9ecf6ab91bbd1a9695a8d06be266bb3fe294`, and `build.log` SHA-256 was `991e7429ba6c3622e1dbc8c27fcc3ce530749d80d0803ee6c76ea0a283e14ce8`. See [the first-failure report](2026-09-20-phase-3-first-build-failure.md).

After the user approved the focused Task 2A amendment, the wrapper removed only LevelDB's exact transitive `-Werror` option, retaining `-Wthread-safety`; its controlled CMake test checks the resulting Core compile command. Before the **single** native retry, the first configure command/log/cache, build command/log/status, host inventory and summary were hash-checked and published atomically under ignored `core-release/attempts/0001`. The archived first configure/build logs still have the above SHA-256 values, and the archived build exit status remains `1`. The configure helper does not write a separate exit-status file; its success is established by continuing to cache inspection and Core compilation. The retry's `build-exit-code.txt` is `0`; `configure.log` SHA-256 is `43d6b5909700eca110cb304ae8e393b900863749923c5b47052abe6660e59647`, and `build.log` SHA-256 is `336916640e4616ec76e2451c41793fefa10190049dc5372b52de9ccd2b9ab028`.

## Archive and architecture evidence

| Result | Value |
| --- | --- |
| Candidate | `Build/airdcpp-core/core-release/upstream/libairdcpp.a` |
| Size | 13,202,464 bytes |
| SHA-256 | `0bc3cc3c9a4424bbceb0bd2c1682e963ecd388b0bacc6acb3c0575aaa8e464e7` |
| Archive-level `file` | `current ar archive` |
| Archive-level `lipo -archs` | `arm64` |
| `ar -t` entries | 131: one `__.SYMDEF` symbol table and 130 object members |
| Per-object result | 130/130 members are thin `arm64` Mach-O objects; zero malformed/non-arm64 rows |

The inspector parses each ar member in archive order, including BSD extended names, extracts each object to a unique numbered temporary path (so duplicate basenames cannot overwrite one another), and checks it with `/usr/bin/file -b` and `/usr/bin/lipo -archs`. It records ordinal, original name, SHA-256, and architecture in `archive-members.tsv`; `xcrun nm -g` output is retained in `archive-symbols.txt`. The raw `ar -t` list and archive hash are retained in `archive-ar-table.txt` and `archive-sha256.txt`. The member report SHA-256 is `52d88b74188020ddf28b98a4c257cf065976af4410b9cb435688e89a5e8f055b`; the symbol inventory SHA-256 is `0a76d8f0614d0fc6ba992ef6704eb84d284594b884e724ce12b6d851114ece5e`. Gate 3 independently regenerates and compares both reports without rebuilding Core.

The only ignored source outputs were `airdcpp/core/version.inc` (SHA-256 `65c2b8b0553cdaa61b54e6ecc6e90cdba308eeeae760f24d22b2623a78a47b3c`) and `airdcpp/core/localization/StringDefs.cpp` (SHA-256 `d7ff5db80e0e6bffa8cdc04065a5c71eb6bcee9a94a1f6d6b58a1b2a4fb75c6c`). Neither is tracked in this repository.

## Required package resolution

All twelve required CMake targets were resolved in `airdcpp-configure-summary.txt`. The observed imported locations are:

| Target | Location or interface |
| --- | --- |
| BZip2::BZip2 | `/opt/homebrew/opt/bzip2/lib/libbz2.a` |
| ZLIB::ZLIB | `/opt/homebrew/opt/zlib/lib/libz.dylib` |
| OpenSSL::SSL / OpenSSL::Crypto | `/opt/homebrew/opt/openssl@3/lib/libssl.dylib` / `libcrypto.dylib` |
| miniupnpc::miniupnpc | `/opt/homebrew/opt/miniupnpc/lib/libminiupnpc.dylib` |
| leveldb::leveldb | `/opt/homebrew/opt/leveldb/lib/libleveldb.1.23.0.dylib`; interface includes Snappy and Threads |
| maxminddb::maxminddb | `/opt/homebrew/opt/libmaxminddb/lib/libmaxminddb.dylib` |
| Boost::thread / Boost::regex | Boost 1.90.0_1 Homebrew Cellar dylibs; thread interface lists Boost atomic/chrono/container/date_time/exception/headers and Threads |
| Snappy::snappy | `/opt/homebrew/opt/snappy/lib/libsnappy.1.2.2.dylib` |
| Threads::Threads | SDK interface target |
| Iconv::Iconv | `/opt/homebrew/opt/libiconv/lib/libiconv.dylib` interface |

These are configure-time resolutions, **not** a proven external consumer link line or distributable static dependency closure. Several direct inputs are dylibs.

## Verification, warnings, and limits

The offline suites `upstream_config_test.sh`, `update_test.sh`, `configure_helpers_test.sh`, `cmake_wrapper_test.sh`, `find_modules_test.sh`, `build_configure_test.sh`, and `build_core_test.sh` passed after the adapter and inspector changes. All six `archive_inspect_test.py` cases passed, including duplicate member names, x86_64 rejection, malformed/empty archive rejection, and symlinked report protection. `AIRDCCORE_RUN_BUILD_TESTS=1 ./tests/gate3_core_build_test.sh` passed on the actual archive: `PASS: Gate 3 verified 130 arm64 Core archive members without packaging`. `AIRDCCORE_RUN_BUILD_TESTS=1 ./tests/gate3_contract_test.sh` passed against copied evidence, rejecting a wrong pin, missing archive, validly shaped but tampered member report, and a parent file changed during verification; disabled opt-in also refused before checking evidence. The independent whole-branch review remains pending.

The successful retry retained two warnings: `HashStore.cpp:404` (`-Wnontrivial-memcall`) and `NetworkUtil.cpp:185` (`-Wvla-cxx-extension`). In particular, the former still copies a database key of callback-supplied length into a fixed-size hash value without a local length check. The wrapper adapter **does not fix or certify** that possible bounds issue; it needs a separate, reviewed upstream-source compatibility/safety decision before publication. The latter uses a Clang C++ extension despite C++20 extensions being disabled in CMake policy and needs a later portability decision.

Gate 3 proves only a controlled, unpackaged static Core archive made of ARM64 objects. It does **not** prove an external executable can link, resolve all transitive dependencies, run correctly, or use installed public headers. Phase 4 must prove the final link interface. Dependencies are still mutable Homebrew discovery inputs; no `Dependencies` or `Dist` exists. No two-clean-build reproducibility, packaging, license bundle, or GitFlow release has been attempted.

## Gate 3 review decision

The measured live acceptance test passed on 2026-09-20. Independent whole-branch review remains pending; do not merge or begin Phase 4 on this report alone.
