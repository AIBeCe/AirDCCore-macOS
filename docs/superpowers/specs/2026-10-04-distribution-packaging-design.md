# Phase 7: Distribution packaging

Status: approved scope; implementation authorized for the complete phase.

## Authority and goal

The original design's Gate 7 and accepted ADR 0001 govern this phase. Consume
the accepted Phase 6 reproducible inputs and publish a relocatable, complete
ARM64 distribution. Do not reopen the archive-shape decision or change the
Phase 6 build/acquisition interfaces. Work on `feature/distribution-packaging`.

## Interfaces

Add `scripts/package` as the dedicated packaging entry point. Its default
operation validates private inputs, constructs and verifies the package, and
publishes `Dist`. A verification-only mode checks an existing distribution
without reconstructing dependencies or Core. No Homebrew discovery is allowed.

The published tree is:

```text
Dist/
  include/airdcpp/       public and generated Core headers
  include/              required non-system public header closure
  lib/libairdcpp.a       exactly one aggregate static archive
  metadata/manifest.json
  metadata/link-interface.json
  metadata/checksums.sha256
  metadata/             ordered member map and coalescing evidence
  licenses/             original Core and redistributed dependency notices
```

Public metadata uses stable relative paths and deterministic serialization;
it records pins, source/archive/header digests, flags, patches, deployment
target, tool identity, license obligations, component mapping, and the final
artifact inventory. Checksums cover every published file except the checksum
file itself. Do not publish mutable source/build paths, host paths, Homebrew
prefixes, wall-clock timestamps, private logs, or executables.

## Construction and validation

Validate actual archives against accepted Phase 6 evidence and immutable lock,
including thin ARM64 and macOS 14 policy. Reuse existing read-only validators
where their interfaces apply. Preserve the accepted inputs and their evidence.

Use ADR 0001's nine-component order: Core, BZip2, zlib, OpenSSL SSL, OpenSSL
Crypto, miniupnpc, LevelDB, MaxMindDB, Snappy. Boost is not an aggregate archive;
include its headers/notices only where the public Core header interface needs
them. Source licenses and other external public headers must be discovered
from actual inputs, not inferred solely from component names.

Inspect each Mach-O member's external definitions. Reject duplicate strong
definitions. Classify every repeated weak/coalesced definition with defining
member identities, actual symbol flags, and an evidence-bound reason for valid
Apple linker coalescing. Unclassified repetitions fail closed. Preserve the
member-table ordinal and payload checksum. Canonical basenames follow
`NN-component-slug--NNNN-original-member-name`; normalize unsafe suffixes and
reject collisions. Byte-sort canonical names with `LC_ALL=C`, then invoke
Apple `/usr/bin/libtool -static -D -filelist`. Regenerate archive TOC.

Construct two fresh aggregate containers from the same validated inputs and
require identical SHA-256. This verifies the ADR container algorithm, not
Phase 8's two full clean source/dependency/Core/package rebuilds.

Independently verify aggregate member identities/count, ARM64, deployment,
TOC, symbols, component mapping, and forbidden embedded build paths. Stage
headers preserving include hierarchy, including deterministic generated
headers and required external header closure. Fail on missing license notices.

## Consumer and publication

Compile a real C++20 consumer against a relocated copy of `Dist` only, link
the aggregate (including a force-load proof), explicitly link SDK Iconv and
use implicit libc++/libSystem. Verify pinned Core identity at runtime and
inspect actual load commands. Verify public header closure without reaching
back to Source, Dependencies, Build, or Homebrew.

Build a candidate privately and validate before replacing `Dist`. Refuse
unsafe output targets; failures preserve an existing accepted distribution.
Reruns must have identical published file inventory and content hashes.
No broad cleanup or mutation of accepted Phase 6 artifacts is authorized.

## Gate 7

- All ordered ingredients are bound to accepted pins/checksums and policy.
- Collision/coalescing decisions and complete member mapping are recorded.
- Two aggregate constructions have identical hashes.
- Headers, aggregate, metadata, checksums, and notices are complete.
- A relocated Dist-only consumer compiles, links, runs, and matches the
  documented system-link boundary without project/Homebrew reach-back.
- Negative tests reject drift, collisions, incomplete packages, checksum
  failures, and unsafe publication without destroying an existing package.
- Focused tests, regression tests, independent review, and the Gate 7 report
  pass before local GitFlow integration.

Stop at Gate 7. Phase 8 owns independent full clean-build comparisons,
minimum-OS runtime proof, release rehearsal, tagging, and release readiness.
No push, remote publication, Objective-C++, SwiftPM, AppKit, or app work.
