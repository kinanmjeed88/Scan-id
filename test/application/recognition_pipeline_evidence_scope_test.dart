import 'dart:async';
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

// Where the pipeline reads text, and what that text is allowed to decide.
//
// Measured on the first field photo: the card fills the frame, the only
// proposal was a sliver, and OCR was confined to that sliver, so it read one
// line and the kind stayed unknown although the frame held sixteen readable
// lines. An unauthorized proposal may add evidence; it must not suppress it.
// Nor may evidence read outside a proposal be used to accept that proposal.
//
// Synthetic images and dictionary phrases only.

const _previewWidth = 400;
const _previewHeight = 250;

final Uint8List _preview = () {
  final image = img.Image(width: _previewWidth, height: _previewHeight);
  img.fill(image, color: img.ColorRgb8(235, 233, 228));
  return Uint8List.fromList(img.encodePng(image));
}();

PipelineImageInput _input() => PipelineImageInput(
  assetId: 'asset1',
  previewBytes: _preview,
  sourceWidth: 1600,
  sourceHeight: 1000,
  importIndex: 0,
);

Future<SegmentationResult> _noMulti(Uint8List bytes) async =>
    const SegmentationResult(candidates: [], multi: false);

List<Point2> _rect(double l, double t, double r, double b) => [
  Point2(l, t),
  Point2(r, t),
  Point2(r, b),
  Point2(l, b),
];

/// A fragment of the frame: valid geometry, far too small to be the card.
final _sliver = _rect(.40, .30, .60, .85);

/// The frame-wide quad the existing catalog-corroboration test uses: its
/// measured aspect matches the unified card.
final _cardShaped = _rect(.1, .15, .9, .95);

OcrLine _line(String text, double confidence, double x, double y) => OcrLine(
  text: text,
  confidence: confidence,
  bounds: _rect(x - .04, y - .02, x + .04, y + .02),
);

/// The card as the frame read sees it: number, a field label and the issuer.
List<OcrLine> _card(List<(double, double)> at) => [
  _line('199000000000', 1, at[0].$1, at[0].$2),
  _line('الاسم', .9, at[1].$1, at[1].$2),
  _line('وزارة الداخلية', .8, at[2].$1, at[2].$2),
];

const _outsideSliver = [(.80, .10), (.80, .50), (.10, .90)];
const _insideSliver = [(.50, .40), (.50, .55), (.50, .70)];
final _noEvidence = [OcrLine(text: 'نص', confidence: .9)];

/// Answers by what it was shown: the whole preview, or a crop of a proposal.
class _ScopedOcr implements OcrEngine {
  _ScopedOcr({
    required this.inside,
    required this.frame,
    this.frameThrows = false,
    this.stall = false,
  });

  final List<OcrLine> inside;
  final List<OcrLine> frame;
  final bool frameThrows;
  final bool stall;
  final reads = <(int, int)>[];

  bool get readTheFrame => reads.contains((_previewWidth, _previewHeight));

  @override
  String get version => 'scoped-ocr-1';

  @override
  bool get isEnabled => true;

  @override
  Future<OcrTextResult> recognize(
    Uint8List imageBytes, {
    CancellationToken? token,
  }) async {
    final image = img.decodeImage(imageBytes)!;
    reads.add((image.width, image.height));
    if (stall) return Completer<OcrTextResult>().future;
    final whole =
        image.width == _previewWidth && image.height == _previewHeight;
    if (whole && frameThrows) throw StateError('engine crashed');
    return OcrTextResult.available(
      lines: whole ? frame : inside,
      engineVersion: version,
    );
  }
}

RecognitionPipeline _learned(
  OcrEngine ocr, {
  List<Point2>? corners,
  Duration? ocrBudget,
}) => RecognitionPipeline(
  suggestSingle: (_) async => null,
  suggestProposal: (_) async => BoundaryProposal(
    producer: BoundaryProducer.learnedModel,
    corners: corners ?? _sliver,
    modelConfidence: .21,
    minAutoAcceptConfidence: .55,
  ),
  segment: _noMulti,
  ocr: ocr,
  ocrBudget: ocrBudget ?? defaultPipelineOcrBudget,
);

RecognitionPipeline _classical(OcrEngine ocr) => RecognitionPipeline(
  suggestSingle: (_) async => null,
  segment: (_) async => SegmentationResult(
    candidates: [
      SegmentCandidate(
        region: [0, 0, 1, 1],
        corners: _cardShaped,
        producer: BoundaryProducer.detector,
        reason: 'test-classical-quad',
      ),
    ],
    multi: false,
  ),
  ocr: ocr,
);

void main() {
  group('an unauthorized proposal does not suppress the frame text', () {
    test(
      'its own text evidences nothing, so the frame is read once more',
      () async {
        final ocr = _ScopedOcr(
          inside: _noEvidence,
          frame: _card(_outsideSliver),
        );
        final analysis = await _learned(ocr).analyze(_input());
        final detection = analysis.detections.single;

        expect(ocr.reads, hasLength(2));
        expect(ocr.reads.last, (_previewWidth, _previewHeight));
        expect(detection.classification.kind, DocumentKind.unifiedNationalId);
      },
    );

    test(
      'a proposal that leaves that text outside is refused, not kept',
      () async {
        final ocr = _ScopedOcr(
          inside: _noEvidence,
          frame: _card(_outsideSliver),
        );
        final analysis = await _learned(ocr).analyze(_input());
        final detection = analysis.detections.single;
        final decision = detection.boundaryDecision!;

        expect(decision.kind, BoundaryDecisionKind.rejected);
        expect(decision.verification.reasons, [
          BoundaryReviewReason.excludesDocumentText,
        ]);
        expect(detection.suggestedCorners, isNull);
        expect(detection.corners, isNull);
        expect(detection.cropAuthorization, isNull);
        // The person is told once, with the decisive reason only.
        expect(analysis.issues.map((issue) => issue.message), [
          boundaryReviewReasonMessage(
            BoundaryReviewReason.excludesDocumentText,
          ),
        ]);
      },
    );

    test('a proposal that contains that text stays a suggestion', () async {
      final ocr = _ScopedOcr(inside: _noEvidence, frame: _card(_insideSliver));
      final analysis = await _learned(ocr).analyze(_input());
      final detection = analysis.detections.single;

      expect(detection.classification.kind, DocumentKind.unifiedNationalId);
      expect(
        detection.boundaryDecision!.kind,
        BoundaryDecisionKind.needsReview,
      );
      expect(
        detection.boundaryDecision!.verification.reasons,
        contains(BoundaryReviewReason.lowModelConfidence),
      );
      expect(detection.suggestedCorners, _sliver);
      expect(detection.cropAuthorization, isNull);
    });

    test('lines the engine did not locate cannot refuse a proposal', () async {
      final ocr = _ScopedOcr(
        inside: _noEvidence,
        frame: [
          OcrLine(text: '199000000000', confidence: 1),
          OcrLine(text: 'الاسم', confidence: .9),
          OcrLine(text: 'وزارة الداخلية', confidence: .8),
        ],
      );
      final detection = (await _learned(
        ocr,
      ).analyze(_input())).detections.single;
      expect(detection.classification.kind, DocumentKind.unifiedNationalId);
      expect(detection.suggestedCorners, _sliver);
    });
  });

  group('what the wider read may not do', () {
    test(
      'evidence read outside a proposal never accepts that proposal',
      () async {
        // A classical quad with the catalog shape. Its own text says nothing;
        // the text that names the kind was read from the wider area.
        final ocr = _ScopedOcr(
          inside: _noEvidence,
          frame: [
            _line('البطاقة الوطنية الموحدة', .96, .5, .4),
            _line('الرقم الوطني', .94, .5, .6),
          ],
        );
        final detection = (await _classical(
          ocr,
        ).analyze(_input())).detections.single;

        expect(ocr.reads, hasLength(2));
        expect(detection.classification.kind, DocumentKind.unifiedNationalId);
        expect(
          detection.boundaryDecision!.kind,
          BoundaryDecisionKind.needsReview,
        );
        expect(detection.boundaryDecision!.verification.corroboration, isNull);
        expect(detection.cropAuthorization, isNull);
        expect(detection.suggestedCorners, _cardShaped);
      },
    );

    test(
      'control: the same quad is accepted when ITS text names the kind',
      () async {
        final lines = [
          OcrLine(text: 'البطاقة الوطنية الموحدة', confidence: .96),
          OcrLine(text: 'الرقم الوطني', confidence: .94),
        ];
        final ocr = _ScopedOcr(inside: lines, frame: lines);
        final detection = (await _classical(
          ocr,
        ).analyze(_input())).detections.single;

        expect(ocr.reads, hasLength(1));
        expect(detection.boundaryDecision!.kind, BoundaryDecisionKind.accepted);
        expect(
          detection.boundaryDecision!.verification.corroboration,
          BoundaryCorroboration.classicalCatalogAspect,
        );
      },
    );

    test('a frame read without evidence changes nothing', () async {
      final ocr = _ScopedOcr(inside: _noEvidence, frame: _noEvidence);
      final analysis = await _learned(ocr).analyze(_input());
      final detection = analysis.detections.single;

      expect(ocr.reads, hasLength(2));
      expect(detection.classification.kind, DocumentKind.unknown);
      expect(
        detection.boundaryDecision!.kind,
        BoundaryDecisionKind.needsReview,
      );
      expect(detection.suggestedCorners, _sliver);
    });

    test(
      'a failed frame read keeps the first read and reports nothing new',
      () async {
        final ocr = _ScopedOcr(
          inside: _noEvidence,
          frame: const [],
          frameThrows: true,
        );
        final analysis = await _learned(ocr).analyze(_input());

        expect(ocr.reads, hasLength(2));
        expect(
          analysis.detections.single.classification.kind,
          DocumentKind.unknown,
        );
        expect(
          analysis.issues.where(
            (issue) => issue.category == RecognitionErrorCategory.ocrFailure,
          ),
          isEmpty,
        );
      },
    );
  });

  group('when no second read is made', () {
    test(
      'an authorized quad is read once, even with no evidence in it',
      () async {
        final ocr = _ScopedOcr(
          inside: _noEvidence,
          frame: _card(_outsideSliver),
        );
        final pipeline = RecognitionPipeline(
          suggestSingle: (_) async => _cardShaped,
          segment: _noMulti,
          ocr: ocr,
        );
        final detection = (await pipeline.analyze(_input())).detections.single;

        expect(detection.cropAuthorization, isNotNull);
        expect(ocr.reads, hasLength(1));
        expect(ocr.readTheFrame, isFalse);
        expect(detection.classification.kind, DocumentKind.unknown);
      },
    );

    test('a proposal whose own text has evidence is read once', () async {
      final ocr = _ScopedOcr(
        inside: _card(_insideSliver),
        frame: _card(_outsideSliver),
      );
      final detection = (await _learned(
        ocr,
      ).analyze(_input())).detections.single;

      expect(ocr.reads, hasLength(1));
      expect(detection.classification.kind, DocumentKind.unifiedNationalId);
      expect(detection.suggestedCorners, _sliver);
    });

    test('a first read that used up the OCR budget is not followed', () async {
      final ocr = _ScopedOcr(
        inside: _noEvidence,
        frame: _noEvidence,
        stall: true,
      );
      final analysis = await _learned(
        ocr,
        ocrBudget: const Duration(milliseconds: 60),
      ).analyze(_input());

      expect(ocr.reads, hasLength(1));
      expect(
        analysis.detections.single.classification.kind,
        DocumentKind.unknown,
      );
    });
  });

  group('documents sharing a frame stay isolated', () {
    test(
      'the wider read of one document is its own region, never the frame',
      () async {
        final ocr = _ScopedOcr(
          inside: _noEvidence,
          frame: _card(_outsideSliver),
        );
        final pipeline = RecognitionPipeline(
          suggestSingle: (_) async =>
              fail('a measured multi-image skips single'),
          segment: (_) async => SegmentationResult(
            multi: true,
            candidates: [
              SegmentCandidate(
                region: const [.02, .04, .48, .96],
                corners: _rect(.05, .08, .45, .92),
                detectionConfidence: .9,
                producer: BoundaryProducer.learnedModel,
                minAutoAcceptConfidence: .55,
                requiresReview: true,
                reason: 'synthetic-unconfirmed-region',
              ),
              SegmentCandidate(
                region: const [.52, .04, .98, .96],
                corners: _rect(.55, .08, .95, .92),
                detectionConfidence: .9,
                producer: BoundaryProducer.learnedModel,
                minAutoAcceptConfidence: .55,
                requiresReview: true,
                reason: 'synthetic-unconfirmed-region',
              ),
            ],
          ),
          ocr: ocr,
        );
        final analysis = await pipeline.analyze(_input());

        expect(analysis.detections, hasLength(2));

        // Each document was read inside its quad, then over its own measured

        // region, which is larger than the quad and smaller than the frame.

        expect(ocr.reads, hasLength(4));

        expect(ocr.reads.toSet(), hasLength(2));
        expect(ocr.readTheFrame, isFalse);
        for (final detection in analysis.detections) {
          expect(detection.classification.kind, DocumentKind.unknown);
        }
      },
    );
  });
}
