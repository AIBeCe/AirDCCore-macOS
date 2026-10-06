# ADR 0001: Aggregate static distribution

**Status:** Accepted

**Decision date:** 2026-09-22

**Gate 4 Core SHA-256:** `f345fe0e5fc7bbf289642e5a8846795f0e0d177288505419b0ba96cc23367441`

**Published library:** `Dist/lib/libairdcpp.a`

## Context and evidence

The [design spec](../superpowers/specs/2026-09-04-airdc-core-macos-design.md) deliberately postponed the final `Dist/lib` shape until a real external consumer established the link closure. The [Gate 4 report](../reports/2026-09-21-gate-4-consumer-link.md) supplies that evidence for upstream commit `55d51ceb817ec006d4ec844d9e3788e1b0ccc352` and the Core archive identified above.

Gate 4 force-loaded all 130 ARM64 Core objects into a standalone C++20 executable. A Core-only link failed. Two omission passes then established seven direct logical inputs, while the final physical command also contained OpenSSL Crypto and Snappy through transitive target interfaces. The consumer ran and exposed the pinned Core commit. Gate 4 found no Apple framework requirement.

The eventual consumer is an Objective-C++ bridge packaged separately with Swift Package Manager. Making that project reproduce CMake target expansion, transitive dependencies, and static-library ordering would expose Project 1 build internals as a fragile public interface. This project therefore owns the non-system static closure and publishes one library-level entry point.

## Decision

The future distribution will publish one aggregate ARM64 static archive at `Dist/lib/libairdcpp.a`. The aggregate contains object files from exactly these Gate 4 non-system components, rebuilt or otherwise supplied from the pinned Phase 6 inputs:

### Aggregate component inventory

- AirDC++ Core
- BZip2
- zlib
- OpenSSL SSL
- OpenSSL Crypto
- miniupnpc
- LevelDB
- MaxMindDB
- Snappy

Component archives may remain private intermediate build products. They are not separate public link inputs under `Dist/lib`. Adding, removing, or substituting an aggregate component requires new link evidence and an amendment or successor to this ADR.

### External Apple system-link inventory

- explicit SDK link input: Iconv from the selected macOS SDK
- implicit toolchain load command: libc++ from the selected macOS toolchain/SDK
- implicit toolchain load command: libSystem from the selected macOS SDK
- measured Apple framework requirement: none

The final package must record both identity and linkage mode for this system boundary in machine-readable metadata. A consumer requests SDK Iconv explicitly; Apple Clang supplies libc++ and libSystem implicitly through its normal compile/link driver behavior. They are observed load commands, not extra public linker flags. If a later clean consumer needs an Apple framework or another system library, packaging stops until the contract and this decision are reviewed.

## Deterministic construction contract

Phase 6 must first prove that each non-system component can be reconstructed as a compatible static ARM64 input with the selected deployment target and feature policy. Phase 7 may construct the aggregate only after those inputs pass their individual checks.

The construction algorithm is part of the publication contract:

1. Validate each input archive's pin, checksum, ARM64 architecture, deployment policy, expected object inventory, and absence of unsafe paths.
2. Enumerate input archives in a declared component order matching the component list in this ADR.
3. Inspect externally visible defined symbols and reject duplicate strong external definitions before aggregation. Separately inventory every repeated weak or coalesced definition. The current Core archive already contains legitimate repeated weak externals, including libc++ inline data and Core singleton definitions, so repetition alone is not a failure. Each accepted repetition requires an evidence-bound coalescing decision that records every defining member, Mach-O symbol classification, why Apple linker coalescing is valid, and the verification that the aggregate consumer resolves it as intended. Link order is not an acceptable collision policy.
4. Enumerate members in original archive member-table order. Extract each archive into a private component-and-ordinal namespace, then give every object a unique basename with the canonical format `NN-component-slug--NNNN-original-member-name`, where `NN` is the declared component-list ordinal and `NNNN` is the member ordinal from the original archive member-table order. Normalize the original member-name suffix to a safe filename and reject any normalization collision. The component identity must be in the basename because Apple `libtool` discards input directory components when naming archive members. This prevents equal source basenames from replacing or obscuring one another and preserves component order under lexical sorting.
5. Set `LC_ALL=C` and generate a byte-sorted file list from the canonical unique member paths. No filesystem enumeration order or locale-specific collation may affect the list.
6. Invoke Apple `/usr/bin/libtool -static -D -filelist` with that list and an explicit output path. The deterministic flag and ordered inputs establish the archive container policy; the resulting table of contents must be regenerated by the selected Apple archive tooling rather than copied from an ingredient archive.
7. Independently verify member count and identity, ARM64 architecture, defined and unresolved symbols, table of contents, embedded path leakage, component mapping, and consumer behavior.
8. Produce two clean aggregate builds from the same locked inputs and require identical SHA-256 output before reproducibility is claimed.

The implementation must fail closed on missing tools, unexpected members, duplicate output names, duplicate strong external definitions, unclassified repeated weak/coalesced definitions, input drift, or a mismatched second build. It must not silently prefer the first archive on the command line.

## Provenance, checksums, and licenses

Publishing one archive does not erase component boundaries. The distribution metadata and license tree must retain, for every component:

- exact source URL and immutable revision;
- source and archive SHA-256 checksums;
- build flags and patches;
- license identity and redistributed notices;
- aggregate member-to-component mapping.

The manifest must also bind the aggregate checksum to the ordered input checksums and construction-tool identity. License obligations are assessed and fulfilled per component even though the consumer receives one archive. Missing or incompatible license evidence blocks packaging.

## Consumer contract and consequences

A clean consumer compiles only from `Dist/include`, links `Dist/lib/libairdcpp.a`, explicitly requests only the declared SDK Iconv input, and lets the Apple toolchain supply the declared implicit libc++ and libSystem load commands. It does not discover Homebrew, `Source`, `Dependencies`, or `Build`. This removes non-system archive ordering and transitive closure from Project 2 without turning implicit runtime/toolchain dependencies into manual link flags.

The tradeoff is that Project 1 assumes responsibility for collision detection, component traceability, static dependency reconstruction, and a larger single artifact. Updating one ingredient rebuilds the aggregate. Debugging and compliance therefore depend on accurate member mapping and per-component metadata rather than separate public archive filenames.

## Rejected alternative: separate public archives

Publishing Core and every dependency as separate archives gives the clearest file-level provenance and avoids flattening. It is rejected because Gate 4 proved an ordered direct and transitive closure; exporting that ordering makes every downstream bridge reproduce Project 1's dependency graph and linker semantics. It would turn current implementation detail into a long-lived consumer contract.

## Rejected alternative: multiple archives behind CMake or pkg-config

A generated CMake package or pkg-config file could hide ordering from C++ consumers while leaving component archives separate. It is rejected as the primary distribution shape because the intended next boundary is Objective-C++ consumed through Swift Package Manager, not a downstream CMake or pkg-config build. Supporting that extra public integration layer would not remove the need to define and verify the SPM-compatible link contract.

## Phase 6 handoff and non-claims

This ADR decides a shape from measured Gate 4 evidence. It does not create `Dependencies` or `Dist`, build an aggregate, or approve packaging. Phase 6 must select immutable dependency versions, establish source/archive checksums, record licenses, determine exact static build flags and patches, and prove each input's ARM64 and macOS 14 compatibility. It must also test whether strong-symbol collision rejection, weak/coalesced-symbol classification, and the canonical construction algorithm are feasible with the reconstructed archives.

Gate 5 does not prove static dependency availability, aggregate feasibility, minimum-macOS runtime compatibility, licensing completeness, deterministic output, two-build reproducibility, or release readiness. Those claims remain blocked on Phases 6 through 8. NAT-PMP and TBB remain disabled, and WebSocket++ remains outside the measured Core closure.

## Superseded records

None.
