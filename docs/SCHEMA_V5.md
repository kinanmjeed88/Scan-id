# Scan ID — Schema v5 Domain & Persistence Design (Phase 1A)

- **Date:** 2026-10-08
- **Status:** DESIGN / CONTRACT ONLY. No production code, schema, dependency,
  migration, feature-flag code, or test changes in Phase 1A.
- **Baseline:** `14a3ee7b46ad6b1c0a5bdb912765e232dfb3ec33` (+ Phase 0 docs).
- **Governs:** ADR-001…ADR-011 (`docs/adr/`). Companion migration design:
  [`docs/MIGRATION_V5.md`](MIGRATION_V5.md).
- **Evidence basis:** current serialization read from `lib/domain/project.dart`,
  `document_kind.dart`, `geometry.dart`, `crop_draft.dart`,
  `image_adjustments.dart`; legacy shapes read from
  `test/persistence/legacy_schema_test.dart` and `test/legacy_schemas/v1…v3c`.
  Nothing below is guessed; every "existing field" is quoted from source.

---

## 0. Design decisions (summary)

1. **Storage strategy: hybrid** (see §2). A new **parallel `DocumentRecord`**
   holds recognition truth + provenance + processed-asset references;
   **`DocumentItem` is extended** (not replaced) for layout/effective values;
   a **separate `UserOverride`** captures only recognition-level user decisions;
   **`DocumentSizeCatalog` is extended** with variants. No existing field is
   duplicated.
2. **One sembast record per project** (unchanged). New entities live inside the
   same `Project` JSON (`documents`, `layoutGroups`, extended `catalog`,
   extended `DocumentItem`), keeping the atomic single-record save and the
   whole-folder `.scanid` backup intact. No second store.
3. **`schemaVersion` becomes 5** (ADR-011). All new fields are **optional with
   safe defaults**, so v4 records load unchanged and v5 records are rejected
   (not misread) by older readers.
4. **Transient vs persisted vs derived** is made explicit (§3). A detection
   candidate is transient; it becomes persisted only as a committed
   `DocumentRecord`. Processed-asset **files** are derived/regenerable; their
   **references** are persisted.

---

## 1. Existing serialization (verbatim, the thing we extend)

Current `Project.toJson()` keys (`schemaVersion=4`):
`schemaVersion, id, name, createdAt, updatedAt, revision, pageCount, paper,
layout, exportProfile, catalog, assets, items`.

| Object | Existing JSON keys |
|---|---|
| `paper` | `orientation, margins{top,right,bottom,left}` |
| `layout` | `horizontalGap, verticalGap, allowRotation, order, strategy` |
| `exportProfile` | `format, dpi, jpegQuality` |
| `catalog` | `residenceCard{width,height}, rationCard{width,height}` (National ID & Passport are code constants, not serialized) |
| `ImageAsset` | `id, captureId, name, originalPath, workingPath, thumbnailPath, width, height, crop, adjustments, transforms` |
| `ImageAsset.crop` (CropGeometry) | `corners[{x,y}×4], outputWidth, outputHeight` |
| `ImageAsset.adjustments` | `brightness, contrast, saturation, sharpness, quarterTurns` |
| `DocumentItem` | `id, assetId, pageIndex, x, y, width, height, rotation, zIndex, locked, keepAspectRatio, documentKind, recognitionConfidence, sizeConfirmed` |

**Do not re-add or rename any of these.** v5 only *adds* optional keys.

---

## 2. Inline vs parallel storage — decision

Compared across the required axes:

| Axis | A. Inline on `DocumentItem` | B. Parallel `DocumentRecord` | Verdict |
|---|---|---|---|
| JSON size | smallest per item | one record + thin item refs | B acceptable (recognition is sparse) |
| Object lifecycle | tied to item delete | independent (review before commit) | **B** (transient detection ≠ permanent until committed) |
| Migration complexity | synthesize fields in place | synthesize a record | B, and gives v4 `recognitionConfidence` a clean home |
| Backup/restore | trivial | records travel inside project JSON | B (same record) |
| Deletion / orphan prevention | simpler | needs ref-counting for processed files | B with explicit ref policy (§MIGRATION) |
| Future schema evolution | bloats `DocumentItem` | additive records | **B** |
| Multi-document source→N | awkward (N items must each carry full recognition+2 sides) | **N records**, N thin items | **B** |
| Provenance | no clean home | dedicated `Provenance` | **B** |
| User overrides | would erase AI (the current anti-pattern) | separate layer | **B** |
| Deterministic serialization | fine | fine (versions only; no clocks in persisted AI) | tie |
| Testability | coupled to editor | testable in isolation | **B** |

**Chosen: B (parallel `DocumentRecord`), with `DocumentItem` extended by thin
optional references.** This keeps `DocumentItem` the single layout truth (editor,
export, packing, `PageLayout` all unchanged for manual items) while recognition
truth, evidence, versions and provenance live in a separate, testable record.
Recognition-level user decisions live in a separate `UserOverride` so they never
erase AI evidence (ADR-004).

---

## 3. Entity relationships and state classes

```
ImageAsset (SourceImage, persisted, existing)
   │  one source may seed many detections (transient candidates)
   ▼
DetectedDocument (TRANSIENT detection candidate — NOT persisted by default)
   │  committed on user accept / batch commit
   ▼
DocumentRecord (DocumentInstance, PERSISTED, new)  ── pairs ──▶ DocumentRecord
   │  has 1–2 sides
   ▼
DocumentSide (PERSISTED, new: front/back/unknown)
   │  references
   ▼
ProcessedAssetRef (DERIVED file reference, PERSISTED; the FILE is regenerable cache)
   │  represented on the sheet by
   ▼
DocumentItem (DocumentLayoutItem, PERSISTED, existing — extended with thin refs)
   │  grouped by
   ▼
LayoutGroup (PERSISTED, new — generic keep-together; engine stays AI-agnostic)
```

**State classes:**
- **Persisted project state:** `ImageAsset`, `DocumentRecord`, `DocumentSide`,
  `ProcessedAssetRef` (the *reference*), `DocumentItem`, `LayoutGroup`,
  `UserOverride`, catalog variants, preset snapshots, provenance.
- **Transient processing state:** `DetectedDocument` candidates, stage progress,
  worker messages, in-flight OCR tensors. **Never auto-persisted.**
- **Derived / cache state:** processed-asset image **files**, thumbnails, any
  intermediate rasters. Regenerable from `ImageAsset` + stored geometry/version;
  garbage-collectable when unreferenced; included in backups while referenced.

---

## 4. v5 JSON contract — added fields

Legend — **Src:** `R` recognition/AI · `D` deterministic · `U` user · `S`
system/migration. **Edit:** user-editable. **BC:** backward-compatible behavior
(all added keys optional; absent ⇒ default).

### 4.1 `Project` (additions; every key optional, default shown)

| Field | Type | Req | Default | Owner | Meaning | BC when absent | Edit | Src |
|---|---|---|---|---|---|---|---|---|
| `documents` | `List<DocumentRecord>` | opt | `[]` | app | recognition entities | no recognition; behaves as v4 | no | R/D |
| `layoutGroups` | `List<LayoutGroup>` | opt | `[]` | app | keep-together groups | no groups | no | D |
| `catalog.variants` | `List<PresetVariant>` | opt | `[]` | user | extra preset variants per type | only the 4 built-in sizes | yes | U/D |
| `schemaVersion` | int | req | `5` | system | on-disk version | v5 writers emit 5 | no | S |

> Existing keys (`paper, layout, exportProfile, catalog.residenceCard/rationCard,
> assets, items, …`) are **unchanged**.

### 4.2 `DocumentItem` (additions; all optional)

| Field | Type | Req | Default | Meaning | BC when absent | Edit | Src |
|---|---|---|---|---|---|---|---|
| `documentId` | String? | opt | `null` | links to a `DocumentRecord` (recognition item) | manual/legacy item; render from `assetId.workingPath` | no (set by pipeline) | R |
| `sideId` | String? | opt | `null` | which side of the instance this item shows | n/a | no | R |
| `presetSnapshot` | `{variantId, widthMm, heightMm, status}`? | opt | `null` | frozen preset at processing time | manual size on the item | via override | R→U |
| `groupId` | String? | opt | `null` | keep-together membership | ungrouped | no | D |
| `reviewState` | enum? (`awaitingReview, ready, dismissed`) | opt | `null` | review queue state | derived from confidences | yes | D/U |

> **No duplication:** position/size/rotation/lock/page/inclusion stay **only** on
> `DocumentItem` (they already are the user's layout decisions). Recognition-level
> overrides go to `UserOverride` (§4.8), never re-copied here.

### 4.3 `DocumentRecord` (new; = DocumentInstance)

| Field | Type | Req | Default | Meaning | Edit | Src |
|---|---|---|---|---|---|---|
| `id` | String | req | — | stable instance id | no | S |
| `sourceImageId` | String | req | — | → `ImageAsset.id` | no | R |
| `sides` | `List<DocumentSide>` (1–2) | req | — | front/back | no | R |
| `recognition` | `RecognitionResult?` | opt | `null` | fused AI result + evidence | no | R |
| `pairing` | `{state, confidence, candidateIds?}` | opt | `{state:single}` | front/back pairing | via override | R |
| `provenance` | `Provenance` | req | — | chain + versions | no | R/D |
| `overrides` | `UserOverride?` | opt | `null` | recognition-level user decisions | yes | U |

`pairing.state ∈ {single, paired, uncertain}`. `paired` requires the group; 
`uncertain` ⇒ review (never silently paired). Same `documentKind` alone never 
implies pairing (ADR-008).

### 4.4 `DocumentSide` (new)

| Field | Type | Req | Meaning | Src |
|---|---|---|---|---|
| `id` | String | req | stable side id | S |
| `side` | enum `front\|back\|unknown` | req | which face | R |
| `processedAsset` | `ProcessedAssetRef` | req | rectified image ref | R |
| `detection` | `DetectionRef` | req | which detection produced it | R |
| `ocrEvidence` | `OcrEvidence?` | opt | per-side OCR anchors/structure (no text) | R |

### 4.5 `ProcessedAssetRef` (new; reference to a DERIVED file)

| Field | Type | Req | Meaning | Src |
|---|---|---|---|---|
| `workingPath` | String | req | derived rectified PNG (under `…/processed/<procId>/working.png`) | R |
| `thumbnailPath` | String | req | derived thumbnail | R |
| `width`,`height` | int | req | output pixels | R |
| `corners` | `CropGeometry.corners` shape | req | source-space corners used | R |
| `outputWidth`,`outputHeight` | int | req | rectified size | R |
| `effectiveDpi` | int? | opt | DPI at physical size (flagged if low) | D |
| `orientation` | int | req | quarter-turns applied to the asset | R |
| `processingVersion` | String | req | pipeline version that produced it | R |

> Mirrors `ImageAsset`'s derived `working/thumb` pattern and `LocalImageEditor`
> `edits/<id>` layout; **regenerable** from source + corners + version. Multiple
> sides/detections use distinct `<procId>` so they never overwrite each other.

### 4.6 `DetectionRef` (new; provenance of one detection)

| Field | Type | Req | Meaning | Src |
|---|---|---|---|---|
| `detectionId` | String | req | stable detection id (transient id, frozen here on commit) | R |
| `polygon` | `List<{x,y}>` | req | source-normalized polygon | R |
| `bbox` | `{x,y,w,h}` | req | source-normalized box | D |
| `detectionConfidence` | `Confidence` | req | detection score + producer/version | R |
| `producer`,`version` | String | req | detector id + version | R |

### 4.7 `RecognitionResult` + confidence model (new)

Replaces the single scalar `recognitionConfidence` **for new records**; the
scalar’s migration meaning is defined in `MIGRATION_V5.md §4`.

| Field | Type | Req | Meaning | Src |
|---|---|---|---|---|
| `documentKind` | enum | req | winning candidate (may be `unknown`) | R |
| `status` | enum `recognized\|unknown\|uncertain` | req | outcome | D |
| `confidences` | `ConfidenceSet` | req | the five(+final) scores | R |
| `evidence` | `List<Evidence>` | req | per-source scores + reasons (no text) | R |
| `preset` | `PresetSelection` | req | chosen variant / `awaitingSize` | R |
| `pipelineVersion` | String | req | recognition pipeline version | R |
| `modelVersions` | `{detector, ocr?, classifier}` | req | producer versions | R |
| `validated` | bool | req (`false`) | Tier-B calibration status (provisional until calibrated) | S |

`ConfidenceSet` = `{detection, geometry, ocr, classification, preset, final}`,
each a `Confidence`:

| `Confidence` field | Type | Req | Meaning |
|---|---|---|---|
| `value` | double `0..1` | req | score (**never invented**; absent source ⇒ field omitted, not 0) |
| `reason` | String? | opt | short human/audit reason |
| `producer` | String? | opt | which stage/model |
| `version` | String? | opt | producer version |

`Evidence` = `{source (visual\|ocr\|geometry\|structure\|aspect), kind, score,
reason}`. **No OCR text and no personal field values are ever stored.**

`PresetSelection` = `{variantId, confidence}` **or** `{awaitingSize:true,
candidates:[variantId]}`.

### 4.8 `UserOverride` (new; separate from recognition — ADR-004)

Recognition-level only. Layout-level user edits remain on `DocumentItem`.

| Field | Type | Meaning |
|---|---|---|
| `documentKind` | enum? | user-selected type |
| `presetVariantId` | String? | user-selected preset variant |
| `corners` | `CropGeometry.corners`? | user-confirmed geometry |
| `side` | enum? | user-confirmed side |
| `pairing` | enum? | user-confirmed pairing (`paired`/`split`) |
| `dismissed` | bool | user dismissed recognition for this instance |
| `fields` | `List<String>` | which of the above are overridden (audit) |

**Precedence (computed, not stored as copies):**
`UserOverride` ▸ validated user confirmation ▸ high-confidence recognition ▸
lower-confidence recognition ▸ `unknown`. The **underlying `recognition` is never
erased**; effective values are derived. This directly replaces today’s
`DocumentEdits.setKind → recognitionConfidence:0` behavior for recognition items.

### 4.9 Preset model (extend `DocumentSizeCatalog`; do not duplicate)

`PresetVariant`:

| Field | Type | Meaning | Src |
|---|---|---|---|
| `id` | String | stable variant id | S |
| `typeId` | `DocumentKind` | owning type | U |
| `labelAr`,`labelEn` | String | display | U |
| `widthMm`,`heightMm` | double | dimensions | U |
| `status` | enum `standard\|measured\|estimated\|user` | provenance of the size | U |
| `enabled` | bool | selectable | U |
| `isDefaultForType` | bool | default when evidence doesn’t discriminate | U |

Built-in sizes remain **exactly**: National ID `85.6 × 53.98` (`standard`,
ISO/IEC 7810 ID-1); Passport `125 × 88` (`standard`, ICAO TD3); Residence
`≈ 92.4 × 62.8` (`estimated`/editable default); Ration `≈ 52 × 287`
(`estimated`/editable default). Estimated sizes are **never** labeled official
(`status` carries this; UI shows «تقديري»).

**Per-item preset snapshot** (`DocumentItem.presetSnapshot`): freezes
`{variantId,widthMm,heightMm,status}` at processing time, so a later catalog
edit does **not** silently resize an already-processed document; re-applying an
updated preset is an explicit user action (mirrors the existing catalog-edit
behavior, now scoped by snapshot).

### 4.10 `LayoutGroup` (new; generic keep-together — ADR-002)

| Field | Type | Meaning | Src |
|---|---|---|---|
| `id` | String | stable group id | S |
| `itemIds` | `List<String>` | member `DocumentItem` ids (a front/back pair) | D |
| `arrangement` | enum `stacked\|sideBySide` | owner-chosen pair layout (Appendix A.5) | U |
| `keepTogether` | bool (`true`) | constraint flag the engine evaluates | D |

The engine learns only “these item ids must stay together”; it never learns
what a pair/type is.

### 4.11 `Provenance` (new; compact, no document contents)

| Field | Type | Answers |
|---|---|---|
| `sourceImageId` | String | which source produced this |
| `detectionIds` | `List<String>` | which detection(s) |
| `processedAssetVersion` | String | which processing op/version made the asset |
| `pipelineVersion`,`modelVersions` | String/map | which recognition pipeline/models |
| `presetVariantId` | String? | which preset was selected |
| `overrideFields` | `List<String>` | which user overrides occurred |
| `layoutItemIds` | `List<String>` | which layout items represent the result |

### 4.12 Feature flag (not in the project schema)

The Smart Recognition flag is an **app-level preference** (off by default),
**not** a project field. The project schema stores only *whether recognition was
applied* (presence of `documents`), never the flag. Rationale: keeps legacy
projects byte-compatible and avoids a per-project flag branching the whole app;
rollout stays a single app preference read at the call site.

---

## 5. Serialization invariants (v5)

- IDs stable; `DocumentRecord.id`, `DocumentSide.id`, `LayoutGroup.id` unique.
- Every `DocumentRecord.sourceImageId` resolves to an `ImageAsset.id`.
- Every `DocumentItem.documentId` (when non-null) resolves to a
  `DocumentRecord.id`; `sideId` resolves within that record.
- Every `ProcessedAssetRef` path is app-owned, under the source asset prefix
  (`validAssetPath`, symlink-safe via `SafeFiles`).
- No duplicate ids across `assets`, `items`, `documents`, `sides`, `groups`.
- No dangling **required** references (validated on load/save).
- `DocumentItem.pageIndex` semantics unchanged (`null` ⇒ off-sheet).
- Existing position/size/rotation/lock/pageIndex survive migration untouched.
- Unknown **future** fields: ignored on read (forward-compatible), preserved is
  **not** guaranteed (v5 is authoritative on write) — consistent with the current
  strict-reader policy for unknown *schema versions* (reject) vs unknown *fields*
  (the current `fromJson` ignores extra keys).
- Deterministic JSON: persisted recognition carries **versions, not clocks**;
  `toJson()` is stable (required by `legacy_schema_test`’s round-trip equality).

---

## 6. Existing behavior v5 MUST preserve (no change merely because recognition exists)

original image (immutable bytes) · working image · thumbnail · crop ·
perspective · adjustments · transforms log · document position · dimensions ·
rotation · lock state · `pageIndex` · manual editing · undo (session
`EditHistory`) · export (PDF/PNG/JPG/print/share) · backup/restore (`.scanid`) ·
existing auto-intake (`arrangeImportedImages`, filename+aspect) · existing
deterministic arrangement (`arrangeDocuments`/`proposePacking`).

When the flag is **OFF**, the import path is byte-for-byte the current behavior
(no `DocumentRecord` is created; `DocumentItem` uses only existing fields).

---

## 7. Phase 1A verification checklist (self-check)

1. Entity relationships re-read: transient `DetectedDocument` is not persisted;
   committed state is `DocumentRecord`/`DocumentSide`/`DocumentItem`/`LayoutGroup`. ✔
2. No duplicate source of truth: layout facts only on `DocumentItem`; AI facts
   only in `DocumentRecord`; recognition-level overrides only in `UserOverride`;
   preset sizes only in the catalog (+ per-item snapshot). ✔
3. Every v5 field checked against existing models (no rename/re-add). ✔
4. Legacy fields mapped to preservation requirements (see `MIGRATION_V5.md`). ✔
5. Backup/restore compatibility traced (records inside the single project JSON;
   derived files inside the project folder). ✔
6. Multi-document source→N representable (N `DocumentRecord`, N `DocumentItem`
   sharing `sourceImageId`, distinct `procId`). ✔
7. Override does not destroy recognition evidence (separate layer; effective
   value derived). ✔
8. Preset snapshot prevents silent catalog-driven resize of processed docs. ✔
9. Flag OFF ⇒ current behavior untouched (flag is app-level; schema stores only
   “recognition applied”). ✔
10. No production code changed in Phase 1A. ✔

**Open items deferred to Gate 1 (design refinement, not blocking this contract):**
exact enum string spellings; whether `reviewState` is persisted or derived;
bounding `documents`/`groups` counts under `maxProjectItems`.
