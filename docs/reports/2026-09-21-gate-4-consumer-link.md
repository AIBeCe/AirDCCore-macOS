# Gate 4: external ARM64 consumer link interface

**Status:** Accepted for Phase 4 discovery on 2026-09-22 after the controlled experiments begun on 2026-09-21. A standalone C++20 executable compiled from staged public headers, force-loaded every object in the amended Gate 3 archive, reached a stable dependency fixed point, and ran successfully as `arm64`. This is link-interface evidence, not a distribution, dependency lock, deployment-target guarantee, or release approval.

## Bound source and staged inputs

| Input | Measured value |
| --- | --- |
| Upstream URL | `https://github.com/airdcpp/airdcpp-core.git` |
| Detached commit | `55d51ceb817ec006d4ec844d9e3788e1b0ccc352` |
| Core archive | `Build/airdcpp-core/core-release/upstream/libairdcpp.a` |
| Core SHA-256 | `f345fe0e5fc7bbf289642e5a8846795f0e0d177288505419b0ba96cc23367441` |
| Core member-report SHA-256 | `bec10125e58e2b97f7d2742ae61cc05dd51c0ffc5a13ca9a1aabf0547f9186e4` |
| Staged headers | 247 regular, non-symlinked files |
| Header-manifest SHA-256 | `9397a895bd68dedb35212bd511e2b8cd50d6eada13e034f126f1142d6bf04872` |
| Input-manifest SHA-256 | `8fca594f71d1b8b29a439fa358749443b4329346ce7f32ce423a796a53b7fd39` |

The ignored stage is `Build/airdcpp-core/link-interface/stage`. It contains a byte-identical copy of the Gate 3 archive and headers selected from the pinned checkout; the standalone smoke project does not call `add_subdirectory`, import the upstream CMake target, or compile upstream source. Generated `version.inc` is included because the staged headers require it; generated `StringDefs.cpp` and `airdcpp/modules/**` are excluded.

The tracked smoke source SHA-256 is `7281cb12d4c94a1f43613dc303a557dae9c5f8a5c011a3a2c7e0b2b30522fcd6`. It calls the public out-of-line `dcpp::getVersionTag()` symbol first and, because this detached commit has an empty tag, falls back to the public out-of-line `dcpp::getGitCommit()` symbol. Both symbols are present in the final executable. The archive is linked with `-force_load`, so the test covers all Core objects rather than only the version object.

## Controlled link experiments

The Core-only configuration succeeded, but its link exited `1` with Apple linker `Undefined symbols` diagnostics. This proves the static Core archive is not self-contained. Its preserved build-log SHA-256 is `a7a39fa9c82f514e15f77e5e0c71a1504b1d917180f5c9a4fe0b653cf634a662`.

The full candidate began with twelve logical targets in upstream order. One-at-a-time omission followed by a second reduced omission pass produced this stable classification:

| Logical item | Pass 1 | Pass 2 / disposition |
| --- | --- | --- |
| BZip2 | required | required |
| ZLIB | required | required |
| OpenSSLSSL | required | required |
| OpenSSLCrypto | transitive | supplied by retained OpenSSL SSL interface |
| miniupnpc | required | required |
| leveldb | required | required |
| maxminddb | required | required |
| BoostThread | transitive | not a direct fixed-point item |
| BoostRegex | transitive | not a direct fixed-point item |
| Snappy | transitive | supplied by retained LevelDB interface |
| Threads | transitive | supplied by retained targets/system toolchain |
| Iconv | required | required system SDK adapter |

The fixed-point configure command, with the worktree normalized, was:

```text
'cmake' '-S' '$PROJECT_ROOT/smoke-test' '-B' '$PROJECT_ROOT/Build/airdcpp-core/link-interface/full/build' '-G' 'Ninja' '-DCMAKE_MODULE_PATH=$PROJECT_ROOT/cmake/modules' '-DCMAKE_BUILD_TYPE=Release' '-DCMAKE_OSX_ARCHITECTURES=arm64' '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0' '-DCMAKE_CXX_STANDARD=20' '-DCMAKE_CXX_EXTENSIONS=OFF' '-DAIRDCCORE_INCLUDE_DIR=$PROJECT_ROOT/Build/airdcpp-core/link-interface/stage/include' '-DAIRDCCORE_LIBRARY=$PROJECT_ROOT/Build/airdcpp-core/link-interface/stage/lib/libairdcpp.a' '-DAIRDCCORE_MODULE_DIR=$PROJECT_ROOT/cmake/modules' '-DAIRDCCORE_SYSTEM_ICONV_LIBRARY=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/libiconv.2.tbd' '-DAIRDCCORE_TEST_LINK_ITEMS=BZip2,ZLIB,OpenSSLSSL,miniupnpc,leveldb,maxminddb,Iconv' '-DCMAKE_PREFIX_PATH=/opt/homebrew/opt/cmake;/opt/homebrew/opt/ninja;/opt/homebrew/opt/boost;/opt/homebrew/opt/bzip2;/opt/homebrew/opt/zlib;/opt/homebrew/opt/openssl@3;/opt/homebrew/opt/miniupnpc;/opt/homebrew/opt/leveldb;/opt/homebrew/opt/libmaxminddb;/opt/homebrew/opt/snappy;/opt/homebrew/opt/libiconv;/opt/homebrew/opt/pkgconf;/opt/homebrew/opt/python@3.14' '-DBZIP2_ROOT=/opt/homebrew/opt/bzip2' '-DZLIB_ROOT=/opt/homebrew/opt/zlib' '-DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@3'
'cmake' '--build' '$PROJECT_ROOT/Build/airdcpp-core/link-interface/full/build' '--verbose'
```

The normalized effective link interface, in order, is:

```text
1  core     stage/lib/libairdcpp.a
2  library  /opt/homebrew/opt/bzip2/lib/libbz2.a
3  library  /opt/homebrew/opt/zlib/lib/libz.dylib
4  library  /opt/homebrew/opt/openssl@3/lib/libssl.dylib
5  library  /opt/homebrew/opt/miniupnpc/lib/libminiupnpc.dylib
6  library  /opt/homebrew/opt/leveldb/lib/libleveldb.1.23.0.dylib
7  library  /opt/homebrew/opt/libmaxminddb/lib/libmaxminddb.dylib
8  library  /opt/homebrew/opt/openssl@3/lib/libcrypto.dylib
9  library  /opt/homebrew/opt/snappy/lib/libsnappy.1.2.2.dylib
10 system   <active macOS SDK>/usr/lib/libiconv.2.tbd
```

The physical OpenSSL Crypto and Snappy libraries remain on the effective command because they are transitive interfaces, despite not being direct fixed-point logical items. No Apple framework was required by this measured link. libc++ and `libSystem` are implicit toolchain load commands.

## Executable and runtime evidence

| Result | Value |
| --- | --- |
| Executable | `Build/airdcpp-core/link-interface/full/airdcpp-smoke` |
| Size | 4,863,568 bytes |
| SHA-256 | `4106951b59ab7da5155e153eb34233234b519a8877efef2a00908fc06735cafe` |
| `file` | `Mach-O 64-bit executable arm64` |
| `lipo -archs` | `arm64` |
| Runtime exit / stderr | `0` / empty |
| Runtime stdout | `AirDC++ Core 55d51ceb817ec006d4ec844d9e3788e1b0ccc352` |

`otool -L` reports zlib, OpenSSL SSL/Crypto, miniupnpc, LevelDB, MaxMindDB, Snappy, `/usr/lib/libiconv.2.dylib`, libc++, and libSystem. Its tracked evidence SHA-256 is `7ce471d9950f544177a12a2c85e8617fa7e26a1f4ea6220d3dbf571025346204`. Independent string and load-command scans found no user-home, worktree, absolute `Source`, or absolute `Build` path in the executable body or effective load commands. The archive itself passed the amended Gate 3 source-path scan before staging.

## Adapters, warnings, and dependency disposition

Two narrow discovery adapters were required and are covered by isolated CMake tests:

- Homebrew LevelDB's plain `snappy` interface item is replaced with the already-discovered exact `Snappy::snappy` target. This removes an invalid ambient `-lsnappy` search without changing dependency identity.
- The Core archive was compiled against the macOS SDK iconv ABI. The consumer therefore uses the active SDK's exact `libiconv.tbd` through `AirDCCore::SystemIconv`, not Homebrew GNU libiconv.

The linker warns that the Homebrew BZip2 objects and several Homebrew dylibs were built for macOS 26.0 while this project links for macOS 14.0. The executable runs on the measured macOS 26.5.1 host, but this does **not** prove macOS 14 runtime compatibility. Every `/opt/homebrew` item above is a Phase 4 discovery input requiring explicit Phase 6 pinning/rebuild/disposition; none is acceptable as an invisible final `Dist` dependency.

The experiment history is retained in the four focused reports for the [LevelDB/Snappy failure](2026-09-21-gate-4-first-link-failure.md), [Iconv ABI failure](2026-09-21-gate-4-second-link-failure.md), [detached-commit runtime identity](2026-09-21-gate-4-runtime-contract-failure.md), and [embedded source path](2026-09-21-gate-4-path-leak-failure.md). Raw commands, logs, statuses, omission cases, attempts, manifests, and binaries stay ignored below `Build/airdcpp-core/link-interface`.

## Gate decision and explicit non-claims

Gate 4 accepts the measured external consumer and the seven-item logical fixed point for planning the next phase. It proves that the amended ARM64 Core archive can be consumed outside the upstream build using the staged headers and recorded current-host link interface.

Gate 4 does **not**:

- choose whether `Dist/lib` contains one aggregate archive or multiple libraries;
- pin, rebuild, or license the non-system dependencies;
- package public headers or libraries, or create `Dependencies` or `Dist`;
- prove macOS 14 compatibility from Homebrew artifacts built for macOS 26;
- prove two-clean-build reproducibility or release readiness;
- resolve or certify the upstream `HashStore.cpp:404` key-length safety concern;
- authorize Phase 5, a merge, push, release branch, or production publication.
