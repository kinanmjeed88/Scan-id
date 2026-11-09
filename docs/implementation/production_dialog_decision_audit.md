# Production decision/dialog audit

## Confirmed defect and scoped correction

`manual_classification_dialog.dart` still displayed a literal ٧٠٪ and an undifferentiated final score, despite the engine shipping C=.60 / boundary=.55. Replaced the literal with shared policy constants, made the two gates explicit, and labelled historical F as unused for acceptance. The actual engine thresholds were already55/60; changing them again would not repair a misleading UI.

The dialog reconstructed failures from primary detection confidence and suggestion presence, losing model disagreement, frame-touch and weak-secondary failures after persistence. `DetectionRef.boundaryDiagnostics` now optionally persists the actual verifier messages (no image, filename or OCR text); SmartIntake captures all verification reasons and the dialog explanations prefer recorded failures over reconstructing a verdict from D. Old projects deserialize without fabricated failure records. Geometry-usable manual suggestions are now described as reviewable corners, not automatic crop authorization.

## Actual path / score ownership

1. DocQuadNet/DocAligner return normalized quads and their own model confidence. `BoundaryProposalCascade` validates both, requires independent acceptance≥55% and corner agreement (maximum displacement .04 of diagonal). Weak/missing secondary or disagreement stays review-only; no averaging scores or points.
2. Arbitration and `verifyBoundary` retain area, edges, intersections, frame, region and content-loss guards; a high model score cannot rescue an invalid quad. Pipeline sets `corners=null` for unauthorized crop and retains a review suggestion only when geometry is usable.
3. OCR receives `prepareOcrRegionIsolated` from the authorized quad, otherwise a geometrically acceptable candidate for OCR only, otherwise the measured region; isolated regions without safe geometry skip OCR. Native engine controls Arabic detection/recognition. Semantic matching uses normalized text and independent anchors from the existing five dictionaries. A missing C can mean unavailable/timed-out/blank OCR or no sufficient unique semantic anchors; it is not evidence of boundary failure.
4. Classifier C is the independent semantic score≥60%, never D/G/F fusion. SmartIntake separately authorizes crop, type and documented millimetres. Known type skips the type dialog and goes to crop/size review. Unknown type with approved crop keeps that crop for manual classification. A manual suggestion checkbox is shown only after the same `inspectSuggestedBoundary` geometry check used by service validation; it is explicit user approval, not automatic acceptance.
5. Legacy F remains readable but does not authorize crop/type. Diagnostic review bands are not crop permission. No remaining70 literal in recognition UI after this correction; unrelated numeric geometry/drawing constants are not acceptance thresholds.

## Evidence limits

No actual image attachments are available in this request. The reported57.2/76.4/12.4 cases are tested as injected scores, not as reconstructed real image inference. It is impossible to assert the source of missing OCR or rejected geometry for those particular images without their pixels and trace. No lexicon expansion, invented type, weakened geometry or removal of secondary corroboration is justified without that evidence.

## Regression / execution

Added production import cases57.2/76.4 accepted when corroborated and valid,12.4 review; existing54.9/55 and C59.9/60 and OCR-failure safe crop cases remain. Added persisted gate diagnostics/legacy compatibility tests, and actual widget assertions for shared55/60 and unused F. Existing unsafe/inner-frame/model-conflict and crop/mm independence tests remain mandatory. Local source/import and diff checks run; Flutter absent locally, so actual analyze/test/Android/Windows execution is via the latest SHA's CI, to be verified before delivery. No merge/release.
