# Architecture decision records

This directory holds evidence-backed decisions that become necessary during implementation, especially the final static distribution shape and optional-feature policy.

Decision records use `NNNN-short-title.md` and contain status, context, evidence, decision, consequences, and superseded records. The authoritative design remains [the design spec](../superpowers/specs/2026-09-04-airdc-core-macos-design.md); a decision record may resolve one of its explicit open questions but may not silently change project scope.

Accepted records:

- [ADR 0001: Aggregate static distribution](0001-aggregate-static-distribution.md) — publish one future ARM64 aggregate archive while retaining per-component provenance and external Apple system-link metadata.
