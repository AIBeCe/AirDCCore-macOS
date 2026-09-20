# Phase 3 first native build: preserved failure

**Status:** Gate 3 has not passed. This report records the first, unmodified native compile attempt on `feature/arm64-static-core-build`; it is not an archive or release report. Paths below are relative to `$PROJECT_ROOT` unless noted.

## Scope and inputs

- Upstream: `https://github.com/airdcpp/airdcpp-core.git` at detached commit `55d51ceb817ec006d4ec844d9e3788e1b0ccc352` in `Source/airdcpp-core`. The checkout had no tracked changes or unexpected untracked files before the attempt.
- Host: macOS 26.5.1, native `arm64`; Xcode 26.6, Apple Clang 21.0.0, SDK 26.5, CMake 4.4.3, Ninja 1.13.2, Homebrew 7.0.4, Python 3.14.7. The full, mutable formula inventory is in `Build/airdcpp-core/core-release/host-inventory.txt`; its formula-inventory SHA-256 is `7245d0f1b75d587823e0dd102187f4aef22e3e3fc4fd5ab73457353657bc18d1`.
- Policy: Release, `arm64`, C++20 with extensions OFF, static Core, deployment target 14.0, NAT-PMP and TBB OFF. `Build/airdcpp-core/core-release/first-build-state.txt` records `core-release.preexisting=absent`.
- Command: `cmake --build "$PROJECT_ROOT/Build/airdcpp-core/core-release" --target airdcpp --config Release --parallel 2`, issued by `./scripts/build --build-core` after wrapper configuration. The literal command is preserved in `build-command.txt`.

## Observed result

Wrapper configuration succeeded. Ninja reached `[51/134]` and failed compiling `airdcpp/hash/HashStore.cpp.o`; it stopped after one additional in-flight compile. `build-exit-code.txt` contains `1`. No `libairdcpp.a`, `Dist`, or `Dependencies` was produced.

The first fatal diagnostic is at upstream `Source/airdcpp-core/airdcpp/hash/HashStore.cpp:404`:

```text
memcpy(&curRoot, aKey, key_len);
error: first argument in call to 'memcpy' is a pointer to non-trivially copyable type 'TTHValue' (aka 'HashValue<TigerHash>') [-Werror,-Wnontrivial-memcall]
```

The actual compile command contains `-Werror -Wthread-safety`. This `-Werror` comes from Homebrew LevelDB 1.23_2's imported `leveldb::leveldb` target, whose `/opt/homebrew/opt/leveldb/lib/cmake/leveldb/leveldbTargets.cmake` exports `INTERFACE_COMPILE_OPTIONS "-Werror;-Wthread-safety"`. Upstream links that target in `Source/airdcpp-core/CMakeLists.txt:210`; the wrapper does not set global `-Werror`. Thus a dependency's warning policy reaches Core compilation. This is the build-stopping mechanism, not proof that the underlying warning is harmless.

There is also a separate correctness concern requiring review before publication: `HashValue<TigerHash>` has a fixed-size `data` array, while the `key_len` passed through `LevelDB::remove_if` is obtained from the database iterator's key size. The shown `memcpy` has no local length check. The first-build evidence alone does not establish whether malformed or unexpected database keys can occur in practice or what recovery behavior a source patch should use. Removing transitive `-Werror` would permit this warning but would **not** resolve that concern.

## Evidence retained

| Ignored artifact under `Build/airdcpp-core/core-release` | SHA-256 / value |
| --- | --- |
| `configure.log` | `1810cf88a22a249a5c09888d704b9ecf6ab91bbd1a9695a8d06be266bb3fe294` |
| `build.log` | `991e7429ba6c3622e1dbc8c27fcc3ce530749d80d0803ee6c76ea0a283e14ce8` |
| `build-exit-code.txt` | `1` |
| `first-build-state.txt` | `core-release.preexisting=absent` |

The upstream build generated only the two allowed ignored files: `airdcpp/core/version.inc` (SHA-256 `65c2b8b0553cdaa61b54e6ecc6e90cdba308eeeae760f24d22b2623a78a47b3c`) and `airdcpp/core/localization/StringDefs.cpp` (SHA-256 `d7ff5db80e0e6bffa8cdc04065a5c71eb6bcee9a94a1f6d6b58a1b2a4fb75c6c`). The source checkout remains detached at the pin; the feature branch has no generated files tracked.

## Reviewed decision before retry

The Phase 3 plan explicitly stopped on the first real compiler failure. The user approved Task 2A on 2026-09-20: test and apply a narrow wrapper-only removal of LevelDB's transitive `-Werror`, retaining `-Wthread-safety`; preserve this first attempt's evidence before reconfiguration; and permit one measured retry. Any remaining warning must stay visible, and this decision does not claim the database-key copy safe. A tracked, behavior-preserving upstream source patch may still be needed after the build feasibility gate and must be designed separately from the warning-policy adapter.
