# Gate 4 First Real-Link Failure

**Date:** 2026-09-21  
**Branch:** `feature/consumer-link-interface`  
**Phase:** 4 — external consumer link-interface discovery  
**Result:** Stopped before retry, as required by the Phase 4 plan.

## Preserved input

- Upstream commit: `55d51ceb817ec006d4ec844d9e3788e1b0ccc352`
- Core archive SHA-256: `0bc3cc3c9a4424bbceb0bd2c1682e963ecd388b0bacc6acb3c0575aaa8e464e7`
- Core-only experiment: configure succeeded and the force-loaded link failed with unresolved dependency symbols, as expected.
- Full candidate experiment: configure succeeded; compilation succeeded; linking failed before omission discovery began.

Raw evidence remains under the ignored directory:

```text
Build/airdcpp-core/link-interface/core-only/
Build/airdcpp-core/link-interface/full/
```

## Unexpected result

The full verbose link command contained both the exact imported Snappy library and a second bare search-name item:

```text
/opt/homebrew/opt/snappy/lib/libsnappy.1.2.2.dylib
-lsnappy
```

Apple `ld` then stopped with:

```text
ld: library 'snappy' not found
clang++: error: linker command failed with exit code 1
```

No omission was classified, no consumer executable was published, and Gate 4 did not pass.

## Root cause

Homebrew's installed `leveldb::leveldb` imported target declares:

```cmake
INTERFACE_LINK_LIBRARIES "snappy;Threads::Threads"
```

The plain `snappy` entry becomes `-lsnappy`, but the imported LevelDB target does not provide Snappy's Homebrew library directory as a link search directory. Separately, `Snappy::snappy` correctly resolves to:

```text
/opt/homebrew/opt/snappy/lib/libsnappy.1.2.2.dylib
```

The failure therefore comes from incomplete third-party imported-target metadata exposed by LevelDB, not from an unknown AirDC++ Core dependency.

## Proposed plan amendment

Add a narrow consumer-side package adapter after both imported targets are discovered:

1. Require `leveldb::leveldb` and `Snappy::snappy` to exist.
2. Read `leveldb::leveldb`'s `INTERFACE_LINK_LIBRARIES`.
3. Replace only the exact plain `snappy` item with `Snappy::snappy`, preserving every other ordered item.
4. Fail configuration if the expected plain item is absent or ambiguous; do not add a global link directory and do not edit Homebrew files.
5. Add an offline CMake contract test for the adapter.
6. Preserve this failed attempt through the existing sequential, hash-checked attempt mechanism before running one second real experiment.

This amendment keeps dependency identity explicit, avoids a broad `-L` search path, and allows omission discovery to determine whether the direct Snappy candidate is required or is supplied transitively through LevelDB.

## Gate status

Gate 4 remains **not passed**. The next real-link run requires explicit approval of the amendment above.

## Resolution

The user approved the narrow adapter. `leveldb::leveldb` now maps only its exact plain `snappy` interface item to `Snappy::snappy`; the adapter contract test passes and later real links contain no stray `-lsnappy`. This report remains the immutable explanation of the first failed experiment.
