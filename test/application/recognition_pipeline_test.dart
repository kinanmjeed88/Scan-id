import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/ocr_engine.dart';
import 'package:scan_id/application/recognition_pipeline.dart';
import 'package:scan_id/application/recognition_worker.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/ocr_evidence.dart';
import 'package:scan_id/imaging/document_segmenter.dart';

final _bytes = Uint8List.fromList([1, 2, 3]);

PipelineImageInput _input({String assetId = 'asset1'}) => PipelineImageInput(
  assetId: assetId,
  previewBytes: _bytes,
  sourceWidth: 1600,
  sourceHeight: 1000,
  importIndex: 0,
);

List<Point2> _quad() => [
  Point2(.1, .15),
  Point2(.9, .15),
  Point2(.9, .95),
  Point2(.1, .95),
];

Uint8List _twoRoundRegions() {
  final image = img.Image(width: 900, height: 700);
  img.fill(image, color: img.ColorRgb8(45, 55, 70));
  final regionColor = img.ColorRgb8(235, 233, 228);
  for (final center in [(230, 210), (670, 490)]) {
    for (var y = center.$2 - 100; y <= center.$2 + 100; y++) {
      for (var x = center.$1 - 100; x <= center.$1 + 100; x++) {
        final dx = x - center.$1, dy = y - center.$2;
        if (dx * dx + dy * dy <= 100 * 100) {
          image.setPixel(x, y, regionColor);
        }
      }
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _oneRoundRegion() {
  final image = img.Image(width: 900, height: 700);
  img.fill(image, color: img.ColorRgb8(45, 55, 70));
  const centerX = 450, centerY = 350, radius = 100;
  for (var y = centerY - radius; y <= centerY + radius; y++) {
    for (var x = centerX - radius; x <= centerX + radius; x++) {
      final dx = x - centerX, dy = y - centerY;
      if (dx * dx + dy * dy <= radius * radius) {
        image.setPixel(x, y, img.ColorRgb8(235, 233, 228));
      }
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _rectangleAndRoundRegions() {
  final image = img.Image(width: 900, height: 700);
  img.fill(image, color: img.ColorRgb8(45, 55, 70));
  img.fillRect(
    image,
    x1: 60,
    y1: 60,
    x2: 420,
    y2: 290,
    color: img.ColorRgb8(235, 233, 228),
  );
  const centerX = 670, centerY = 490, radius = 100;
  for (var y = centerY - radius; y <= centerY + radius; y++) {
    for (var x = centerX - radius; x <= centerX + radius; x++) {
      final dx = x - centerX, dy = y - centerY;
      if (dx * dx + dy * dy <= radius * radius) {
        image.setPixel(x, y, img.ColorRgb8(235, 233, 228));
      }
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

Future<SegmentationResult> _noMulti(Uint8List bytes) async =>
    const SegmentationResult(candidates: [], multi: false);

class _ThrowingOcr implements OcrEngine {
  @override
  String get version => 'broken-ocr-1';
  @override
  Future<OcrTextResult> recognize(
    Uint8List imageBytes, {
    CancellationToken? token,
  }) async => throw StateError('engine crashed');
}

void main() {
  test(
    'a valid quad is crop-authorized without inventing a document kind',
    () async {
      final pipeline = RecognitionPipeline(
        suggestSingle: (bytes) async => _quad(),
        segment: _noMulti,
      );
      final analysis = await pipeline.analyze(_input());
      expect(analysis.multi, isFalse);
      expect(analysis.issues, isEmpty);
      final detection = analysis.detections.single;
      expect(detection.detectionId, 'asset1-d0');
      expect(detection.hasUsableQuad, isTrue);
      expect(detection.cropAuthorization, isNotNull);
      expect(detection.geometry!.acceptable, isTrue);
      expect(detection.classification.kind, DocumentKind.unknown);
      expect(detection.classification.evidence, isEmpty);
      expect(
        detection.detectionConfidence,
        isNull,
        reason: 'the single detector has no calibrated score',
      );
    },
  );

  test('asset identity cannot create type or boundary evidence', () async {
    final pipeline = RecognitionPipeline(
      suggestSingle: (bytes) async => _quad(),
      segment: _noMulti,
    );
    final first = await pipeline.analyze(_input());
    final second = await pipeline.analyze(_input(assetId: 'another-asset'));
    final a = first.detections.single;
    final b = second.detections.single;
    expect(a.classification.kind, DocumentKind.unknown);
    expect(b.classification.kind, a.classification.kind);
    expect(b.classification.evidence, a.classification.evidence);
    expect(b.boundaryDecision?.kind, a.boundaryDecision?.kind);
    expect(b.cropAuthorization != null, a.cropAuthorization != null);
  });

  test(
    'segmentation failure degrades to the single path with an issue',
    () async {
      final pipeline = RecognitionPipeline(
        suggestSingle: (bytes) async => _quad(),
        segment: (bytes) async => throw StateError('segmenter crashed'),
      );
      final analysis = await pipeline.analyze(_input());
      expect(
        analysis.issues.map((i) => i.category),
        contains(RecognitionErrorCategory.segmentationFailure),
      );
      expect(analysis.detections.single.hasUsableQuad, isTrue);
    },
  );

  test('detector failure falls back to full frame with an issue', () async {
    final pipeline = RecognitionPipeline(
      suggestSingle: (bytes) async => throw StateError('detector crashed'),
      segment: _noMulti,
    );
    final analysis = await pipeline.analyze(_input());
    expect(
      analysis.issues.map((i) => i.category),
      contains(RecognitionErrorCategory.detectionFailure),
    );
    final detection = analysis.detections.single;
    expect(detection.hasUsableQuad, isFalse);
    expect(detection.corners, isNull);
  });

  test(
    'a geometrically rejected quad becomes full frame with an issue',
    () async {
      final crossed = [
        Point2(.1, .1),
        Point2(.9, .9),
        Point2(.9, .1),
        Point2(.1, .9),
      ];
      final pipeline = RecognitionPipeline(
        suggestSingle: (bytes) async => crossed,
        segment: _noMulti,
      );
      final analysis = await pipeline.analyze(_input());
      expect(
        analysis.issues.map((i) => i.category),
        contains(RecognitionErrorCategory.geometryFailure),
      );
      expect(analysis.detections.single.hasUsableQuad, isFalse);
    },
  );

  test(
    'multi path analyzes each candidate with stable detection ids',
    () async {
      final top = [
        Point2(.1, .05),
        Point2(.9, .05),
        Point2(.9, .45),
        Point2(.1, .45),
      ];
      final bottom = [
        Point2(.1, .55),
        Point2(.9, .55),
        Point2(.9, .95),
        Point2(.1, .95),
      ];
      final pipeline = RecognitionPipeline(
        suggestSingle: (bytes) async => fail('single path must not run'),
        segment: (bytes) async => SegmentationResult(
          multi: true,
          candidates: [
            SegmentCandidate(
              region: const [.1, .05, .9, .45],
              corners: top,
              detectionConfidence: .8,
              reason: 'component-support',
            ),
            SegmentCandidate(
              region: const [.1, .55, .9, .95],
              corners: bottom,
              detectionConfidence: .7,
              reason: 'component-support',
            ),
          ],
        ),
      );
      final analysis = await pipeline.analyze(_input());
      expect(analysis.multi, isTrue);
      expect(analysis.detections, hasLength(2));
      expect(analysis.detections[0].detectionId, 'asset1-d0');
      expect(analysis.detections[1].detectionId, 'asset1-d1');
      expect(analysis.detections[0].detectionConfidence, .8);
      expect(
        analysis.detections[0].classification.confidences.detection?.value,
        .8,
      );
    },
  );

  test(
    'an uncorroborated candidate keeps its confidence and cannot authorize an automatic crop',
    () async {
      final pipeline = RecognitionPipeline(
        suggestSingle: (bytes) => fail('measured region must not fall back'),
        segment: (bytes) async => SegmentationResult(
          multi: false,
          candidates: [
            SegmentCandidate(
              region: const [.1, .15, .9, .95],
              corners: _quad(),
              detectionConfidence: .91,
              producer: BoundaryProducer.learnedModel,
              minAutoAcceptConfidence: .55,
              requiresReview: true,
              reason: 'synthetic-unconfirmed-multi-region',
            ),
          ],
        ),
      );

      final analysis = await pipeline.analyze(_input());
      final detection = analysis.detections.single;
      final expected = _quad();
      expect(detection.detectionConfidence, .91);
      expect(detection.suggestedCorners, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect(detection.suggestedCorners![i].x, expected[i].x);
        expect(detection.suggestedCorners![i].y, expected[i].y);
      }
      expect(detection.corners, isNull);
      expect(detection.cropAuthorization, isNull);
      expect(detection.needsManualBoundary, isTrue);
      expect(analysis.needsMultiIntake, isTrue);
      expect(
        detection.boundaryDecision!.verification.reasons,
        contains(BoundaryReviewReason.multiSceneNotCorroborated),
      );
      expect(
        analysis.issues.map((issue) => issue.message),
        contains(
          boundaryReviewReasonMessage(
            BoundaryReviewReason.multiSceneNotCorroborated,
          ),
        ),
      );
    },
  );

  test('a cornerless candidate is an explicit issue, not a guess', () async {
    final pipeline = RecognitionPipeline(
      suggestSingle: (bytes) async => _quad(),
      segment: (bytes) async => SegmentationResult(
        // A measured candidate is not rejected merely because its corners are
        // unresolved; two candidates make this a multi-region source.
        multi: false,
        candidates: [
          const SegmentCandidate(
            region: [.1, .1, .5, .5],
            reason: 'no-trustworthy-quad',
          ),
          SegmentCandidate(
            region: const [.1, .55, .9, .95],
            corners: [
              Point2(.1, .55),
              Point2(.9, .55),
              Point2(.9, .95),
              Point2(.1, .95),
            ],
            detectionConfidence: .7,
            reason: 'component-support',
          ),
        ],
      ),
    );
    final analysis = await pipeline.analyze(_input());
    expect(
      analysis.issues.map((i) => i.category),
      contains(RecognitionErrorCategory.detectionFailure),
    );
    expect(analysis.detections, hasLength(1));
    expect(
      analysis.multi,
      isTrue,
      reason: 'both measured candidates count even when one lacks corners',
    );
    expect(analysis.unresolvedRegions, hasLength(1));
    expect(analysis.regionCount, 2);
    expect(analysis.needsMultiIntake, isTrue);
  });

  test(
    'synthetic segmentation preserves one measured cornerless region for manual recovery',
    () async {
      final bytes = _oneRoundRegion();
      final segmentation = segmentDocumentBytes(bytes);
      expect(segmentation.multi, isFalse);
      expect(segmentation.candidates, hasLength(1));
      expect(segmentation.candidates.single.corners, isNull);

      var singleCalled = false;
      final pipeline = RecognitionPipeline(
        suggestSingle: (preview) async {
          singleCalled = true;
          return _quad();
        },
        segment: (preview) async => segmentDocumentBytes(preview),
      );
      final analysis = await pipeline.analyze(
        PipelineImageInput(
          assetId: 'round-region',
          previewBytes: bytes,
          sourceWidth: 900,
          sourceHeight: 700,
          importIndex: 0,
        ),
      );

      expect(singleCalled, isFalse);
      expect(analysis.detections, isEmpty);
      expect(analysis.unresolvedRegions, hasLength(1));
      expect(analysis.unresolvedRegions.single.region, isNotNull);
      expect(analysis.unresolvedRegions.single.corners, isNull);
      expect(analysis.multi, isFalse);
      expect(analysis.needsMultiIntake, isTrue);
    },
  );

  test(
    'synthetic segmentation keeps a valid quad beside an unresolved measured region',
    () async {
      final bytes = _rectangleAndRoundRegions();
      final segmentation = segmentDocumentBytes(bytes);
      expect(segmentation.candidates, hasLength(2));
      expect(segmentation.candidates.first.corners, isNotNull);
      expect(segmentation.candidates.last.corners, isNull);

      var singleCalled = false;
      final pipeline = RecognitionPipeline(
        suggestSingle: (preview) async {
          singleCalled = true;
          return _quad();
        },
        segment: (preview) async => segmentDocumentBytes(preview),
      );
      final analysis = await pipeline.analyze(
        PipelineImageInput(
          assetId: 'mixed-regions',
          previewBytes: bytes,
          sourceWidth: 900,
          sourceHeight: 700,
          importIndex: 0,
        ),
      );

      expect(singleCalled, isFalse);
      expect(analysis.detections, hasLength(1));
      expect(analysis.detections.single.hasUsableQuad, isTrue);
      expect(analysis.unresolvedRegions, hasLength(1));
      expect(analysis.unresolvedRegions.single.corners, isNull);
      expect(analysis.multi, isTrue);
      expect(analysis.needsMultiIntake, isTrue);
    },
  );

  test(
    'synthetic segmentation preserves two plausible cornerless regions through pipeline',
    () async {
      final bytes = _twoRoundRegions();
      final segment = segmentDocumentBytes(bytes);
      expect(segment.multi, isFalse);
      expect(segment.candidates, hasLength(2));
      expect(
        segment.candidates.every((candidate) => candidate.corners == null),
        isTrue,
      );

      var singleCalled = false;
      final pipeline = RecognitionPipeline(
        suggestSingle: (preview) async {
          singleCalled = true;
          return _quad();
        },
        segment: (preview) async => segmentDocumentBytes(preview),
      );
      final analysis = await pipeline.analyze(
        PipelineImageInput(
          assetId: 'round-regions',
          previewBytes: bytes,
          sourceWidth: 900,
          sourceHeight: 700,
          importIndex: 0,
        ),
      );

      expect(singleCalled, isFalse);
      expect(analysis.detections, isEmpty);
      expect(analysis.unresolvedRegions, hasLength(2));
      expect(analysis.multi, isTrue);
      expect(analysis.needsMultiIntake, isTrue);
      expect(
        analysis.unresolvedRegions.every((region) => region.corners == null),
        isTrue,
      );
      expect(analysis.allRegions.map((region) => region.regionIndex), [0, 1]);
    },
  );

  test(
    'all measured candidates survive when the multi hint is false',
    () async {
      var singleCalled = false;
      final pipeline = RecognitionPipeline(
        suggestSingle: (bytes) async {
          singleCalled = true;
          return _quad();
        },
        segment: (bytes) async => const SegmentationResult(
          multi: false,
          candidates: [
            SegmentCandidate(
              region: [.1, .1, .45, .45],
              reason: 'no-trustworthy-quad',
            ),
            SegmentCandidate(
              region: [.55, .55, .9, .9],
              reason: 'no-trustworthy-quad',
            ),
          ],
        ),
      );

      final analysis = await pipeline.analyze(_input());

      expect(
        singleCalled,
        isFalse,
        reason: 'never replace candidates with a full frame',
      );
      expect(analysis.detections, isEmpty);
      expect(analysis.unresolvedRegions, hasLength(2));
      expect(analysis.allRegions.map((region) => region.regionIndex), [0, 1]);
      expect(analysis.multi, isTrue);
      expect(analysis.needsMultiIntake, isTrue);
      expect(
        analysis.unresolvedRegions.every((region) => region.corners == null),
        isTrue,
        reason: 'no corners may be invented for unresolved candidates',
      );
    },
  );

  test(
    'rejected unusable measurements are not promoted to candidates',
    () async {
      const rejected = RejectedRegion(
        region: [.01, .01, .03, .03],
        rejection: RegionRejection.unusableCrop,
        aspect: 1,
        areaFraction: .0004,
        fill: 1,
        borderSides: 0,
        cropWidth: 20,
        cropHeight: 20,
      );
      final pipeline = RecognitionPipeline(
        suggestSingle: (bytes) async => _quad(),
        segment: (bytes) async => const SegmentationResult(
          multi: true,
          candidates: [
            SegmentCandidate(
              region: [.1, .1, .45, .45],
              reason: 'no-trustworthy-quad',
            ),
            SegmentCandidate(
              region: [.55, .55, .9, .9],
              reason: 'no-trustworthy-quad',
            ),
          ],
          rejected: [rejected],
        ),
      );

      final analysis = await pipeline.analyze(_input());

      expect(analysis.unresolvedRegions, hasLength(2));
      expect(analysis.rejectedRegions, [rejected]);
      expect(
        analysis.regionCount,
        2,
        reason: 'rejected clutter is not retained as a candidate',
      );
      expect(analysis.allRegions.map((region) => region.region), [
        [.1, .1, .45, .45],
        [.55, .55, .9, .9],
      ]);
    },
  );

  test(
    'a valid measured quad is used even when the multi hint is false',
    () async {
      var singleCalled = false;
      final pipeline = RecognitionPipeline(
        suggestSingle: (bytes) async {
          singleCalled = true;
          return _quad();
        },
        segment: (bytes) async => SegmentationResult(
          multi: false,
          candidates: [
            SegmentCandidate(
              region: const [.08, .12, .92, .94],
              corners: _quad(),
              detectionConfidence: .75,
              reason: 'component-support',
            ),
          ],
        ),
      );

      final analysis = await pipeline.analyze(_input());

      expect(singleCalled, isFalse);
      expect(
        analysis.detections.single.corners
            ?.map((point) => [point.x, point.y])
            .toList(),
        _quad().map((point) => [point.x, point.y]).toList(),
      );
      expect(analysis.detections.single.region, [.08, .12, .92, .94]);
      expect(analysis.unresolvedRegions, isEmpty);
      expect(analysis.multi, isFalse);
      expect(analysis.needsMultiIntake, isFalse);
    },
  );

  test(
    'one unresolved measured region uses manual recovery, not a full-frame guess',
    () async {
      var singleCalled = false;
      final pipeline = RecognitionPipeline(
        suggestSingle: (bytes) async {
          singleCalled = true;
          return _quad();
        },
        segment: (bytes) async => const SegmentationResult(
          multi: false,
          candidates: [
            SegmentCandidate(
              region: [.2, .2, .8, .8],
              reason: 'no-trustworthy-quad',
            ),
          ],
        ),
      );

      final analysis = await pipeline.analyze(_input());

      expect(singleCalled, isFalse);
      expect(analysis.detections, isEmpty);
      expect(analysis.unresolvedRegions.single.region, [.2, .2, .8, .8]);
      expect(analysis.unresolvedRegions.single.corners, isNull);
      expect(analysis.needsMultiIntake, isTrue);
      expect(analysis.multi, isFalse);
    },
  );

  test('an unresolved region is kept and reportable, never dropped', () async {
    final pipeline = RecognitionPipeline(
      suggestSingle: (bytes) async => _quad(),
      segment: (bytes) async => SegmentationResult(
        multi: true,
        candidates: [
          const SegmentCandidate(
            region: [.1, .1, .5, .5],
            reason: 'no-trustworthy-quad',
          ),
          SegmentCandidate(
            region: const [.1, .55, .9, .95],
            corners: [
              Point2(.1, .55),
              Point2(.9, .55),
              Point2(.9, .95),
              Point2(.1, .95),
            ],
            detectionConfidence: .7,
            reason: 'component-support',
          ),
        ],
      ),
    );
    final analysis = await pipeline.analyze(_input());
    expect(
      analysis.issues.map((i) => i.category),
      contains(RecognitionErrorCategory.detectionFailure),
    );
    // The measured region SURVIVES with its bounds so it can be recovered:
    // dropping it is how a multi-region source loses a measured candidate.
    expect(analysis.unresolvedRegions, hasLength(1));
    final unresolved = analysis.unresolvedRegions.single;
    expect(unresolved.region, [.1, .1, .5, .5]);
    expect(unresolved.corners, isNull, reason: 'no rectangle is invented');
    expect(unresolved.boundary, DetectionBoundary.undetected);
    expect(unresolved.needsManualBoundary, isTrue);
    // Deterministic region order is preserved across both channels.
    expect(analysis.allRegions.map((d) => d.regionIndex).toList(), [0, 1]);
    expect(analysis.regionCount, 2);
    // A multi-region source must never take the single-document path: that
    // path would crop the SOURCE asset to one quad (ADR-003).
    expect(analysis.needsMultiIntake, isTrue);
  });

  test(
    'a geometrically rejected quad keeps its region for manual recovery',
    () async {
      final crossed = [
        Point2(.1, .1),
        Point2(.9, .9),
        Point2(.9, .1),
        Point2(.1, .9),
      ];
      final pipeline = RecognitionPipeline(
        suggestSingle: (bytes) async => crossed,
        segment: (bytes) async => SegmentationResult(
          multi: true,
          candidates: [
            SegmentCandidate(
              region: const [.1, .1, .9, .9],
              corners: crossed,
              detectionConfidence: .6,
              reason: 'component-support',
            ),
            SegmentCandidate(
              region: const [.05, .05, .5, .4],
              corners: [
                Point2(.05, .05),
                Point2(.5, .05),
                Point2(.5, .4),
                Point2(.05, .4),
              ],
              detectionConfidence: .7,
              reason: 'component-support',
            ),
          ],
        ),
      );
      final analysis = await pipeline.analyze(_input());
      expect(
        analysis.issues.map((i) => i.category),
        contains(RecognitionErrorCategory.geometryFailure),
      );
      final rejected = analysis.detections.firstWhere(
        (d) => d.boundary == DetectionBoundary.rejected,
      );
      expect(rejected.corners, isNull);
      expect(rejected.region, [.1, .1, .9, .9], reason: 'bounds are kept');
      expect(rejected.needsManualBoundary, isTrue);
      // Both regions are still present, so neither is silently lost.
      expect(analysis.regionCount, 2);
      expect(analysis.needsMultiIntake, isTrue);
    },
  );

  test(
    'one measured region with rejected corners uses the manual recovery intake',
    () async {
      final crossed = [
        Point2(.1, .1),
        Point2(.9, .9),
        Point2(.9, .1),
        Point2(.1, .9),
      ];
      var singleCalled = false;
      final pipeline = RecognitionPipeline(
        suggestSingle: (bytes) async {
          singleCalled = true;
          return _quad();
        },
        segment: (bytes) async => SegmentationResult(
          multi: false,
          candidates: [
            SegmentCandidate(
              region: const [.2, .15, .8, .85],
              corners: crossed,
              detectionConfidence: .6,
              reason: 'component-support',
            ),
          ],
        ),
      );

      final analysis = await pipeline.analyze(_input());
      final detection = analysis.detections.single;

      expect(singleCalled, isFalse);
      expect(analysis.multi, isFalse);
      expect(analysis.needsMultiIntake, isTrue);
      expect(detection.region, [.2, .15, .8, .85]);
      expect(detection.corners, isNull);
      expect(detection.boundary, DetectionBoundary.rejected);
      expect(detection.hasUsableQuad, isFalse);
    },
  );

  test('without an offline OCR result, classification stays unknown', () async {
    final pipeline = RecognitionPipeline(
      suggestSingle: (bytes) async => _quad(),
      segment: _noMulti,
    );
    final analysis = await pipeline.analyze(_input());
    final classification = analysis.detections.single.classification;
    expect(classification.kind, DocumentKind.unknown);
    expect(classification.evidence, isEmpty);
    expect(classification.confidences.ocr, isNull);
  });

  test('OCR failure is an issue and never aborts the analysis', () async {
    final pipeline = RecognitionPipeline(
      suggestSingle: (bytes) async => _quad(),
      segment: _noMulti,
      ocr: _ThrowingOcr(),
    );
    final analysis = await pipeline.analyze(_input());
    expect(
      analysis.issues.map((i) => i.category),
      contains(RecognitionErrorCategory.ocrFailure),
    );
    expect(
      analysis.detections.single.classification.kind,
      DocumentKind.unknown,
    );
  });

  test(
    'the shipped default OCR engine reports honest unavailability',
    () async {
      const engine = UnavailableOcrEngine();
      final result = await engine.recognize(_bytes);
      expect(result.isAvailable, isFalse);
      expect(result.unavailableReason, 'no-offline-engine-packaged');
      expect(ocrKeywordEvidence(result), isEmpty);
    },
  );

  test('cancellation stops analysis with OperationCancelled', () async {
    final token = CancellationToken()..cancel();
    final pipeline = RecognitionPipeline(
      suggestSingle: (bytes) async => _quad(),
      segment: _noMulti,
    );
    expect(
      () => pipeline.analyze(_input(), token: token),
      throwsA(isA<OperationCancelled>()),
    );
  });
}
