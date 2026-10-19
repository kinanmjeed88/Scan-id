# Boundary Evaluation Protocol (pre-ML gate)

Status: **protocol only — no evaluation dataset exists in this repository yet,
and no learned model may enter the production path until this protocol is
satisfied.** Established by the boundary audits
(`docs/reports/DOCUMENT_BOUNDARY_AUDIT_2026-10-17.md`, second critical review
2026-10-18) as acceptance conditions 7–8. It exists so a future model — or a
future threshold — is judged by evidence instead of enthusiasm.

## Data rules (non-negotiable)

1. **Licensed or project-owned images only.** No real personal documents
   without ownership/licence/consent recorded per source. Public datasets
   enter only with their licence verified for this product's commercial use;
   unresolved-licence data (e.g. BIPED-trained weights, whose dataset terms
   are non-commercial per the dataset authors' own page) stays out of the
   production path until the licence question is resolved in writing.
2. **Split at scene/source level.** All crops, warps and exports derived from
   one photographed scene stay in the same split. Splitting derived images
   across train/test is leakage and invalidates the result.
3. **Double-reviewed ground truth.** Every evaluation boundary is annotated
   by two reviewers with a documented adjudication step for disagreements;
   single-pass labels are pilot material, not ground truth.
4. **Pilot ≠ proof.** ~30 images/class is a debugging pilot. Zero failures in
   30 trials still permits ~10% true failure at 95% confidence; no acceptance
   claim may be made from pilot numbers.

## What gets measured (separately, never as one blended score)

- **Proposer quality**: corner error distribution, split rate, merge rate,
  missed-document rate, false-document rate — per failure class.
- **Verifier/gate value**: silent-false-accept rate (the number that must be
  driven down), false-review rate, and the review burden each threshold buys.
  Because verification here re-uses detector-side measurements, it is **not**
  statistically independent evidence; agreement between two genuinely
  different proposers, full-resolution re-measurement, and set-level
  consistency are the stronger signals and are what a future study must add.
- **End-to-end**: accepted crops that a human judges wrong, documents forced
  to a wrong catalog size, truncated documents refused, frame-filling
  documents, glare/shadow/printed-inner-frame cases — each reported as its
  own class, never averaged away.
- Detector and verifier are always reported **separately** before any joint
  number is quoted.

## Standing regression guarantees (already encoded as tests; keep them green)

Originals are never modified; a rejected/unresolved boundary never becomes a
saved derivative; an automatic rerun never replaces a user-authored crop;
unresolved regions survive as region crops; the manual crop path stays
available for every image the gate refuses.

## Decision rule

Thresholds are set from the measurements above, on the frozen evaluation
set, with the silent-false-accept class weighted first. No threshold is
invented in code before that evidence exists.

`lib/domain/boundary_decision.dart` therefore uses only constants the
project already had, for two different comparisons:

- `shapeTolerance` (`0.04` in `lib/domain/document_kind.dart`) is the
  relative error `(measured / imposed - 1).abs()`. Classification already
  uses it. Inside this tolerance the catalog millimetre slot may be used
  and `sizeConfirmed` may be set. An automatic warp does not adopt the
  catalog aspect at any disagreement, including inside this tolerance.
  Export and the sheet preview fit the pixels uniformly inside the slot
  (`BoxFit.contain`). A residual difference is a margin, not a stretch.
- `maxAspectClaimRatio` (`2.5`) is the opposite-edge implausibility bound
  `assessQuad` already applies, reused as an outer claim refusal:
  `max(measured, imposed) / min(measured, imposed)`. Above it the imposed
  size is a different document and no automatic warp runs. It is not a
  permission to stretch every milder disagreement onto the catalog ratio.
  Among the catalogued cards it separates the ration card (~5.52) from
  ID-1 (~1.59); it does not separate ID, residence and passport.

Structural checks (`assessQuad`: convexity, area, edge length, opposite-edge
ratio) are unchanged. Nothing here is a new cutoff, and nothing here is a
measurement of the real document edge.
