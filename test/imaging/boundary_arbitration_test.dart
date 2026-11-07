import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/imaging/boundary_arbitration.dart';
import 'package:scan_id/imaging/document_detector.dart';

// A clear photo can yield four geometrically VALID points that sit in the
// middle of the card. assessQuad cannot see that; measured evidence can. These
// tests also pin the NON-edge guards, so a sharp printed inner frame can never
// win just because its gradients are stronger.
final learnedQuad = <Point2>[
  Point2(.3, .3),
  Point2(.7, .3),
  Point2(.7, .7),
  Point2(.3, .7),
];
final classicalQuad = <Point2>[
  Point2(.1, .1),
  Point2(.9, .1),
  Point2(.9, .9),
  Point2(.1, .9),
];
final outsideRegionQuad = <Point2>[
  Point2(.02, .02),
  Point2(.9, .02),
  Point2(.9, .9),
  Point2(.02, .9),
];

MeasuredBoundaryCandidate candidate(
  List<Point2> corners,
  double mean,
  double min, {
  bool refined = false,
}) => MeasuredBoundaryCandidate(
  corners: corners,
  originalCorners: corners,
  evidence: QuadEdgeEvidence(meanSupport: mean, minSupport: min, score: 0),
  wasRefined: refined,
);

BoundaryProposal learned({
  double confidence = .46,
  List<double>? region,
  double? imposedAspect,
  List<Point2>? corners,
  bool forceReview = false,
}) => BoundaryProposal(
  producer: BoundaryProducer.learnedModel,
  corners: corners ?? learnedQuad,
  region: region,
  imposedAspect: imposedAspect,
  modelConfidence: confidence,
  minAutoAcceptConfidence: .70,
  forceReview: forceReview,
);

BoundaryMeasurements measurements({
  MeasuredBoundaryCandidate? learnedEvidence,
  MeasuredBoundaryCandidate? classicalEvidence,
}) => BoundaryMeasurements(
  sourceWidth: 400,
  sourceHeight: 250,
  learned: learnedEvidence,
  classical: classicalEvidence,
);

void main() {
  test('a weaker-measured learned quad is replaced by the edge-based quad', () {
    final result = arbitrateBoundaryProposal(
      learned: learned(),
      measurements: measurements(
        learnedEvidence: candidate(learnedQuad, .2, .1),
        classicalEvidence: candidate(classicalQuad, .9, .8),
      ),
    );
    expect(result, isNotNull);
    expect(result!.producer, BoundaryProducer.detector);
    expect(result.corners, classicalQuad);
    expect(result.forceReview, isTrue);
    expect(result.forceReviewReason, BoundaryReviewReason.modelDisagreement);
    // A classical candidate NEVER inherits a learned confidence: it is still
    // routed to review by verifyBoundary.
    expect(result.modelConfidence, isNull);
  });

  test('agreement keeps the learned claim and its honest review flags', () {
    final refined = <Point2>[
      Point2(.11, .1),
      Point2(.9, .1),
      Point2(.9, .9),
      Point2(.1, .9),
    ];
    final result = arbitrateBoundaryProposal(
      learned: learned(),
      measurements: measurements(
        learnedEvidence: candidate(refined, .9, .8, refined: true),
        classicalEvidence: candidate(classicalQuad, .88, .8),
      ),
    );
    expect(result!.producer, BoundaryProducer.learnedModel);
    expect(result.corners, refined, reason: 'snapped corners are shown');
    expect(result.modelConfidence, .46);
    expect(result.forceReview, isFalse);
  });

  test('no learned claim yields a plain review-only classical proposal', () {
    final result = arbitrateBoundaryProposal(
      learned: null,
      measurements: measurements(
        classicalEvidence: candidate(classicalQuad, .9, .8),
      ),
    );
    expect(result!.producer, BoundaryProducer.detector);
    expect(result.corners, classicalQuad);
    expect(result.forceReview, isFalse);
    expect(result.modelConfidence, isNull);
  });

  test('a lone learned claim with no measurements is kept, not dropped', () {
    final result = arbitrateBoundaryProposal(
      learned: learned(),
      measurements: measurements(),
    );
    expect(result, isNotNull);
    expect(result!.producer, BoundaryProducer.learnedModel);
    expect(result.corners, learnedQuad);
    expect(result.modelConfidence, .46);
  });

  // ---- Guards that stop edge strength from producing a wrong crop ----
  test('a sharp inner printed frame does NOT replace the outer boundary', () {
    final result = arbitrateBoundaryProposal(
      learned: learned(corners: classicalQuad),
      measurements: measurements(
        learnedEvidence: candidate(classicalQuad, .55, .4),
        // Much sharper gradients, but it is an inner frame.
        classicalEvidence: candidate(learnedQuad, .98, .95),
      ),
    );
    expect(result!.producer, BoundaryProducer.learnedModel);
    expect(result.corners, classicalQuad);
    expect(result.forceReview, isTrue);
  });

  test('weak edge evidence never switches proposals', () {
    final result = arbitrateBoundaryProposal(
      learned: learned(),
      measurements: measurements(
        learnedEvidence: candidate(learnedQuad, .2, .1),
        classicalEvidence: candidate(classicalQuad, .3, .1),
      ),
    );
    expect(result!.producer, BoundaryProducer.learnedModel);
    expect(result.corners, learnedQuad);
  });

  test('a candidate outside the measured region is not selected', () {
    final result = arbitrateBoundaryProposal(
      learned: learned(region: const [.1, .1, .95, .95]),
      measurements: measurements(
        learnedEvidence: candidate(learnedQuad, .2, .1),
        classicalEvidence: candidate(outsideRegionQuad, .95, .9),
      ),
    );
    expect(result!.producer, BoundaryProducer.learnedModel);
    expect(result.corners, learnedQuad);
  });

  test(
    'a candidate contradicting the claimed physical aspect is not selected',
    () {
      final result = arbitrateBoundaryProposal(
        learned: learned(imposedAspect: 8),
        measurements: measurements(
          learnedEvidence: candidate(learnedQuad, .2, .1),
          classicalEvidence: candidate(classicalQuad, .95, .9),
        ),
      );
      expect(result!.producer, BoundaryProducer.learnedModel);
      expect(result.corners, learnedQuad);
    },
  );

  test('an existing safety reason is preserved when review is forced', () {
    final claim = learned(forceReview: true);
    final result = arbitrateBoundaryProposal(
      learned: claim,
      measurements: measurements(
        learnedEvidence: candidate(learnedQuad, .2, .1),
        classicalEvidence: candidate(classicalQuad, .3, .1),
      ),
    );
    expect(result!.forceReview, isTrue);
    expect(
      result.forceReviewReason,
      claim.forceReviewReason ?? BoundaryReviewReason.modelDisagreement,
    );
  });

  test('quality is robust against one unsupported side', () {
    const oneWeak = QuadEdgeEvidence(meanSupport: .8, minSupport: 0, score: 0);
    expect(oneWeak.quality, closeTo(.48, 1e-9));
    expect(oneWeak.looksLikeBoundary, isFalse);
    const allStrong = QuadEdgeEvidence(
      meanSupport: .8,
      minSupport: .7,
      score: 0,
    );
    expect(allStrong.quality, greaterThan(oneWeak.quality));
    expect(allStrong.looksLikeBoundary, isTrue);
  });

  test('disagreement is the largest corner shift over the image diagonal', () {
    expect(
      boundaryDisagreement(classicalQuad, classicalQuad, 400, 250),
      closeTo(0, 1e-12),
    );
    expect(
      boundaryDisagreement(learnedQuad, classicalQuad, 400, 250),
      greaterThan(boundaryAgreementTolerance),
    );
  });

  test('snapping that jumps to a distant edge is refused', () {
    final near = <Point2>[
      Point2(.105, .1),
      Point2(.9, .1),
      Point2(.9, .9),
      Point2(.1, .9),
    ];
    expect(withinRefinementDisplacement(classicalQuad, near, 400, 250), isTrue);
    expect(
      withinRefinementDisplacement(classicalQuad, learnedQuad, 400, 250),
      isFalse,
    );
  });

  test('containment and region helpers are strict and symmetric-safe', () {
    expect(containsQuad(classicalQuad, learnedQuad), isTrue);
    expect(containsQuad(learnedQuad, classicalQuad), isFalse);
    expect(containsQuad(classicalQuad, classicalQuad), isFalse);
    expect(pointInConvexQuad(Point2(.5, .5), classicalQuad), isTrue);
    expect(pointInConvexQuad(Point2(.01, .01), classicalQuad), isFalse);
    expect(quadInRegion(classicalQuad, const [.1, .1, .95, .95]), isTrue);
    expect(quadInRegion(outsideRegionQuad, const [.1, .1, .95, .95]), isFalse);
    expect(touchesFrameEdge(outsideRegionQuad), isFalse);
    expect(touchesFrameEdge(<Point2>[]), isFalse);
  });

  // ---- 70% acceptance path must stay intact, with safety checks ----
  test('a corroborated 70% proposal is still accepted', () {
    final claim = learned(confidence: .70, corners: classicalQuad);
    final result = arbitrateBoundaryProposal(
      learned: claim,
      measurements: measurements(
        learnedEvidence: candidate(classicalQuad, .9, .8),
        classicalEvidence: candidate(classicalQuad, .9, .8),
      ),
    );
    expect(result!.modelConfidence, .70);
    expect(result.forceReview, isFalse);
    final decision = verifyBoundary(
      result,
      sourceWidth: 400,
      sourceHeight: 250,
    );
    expect(decision.verification.reasons, isEmpty);
    expect(decision.kind, BoundaryDecisionKind.accepted);
    expect(decision.cropAuthorization, isNotNull);
  });

  test(
    'a 46% proposal is refused for automatic cropping even when measured',
    () {
      final result = arbitrateBoundaryProposal(
        learned: learned(confidence: .46, corners: classicalQuad),
        measurements: measurements(
          learnedEvidence: candidate(classicalQuad, .9, .8),
          classicalEvidence: candidate(classicalQuad, .9, .8),
        ),
      );
      final decision = verifyBoundary(
        result!,
        sourceWidth: 400,
        sourceHeight: 250,
      );
      expect(decision.kind, BoundaryDecisionKind.needsReview);
      expect(decision.cropAuthorization, isNull);
      expect(
        decision.verification.reasons,
        contains(BoundaryReviewReason.lowModelConfidence),
      );
    },
  );

  group('real image gradients', () {
    img.Image scene() {
      final image = img.Image(width: 240, height: 170);
      img.fill(image, color: img.ColorRgb8(60, 45, 30));
      img.fillRect(
        image,
        x1: 40,
        y1: 35,
        x2: 199,
        y2: 135,
        color: img.ColorRgb8(235, 235, 230),
      );
      return image;
    }

    final onEdge = <Point2>[
      Point2(40 / 239, 35 / 169),
      Point2(199 / 239, 35 / 169),
      Point2(199 / 239, 135 / 169),
      Point2(40 / 239, 135 / 169),
    ];
    final insideCard = <Point2>[
      Point2(90 / 239, 70 / 169),
      Point2(150 / 239, 70 / 169),
      Point2(150 / 239, 110 / 169),
      Point2(90 / 239, 110 / 169),
    ];

    test(
      'the visible card edges measure better than a quad inside the card',
      () {
        final image = scene();
        final real = measureQuadEdges(image, onEdge);
        final bogus = measureQuadEdges(image, insideCard);
        expect(real, isNotNull);
        expect(bogus, isNotNull);
        expect(
          real!.quality,
          greaterThan(bogus!.quality + measuredQualityMargin),
          reason: 'a quad in the middle of a clear card must not win',
        );
      },
    );

    test('refinement keeps a valid quad on the measured source', () {
      final refined = refineQuadToEdges(scene(), onEdge);
      expect(refined, isNotNull);
      expect(refined, hasLength(4));
      expect(quadFitsImage(refined!, scene()), isTrue);
      for (final point in refined) {
        expect(point.x, inInclusiveRange(0, 1));
        expect(point.y, inInclusiveRange(0, 1));
      }
    });

    test('the isolate payload measures both claims against one image', () {
      final bytes = Uint8List.fromList(img.encodePng(scene()));
      final encoded = <double>[
        for (final p in insideCard) p.x,
        for (final p in insideCard) p.y,
      ];
      final both = measureBoundaryCandidates(bytes, encoded);
      expect(both.sourceWidth, 240);
      expect(both.sourceHeight, 170);
      expect(both.learned, isNotNull);
      expect(both.learned!.evidence.quality, isFinite);
      expect(measureBoundaryCandidates(bytes, null).learned, isNull);
    });
  });
}
