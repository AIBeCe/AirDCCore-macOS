# Phase 8 — independent verification and release rehearsal

Status: approved scope; implementation pending. Authority: the original design
spec sections 13, 14, 15, 16 (Gate 8), and 19. User authorized continuous Phase 8
execution and approved the path-independent publication identity correction.

## Boundary

Complete `scripts/verify`, scoped `scripts/clean`, two genuinely fresh
source/dependency/Core/package builds, rerun checks, independent review, and
an isolated GitFlow release rehearsal. Preserve all existing Phase 6/7 inputs
and published outputs. No application, ObjC++, SPM, signing or notarization.
No actual master branch, release tag, or public binary release is created by
the rehearsal. Production promotion is a separate decision after Gate 8.

## Approved identity correction

Phase 6 private evidence intentionally binds the absolute staging root. Keep
its input documents, fingerprints and validators unchanged. Publication must
instead bind a path-independent Core input identity. Recompute the private
version-authority digest from the authority document with only its validated
`staged_root` replaced by `$CORE_SOURCE`, then substitute that digest into a
copy of the validated Core input document and hash canonical bytes. Keep all
source/implementation/tool/Python identities and other authority fields bound.
The published Core fingerprint uses this digest; never copy the path-sensitive
private fingerprint into the public package. Schema 2 packaging policy pins
this normalized identity, preserving the exact Core archive SHA, compiler,
libtool, SDK, flags, definitions and upstream pin. Derive the new expected
digest from the preserved accepted inputs, never from an unverified rebuild.
Tests must prove relocation equality and reject non-path authority/input drift.
Old schema 1 packages/policy remain explicitly identifiable; do not weaken
verification by accepting arbitrary self-reported fingerprints or hashes.

## Verification and cleanup

`scripts/verify [DIST]` independently verifies the public package using the
existing complete structural/Mach-O/member/symbol/license/checksum checks and
a fresh relocated, network-denied consumer. It reads only public Dist plus
tracked authority and the declared toolchain/SDK. Nonzero errors are actionable.

`scripts/clean` removes only validated generated Build and Dist trees at its
own validated project root. It does not delete Source or Dependencies, modify
tracked files, or touch unrelated dirty source. Reject unsafe/symlinked roots
and generated top-level targets before any mutation. Avoid following nested
symlinks. Failure must not expand scope; tests use disposable fixtures only.

## Clean-build experiment

The opt-in Gate 8 driver creates two separately owned fresh tracked-only Git
checkouts under `/private/tmp`, with Source, Dependencies, Build and Dist absent.
Each independently acquires pinned upstream and locked dependency sources,
builds all dependencies, builds Core and the reproducible private consumer,
packages and independently verifies Dist. Do not share accepted prefixes,
build products or unvalidated source trees. Network is allowed for acquisition
only; retain existing compiler/consumer confinement. Capture command/status
evidence outside each project to avoid interfering with snapshot guards.

Each run repeats upstream/dependency acquisition and build/publication as
appropriate and proves no meaningful output drift. Compare exact full Dist
inventories/checksums between clean runs; do not accept semantic equality in
place of bytes without explicit approval. Preserve failure evidence and both
successful distributions. Report private path-sensitive fingerprints separately
from normalized published fingerprints. Bind receipts to implementation Git
commit, config/lock/pins, toolchain, aggregate and full package hashes.

## Release rehearsal and acceptance

On 2026-10-06 the user explicitly replaced original criterion 1 with:
"Two independent clean checkouts on a declared supported Xcode/macOS host
reconstruct exact source and dependency inputs from tracked configuration."
This is an acceptance-scope change, not evidence of a fresh physical machine.
The original design criterion is updated to the approved wording; the measured
same-host clean builds satisfy it. All other acceptance criteria remain unchanged.

Use a disposable local Git repository to exercise feature integration,
release-from-develop, first-master bootstrap, annotated version tag, and
merge-back. Confirm tag/master/release identity and develop reachability.
These are rehearsal refs only, not production output or authority to publish.

Map all fourteen original measurable criteria to evidence. Do not claim a
fresh physical machine or actual macOS 14 execution when only this host was
tested. Minimum deployment target is checked in every Mach-O object; supported
runtime claims are limited to the measured host. If an acceptance criterion
cannot be established, Gate 8 stays incomplete; record the exact limitation.
Independent review must PASS before feature integration. Existing authorization
covers normal GitFlow feature integration and push, but not release publication.
