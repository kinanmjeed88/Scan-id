# Architecture Decision Records — Scan ID

Index of ADRs governing the Smart Recognition + deterministic A4 layout work.
Each ADR is a binding architectural contract for later implementation phases.
Phase 0 records decisions only; no production code, schema, dependency, OCR, ML,
or UI changes are made here.

| ADR | Title | Status |
|---|---|---|
| [ADR-001](ADR-001.md) | Sembast remains the persistence layer (no Isar) | Accepted |
| [ADR-002](ADR-002.md) | Deterministic A4 layout is the sole placement authority | Accepted |
| [ADR-003](ADR-003.md) | Source images are immutable; derived assets are separate | Accepted |
| [ADR-004](ADR-004.md) | Recognition state is separated from user overrides | Accepted |
| [ADR-005](ADR-005.md) | Offline-first recognition (no cloud, no runtime model download) | Accepted |
| [ADR-006](ADR-006.md) | Classical CV retained and extended before any learned detector | Accepted |
| [ADR-007](ADR-007.md) | OCR is evidence, not the sole classifier | Accepted |
| [ADR-008](ADR-008.md) | Multi-document recognition entity chain | Accepted |
| [ADR-009](ADR-009.md) | Worker abstraction: bounded concurrency, progress, cancellation | Accepted |
| [ADR-010](ADR-010.md) | Explicit schema migration before recognition metadata is persisted | Accepted |
| [ADR-011](ADR-011.md) | Persistence schema version becomes 5 | Accepted (decision); implementation deferred to Phase 1 (Gate 1) |

Baseline for all ADRs: `docs/AUDIT.md`. Prior audit history: `docs/AUDIT_HISTORY.md`.
