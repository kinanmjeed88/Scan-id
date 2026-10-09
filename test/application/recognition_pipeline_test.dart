import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/ocr_engine.dart';
import 'package:scan_id/application/recognition_pipeline.dart';
import 'package:scan_id/application/recognition_worker.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/ocr_evidence.dart';
import 'package:scan_id/imaging/document_segmenter.dart';

final _bytes = Uint8List.fromList([1, 2, 3]);

PipelineImageInput _input({String name = 'البطاقة الوطنية الموحدة.png'}) =>
    PipelineImageInput(
      assetId: 'asset1',
      name: name,
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

Future<SegmentationResult> _noMulti(Uint8List bytes) async =>
    const SegmentationResult(candidates: [], multi: false);

class _KeywordOcr implements OcrEngine {
  @override
  String get version => 'fake-ocr-1';
  @override
  Future<OcrTextResult> recognize(
    Uint8List imageBytes, {
    CancellationToken? token,
  }) async => OcrTextResult.available(
    lines: [OcrLine(text: 'جواز سفر', confidence: .85)],
    engineVersion: version,
  );
}

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
  test('single path: quad accepted, classified, no issues', () async {
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
    expect(detection.geometry!.acceptable, isTrue);
    expect(
      detection.classification.kind,
      DocumentKind.unifiedNationalId,
      reason: '0.8×1599 by 0.8×999 ≈ the ID-1 shape',
    );
    expect(
      detection.detectionConfidence,
      isNull,
      reason: 'the single detector has no calibrated score',
    );
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
      final analysis = await pipeline.analyze(_input(name: 'cards.png'));
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

  test('a cornerless candidate is an explicit issue, not a guess', () async {
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
    final analysis = await pipeline.analyze(_input(name: 'cards.png'));
    expect(
      analysis.issues.map((i) => i.category),
      contains(RecognitionErrorCategory.detectionFailure),
    );
    expect(analysis.detections, hasLength(1));
    expect(
      analysis.multi,
      isFalse,
      reason: 'one usable quad is not a multi-document image',
    );
  });

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
    final analysis = await pipeline.analyze(_input(name: 'cards.png'));
    expect(
      analysis.issues.map((i) => i.category),
      contains(RecognitionErrorCategory.detectionFailure),
    );
    // The measured region SURVIVES with its bounds so it can be recovered:
    // dropping it is how a photo of several documents loses one.
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
      final analysis = await pipeline.analyze(_input(name: 'cards.png'));
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

  test('OCR keywords become evidence; the engine version is visible', () async {
    final pipeline = RecognitionPipeline(
      suggestSingle: (bytes) async => _quad(),
      segment: _noMulti,
      ocr: _KeywordOcr(),
    );
    final analysis = await pipeline.analyze(_input(name: 'IMG_1.png'));
    final classification = analysis.detections.single.classification;
    expect(classification.evidence.map((e) => e.kind), contains('ocr-keyword'));
    expect(classification.confidences.ocr?.value, .85);
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
      DocumentKind.unifiedNationalId,
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
