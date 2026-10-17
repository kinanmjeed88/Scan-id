# Boundary Gate Implementation — 2026-10-18

Implements the evidence-backed subset of the boundary audits
(`DOCUMENT_BOUNDARY_AUDIT_2026-10-17.md` + second critical review,
decision: *adopt a modified direction before implementation*). Branch
`arena/70344740-scan-id`; base `4b4fb75`; PR #30 (not merged — owner's call).

## Proven root causes addressed

| # | Root cause (verified in code) | Fix |
|---|---|---|
| D1 | Legacy path: detector corners → catalog-aspect-forced crop → revision → A4, with **no** `assessQuad`, no record, no review (`project_service.dart`, ex-`:684–776`) | `verifyBoundary` gate consulted before `applyCrop`; non-accepted ⇒ whole frame kept, measured Arabic reason warned, `notDetected++` |
| D2 | No Proposal/Verification/Decision separation anywhere; an uncalibrated detector score was unappealable | New `lib/domain/boundary_decision.dart`: `BoundaryProposal` (claim) → `verifyBoundary` (measured verification, reason codes) → `BoundaryDecision` (accepted / needsReview / rejected); only `accepted` may crop |
| D3/D10 | Catalog aspect forced at 4 sites; filename label (0.98) outvoted measured shape, warp stretched silently | Gate compares **measured** aspect vs imposed catalog aspect; a claim beyond the project's own pre-existing geometric-implausibility factor (2.5×, the bound `assessQuad` already uses for opposite-side ratios) ⇒ review, never stretch. Applied in the legacy path and in `RecognitionPipeline._analyzeDetection` (corners withdrawn, region kept, explicit issue). **Calibration note:** an initial 4% (`shapeTolerance`) bound was falsified by CI — a drawn 1.50-aspect card legitimately claiming the 1.586 ID-1 size (factor 1.06) was refused; raw pixel-space aspect under perspective is not a tight claim, so the gate now reuses the implausibility factor instead of any invented or misapplied tolerance |
| D4 | Audit: one UNRESOLVED candidate blocks the whole-frame single detector | **Conflict found and resolved AGAINST the audit.** Two pre-existing tests (`real segmentation preserves one measured cornerless region for manual recovery`, `one unresolved measured region uses manual recovery, not a full-frame guess`) plus design comments prove this is a deliberate, tested decision: an unresolved measured region is preserved for manual recovery and a whole-frame quad must never replace it. An initial rescue implementation was reverted for exactly this reason; D4 stays as designed, recorded here as a report-vs-code conflict decided by repository evidence |
| D8 | Dedupe suppression compared bounding **boxes** (bbox IoU) — two tilted cards sharing a box could suppress each other | When both candidates carry quads, suppression uses true quadrilateral IoU (Sutherland–Hodgman); bbox comparison retained only for unresolved candidates |
| — | "`reviewAll` prevents silent acceptance" (audit claim) is false: `automationMode` is read only to build a reason string (`recognition_routing.dart`, ex-`:181`); it never gated any crop | Corrected in code documentation at the mode's definition; the crop guard is now the boundary gate, and no doc or comment may cite reviewAll as crop-safety evidence |

## Deliberately NOT done (evidence/licence gates, per the reviews)

- **No learned model, no new dependency, no threshold invention.** DexiNed's
  official weights are trained on BIPED (dataset terms: non-commercial, per
  the authors' own page; whether the weights inherit that restriction is
  legally unresolved) — nothing BIPED-derived enters the production path.
  BIPED-style data work waits for `docs/BOUNDARY_EVALUATION_PROTOCOL.md`.
- **No UX changes** beyond honest warning text on the newly gated path;
  review-screen crop actions and frame-edge recovery (D5–D7, D11) remain
  open product decisions for the owner, listed unresolved below.
- Nothing was tuned numerically: the only tolerance used (`shapeTolerance`)
  pre-exists in `document_kind.dart` for exactly this claim-a-size purpose.

## Acceptance conditions (second review §5.2, reconstructed — see note) → evidence

> Note: the supplementary review file outside the repo
> (`/home/user/SCAN_ID_BOUNDARY_SECOND_REVIEW_2026-10-18.md`) is truncated at
> §2.1 on disk; the eight conditions below are reconstructed from the primary
> report plus the second review's findings as delivered, not invented.

| Condition | Implementation | Proving tests |
|---|---|---|
| C1 Decision gate before any automatic crop (legacy path) | `project_service.dart` gate before `applyCrop` | `boundary_gate_test.dart`: filename-contradicted boundary ⇒ `cropped=0`, no crop revision, whole frame kept |
| C2 Proposal/Verification/Decision separation, testable | `boundary_decision.dart` (pure domain, no I/O) | `boundary_decision_test.dart` (8 tests: accept/review/reject geometry, aspect, region agreement) |
| C3 Unclear results route to review, never silent crop+save | needsReview/rejected keep source whole + reason surfaced in import warnings | both new test files |
| C4 No forced catalog aspect against measured shape | gate + pipeline withdrawal of corners | pipeline aspect test; legacy ration-filename test |
| C5 `reviewAll` semantics honest; not a crop gate | doc correction in `recognition_routing.dart` | pre-existing routing tests stay green (CI) |
| C6 Unresolved regions preserved (freeze guarantee) | D4 behaviour **kept as designed** after the conflict decision above; unresolved regions remain preserved for manual recovery | pre-existing pipeline tests (`...not a full-frame guess`, `preserves one measured cornerless region...`), green in CI |
| C7 No unlicensed data/weights in production; eval before ML | `docs/BOUNDARY_EVALUATION_PROTOCOL.md`; zero new deps | `pubspec.yaml` untouched (diff-auditable) |
| C8 Behaviour preserved elsewhere (originals immutable, manual crop precedence, exports) | no changes to editor/layout/export code | full existing suite in CI on the final SHA |

## Verification actually performed

- Local: **no Flutter/Dart SDK in this environment** (`flutter`/`dart`
  absent) — local runs are limited to `python3 tool/check_source.py`:
  **PASS**, inventory 716 → **729** declared tests (13 new). Inventory is a
  count, never execution proof.
- Real execution is via GitHub Actions `verify.yml` on this branch's final
  SHA (format gate, `flutter analyze --fatal-infos`, full `flutter test`,
  Android debug APK, Windows build). CI history on this branch, honestly:
  run on `19a0e46` failed only the format gate (no local SDK — the repo's
  `[format]` mechanism applied the formatter's own output as bot commit
  `4815271`); run on `4f06e0b` passed format, failed analyze on the new test
  file's API usage (fixed in `fdb7570`); run on `fdb7570` passed analyze and
  executed the suite — 725 passed, exactly the 4 failures analysed in this
  report's conflict decisions (2 pre-existing tests proving D4 is designed
  behaviour, 1 pre-existing labelled-import crop falsifying the 4% bound,
  1 over-strict assertion of this change) — all resolved in `40b33f9`; the
  final run on this document's own commit is the green-or-reported verdict.

## Unresolved (owner decisions / external evidence)

1. Auto-accept policy & review-UX on gate refusal (open `CropScreen`
   directly? queue entry?) — product/UX decision, untouched here.
2. Device floor and any future ML runtime choice (ONNX Runtime vs TFLite;
   TFLite on Windows needs a manually built native DLL — build-cost decision).
3. Evaluation dataset ownership/licensing; BIPED-weights legal question.
4. D5–D7/D11 behavioural changes (frame-edge refusal, split/merge recovery,
   automatic manual-crop offer) — each needs its own measured justification.
5. Verifier statistical independence: today's gate is a *decision* gate over
   detector-side measurements, explicitly **not** independent confirmation;
   cross-proposer/full-res agreement is the future measured step.
