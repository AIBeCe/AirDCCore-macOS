# Gate 4 Runtime Contract Failure

**Date:** 2026-09-21

**Branch:** `feature/consumer-link-interface`

**Phase:** 4 — external consumer link-interface discovery

**Result:** Link closure reached a fixed point; runtime contract stopped Gate 4.

## What passed

- The force-loaded external consumer linked successfully as an `arm64` Mach-O executable.
- Every dependency loaded successfully when the executable ran.
- The two omission passes reached the same fixed-point closure.
- Required logical items: `BZip2`, `ZLIB`, `OpenSSLSSL`, `miniupnpc`, `leveldb`, `maxminddb`, `Iconv`.
- Transitively supplied items: `OpenSSLCrypto`, `BoostThread`, `BoostRegex`, `Snappy`, `Threads`.
- The system Iconv dependency resolves to `/usr/lib/libiconv.2.dylib`, matching the ABI compiled into Core.

## Runtime failure

The executable returned `1` with:

```text
AirDC++ Core version is empty
```

The generated pinned-source metadata contains:

```text
#define GIT_TAG ""
#define GIT_COMMIT "55d51ceb817ec006d4ec844d9e3788e1b0ccc352"
```

`dcpp::getVersionTag()` therefore correctly returns an empty string for this detached, untagged upstream commit. `dcpp::getGitCommit()` is an adjacent public, out-of-line Core symbol and returns the exact nonempty configured commit.

## Proposed runtime-contract amendment

1. Keep calling `dcpp::getVersionTag()` first.
2. If the tag is empty, call `dcpp::getGitCommit()` and use that value as the Core identity.
3. Continue failing if both values are empty.
4. Preserve the output format `AirDC++ Core <nonempty-identity>`.
5. Extend the isolated archive fixture with both real signatures and add an empty-tag/nonempty-commit fallback test.
6. Do not regenerate metadata or rebuild `libairdcpp.a`.

This retains the original tag when one exists, proves real archive symbol resolution in both cases, and makes the smoke contract valid for the deliberately pinned detached checkout.

## Gate status

Gate 4 remains **not passed** until the amended consumer runs successfully and the remaining normalized/path-leak evidence checks pass.

## Resolution

The user approved the identity fallback. The consumer still calls `getVersionTag()` first, falls back to `getGitCommit()` only for an empty tag, and now prints the exact pinned commit with exit status `0`. The fixture test covers both tagged and detached-commit identities.
