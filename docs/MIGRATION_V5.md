# Scan ID — Schema v5 Migration, Backup & Lifecycle Design (Phase 1A)

- **Date:** 2026-10-08
- **Status:** DESIGN ONLY. **Gate 1 Design Lock applied** (§4 legacy-confidence
  semantics, §9 snapshot mechanism). No migration code, no tests, no production
  changes.
- **Governs:** ADR-010 (explicit migration), ADR-011 (schemaVersion = 5),
  [`docs/SCHEMA_V5.md`](SCHEMA_V5.md).
- **Evidence basis:** `lib/persistence/local_project_repository.dart` (sembast,
  optimistic `revision`, `RecoveryCheckpoints`, explicit `recover`),
  `lib/persistence/local_project_backups.dart` (`.scanid`),
  `lib/persistence/local_storage_maintenance.dart`, and the legacy ladder in
  `test/persistence/legacy_schema_test.dart` + `test/legacy_schemas/v1…v3c`.

---

## 1. Confirmed on-disk version ladder (from fixtures, not guessed)

| Ver | Added on-disk fields (vs previous) | Source |
|---|---|---|
| v1 `1c68dbc` | base: `Project{id,name,createdAt,updatedAt,revision,paper,layout,exportProfile,assets,items}`; `ImageAsset{…crop,transforms}` (no `adjustments`, no `captureId`); `DocumentItem{…no pageIndex, no documentKind/recognitionConfidence/sizeConfirmed}`; `layout{…no strategy}` | `legacy_schemas/v1_1c68dbc/project.dart` |
| v2 `cd58739` | `ImageAsset.adjustments{brightness,contrast,saturation,sharpness,quarterTurns}` | `v2_cd58739` |
| v3a `478e098` | `Project.pageCount`; `DocumentItem.pageIndex` (nullable) | `v3a_478e098` |
| v3b `90de23c` | `ImageAsset.captureId` | `v3b_90de23c` |
| v3c `64d146e` | `DocumentItem.documentKind, recognitionConfidence, sizeConfirmed` | `v3c_64d146e` |
| v4 (current) | `Project.catalog` (`DocumentSizeCatalog`); `layout.strategy`; semantic: `sizeConfirmed=false ⇒ pageIndex forced null` (off-sheet) | `lib/domain/project.dart` |
| **v5 (this design)** | `Project.documents, layoutGroups, catalog.variants`; `DocumentItem.documentId, sideId, presetSnapshot, groupId` (`reviewState` is derived, not stored) | SCHEMA_V5.md |

All five stored formats share `schemaVersion` integers `{1,2,3,3,3}`; the
lettered v3 variants are distinguished by field presence, not by the integer
(`legacy_schema_test.dart` header states this explicitly).

---

## 2. Migration procedure (invariant contract)

Mirrors and tightens the behavior `legacy_schema_test.dart` already proves
(“opening never rewrites; save upgrades; old reader rejects; image files
untouched”). The v5 upgrade adds an explicit snapshot + synthesized records.

1. **Read (never mutate).** Opening a record with `schemaVersion ∈ {1,2,3,4}`
   parses it through the compatibility reader with per-version defaults. The
   stored bytes are **not** rewritten on open (existing guarantee; re-asserted
   by test).
2. **Trigger.** Upgrade happens **only** on an explicit save / upgrade action —
   never implicitly on open.
3. **Pre-upgrade snapshot.** Before the first v5 write of a record read as ≤4,
   persist the **raw old JSON** as a pre-upgrade snapshot (a dedicated entry
   aligned with the existing `RecoveryCheckpoints` design) so the exact prior
   bytes are recoverable.
4. **Transform (deterministic).** Copy every preserved field verbatim; add new
   optional fields with their defaults; synthesize `DocumentRecord`s per §4.
   No timestamps/randomness enter the transform.
5. **Validate.** Fully validate the resulting v5 record against every
   SCHEMA_V5 §5 invariant; any violation aborts before write.
6. **Atomic replace.** Write inside the existing sembast transaction (optimistic
   `revision` check ⇒ `put` new JSON). The transaction is the atomic boundary;
   the pre-upgrade snapshot (§3) is the rollback source.
7. **Recover.** Any failure before the commit leaves the original intact and the
   snapshot restorable. After commit, a v4 reader must **reject** the v5 record
   with a clear message (never misread) — symmetric with today’s schema-4 rule.
8. **Idempotent.** Re-running the upgrade on an already-v5 record
   (`schemaVersion==5`, items already linked) is a no-op.

---

## 3. Migration matrix (v1…v4 → v5)

For each source: **action**, **preserved**, **added (defaults)**,
**validation**, **failure behavior**. “Preserved” always includes every SCHEMA_V5
§6 field (position, size, rotation, lock, `pageIndex`, crop, adjustments,
transforms, original/working/thumb, paper/layout/export, catalog).

| From | Action | Preserved | Added (defaults) | Validation | Failure behavior |
|---|---|---|---|---|---|
| v1 | read w/ defaults → v5 | all v1 fields verbatim | `adjustments`=neutral, `pageCount`=1, `pageIndex` per item, `captureId`=null, `documentKind`=unknown, `recognitionConfidence`=0, `sizeConfirmed`=false (⇒ off-sheet), `catalog`=defaults, `strategy`=ordered, `documents`=[], `groups`=[], item refs=null | full v5 invariants | abort; original + snapshot intact |
| v2 | + carry `adjustments` | v2 + adjustments | as v1 for the rest | same | same |
| v3a | + carry `pageCount`/`pageIndex` | v3a | as above for recognition/catalog | same | same |
| v3b | + carry `captureId` | v3b | as above | same | same |
| v3c | + carry `documentKind`/`recognitionConfidence`/`sizeConfirmed` | v3c | **synthesize `DocumentRecord`** per §4 for items with a recognition signal | same | same |
| v4 | carry `catalog`/`strategy` + sizeConfirmed semantic | v4 | **synthesize `DocumentRecord`** per §4 | same | same |
| v5→v5 | no-op (idempotent) | — | — | — | — |
| malformed / unknown-future / bad enum / bad geometry / dup id / dangling ref | **reject** with typed `ValidationException`; never silently downgrade or partial-write | — | — | — | safe refusal |

---

## 4. `recognitionConfidence` migration meaning (the single scalar → v5)

**Locked semantics (Gate 1, point 2).** The legacy scalar is the *only*
recognition state that exists pre-v5 (v3c/v4 inline triple `documentKind`,
`recognitionConfidence`, `sizeConfirmed`). Legacy Scan-id performed **no** modern
detection/geometry/OCR analysis, so the scalar may populate **only** the
confidence it actually represents, and the migrated record must identify itself
as legacy-imported.

Exact per-source-version interpretation of `recognitionConfidence`:

| Source | `recognitionConfidence` present? | Migrated to |
|---|---|---|
| v1, v2, v3a, v3b | absent (field did not exist) | n/a — no signal, no record synthesized |
| v3c, v4 | a double `0..1` from `suggestDocumentType` | `confidences.classification` **and** `confidences.final`, each `{value, reason:"legacy scalar (pre-v5)", producer:"suggestDocumentType", version:"legacy"}` |

- **`detection`, `geometry`, `ocr` confidences ⇒ ABSENT (null).** Legacy had no
  detector/geometry-scorer/OCR. They are **never fabricated as numeric zero** —
  an unavailable dimension is omitted from `ConfidenceSet`, per the AUDIT §F
  convention ("unavailable sources excluded, never zero").
- **`presetConfidence` ⇒ ABSENT** unless a preset stage actually scored it
  (legacy did not; the preset is resolved by kind, not scored).
- **Legacy-import provenance (required):** the synthesized record sets
  `provenance.importedFrom = {schema:<sourceVersion>, field:"recognitionConfidence",
  migrationVersion:"5"}` and `evidence: []`. This marks it as legacy-imported so
  it can never be mistaken for modern multi-source analysis.
- `validated = false` (never Tier-B calibrated).

On upgrade, for each `DocumentItem` with **no** `documentId`:

- **Has a recognition signal** (`documentKind != unknown` **or**
  `recognitionConfidence > 0`): synthesize a deterministic `DocumentRecord`
  - `id = "rec-<itemId>"`, `sourceImageId = item.assetId`.
  - one side `id="side-<itemId>"`, `side=unknown` (legacy never knew front/back),
    `processedAsset` → the asset’s **existing** working image
    (`workingPath`/`thumbnailPath`, `width`/`height`, `corners` from
    `asset.crop` if present, `orientation = adjustments.quarterTurns`,
    `processingVersion="legacy-v4"`). **No new file is created.**
  - `detection`: `detectionId=itemId`, polygon = crop corners (or full-frame
    box), `detectionConfidence` **omitted** (legacy had none — never invented).
  - `recognition`: `documentKind=item.documentKind`,
    `status = recognized iff documentKind != unknown`,
    `confidences.classification = {value: recognitionConfidence, reason:
    "legacy scalar (pre-v5)", producer:"suggestDocumentType", version:"legacy"}`,
    `confidences.final = ` same value; **`detection`/`geometry`/`ocr` absent**
    (unavailable ⇒ excluded, never zero); `presetConfidence` absent;
    `importedFrom` set as above; `validated=false`.
  - `preset`: if `documentKind` has a built-in size ⇒
    `{variantId:"builtin-<kind>", presetConfidence: absent}` else `awaitingSize`.
  - link `item.documentId/sideId`; set `item.presetSnapshot =
    {variantId:"builtin-<kind>"|null, widthMm:item.width, heightMm:item.height,
    status:<catalog status>}` (freezes the current size).
- **No signal** (`unknown` + `0`): leave as a pure manual item (`documentId` =
  null) — behaves exactly as today.

This is **deterministic** (ids derived from stable `itemId`), **idempotent**
(second pass sees `documentId != null` ⇒ skip), **non-destructive** (original +
snapshot preserved), and **never invents** a detection/geometry/OCR score.

---

## 5. Backup / restore participation (`.scanid`)

Existing format (traced from `local_project_backups.dart`): magic + 4-byte
big-endian manifest length + manifest JSON (≤16 MiB) + uncompressed payloads,
SHA256 per file, zip-slip/size/duplicate guards, restore as a **new** project id,
extract-to-temp then activate (a DB failure after rename keeps the new folder).

- **v5 backup** contains the project JSON (`schemaVersion=5`, including
  `documents`, `layoutGroups`, variants, snapshots) in the manifest, and every
  referenced derived file (originals, working, thumbnails, **processed assets**
  under `…/processed/<procId>/`) as payloads — they live inside the project
  folder, so the existing whole-folder inclusion already covers them.
- **Restore** validates the manifest + hashes, then opens through the **same**
  compatibility layer (`Project.fromJson` accepting 1–5). A v4 build restoring a
  v5 backup must **reject** it safely.
- **No partial restore becomes active** (existing temp→verify→activate).
- **Legacy backup compatibility stays explicit**: v1–v4 archives restore and
  open via the compatibility layer; models and OCR text are never in a backup
  (models are packaged, OCR text is never persisted).

---

## 6. Delete / orphan policy (v5 lifecycle)

Aligned with the existing rule “metadata first, files after; no automatic
destructive cleanup unless reference ownership is proven”
(`local_project_repository.remove` is metadata-only; `StorageMaintenance` GCs
proven orphans).

| Deletion | Rule |
|---|---|
| Source `ImageAsset` | refused while any `DocumentItem` **or** `DocumentRecord` references it (extends today’s “used inside the sheet” guard to recognition refs) |
| `DocumentRecord` | its `DocumentItem`s removed first (explicit), or cascade on explicit user action; its **exclusive** processed files become orphan-able |
| `DocumentSide` | removed with its record; its processed file orphan-able if not shared |
| Processed asset file | derived/cache; GC’d by `StorageMaintenance` once no `ProcessedAssetRef` references it; never auto-deleted without proven ownership |
| Cancelled batch | transient `DetectedDocument` candidates discarded; **no** partial `DocumentRecord` persisted (commit is per-source/instance, atomic) |
| Failed processing | source + any committed records untouched; failure recorded with a typed reason |

**Invariant:** after any delete, load/save validation (SCHEMA_V5 §5) guarantees
no dangling required references.

---

## 7. Migration test matrix (design only — not written in Phase 1A)

To be implemented in Phase 1B behind Gate 1. Each asserts the SCHEMA_V5 §6
preservation set and, where relevant, “image files never rewritten”.

- **Per legacy version** v1, v2, v3a, v3b, v3c, v4 → v5: opens, keeps data,
  upgrades on save, `schemaVersion==5`, round-trip equality
  (`fromJson(upgraded).toJson()==saved.toJson()`), old reader rejects, files
  untouched. (Extends the existing `legacy_schema_test.dart` loop.)
- **Synthesis**: a v3c/v4 item with a recognition signal yields exactly one
  `DocumentRecord` with the §4 confidences; a pure-manual item yields none;
  re-running the upgrade changes nothing (idempotent).
- **Malformed / missing / unknown fields / invalid enum / invalid geometry /
  invalid references / duplicate IDs** ⇒ typed rejection, no partial write.
- **Interrupted migration** (fault injected mid-transform) ⇒ original intact.
- **Failed temp write / failed validation / failed atomic replace** ⇒ original
  intact; snapshot restorable.
- **Repeated migration** ⇒ no-op.
- **backup → restore**, **restore → upgrade**, **upgrade → backup → restore**
  round-trips; v5 backup restored by a v4 reader is rejected.
- **Regression**: every pre-existing test stays green (no assertion weakened;
  no test moved).

---

## 8. Phase 1A self-check

1. Relationships re-read; transient detection never auto-persisted. ✔
2. No duplicate sources of truth. ✔
3. Every v5 field checked against existing models; no rename/re-add. ✔
4. Every legacy field mapped to a preservation requirement (§3). ✔
5. Backup/restore compatibility traced (§5). ✔
6. source→N documents representable. ✔
7. Override preserves recognition evidence (§4). ✔
8. Preset snapshot prevents silent catalog-driven resize. ✔
9. Flag OFF ⇒ current import path untouched (flag is app-level; §4/§6). ✔
10. Deterministic, idempotent, non-destructive, failure-safe migration contract
    stated (§2). ✔

**Risks carried to Gate 1 — now RESOLVED:** synthesized-record growth (bounded by
`maxProjectItems`, SCHEMA_V5 §8.4); pre-upgrade-snapshot key (§9 below); enum
spellings (canonical intent fixed; exact strings at implementation); bounding
`documents`/`layoutGroups` (reuse `maxProjectItems`).

---

## 9. Pre-upgrade snapshot mechanism (Gate 1, point 4)

- **Storage key/name:** `migration-snapshots/<projectId>.json` at the app storage
  root — a **separate namespace** from `checkpoints/`, so `RecoveryCheckpoints`
  `.read()`/`recover()` are unaffected and a snapshot is never mistaken for a
  committed recovery point. Written **before** the first v5 commit of a record
  whose stored `schemaVersion < Project.schemaVersion`.
- **Version metadata / content:** `{version:1, schemaVersion:<oldInt>,
  project:<raw old JSON, byte-faithful>}`. `version:1` is the snapshot-envelope
  version (independent of the project `schemaVersion` it carries).
- **Collision handling:** **write-if-absent.** If a snapshot already exists for
  the id, it is left untouched (the earliest pre-upgrade bytes win); the upgrade
  still proceeds. Atomic via temp file (`migration-snapshots/<id>-<rand>.tmp`) +
  rename, so a crash never leaves a half-written snapshot under the final name.
- **Deterministic behavior:** the snapshot is the *exact* prior record; the
  migration transform itself carries no timestamps/randomness (§2.4). The only
  nondeterminism is the temp-file suffix, which never affects the final name or
  content.
- **Failure-safe / recovery after interrupted migration:** the snapshot is
  written **inside** the save, before the atomic `put`. If the snapshot write
  **fails**, the migration write is **aborted** and the ≤4 record stays intact
  (no upgrade without a rollback point). If a fault occurs **after** the commit,
  the ≤4 bytes are restorable from the snapshot (rollback), independent of the
  normal `recover()` flow.
- **Cleanup after successful migration:** the snapshot is **retained** after a
  successful v5 write (it is the only rollback source to ≤4). Retention/expiry
  policy is a later design; v5 does not auto-delete it, and it is outside the
  `StorageMaintenance` orphan walk (root-level, not under `projects/`), so GC
  never removes it.

**Migration invariants (restated, ADR-010/011):** deterministic · idempotent
(v5→v5 is a no-op; synthesis gated on `documentId == null` and
`schemaVersion < 5`) · non-destructive (open never mutates; upgrade only on
explicit save, after the snapshot) · failure-safe (abort leaves the original
intact) · atomic from the app's point of view (single sembast transaction:
optimistic `revision` check ⇒ `put`).
