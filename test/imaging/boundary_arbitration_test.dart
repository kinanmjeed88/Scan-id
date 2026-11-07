import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/imaging/boundary_arbitration.dart';
import 'package:scan_id/imaging/document_detector.dart';

// A clear photo can yield four geometrically VALID points that sit in the
// middle of the card. assessQuad cannot see that; measured edge support can.
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

BoundaryProposal learned() => BoundaryProposal(
  producer: BoundaryProducer.learnedModel,
  corners: learnedQuad,
  modelConfidence: .46,
  minAutoAcceptConfidence: .70,
);

void main() {
  test('a weaker-measured learned quad is replaced by the edge-based quad', () {
    final result = arbitrateBoundaryProposal(
      learned: learned(),
      measurements: BoundaryMeasurements(
        sourceWidth: 400,
        sourceHeight: 250,
        learned: candidate(learnedQuad, .2, .1),
        classical: candidate(classicalQuad, .9, .8),
      ),
    );
    expect(result, isNotNull);
    expect(result!.producer, BoundaryProducer.detector);
    expect(result.corners, classicalQuad);
    expect(result.forceReview, isTrue);
    expect(result.forceReviewReason, BoundaryReviewReason.modelDisagreement);
    // A classical candidate NEVER inherits a learned confidence: it is still
    // routed to review by verifyBoundary as an uncalibrated classical score.
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
      measurements: BoundaryMeasurements(
        sourceWidth: 400,
        sourceHeight: 250,
        learned: candidate(refined, .9, .8, refined: true),
        classical: candidate(classicalQuad, .88, .8),
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
      measurements: BoundaryMeasurements(
        sourceWidth: 400,
        sourceHeight: 250,
        classical: candidate(classicalQuad, .9, .8),
      ),
    );
    expect(result!.producer, BoundaryProducer.detector);
    expect(result.corners, classicalQuad);
    expect(result.forceReview, isFalse);
    expect(result.modelConfidence, isNull);
  });

  test('no measurable candidate yields no proposal at all', () {
    expect(
      arbitrateBoundaryProposal(
        learned: BoundaryProposal(
          producer: BoundaryProducer.learnedModel,
          corners: learnedQuad,
        ),
        measurements: const BoundaryMeasurements(
          sourceWidth: 400,
          sourceHeight: 250,
        ),
      ),
      isNull,
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
      greaterThan(.04),
    );
  });

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
      final measurements = measureBoundaryCandidates(bytes, encoded);
      expect(measurements.sourceWidth, 240);
      expect(measurements.sourceHeight, 170);
      expect(measurements.learned, isNotNull);
      expect(measurements.learned!.evidence.quality, isFinite);
      expect(measureBoundaryCandidates(bytes, null).learned, isNull);
    });
  });
}
