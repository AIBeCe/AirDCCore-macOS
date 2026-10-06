# Gate 4 Embedded Path Failure

**Date:** 2026-09-21

**Branch:** `feature/consumer-link-interface`

**Phase:** 4 — external consumer link-interface discovery

**Result:** Link and runtime passed; embedded-path verification stopped Gate 4.

## What passed

- The fixed-point external consumer linked successfully.
- The executable is exactly `arm64`.
- All dynamic dependencies loaded.
- The executable returned `0` with:

```text
AirDC++ Core 55d51ceb817ec006d4ec844d9e3788e1b0ccc352
```

- The seven required logical closure items remained stable across both omission passes.

## Failing evidence

The final `strings` inspection found one user-home/worktree path:

```text
/Users/davidalarcon/.codex/worktrees/phase2-integration/AirDCCore-macOS/Source/airdcpp-core/airdcpp/core/crypto/CryptoManager.cpp
```

The same string is already present in the Phase 3 `CryptoManager.cpp.o` archive member. It is not introduced by the Phase 4 consumer or its link command.

## Root cause

OpenSSL macros used while compiling `CryptoManager.cpp` capture `__FILE__`. Apple Clang received the absolute upstream source path, so the Release object contains that path as a string literal. Force-loading the complete archive correctly carries it into the external executable.

Linker stripping cannot safely normalize a string literal used by compiled code. Editing the archive after compilation would also invalidate the verified object evidence without fixing the build process.

## Proposed Phase 3 amendment

1. Add the deterministic Apple Clang option below to the upstream `airdcpp` target from the wrapper, without editing upstream source:

   ```text
   -ffile-prefix-map=<absolute pinned checkout>=airdcpp-core
   ```

2. Record the prefix-map policy in Phase 3 build inputs and configure summary.
3. Extend the Core build tests and Gate 3 verification to reject user-home, worktree, absolute `Source`, or absolute `Build` strings in `libairdcpp.a`.
4. Preserve the current Phase 3 evidence as another hash-checked attempt, then rebuild `libairdcpp.a` once with otherwise identical ARM64/Release/macOS-14/C++20 inputs.
5. Re-run archive member/symbol inspection and publish the new archive hash.
6. Re-run Phase 4 closure and runtime verification against only the amended archive.

This changes the Phase 3 archive hash, so it requires explicit approval. It does not alter upstream source, dependency selection, public APIs, architecture, or deployment policy.

## Gate status

Gate 4 remains **not passed** solely because the existing Phase 3 artifact contains the absolute source path. The consumer link, fixed-point closure, and runtime identity contract have otherwise passed.

## Resolution

The user approved the Gate 3 amendment. The wrapper now applies `-ffile-prefix-map=<absolute pinned checkout>=airdcpp-core`, records that policy, and rejects absolute home, `Source`, or `Build` paths in the archive. The rebuilt archive SHA-256 is `f345fe0e5fc7bbf289642e5a8846795f0e0d177288505419b0ba96cc23367441`; live Gate 3 and the complete Phase 4 fixed-point link/runtime experiment pass against it.
