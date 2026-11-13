# Candidate-ordering fix in the classical detector — 2026-11-11

Branch `arena/6977d266-scan-id` (PR #54), base `4c195f4` (`searchidf`).

## 1. Fate of the previously reported fix

The earlier session reported a candidate-ordering fix and a regression test on
`arena/68eaa17d-scan-id`, but neither appeared in `searchidf` or in PR #53.
The search below establishes that it was never committed anywhere reachable:

- Every local and remote branch (`git ls-remote`), all PR refs 1–53 and all tags
  were fetched, so the graph is complete rather than limited to the grafted
  clone tip.
- `git log --all` over `lib/imaging/document_detector.dart` and
  `lib/domain/boundary_decision.dart` lists eight commits touching the
  detector. All eight unique blobs of that file
  (`1f1e838`, `3f7e630`, `673da54`, `7079ba7`, `8c05110`, `d414c44`, `e75c2c0`,
  `ec4ef07`) contain the identical failing logic
  `final best = scored.first.score; if (best.mean < needMean || best.min < needMin) return null;`.
  No variant with a candidate fallback exists in any of them.
- `git fsck --full --unreachable --no-reflogs` printed nothing, `git stash list`
  was empty, and no commit message in the fetched history describes a
  candidate-ordering fix.
- PR #53 (head `9f1ef42`, merged `2026-11-11T11:57:22Z`) modifies 34 files for
  the printed-wording lexicon and evidence labelling; `document_detector.dart`
  is not among them.

Conclusion: the earlier report produced no committed change. The fix below is
a re-implementation from the proven root cause, not a restoration.

## 2. Root cause

`lib/imaging/document_detector.dart`, `_Detector.runScored` (base revision
lines 507–522):

```dart
scored.sort((a, b) => b.score.total.compareTo(a.score.total));
final best = scored.first.score;
if (best.mean < needMean || best.min < needMin) {
  return null;                       // <- ends the entire pass
}
final shortlist = <_Candidate>[];
for (final c in scored) {
  if (c.score.total < best.total - .05 || shortlist.length >= 12) break;
  ...
}
```

Two coupled defects, both rooted in treating `scored.first` as the only
candidate that matters:

1. The early `return null` discards every lower-scored candidate as soon as
   the top-scored one fails the edge-support gates.
2. The near-best window is anchored to the failing candidate, so even without
   the early return a passing candidate more than `0.05` below it would be
   dropped by `break` (and `shortlist.first` would then throw on the empty
   list).

`_detectOnActiveImage` (lines 116–122) runs two passes and treats a `null`
pass as absent, so one unsupported high-scoring outline (a cast shadow, a
printed inner frame) could suppress an otherwise correct boundary.

## 3. Change

`runScored` now builds its shortlist through `shortlistEdgeSupportedCandidates`,
a small generic helper placed next to `_Candidate`:

- a candidate that fails `needMean` or `needMin` is skipped, not fatal;
- the near-best window anchors to the **first candidate that passes both
  gates**, which is the top candidate whenever the top candidate passes;
- the 12-candidate cap, the ranked order and the duplicate rule (every corner
  pair within 1.5 px, first of the group kept — now `_sameQuad`) are unchanged;
- an empty shortlist still returns `null`: a failing candidate is never
  returned because it is the best available.

Everything downstream is untouched: fine-scale sharpness re-rank, two-pass
`_refine`, `_validQuad(.03)`, `_orderQuad`, `CropGeometry` validation and both
passes' thresholds (`needMean`/`needMin`).

### Behaviour preservation

An exhaustive random check over 40,000 ranked candidate sets (mixing passing,
mean-failing, min-failing and duplicate candidates) compared the old and new
selection:

- **0 differences** across every case where the top candidate passes — the
  shortlisted set is bit-for-bit what the old code produced;
- **14,135 cases** where the new selection returns candidates the old one
  rejected — exactly the intended fallback.

## 4. Tests

`test/imaging/document_detector_candidate_order_test.dart` — 18 synthetic
cases, no photographs, no OCR. It pins the fallback (mean and min gates),
all-fail rejection, unchanged top-passing behaviour, a later failing candidate
being skipped without ending the search, the near-best window in both
orientations, re-anchoring, equal-score determinism, duplicate suppression,
the never-return-a-failing-candidate rule, the 12-cap and the inclusive window
boundary. A behavioural copy of the old loop (`_legacyShortlist`) is asserted
empty on the fallback scene, so the regression is demonstrably discriminating.

## 5. Effect on the production boundary decision

`corroborateClassicalBoundaryWithCatalog` (`lib/domain/boundary_decision.dart`,
called from `lib/application/recognition_pipeline.dart:631`) is unchanged. It
still requires `needsReview`, a detector-produced proposal, `forceReview` off,
the sole `uncalibratedClassicalScore` reason, usable geometry, a qualified
classification and catalog aspect agreement within `shapeTolerance`. A
successful candidate pick only supplies the corners that gate then judges; it
does not authorize a crop.

## 6. Verification (executed)

All results come from GitHub Actions run `43028853131` (PR) and
`43028841162` (push) on SHA `75a811e`:

| Gate | Result |
| --- | --- |
| `dart format` (read-only gate) | pass |
| `flutter analyze --fatal-infos` | pass |
| `flutter test` (1345 tests) | pass |
| Android debug APK build | pass |
| Android startup diagnostic APK | pass |
| Android signed release R8 intake regression | pass |
| Android native instrumentation (BitmapRegionDecoder) | pass |
| Windows build | pass |
| Android debug/diagnostic differential | pass |
| Android 16 startup evidence | pass |

Local toolchain: the sandbox has no Dart/Flutter and cannot reach
`storage.googleapis.com`/`pub.dev`, so `dart format`, `flutter analyze`,
`flutter test` and the builds were executed by CI, not locally. The
repository's Python gates (`check_source.py`, `check_workflow_permissions.py`,
`check_android_r8.py`, `check_detector_retirement.py`) pass locally.

## 7. Complexity and edge cases

- Time and memory are unchanged: the loop visits the same ranked list, does the
  same constant work per candidate, and never recomputes geometry. Refinement
  still runs on at most 12 shortlisted candidates. The only behaviour change
  is that the loop may continue past candidates it previously abandoned.
- When no candidate passes, the cost is one extra linear scan that the old
  early return skipped; no scoring or refinement work is added.
- Determinism: `List.sort` is not stable, so exactly equal totals are ordered
  by the sort's own result — the same property the old code had. No tie-breaker
  was introduced.
- If every passing candidate is geometrically degenerate, refinement and
  `_validQuad` reject them as before; the fix does not weaken those gates.
