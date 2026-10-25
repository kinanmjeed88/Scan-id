import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/imaging/document_detector.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/imaging/hybrid_boundary_arbitrator.dart';
import 'package:scan_id/imaging/prepare_image.dart';

img.Image _solidCanvas(int width, int height, int r, int g, int b) {
  final canvas = img.Image(width: width, height: height);
  img.fill(canvas, color: img.ColorRgb8(r, g, b));
  return canvas;
}

void _drawFilledQuad(
  img.Image canvas,
  List<Point2> normQuad,
  img.ColorRgb8 color,
) {
  final w = canvas.width, h = canvas.height;
  final pts = [for (final p in normQuad) Point2(p.x * (w - 1), p.y * (h - 1))];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var inside = true;
      for (var i = 0; i < 4; i++) {
        final a = pts[i], b = pts[(i + 1) % 4];
        final cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
        if (cross < 0) {
          inside = false;
          break;
        }
      }
      if (inside) {
        canvas.setPixel(x, y, color);
      }
    }
  }
}

void main() {
  test(
    'letterboxed phone screenshot strips black bars and maps quad back to full-frame coordinates',
    () {
      final image = _solidCanvas(552, 1200, 0, 0, 0);
      // Photo viewport occupies y = 240..960 with dark wood desk background.
      img.fillRect(
        image,
        x1: 0,
        y1: 240,
        x2: 551,
        y2: 960,
        color: img.ColorRgb8(58, 46, 38),
      );
      // Card inside viewport at x = 44..496, y = 468..792.
      img.fillRect(
        image,
        x1: 44,
        y1: 468,
        x2: 496,
        y2: 792,
        color: img.ColorRgb8(232, 234, 238),
      );

      final scored = detectDocumentCornersScored(image);
      expect(scored, isNotNull);
      expect(scored!.viewportTop, closeTo(240, 2));
      expect(scored.viewportHeight, closeTo(721, 4));
      expect(scored.corners[0].x, closeTo(44 / 551, .025));
      expect(scored.corners[0].y, closeTo(468 / 1199, .025));
      expect(scored.corners[2].x, closeTo(496 / 551, .025));
      expect(scored.corners[2].y, closeTo(792 / 1199, .025));
    },
  );

  test(
    'foreshortened -32 degree landscape card preserves canonical [TL, TR, BR, BL] ordering',
    () {
      final image = _solidCanvas(552, 1200, 42, 46, 52);
      // Exact geometry where TR->BR has larger normalized +dx than TL->TR.
      final groundTruth = [
        Point2(0.06, 0.52), // TL
        Point2(0.58, 0.20), // TR
        Point2(0.92, 0.32), // BR
        Point2(0.48, 0.83), // BL
      ];
      _drawFilledQuad(image, groundTruth, img.ColorRgb8(236, 234, 226));

      final detected = detectDocumentCorners(image);
      expect(detected, isNotNull);
      for (var i = 0; i < 4; i++) {
        expect(detected![i].x, closeTo(groundTruth[i].x, .03));
        expect(detected[i].y, closeTo(groundTruth[i].y, .03));
      }
    },
  );

  test(
    'trimodal pale card with dark portrait on white table resolves outer card boundary',
    () {
      final image = _solidCanvas(960, 720, 244, 245, 247);
      // Pale card on slightly brighter white desk + high-contrast portrait & text inside.
      img.fillRect(
        image,
        x1: 110,
        y1: 130,
        x2: 850,
        y2: 590,
        color: img.ColorRgb8(212, 216, 224),
      );
      img.fillRect(
        image,
        x1: 630,
        y1: 210,
        x2: 800,
        y2: 450,
        color: img.ColorRgb8(28, 30, 35),
      );
      for (var row = 0; row < 5; row++) {
        img.fillRect(
          image,
          x1: 160,
          y1: 230 + row * 48,
          x2: 560,
          y2: 244 + row * 48,
          color: img.ColorRgb8(35, 38, 44),
        );
      }

      final detected = detectDocumentCorners(image);
      expect(detected, isNotNull);
      expect(detected![0].x, closeTo(110 / 959, .03));
      expect(detected[0].y, closeTo(130 / 719, .03));
      expect(detected[2].x, closeTo(850 / 959, .03));
      expect(detected[2].y, closeTo(590 / 719, .03));
    },
  );

  test(
    'multi-card white sheet decomposes pale cards inside outer container frame',
    () {
      final image = _solidCanvas(900, 1200, 0, 0, 0);
      // White sheet inside screenshot frame.
      img.fillRect(
        image,
        x1: 45,
        y1: 45,
        x2: 855,
        y2: 1155,
        color: img.ColorRgb8(248, 249, 250),
      );
      const cardRects = [
        (80, 140, 415, 360),
        (485, 140, 820, 360),
        (80, 440, 415, 660),
        (485, 440, 820, 660),
        (80, 740, 415, 960),
      ];
      for (final (x1, y1, x2, y2) in cardRects) {
        img.fillRect(
          image,
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2,
          color: img.ColorRgb8(222, 226, 232),
        );
        img.drawRect(
          image,
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2,
          color: img.ColorRgb8(65, 72, 82),
          thickness: 3,
        );
      }

      final result = segmentDecoded(image);
      expect(result.multi, isTrue);
      expect(result.candidates.length, 5);
    },
  );

  test(
    'open passport spread remains one reviewable outer boundary across its two pages',
    () {
      final image = _solidCanvas(1000, 720, 52, 46, 40);
      // One opened booklet: a single strong outer cover, two slightly lighter
      // facing pages, a central gutter, and synthetic text strokes.
      img.fillRect(
        image,
        x1: 120,
        y1: 120,
        x2: 880,
        y2: 600,
        color: img.ColorRgb8(224, 222, 211),
      );
      img.fillRect(
        image,
        x1: 136,
        y1: 136,
        x2: 486,
        y2: 584,
        color: img.ColorRgb8(230, 228, 219),
      );
      img.fillRect(
        image,
        x1: 514,
        y1: 136,
        x2: 864,
        y2: 584,
        color: img.ColorRgb8(230, 228, 219),
      );
      img.fillRect(
        image,
        x1: 490,
        y1: 120,
        x2: 510,
        y2: 600,
        color: img.ColorRgb8(196, 190, 178),
      );
      for (final x in [168, 546]) {
        for (var row = 0; row < 8; row++) {
          img.fillRect(
            image,
            x1: x,
            y1: 194 + row * 48,
            x2: x + 265,
            y2: 199 + row * 48,
            color: img.ColorRgb8(92, 88, 81),
          );
        }
      }

      // A model may call the facing pages two documents. The measured single
      // outer cover has >2.2x stronger physical edge support, so that split is
      // suppressed; single-boundary arbitration then retains the full spread.
      final left = [
        Point2(120 / 999, 120 / 719),
        Point2(495 / 999, 120 / 719),
        Point2(495 / 999, 600 / 719),
        Point2(120 / 999, 600 / 719),
      ];
      final right = [
        Point2(505 / 999, 120 / 719),
        Point2(880 / 999, 120 / 719),
        Point2(880 / 999, 600 / 719),
        Point2(505 / 999, 600 / 719),
      ];
      final split = arbitrateSceneBoundaries(
        image,
        SegmentationResult(
          multi: true,
          candidates: [
            SegmentCandidate(
              region: [120 / 999, 120 / 719, 495 / 999, 600 / 719],
              corners: left,
              detectionConfidence: .90,
              producer: BoundaryProducer.learnedModel,
              reason: 'synthetic-open-passport-left-page',
            ),
            SegmentCandidate(
              region: [505 / 999, 120 / 719, 880 / 999, 600 / 719],
              corners: right,
              detectionConfidence: .90,
              producer: BoundaryProducer.learnedModel,
              reason: 'synthetic-open-passport-right-page',
            ),
          ],
        ),
      );
      expect(split.multi, isFalse);
      expect(split.candidates, isEmpty);

      final outer = arbitrateSingleBoundary(image, null);
      expect(outer, isNotNull);
      expect(outer!.producer, BoundaryProducer.wholeFrameDetector);
      final expected = [
        Point2(120 / 999, 120 / 719),
        Point2(880 / 999, 120 / 719),
        Point2(880 / 999, 600 / 719),
        Point2(120 / 999, 600 / 719),
      ];
      for (var i = 0; i < 4; i++) {
        expect(outer.corners![i].x, closeTo(expected[i].x, .02));
        expect(outer.corners![i].y, closeTo(expected[i].y, .02));
      }
      final decision = verifyBoundary(
        outer,
        sourceWidth: image.width,
        sourceHeight: image.height,
      );
      expect(decision.kind, BoundaryDecisionKind.needsReview);
      expect(decision.acceptedCorners, isNull);
      expect(decision.cropAuthorization, isNull);
      expect(decision.proposal.corners, hasLength(4));
    },
  );

  test(
    'arbitrateSceneBoundaries suppresses false split across single card without merging candidates',
    () {
      final image = _solidCanvas(1000, 700, 35, 38, 44);
      img.fillRect(
        image,
        x1: 80,
        y1: 160,
        x2: 920,
        y2: 560,
        color: img.ColorRgb8(236, 235, 230),
      );
      final fakeSplit = SegmentationResult(
        multi: true,
        candidates: [
          SegmentCandidate(
            region: [0.08, 0.23, 0.52, 0.80],
            reason: 'synthetic-false-split-left',
            corners: [
              Point2(0.08, 0.23),
              Point2(0.50, 0.23),
              Point2(0.50, 0.80),
              Point2(0.08, 0.80),
            ],
            detectionConfidence: .66,
          ),
          SegmentCandidate(
            region: [0.49, 0.23, 0.92, 0.80],
            reason: 'synthetic-false-split-right',
            corners: [
              Point2(0.50, 0.23),
              Point2(0.92, 0.23),
              Point2(0.92, 0.80),
              Point2(0.50, 0.80),
            ],
            detectionConfidence: .67,
          ),
        ],
      );

      final arbitrated = arbitrateSceneBoundaries(image, fakeSplit);
      expect(arbitrated.multi, isFalse);
      expect(arbitrated.candidates, isEmpty);

      // Uncorroborated classical multi-region rescue (e.g. non-document boxes
      // on a white page rejected by Stage-1, or pale multi-card sheet missed
      // by Stage-2A) keeps authentic confidence/provenance and routes every
      // candidate to `needsReview` rather than silently auto-cropping.
      final whiteBoxes = _solidCanvas(900, 700, 248, 249, 250);
      img.fillRect(
        whiteBoxes,
        x1: 70,
        y1: 180,
        x2: 410,
        y2: 410,
        color: img.ColorRgb8(42, 88, 155),
      );
      img.fillRect(
        whiteBoxes,
        x1: 490,
        y1: 180,
        x2: 830,
        y2: 410,
        color: img.ColorRgb8(155, 62, 54),
      );
      final rawClassical = segmentDecoded(whiteBoxes);
      final rescuedMulti = arbitrateSceneBoundaries(
        whiteBoxes,
        const SegmentationResult(candidates: [], multi: false),
      );
      expect(rescuedMulti.multi, isTrue);
      expect(rescuedMulti.candidates.length, 2);
      for (var i = 0; i < rescuedMulti.candidates.length; i++) {
        final candidate = rescuedMulti.candidates[i];
        expect(candidate.producer, BoundaryProducer.segmenter);
        expect(candidate.requiresReview, isTrue);
        expect(
          candidate.detectionConfidence,
          rawClassical.candidates[i].detectionConfidence,
          reason: 'the arbitration must preserve authentic region support',
        );
        expect(
          candidate.minAutoAcceptConfidence,
          rawClassical.candidates[i].minAutoAcceptConfidence,
        );
        final decision = verifyBoundary(
          BoundaryProposal(
            producer: candidate.producer,
            corners: candidate.corners,
            region: candidate.region,
            modelConfidence: candidate.detectionConfidence,
            minAutoAcceptConfidence: candidate.minAutoAcceptConfidence,
            touchesFrameEdge: candidate.touchesFrameEdge,
            forceReview: candidate.requiresReview,
          ),
          sourceWidth: whiteBoxes.width,
          sourceHeight: whiteBoxes.height,
        );
        expect(decision.kind, BoundaryDecisionKind.needsReview);
        expect(
          decision.verification.reasons,
          contains(BoundaryReviewReason.multiSceneNotCorroborated),
        );
      }
    },
  );

  test(
    'uncorroborated multi-region evidence survives for review and invalid geometry never authorizes a crop',
    () {
      final flat = _solidCanvas(500, 350, 92, 94, 98);
      final valid = [
        Point2(.08, .12),
        Point2(.46, .12),
        Point2(.46, .82),
        Point2(.08, .82),
      ];
      final invalid = [
        Point2(.56, .18),
        Point2(.92, .18),
        Point2(.74, .18),
        Point2(.56, .18),
      ];
      final input = SegmentationResult(
        multi: true,
        candidates: [
          SegmentCandidate(
            region: const [.08, .12, .46, .82],
            corners: valid,
            detectionConfidence: .91,
            producer: BoundaryProducer.learnedModel,
            minAutoAcceptConfidence: .55,
            reason: 'synthetic-valid-but-unconfirmed',
          ),
          SegmentCandidate(
            region: const [.56, .18, .92, .72],
            corners: invalid,
            detectionConfidence: .88,
            producer: BoundaryProducer.learnedModel,
            minAutoAcceptConfidence: .55,
            reason: 'synthetic-invalid-quad',
          ),
        ],
      );

      final kept = arbitrateSceneBoundaries(flat, input);
      expect(kept.multi, isTrue);
      expect(kept.candidates, hasLength(2));
      expect(kept.candidates.map((c) => c.region).toList(), [
        const [.08, .12, .46, .82],
        const [.56, .18, .92, .72],
      ]);
      expect(kept.candidates.map((c) => c.detectionConfidence).toList(), [
        .91,
        .88,
      ]);
      expect(
        kept.candidates.every((c) => c.requiresReview),
        isTrue,
        reason: 'weak multi-set corroboration is a separate review constraint',
      );

      final validDecision = verifyBoundary(
        BoundaryProposal(
          producer: kept.candidates.first.producer,
          corners: kept.candidates.first.corners,
          region: kept.candidates.first.region,
          modelConfidence: kept.candidates.first.detectionConfidence,
          minAutoAcceptConfidence:
              kept.candidates.first.minAutoAcceptConfidence,
          forceReview: kept.candidates.first.requiresReview,
        ),
        sourceWidth: flat.width,
        sourceHeight: flat.height,
      );
      expect(validDecision.kind, BoundaryDecisionKind.needsReview);
      expect(validDecision.cropAuthorization, isNull);
      expect(
        validDecision.verification.reasons,
        contains(BoundaryReviewReason.multiSceneNotCorroborated),
      );

      final invalidDecision = verifyBoundary(
        BoundaryProposal(
          producer: kept.candidates.last.producer,
          corners: kept.candidates.last.corners,
          region: kept.candidates.last.region,
          modelConfidence: kept.candidates.last.detectionConfidence,
          minAutoAcceptConfidence:
              kept.candidates.last.minAutoAcceptConfidence,
          forceReview: kept.candidates.last.requiresReview,
        ),
        sourceWidth: flat.width,
        sourceHeight: flat.height,
      );
      expect(invalidDecision.kind, BoundaryDecisionKind.needsReview);
      expect(invalidDecision.acceptedCorners, isNull);
      expect(invalidDecision.cropAuthorization, isNull);
      expect(
        invalidDecision.verification.reasons,
        contains(BoundaryReviewReason.geometryRejected),
      );
      expect(
        invalidDecision.verification.reasons,
        contains(BoundaryReviewReason.multiSceneNotCorroborated),
      );
    },
  );

  test(
    'hybrid arbitration keeps a measured cornerless classical region when AI finds no candidate',
    () {
      final roundRegion = _solidCanvas(900, 700, 45, 55, 70);
      img.fillCircle(
        roundRegion,
        x: 450,
        y: 350,
        radius: 100,
        color: img.ColorRgb8(235, 233, 228),
      );
      final raw = segmentDecoded(roundRegion);
      expect(raw.candidates, hasLength(1));
      expect(raw.candidates.single.corners, isNull);

      final kept = arbitrateSceneBoundaries(
        roundRegion,
        const SegmentationResult(candidates: [], multi: false),
      );
      expect(kept.candidates, hasLength(1));
      expect(kept.candidates.single.region, raw.candidates.single.region);
      expect(kept.candidates.single.corners, isNull);
      expect(kept.candidates.single.requiresReview, isTrue);
      expect(kept.multi, isFalse);
    },
  );

  test(
    'arbitrateSingleBoundary upgrades interior portrait corner jump and gates truncated cards to review',
    () {
      final cardScene = _solidCanvas(1000, 700, 40, 44, 52);
      img.fillRect(
        cardScene,
        x1: 100,
        y1: 150,
        x2: 900,
        y2: 560,
        color: img.ColorRgb8(236, 235, 230),
      );
      // Dark portrait inside card that tricked neural corner heatmap.
      img.fillRect(
        cardScene,
        x1: 680,
        y1: 210,
        x2: 850,
        y2: 430,
        color: img.ColorRgb8(30, 32, 36),
      );
      final defectiveAi = BoundaryProposal(
        producer: BoundaryProducer.learnedModel,
        corners: [
          Point2(0.10, 0.214),
          Point2(0.68, 0.214), // jumped inward to portrait left border!
          Point2(0.90, 0.800),
          Point2(0.10, 0.800),
        ],
        modelConfidence: .84,
        minAutoAcceptConfidence: .55,
      );

      final fixed = arbitrateSingleBoundary(cardScene, defectiveAi);
      expect(fixed, isNotNull);
      expect(fixed!.producer, BoundaryProducer.wholeFrameDetector);
      expect(fixed.modelConfidence, lessThan(.55));
      expect(fixed.corners![1].x, closeTo(0.90, .03));
      expect(
        verifyBoundary(
          fixed,
          sourceWidth: cardScene.width,
          sourceHeight: cardScene.height,
        ).kind,
        BoundaryDecisionKind.needsReview,
      );

      // Pure classical mode (`hasLearnedModel: false`) never fabricates neural provenance.
      final pureClassical = arbitrateSingleBoundary(
        cardScene,
        null,
        hasLearnedModel: false,
      );
      expect(pureClassical, isNotNull);
      expect(pureClassical!.producer, BoundaryProducer.wholeFrameDetector);
      expect(pureClassical.modelConfidence, isNull);

      // Enclosed inner sub-box inside a much crisper outer card is rejected in favor of outer card + review.
      final outerScene = _solidCanvas(900, 640, 245, 215, 20);
      img.fillRect(
        outerScene,
        x1: 150,
        y1: 100,
        x2: 750,
        y2: 520,
        color: img.ColorRgb8(24, 118, 62),
      );
      img.fillRect(
        outerScene,
        x1: 210,
        y1: 150,
        x2: 650,
        y2: 390,
        color: img.ColorRgb8(62, 152, 92),
      );
      final innerSubAi = BoundaryProposal(
        producer: BoundaryProducer.learnedModel,
        corners: [
          Point2(210 / 899, 150 / 639),
          Point2(650 / 899, 150 / 639),
          Point2(650 / 899, 390 / 639),
          Point2(210 / 899, 390 / 639),
        ],
        modelConfidence: .92,
        minAutoAcceptConfidence: .55,
      );
      final rescuedOuter = arbitrateSingleBoundary(outerScene, innerSubAi);
      expect(rescuedOuter, isNotNull);
      expect(rescuedOuter!.producer, BoundaryProducer.wholeFrameDetector);
      expect(rescuedOuter.corners![2].y, closeTo(520 / 639, .03));
      expect(
        verifyBoundary(
          rescuedOuter,
          sourceWidth: outerScene.width,
          sourceHeight: outerScene.height,
        ).kind,
        BoundaryDecisionKind.needsReview,
      );

      // Two circular blobs on bright background must never fabricate rectangular crops.
      final circlesScene = _solidCanvas(800, 600, 246, 247, 248);
      img.fillCircle(
        circlesScene,
        x: 240,
        y: 300,
        radius: 115,
        color: img.ColorRgb8(48, 52, 60),
      );
      img.fillCircle(
        circlesScene,
        x: 560,
        y: 300,
        radius: 115,
        color: img.ColorRgb8(48, 52, 60),
      );
      final circleSeg = segmentDecoded(circlesScene);
      expect(circleSeg.multi, isFalse);

      // Golden truncated top card must never auto-accept; it must route to needsReview.
      final truncatedBytes = File(
        'test/fixtures/ai_golden_truncated.png',
      ).readAsBytesSync();
      final truncatedDecoded = decodeForProcessing(truncatedBytes);
      final truncProposal = arbitrateSingleBoundary(truncatedDecoded, null);
      expect(truncProposal, isNotNull);
      final decision = verifyBoundary(
        truncProposal!,
        sourceWidth: truncatedDecoded.width,
        sourceHeight: truncatedDecoded.height,
      );
      expect(decision.kind, BoundaryDecisionKind.needsReview);
    },
  );

  test(
    'Project JSON round-trip preserves crop corners, suggestedCrop, and pixel dimensions losslessly',
    () {
      final cropCorners = [
        Point2(0.0680, 0.2640),
        Point2(0.7690, 0.2530),
        Point2(0.7750, 0.8660),
        Point2(0.0630, 0.8500),
      ];
      final recipe = CropDraft(corners: cropCorners).toRecipe(1200, 900);
      final asset = ImageAsset(
        id: 'asset-rt',
        name: 'id_front.jpg',
        originalPath: 'projects/proj-rt/assets/asset-rt/originals/id_front.jpg',
        workingPath:
            'projects/proj-rt/assets/asset-rt/revisions/id_front_rev1.png',
        thumbnailPath:
            'projects/proj-rt/assets/asset-rt/thumbnails/id_front_thumb.jpg',
        width: recipe.geometry.outputWidth,
        height: recipe.geometry.outputHeight,
        crop: recipe.geometry,
        userAuthoredCrop: false,
      );
      final reviewAsset = ImageAsset(
        id: 'asset-rev',
        name: 'id_clipped.jpg',
        originalPath:
            'projects/proj-rt/assets/asset-rev/originals/id_clipped.jpg',
        workingPath:
            'projects/proj-rt/assets/asset-rev/revisions/id_clipped_rev1.png',
        thumbnailPath:
            'projects/proj-rt/assets/asset-rev/thumbnails/id_clipped_thumb.jpg',
        width: 1200,
        height: 900,
        suggestedCrop: cropCorners,
      );
      final project = Project(
        id: 'proj-rt',
        name: 'مشروع فحص الثبات',
        createdAt: DateTime.utc(2026, 10, 23),
        updatedAt: DateTime.utc(2026, 10, 23),
        assets: [asset, reviewAsset],
        items: const [],
      );
      final reopened = Project.fromJson(project.toJson());
      expect(reopened.assets[0].crop, isNotNull);
      expect(reopened.assets[1].suggestedCrop, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect(
          reopened.assets[0].crop!.corners[i].x,
          closeTo(cropCorners[i].x, 1e-12),
        );
        expect(
          reopened.assets[1].suggestedCrop![i].y,
          closeTo(cropCorners[i].y, 1e-12),
        );
      }
    },
  );
}
