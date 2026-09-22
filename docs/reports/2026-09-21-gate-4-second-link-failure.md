# Gate 4 Second Real-Link Failure

**Date:** 2026-09-21  
**Branch:** `feature/consumer-link-interface`  
**Phase:** 4 — external consumer link-interface discovery  
**Result:** Stopped before a third real-link run.

## Preserved state

- The first failed full-link attempt is preserved at `Build/airdcpp-core/link-interface/full/attempts/0001`.
- Its complete `sha256.txt` manifest verifies successfully.
- The approved LevelDB/Snappy adapter removed the stray bare `-lsnappy`; the second verbose link contains only the exact `Snappy::snappy` dylib.
- The Core archive remains unchanged at SHA-256 `0bc3cc3c9a4424bbceb0bd2c1682e963ecd388b0bacc6acb3c0575aaa8e464e7`.

## Unexpected result

The second full link reached Core's iconv references and failed with:

```text
Undefined symbols for architecture arm64:
  "_iconv"
  "_iconv_close"
  "_iconv_open"
```

The selected Homebrew library was present on the link line, but it exports the GNU-prefixed ABI:

```text
_libiconv
_libiconv_close
_libiconv_open
```

## Root cause

The Phase 3 toolchain sets `CMAKE_SYSTEM_NAME=Darwin`, which makes CMake's same-host ARM64 build report `CMAKE_CROSSCOMPILING`. Upstream AirDC++ Core conditionally appends `Threads::Threads` and `Iconv::Iconv` only when `CMAKE_CROSSCOMPILING` is false.

The archived `Text.cpp` compile command therefore has no Homebrew libiconv include directory. It uses the macOS SDK `<iconv.h>` and correctly emits references to the macOS `_iconv*` ABI. The SDK provides those symbols through:

```text
<macOS SDK>/usr/lib/libiconv.tbd
install-name: /usr/lib/libiconv.2.dylib
```

The Phase 4 consumer's forced Homebrew `Iconv::Iconv` candidate was therefore the wrong ABI for the already-built Core archive.

## Proposed second amendment

1. Resolve the active SDK with `xcrun --show-sdk-path` and require a regular `usr/lib/libiconv.tbd` input.
2. Add a narrow imported interface target, `AirDCCore::SystemIconv`, that links that exact SDK stub.
3. Map the logical `Iconv` closure candidate to `AirDCCore::SystemIconv`.
4. Stop forcing Homebrew `Iconv_INCLUDE_DIR` and `Iconv_LIBRARY` in the standalone consumer; do not rebuild Core.
5. Add isolated CMake contract tests for the absolute SDK-stub input, missing-file rejection, and imported-target link item.
6. Preserve the current second failure as the next hash-checked attempt before a third real experiment.

This amendment matches the ABI that Phase 3 actually compiled against and keeps the dependency explicit without relying on an ambient `-L` search path.

## Additional measured limitation

The linker also warns that the current Homebrew discovery libraries were built for macOS 26.0 while the consumer deployment target is 14.0. This does not explain the iconv failure, but it means Homebrew artifacts cannot prove macOS 14 runtime compatibility or become final `Dist` inputs. The Phase 4 report must retain this limitation for the pinned-dependency work in Phase 6.

## Gate status

Gate 4 remains **not passed**. A third real-link run requires explicit approval of the second amendment above.

## Resolution

The user approved the system-Iconv adapter. The consumer now links the active SDK stub through `AirDCCore::SystemIconv`, the adapter contract test passes, and the executable loads `/usr/lib/libiconv.2.dylib`. This report remains the immutable explanation of the second failed experiment.
