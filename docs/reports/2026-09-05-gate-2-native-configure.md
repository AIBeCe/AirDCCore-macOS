# Gate 2 — native configure discovery

## Scope and result

Gate 2 is accepted for configure-only discovery on the measured host. The wrapped final configure exited 0 and all source, evidence-preservation, dependency-path, policy, and output-scope assertions passed. This records configuration and CMake compiler/check probes only; AirDC++ Core compilation, linking, runtime behavior, packaging, and final binary compatibility remain unproven. Phase 3 is a separate hard stop, not authorized by this report.

Dist is absent. libairdcpp.a is absent. `Dependencies` is absent. No Core objects, archives, shared libraries, or Ninja execution logs exist in the configured output trees. Homebrew library imports, including dylibs, are discovery inputs; `BUILD_SHARED_LIBS=OFF` is Core policy, not a claim that the dependency closure is static.

Raw evidence remains ignored below `Build/airdcpp-core`; only this selected, normalized report is tracked. The [authoritative design](../superpowers/specs/2026-09-04-airdc-core-macos-design.md) defines the later gates. Commands below use `$PROJECT_ROOT` for the checkout root, omit volatile timings, and preserve the measured arguments rather than broad environment dumps.

## Source identity and cleanliness

Upstream URL: `https://github.com/airdcpp/airdcpp-core.git`.
Exact detached commit: `55d51ceb817ec006d4ec844d9e3788e1b0ccc352`.
Source directory: `$PROJECT_ROOT/Source/airdcpp-core`.
Upstream `CMakeLists.txt` SHA-256: `450f21cce9d433a4c8d50cf97200e2ca2c05313c913e54c934badb9fbfaed9af`.

The raw `unmodified/inputs.txt` records `upstream.pre_status=clean` and `upstream.post_status=clean`. Subsequent live Gate 2 runs independently compared detached HEAD, exact origin, tracked binary diff, staged/untracked/ignored state, and generated-file fingerprints before/after; upstream porcelain status remained empty. No upstream patch was applied. `airdcpp/core/version.inc` and `airdcpp/core/localization/StringDefs.cpp` were absent before and after every reviewed configure, so their fingerprints are `absent`, not fabricated hashes.

## Host and tool inventory

Measured `evidence/host-inventory.txt` values:

| Input | Measured value |
| --- | --- |
| Host | Darwin/macOS 26.5.1, build 25F80, arm64 |
| Xcode | 26.6, build 17F113 |
| Apple Clang | 21.0.0, clang-2100.1.1.101; CMake ID AppleClang 21.0.0.21000101 |
| C compiler | `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang` |
| C++ compiler | same directory, `clang++`; implicit C++ link library `c++` (libc++) |
| SDK | 26.5, `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk` |
| Git | 2.53.0; cache executable `/opt/homebrew/bin/git` |
| Python | 3.14.3; cache executable `/opt/homebrew/opt/python@3.14/bin/python3` |
| Homebrew | 6.0.14, prefix `/opt/homebrew` |
| CMake | 4.4.2 |
| Ninja | 1.13.2 (generator tool, not an executed Core build) |
| pkg-config | pkgconf 2.5.1, `/opt/homebrew/opt/pkgconf/bin/pkg-config` |

Only this host/toolchain was measured; no supported Xcode range or older-host runtime compatibility is established.

## Homebrew formula inventory

The exact required discovery set, in helper order, is:

| Formula | Installed version | Resolved opt prefix |
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
| libnatpmp (optional) | absent | unresolved; `/opt/homebrew/opt/libnatpmp` is not an installed input |
| tbb (optional) | absent | unresolved; `/opt/homebrew/opt/tbb` is not an installed input |

`dependency_cmake_prefix_path` joins the thirteen installed prefixes above with semicolons in that order. `dependency_pkg_config_path` joins each prefix's `lib/pkgconfig` then `share/pkgconfig` with colons in the same order. These are explicit discovery hints, not dependency source pins or publication dependencies. No package installation occurs during the gate.

## Unmodified upstream configure

Preserved command, normalized without changing arguments:

```sh
cmake -S "$PROJECT_ROOT/Source/airdcpp-core" \
  -B "$PROJECT_ROOT/Build/airdcpp-core/unmodified" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_CXX_STANDARD=20 -DCMAKE_CXX_EXTENSIONS=OFF \
  -DCMAKE_FIND_DEBUG_MODE=ON
```

Exit: 1. First fatal diagnostic at upstream `CMakeLists.txt:40`: `Unknown CMake command "CHECK_FUNCTION_EXISTS".` The earlier author warning states that `cmake_minimum_required()` should precede top-level `project()`. Neither was suppressed or rewritten in this capture.

Optional flags were intentionally omitted. The preserved cache records `ENABLE_NATPMP=ON` and `ENABLE_TBB=ON`, matching inspected native defaults; the early fatal error prevents any inference about optional package availability from this attempt.

`unmodified/configure.log` SHA-256: `c3e5aa8715eb3a5c01bdb96792d418c30f9c89d2372366e1e90c0e2110b58894`. The historical four-file record remains byte-for-byte intact. Its original narrower input schema is retained; the separately preserved `evidence/unmodified-reuse-inputs.txt` binds reuse to current tool/formula/source inputs without rewriting history.

## Wrapper-only configure

The following historical command preceded the two Find adapters. Prefix contents are exactly the installed discovery set above:

```sh
. "$PROJECT_ROOT/scripts/lib/configure.sh"
CMAKE_PREFIX_PATH=$(dependency_cmake_prefix_path)
cmake -S "$PROJECT_ROOT" -B "$PROJECT_ROOT/Build/airdcpp-core/wrapper-baseline" \
  -G Ninja -DCMAKE_TOOLCHAIN_FILE="$PROJECT_ROOT/cmake/toolchains/macos-arm64.cmake" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_CXX_STANDARD=20 -DCMAKE_CXX_EXTENSIONS=OFF \
  -DENABLE_NATPMP=OFF -DENABLE_TBB=OFF \
  -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH" \
  -DBZIP2_ROOT=/opt/homebrew/opt/bzip2 -DZLIB_ROOT=/opt/homebrew/opt/zlib \
  -DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@3 \
  -DIconv_INCLUDE_DIR=/opt/homebrew/opt/libiconv/include \
  -DIconv_LIBRARY=/opt/homebrew/opt/libiconv/lib/libiconv.dylib \
  -DCMAKE_FIND_DEBUG_MODE=ON
```

Exit: 1. Function/include checks execute and BZip2 1.0.8, ZLIB 1.3.2, OpenSSL 3.6.1 are located. First fatal package mismatch at upstream line 58: no `Findminiupnpc.cmake`, `miniupnpc.cps`, `miniupnpcConfig.cmake`, or `miniupnpc-config.cmake`. Formula inspection found `include/miniupnpc/miniupnpc.h`, `.a`/`.dylib` libraries, and `lib/pkgconfig/miniupnpc.pc`, but no CMake package config. The analogous libmaxminddb layout has `include/maxminddb.h`, libraries, and `lib/pkgconfig/libmaxminddb.pc`, also no CMake config; this is layout evidence, not a second failure reached by the baseline.

The baseline retains the CMP0144/BZIP2_ROOT warning. `wrapper-baseline/configure.log` SHA-256: `031849bc4b23772c028de75737ec6d3e67e5a71455d18d258220fc24463e2c9b`. Its existing command/exit/cache/probe tree is preserved; there is no historical `wrapper-baseline/inputs.txt`.

## Adaptations and evidence

| Adaptation | Prior evidence and narrow response |
| --- | --- |
| Root wrapper includes CheckFunctionExists and CheckIncludeFiles | Raw failure at CHECK_FUNCTION_EXISTS; inspected upstream invokes both checks without importing parent modules. Include them before nesting upstream. |
| Explicit parent variables | Inspected upstream uses VERSION, TAG_APPLICATION, APPLICATION_ID, RESOURCE_DIRECTORY, GLOBAL_CONFIG_DIRECTORY, PROJECT_NAME_GLOBAL. Wrapper supplies configure-only values; nested fixture checks the contract. |
| macos-arm64 toolchain and policy module | Authoritative native/static policy and current source ranges use require AppleClang/libc++, arm64, Release, C++20 required, extensions OFF; fixture rejection tests exercise incompatible inputs. No extra compiler/linker or -stdlib flags. |
| Findminiupnpc.cmake | Baseline fatal config mismatch plus header/library/.pc layout; package-neutral module validates actual header and library, imports miniupnpc::miniupnpc, optionally reads pkg-config version/hints. |
| Findmaxminddb.cmake | Analogous measured libmaxminddb layout; same narrow validation and maxminddb::maxminddb import. No other adapter or upstream patch needed. |
| CMAKE_FIND_PACKAGE_TARGETS_GLOBAL=TRUE | Child-loaded package fixture exposed missing parent target evidence; promote imports before add_subdirectory rather than inventing summary targets. |
| Configuration-specific target recorder | Real imports had empty generic locations but valid IMPORTED_LOCATION_RELEASE. Recorder retains generic fields and adds sorted configuration-specific fields; actual nested package fixture proves Release-only behavior. |
| Configure-only CLI and reuse sidecar | Preserve the two first attempts while refreshing final configure with --fresh; refuse partial/changed historical evidence, invalid checkout/host/path, missing formulas, or any outside-output mutation. |

The concrete implementations are [CMakeLists.txt](../../CMakeLists.txt), [toolchain](../../cmake/toolchains/macos-arm64.cmake), [policy/recorder](../../cmake/modules/AirDCCorePolicy.cmake), [miniupnpc adapter](../../cmake/modules/Findminiupnpc.cmake), [maxminddb adapter](../../cmake/modules/Findmaxminddb.cmake), and [configure helpers](../../scripts/lib/configure.sh). The [wrapper tests](../../tests/cmake_wrapper_test.sh), [adapter tests](../../tests/find_modules_test.sh), and [CLI tests](../../tests/build_configure_test.sh) validate their behaviors.

## Final deterministic configure

Operator command: `"$PROJECT_ROOT/scripts/build" --configure-only`. Exact underlying configure, normalized:

```sh
. "$PROJECT_ROOT/scripts/lib/configure.sh"
CMAKE_PREFIX_PATH=$(dependency_cmake_prefix_path)
PKG_CONFIG_PATH=$(dependency_pkg_config_path)
PKG_CONFIG_PATH="$PKG_CONFIG_PATH" cmake --fresh -S "$PROJECT_ROOT" \
  -B "$PROJECT_ROOT/Build/airdcpp-core/release" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$PROJECT_ROOT/cmake/toolchains/macos-arm64.cmake" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_CXX_STANDARD=20 -DCMAKE_CXX_EXTENSIONS=OFF \
  -DENABLE_NATPMP=OFF -DENABLE_TBB=OFF \
  -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH" \
  -DBZIP2_ROOT=/opt/homebrew/opt/bzip2 -DZLIB_ROOT=/opt/homebrew/opt/zlib \
  -DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@3 \
  -DIconv_INCLUDE_DIR=/opt/homebrew/opt/libiconv/include \
  -DIconv_LIBRARY=/opt/homebrew/opt/libiconv/lib/libiconv.dylib \
  -DCMAKE_FIND_DEBUG_MODE=ON
cmake -N -LA "$PROJECT_ROOT/Build/airdcpp-core/release"
```

Exit: 0. Cache and `release/airdcpp-configure-summary.txt` agree: C/C++ ID AppleClang; selected compiler/SDK paths as inventoried; implicit C++ library `c++`; architecture arm64; deployment 14.0; build type Release; C++20 required ON; extensions OFF; BUILD_SHARED_LIBS OFF; enable_natpmp OFF; enable_tbb OFF; upstream_source `$PROJECT_ROOT/Source/airdcpp-core`.

Parent summary values: version `0.0.0`, tag_application `AirDCCore-macOS`, application_id `org.airdcpp.core.macos.configure`, resource_directory `share/airdcpp`, global_config_directory `Library/Application Support/AirDC++`, project_name `AirDCCore`. These are explicit configure contracts, not published runtime metadata.

All twelve required target blocks report existence TRUE. Locations, includes, and interfaces are detailed below, including RELEASE-only values. The only final warning is CMP0144. `build.ninja` and a PCH source/header are generated configuration files, not executed Core compilation. Core artifact searches print nothing; `.ninja_log` and `.ninja_deps` are absent. Only CMake CompilerId and Check* probe products are permitted.

## Deployment target decision

The preserved configure-only probes used the wrapped command with separate `deployment-13.0`, `deployment-14.0`, and `deployment-15.0` output directories and the respective explicit `-DCMAKE_OSX_DEPLOYMENT_TARGET` value, retaining both optional flags OFF. The prior measured exits were 0 for each; each preserved log records configure/generate completion. Each summary matches its target, arm64, AppleClang, libc++, Release/C++20/static Core policy, and identical required package paths. Each generated C/C++ compiler record independently sets compiler works TRUE.

The reviewed Phase 2 selection is 14.0, the declared baseline, with no legacy-specific patch required by configure. 13.0 and 15.0 remain diagnostic candidates, not validated deployment promises. Compiler probes on SDK 26.5 and mutable Homebrew bottles do not prove Core source compilation, dependency minimum-OS compatibility, consumer linking, or runtime compatibility on any of those systems. Later build, link, and pinned-dependency gates must validate those limitations before publication.

## Optional NAT-PMP and TBB behavior

Inspected upstream defaults are `ENABLE_NATPMP=ON` and native `ENABLE_TBB=ON`. A clearly separate optional probe used `Build/airdcpp-core/optional-on`, `-DENABLE_NATPMP=ON -DENABLE_TBB=ON`, otherwise the wrapped 14.0 command. Prior measured exit: 0. Both optional formulas are absent; cache has `natpmp_DIR=natpmp_DIR-NOTFOUND` and `TBB_DIR=TBB_DIR-NOTFOUND`, and the log retains nonfatal missing-config warnings. Generated graph has no Mapper_NATPMP.cpp, HAVE_NATPMP_H, HAVE_INTEL_TBB, libnatpmp, or TBB::tbb reference.

Final policy is explicitly `ENABLE_NATPMP=OFF` and `ENABLE_TBB=OFF`, also recorded as OFF/OFF in cache/summary. Final log/graph contain no optional lookup references. Optional formula absence cannot alter the final configuration: those searches/features are disabled rather than selected by host availability. No NAT-PMP/TBB release performance or ABI claim follows from the optional probe.

## Package resolution

Measured target evidence; `R` means IMPORTED_LOCATION_RELEASE with generic IMPORTED_LOCATION empty, not an absent library. All R entries have imported_configurations RELEASE. Unmarked library entries use generic IMPORTED_LOCATION and have no imported configurations. Blank interfaces mean the recorded property is empty.

| Target (type) | Library location | Include directory | Link interface |
| --- | --- | --- | --- |
| BZip2::BZip2 (UNKNOWN_LIBRARY) | R `/opt/homebrew/opt/bzip2/lib/libbz2.a` | `/opt/homebrew/opt/bzip2/include` | empty |
| ZLIB::ZLIB (UNKNOWN_LIBRARY) | R `/opt/homebrew/opt/zlib/lib/libz.dylib` | `/opt/homebrew/opt/zlib/include` | empty |
| OpenSSL::SSL (UNKNOWN_LIBRARY) | `/opt/homebrew/opt/openssl@3/lib/libssl.dylib` | `/opt/homebrew/opt/openssl@3/include` | OpenSSL::Crypto |
| OpenSSL::Crypto (UNKNOWN_LIBRARY) | `/opt/homebrew/opt/openssl@3/lib/libcrypto.dylib` | `/opt/homebrew/opt/openssl@3/include` | empty |
| miniupnpc::miniupnpc (UNKNOWN_LIBRARY) | `/opt/homebrew/opt/miniupnpc/lib/libminiupnpc.dylib` | `/opt/homebrew/opt/miniupnpc/include` | empty |
| leveldb::leveldb (SHARED_LIBRARY) | R `/opt/homebrew/opt/leveldb/lib/libleveldb.1.23.0.dylib` | `/opt/homebrew/opt/leveldb/include` | snappy;Threads::Threads |
| maxminddb::maxminddb (UNKNOWN_LIBRARY) | `/opt/homebrew/opt/libmaxminddb/lib/libmaxminddb.dylib` | `/opt/homebrew/opt/libmaxminddb/include` | empty |
| Boost::thread (SHARED_LIBRARY) | R `/opt/homebrew/Cellar/boost/1.90.0_1/lib/libboost_thread.dylib` | `/opt/homebrew/Cellar/boost/1.90.0_1/include` | Boost::atomic;Boost::chrono;Boost::container;Boost::date_time;Boost::exception;Boost::headers;Threads::Threads |
| Boost::regex (SHARED_LIBRARY) | R `/opt/homebrew/Cellar/boost/1.90.0_1/lib/libboost_regex.dylib` | `/opt/homebrew/Cellar/boost/1.90.0_1/include` | Boost::headers |
| Snappy::snappy (SHARED_LIBRARY) | R `/opt/homebrew/opt/snappy/lib/libsnappy.1.2.2.dylib` | `/opt/homebrew/opt/snappy/include` | empty |
| Threads::Threads (INTERFACE_LIBRARY) | empty; SDK interface | empty | empty |
| Iconv::Iconv (INTERFACE_LIBRARY) | empty; link-interface library below | `/opt/homebrew/opt/libiconv/include` | `/opt/homebrew/opt/libiconv/lib/libiconv.dylib` |

Every recorded include/library exists and its physical path lies below the physical prefix from the corresponding inventory formula. Boost's recorded Cellar paths resolve under the physical `/opt/homebrew/opt/boost` prefix. SDK Threads is not a Homebrew library. Iconv has no imported location/configuration; its library is in the interface.

Package configs in the cache: Boost `/opt/homebrew/opt/boost/lib/cmake/Boost-1.90.0`; leveldb `/opt/homebrew/opt/leveldb/lib/cmake/leveldb`; Snappy `/opt/homebrew/opt/snappy/lib/cmake/Snappy`. Boost component config directories are `/opt/homebrew/opt/boost/lib/cmake/boost_<component>-1.90.0` for atomic, chrono, container, date_time, exception, headers, regex, and thread. BZip2/ZLIB/OpenSSL/Threads/Iconv use CMake modules; miniupnpc/maxminddb use the two parent modules, with pkg-config versions 2.3.3/1.13.3. No missing CMake config is disguised as a config resolution for those modules.

## Warnings and failures

Raw standalone failure and wrapper-only miniupnpc mismatch are accepted preserved discovery evidence, not successful attempts. The wrapper solves their measured causes without modifying Source. The raw project/minimum-required ordering author warning is retained historically. Final and baseline CMP0144 warnings state uppercase BZIP2_ROOT may be ignored for compatibility; accepted because independent include/RELEASE-library records prove correct formula resolution and final configure completes. Optional probe missing natpmp/TBB configs are accepted only as OFF-policy justification, not required final packages. No warning was suppressed to turn the gate green.

Debug-only BZip2/ZLIB `-NOTFOUND` cache entries do not invalidate the measured Release locations. Non-macOS optional tool entries CMAKE_ADDR2LINE/DLLTOOL/OBJCOPY are not required configure inputs. There is no final fatal diagnostic or unresolved required Release import.

WebSocket++, nlohmann-json, npm, and Boost system are not resolved by this Core configure and are not direct dependencies declared by inspected upstream CMake. Boost's measured extra thread interface targets are recorded above, not inferred into a final archive/link closure. Any later closure change needs real compile/link evidence.

## Rerun and scope verification

The reviewed real [Gate 2 test](../../tests/gate2_configure_test.sh) was run successively twice on the Task 5 final test, each exit 0 with exactly `PASS: Gate 2 configured pinned AirDC++ Core without compilation`. Each run refreshed final configure with `--fresh`, asserted reuse of the raw failed attempt, and compared all existing evidence except mutable release and refreshed host inventory by SHA-256, mtime, size, and permissions. Historical captures, deployment/optional probe trees, and reuse sidecar were unchanged byte-for-byte. Final deterministic summary SHA-256 in this checkout: `0cd92628a86533e734153016a76ad554cd16d3f8e9d8fb26458f16e29a7245b7` (raw workspace-specific summary, not a portable artifact hash).

Task 5 parent/upstream porcelain status was empty before and after each live run. Task 6 adds only this report, the four operator docs, and report validation in the gate test; its final gate run compares the pre-existing documentation/test edit state before/after, not a falsely claimed clean parent during implementation. Full parent content snapshots, including ignored state outside Build/airdcpp-core, and upstream identity/diff/ignored/generated snapshots must remain equal. After the documentation commit the parent can be clean; commit cleanliness is separate from configure non-mutation.

The scope assertion requires `Dependencies` and `Dist` absent, `release/libairdcpp.a` absent, and no `.o`, `.a`, or `.dylib` under Build/airdcpp-core except standard CMake CompilerId/Check* probe directories. All five wrapped upstream-target output directories contain no such files. `.ninja_log`/`.ninja_deps` are absent throughout. No Core build, dependency reconstruction, push, merge, PR, or publication operation occurred.

Final acceptance commands:

```sh
cd "$PROJECT_ROOT"
AIRDCCORE_RUN_CONFIGURE_TESTS=1 ./tests/gate2_configure_test.sh
./tests/build_configure_test.sh
./tests/configure_helpers_test.sh
./tests/cmake_wrapper_test.sh
./tests/find_modules_test.sh
./tests/upstream_config_test.sh
./tests/update_test.sh
```

Every command exited 0 and printed PASS; the real configure remained compile-free. Without the enablement variable the gate refuses before configure. Missing report/headings/explicit absence assertions, user-home leakage, optional ON outside the labeled discovery/probe sections, or unsupported compilation/publication/package claims fail the report contract before configuration.

## Gate 2 review decision

Accepted for the measured host and explicit configure-only policy: final exit 0, all required imports evidenced with their actual generic/RELEASE/interface locations, deterministic OFF optional policy, reviewed 14.0 selection with limitations, immutable first attempts, unchanged source/scope, and all seven acceptance tests passing. No blocker remains within Gate 2. A future failure of final configure or any scope assertion blocks the gate and later phases. Stop before Phase 3; this acceptance grants no compile, final-link, binary-compatibility, dependency-pin, packaging, merge, or publication approval.
