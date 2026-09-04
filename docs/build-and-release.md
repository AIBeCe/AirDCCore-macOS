# Build and release gates

This is a concise operator-oriented phase map. The full contract is in [the design spec](superpowers/specs/2026-09-04-airdc-core-macos-design.md).

No build or release workflow exists at the design-baseline commit.

## Required sequence

1. **Acquire:** fetch the versioned upstream URL, verify the exact commit, and leave the checkout in a known state.
2. **Discover:** use Homebrew-assisted host tooling and dependency discovery for the first native feasibility build.
3. **Build core:** configure Release with Apple Clang/libc++, `BUILD_SHARED_LIBS=OFF`, and `CMAKE_OSX_ARCHITECTURES=arm64`.
4. **Close the link:** inspect unresolved symbols and link a real external C++ program. Record every required archive, framework, and system library.
5. **Choose distribution shape:** decide from evidence whether `Dist/lib` contains one archive, multiple archives plus an explicit link interface, or an aggregate artifact.
6. **Reproduce dependencies:** replace mutable Homebrew runtime assumptions with pinned source builds or pinned packaged archives wherever publication requires it.
7. **Package:** stage headers, libraries, metadata, checksums, and license material into `Dist` only after all preceding gates pass.
8. **Verify and release:** run architecture, symbol, header, link, provenance, cleanliness, and two-clean-build reproducibility checks.

No later phase may conceal a failed earlier gate with an undocumented patch or manually copied local artifact.

## Release evidence

A releasable `Dist` must include machine-readable provenance and link-interface metadata, SHA-256 checksums, and all required notices. Verification must exercise `file`, `lipo`, `nm` or equivalent Apple tooling, plus a fresh C++ consumer that compiles and links without using the source or build trees.
