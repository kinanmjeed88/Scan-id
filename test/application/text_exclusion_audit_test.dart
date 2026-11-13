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

// Audit of the `excludesDocumentText` refusal: which documents can it touch?
//
// The refusal removes a boundary SUGGESTION when the text that names the
// document was read from the wider area and most of that text lies outside
// the suggested quadrilateral. It must never fire because a document has
// little text, because OCR failed, or because text sits close to an edge.
// These tests walk those cases, and they also pin the one situation the rule
// cannot tell apart, so that it is a documented limit and not a surprise.
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

/// The proposal under test: the middle of the frame.
final _proposal = _rect(.30, .30, .70, .70);

/// A frame-wide quad whose measured aspect matches the unified card.
final _cardShaped = _rect(.1, .15, .9, .95);

OcrLine _at(
  String text,
  double confidence,
  double x,
  double y, {
  double halfWidth = .04,
}) => OcrLine(
  text: text,
  confidence: confidence,
  bounds: _rect(x - halfWidth, y - .02, x + halfWidth, y + .02),
);

/// The three facts that evidence the unified card, at the given centres.
List<OcrLine> _card(List<(double, double)> at, {double halfWidth = .04}) => [
  _at('199000000000', 1, at[0].$1, at[0].$2, halfWidth: halfWidth),
  _at('الاسم', .9, at[1].$1, at[1].$2, halfWidth: halfWidth),
  _at('وزارة الداخلية', .8, at[2].$1, at[2].$2, halfWidth: halfWidth),
];

/// Lines that are text but evidence nothing.
List<OcrLine> _filler(List<(double, double)> at) => [
  for (final (x, y) in at) _at('نص', .9, x, y),
];

enum _FirstRead { answers, unavailable, throws }

/// Answers by what it was shown: the whole preview, or a crop of a proposal.
class _ScopedOcr implements OcrEngine {
  _ScopedOcr({
    required this.inside,
    required this.frame,
    this.first = _FirstRead.answers,
    this.enabled = true,
  });

  final List<OcrLine> inside;
  final List<OcrLine> frame;
  final _FirstRead first;
  final bool enabled;
  final reads = <(int, int)>[];

  @override
  String get version => 'exclusion-audit-ocr-1';

  @override
  bool get isEnabled => enabled;

  @override
  Future<OcrTextResult> recognize(
    Uint8List imageBytes, {
    CancellationToken? token,
  }) async {
    final image = img.decodeImage(imageBytes)!;
    reads.add((image.width, image.height));
    final whole =
        image.width == _previewWidth && image.height == _previewHeight;
    if (!whole && first == _FirstRead.throws) throw StateError('engine');
    if (!whole && first == _FirstRead.unavailable) {
      return OcrTextResult.unavailable(
        unavailableReason: 'model-missing',
        engineVersion: version,
      );
    }
    return OcrTextResult.available(
      lines: whole ? frame : inside,
      engineVersion: version,
    );
  }
}

RecognitionPipeline _learned(OcrEngine ocr, {List<Point2>? corners}) =>
    RecognitionPipeline(
      suggestSingle: (_) async => null,
      suggestProposal: (_) async => BoundaryProposal(
        producer: BoundaryProducer.learnedModel,
        corners: corners ?? _proposal,
        modelConfidence: .21,
        minAutoAcceptConfidence: .55,
      ),
      segment: _noMulti,
      ocr: ocr,
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

Future<DetectionAnalysis> _detect(RecognitionPipeline pipeline) async =>
    (await pipeline.analyze(_input())).detections.single;

bool _refused(DetectionAnalysis detection) => detection
    .boundaryDecision!
    .verification
    .reasons
    .contains(BoundaryReviewReason.excludesDocumentText);

void _expectKeptForReview(DetectionAnalysis detection) {
  expect(_refused(detection), isFalse);
  expect(detection.boundaryDecision!.kind, BoundaryDecisionKind.needsReview);
  expect(detection.suggestedCorners, _proposal);
  expect(detection.cropAuthorization, isNull);
}

void _expectRefusedAndWhole(DetectionAnalysis detection) {
  expect(detection.boundaryDecision!.kind, BoundaryDecisionKind.rejected);
  expect(detection.boundaryDecision!.verification.reasons, [
    BoundaryReviewReason.excludesDocumentText,
  ]);
  // Nothing is cropped and nothing is offered: the image stays whole.
  expect(detection.suggestedCorners, isNull);
  expect(detection.corners, isNull);
  expect(detection.cropAuthorization, isNull);
}

void main() {
  group('a document that cannot be read is never refused for it', () {
    test('no text anywhere in the frame', () async {
      final ocr = _ScopedOcr(inside: const [], frame: const []);
      final detection = await _detect(_learned(ocr));

      _expectKeptForReview(detection);
      expect(detection.classification.kind, DocumentKind.unknown);
    });

    test('text everywhere, but none that names a document', () async {
      final ocr = _ScopedOcr(
        inside: _filler(const [(.5, .5)]),
        frame: _filler(const [(.1, .1), (.9, .1), (.1, .9), (.9, .9)]),
      );
      final detection = await _detect(_learned(ocr));

      // Every located line is outside the proposal, and still nothing is
      // refused: without evidence the frame text does not describe a document.
      _expectKeptForReview(detection);
      expect(detection.classification.kind, DocumentKind.unknown);
    });

    test('the engine is unavailable: one read, no refusal', () async {
      final ocr = _ScopedOcr(
        inside: const [],
        frame: _card(const [(.1, .1), (.9, .1), (.1, .9)]),
        first: _FirstRead.unavailable,
      );
      final detection = await _detect(_learned(ocr));

      expect(ocr.reads, hasLength(1));
      _expectKeptForReview(detection);
      expect(detection.classification.kind, DocumentKind.unknown);
    });

    test('the engine fails: an OCR failure is reported, not a boundary '
        'refusal', () async {
      final ocr = _ScopedOcr(
        inside: const [],
        frame: _card(const [(.1, .1), (.9, .1), (.1, .9)]),
        first: _FirstRead.throws,
      );
      final analysis = await _learned(ocr).analyze(_input());
      final detection = analysis.detections.single;

      expect(ocr.reads, hasLength(1));
      _expectKeptForReview(detection);
      expect(
        analysis.issues.where(
          (issue) => issue.category == RecognitionErrorCategory.ocrFailure,
        ),
        hasLength(1),
      );
      expect(
        analysis.issues.map((issue) => issue.message),
        isNot(
          contains(
            boundaryReviewReasonMessage(
              BoundaryReviewReason.excludesDocumentText,
            ),
          ),
        ),
      );
    });

    test('OCR is switched off: nothing is read and nothing refused', () async {
      final ocr = _ScopedOcr(
        inside: const [],
        frame: _card(const [(.1, .1), (.9, .1), (.1, .9)]),
        enabled: false,
      );
      final detection = await _detect(_learned(ocr));

      expect(ocr.reads, isEmpty);
      _expectKeptForReview(detection);
    });
  });

  group('a document with little text', () {
    test('three lines, all inside the proposal', () async {
      final ocr = _ScopedOcr(
        inside: const [],
        frame: _card(const [(.5, .4), (.5, .5), (.5, .6)]),
      );
      final detection = await _detect(_learned(ocr));

      _expectKeptForReview(detection);
      expect(detection.classification.kind, DocumentKind.unifiedNationalId);
    });

    test('three lines, two inside: most of the text is inside', () async {
      final ocr = _ScopedOcr(
        inside: const [],
        frame: _card(const [(.5, .4), (.5, .6), (.9, .9)]),
      );
      _expectKeptForReview(await _detect(_learned(ocr)));
    });

    test('four lines, two inside: an even split is not "most"', () async {
      final ocr = _ScopedOcr(
        inside: const [],
        frame: [
          ..._card(const [(.5, .4), (.5, .6), (.9, .9)]),
          ..._filler(const [(.1, .1)]),
        ],
      );
      _expectKeptForReview(await _detect(_learned(ocr)));
    });

    test('three lines, one inside: the proposal frames a fragment', () async {
      final ocr = _ScopedOcr(
        inside: const [],
        frame: _card(const [(.5, .5), (.9, .1), (.1, .9)]),
      );
      _expectRefusedAndWhole(await _detect(_learned(ocr)));
    });
  });

  group('a document that is more picture than text', () {
    test('its few lines sit in one corner of a proposal that frames it '
        'whole', () async {
      // The rectified read finds nothing; the frame read finds the three
      // lines, all in the top-right corner of the proposal.
      final ocr = _ScopedOcr(
        inside: const [],
        frame: _card(const [(.62, .33), (.64, .37), (.66, .41)]),
      );
      final detection = await _detect(_learned(ocr));

      _expectKeptForReview(detection);
      // The kind is known from the frame read, and still nothing is cropped
      // on its strength.
      expect(detection.classification.kind, DocumentKind.unifiedNationalId);
      expect(detection.boundaryDecision!.verification.corroboration, isNull);
    });
  });

  group('text close to the edges', () {
    test('centres just inside every side', () async {
      final ocr = _ScopedOcr(
        inside: const [],
        frame: [
          ..._card(const [(.302, .5), (.698, .5), (.5, .302)]),
          ..._filler(const [(.5, .698)]),
        ],
      );
      _expectKeptForReview(await _detect(_learned(ocr)));
    });

    test('centres exactly on the sides count as inside', () async {
      final ocr = _ScopedOcr(
        inside: const [],
        frame: [
          ..._card(const [(.30, .5), (.70, .5), (.5, .30)]),
          ..._filler(const [(.5, .70)]),
        ],
      );
      _expectKeptForReview(await _detect(_learned(ocr)));
    });

    test('wide lines that cross a side, with their centres inside', () async {
      final ocr = _ScopedOcr(
        inside: const [],
        frame: _card(const [(.34, .4), (.66, .5), (.34, .6)], halfWidth: .12),
      );
      _expectKeptForReview(await _detect(_learned(ocr)));
    });
  });

  group('two columns of text', () {
    // Left column inside the proposal, right column outside it.
    const left = [(.40, .35), (.40, .45), (.40, .55), (.40, .65)];
    const right = [(.90, .35), (.90, .45), (.90, .55), (.90, .65)];

    test('the proposal frames the column that holds half of the lines '
        'or more', () async {
      final ocr = _ScopedOcr(
        inside: const [],
        frame: [
          ..._card(left.sublist(0, 3)),
          ..._filler([left[3]]),
          ..._filler(right),
        ],
      );
      _expectKeptForReview(await _detect(_learned(ocr)));
    });

    test('the proposal frames the minor column: it is a fragment of the '
        'page', () async {
      final ocr = _ScopedOcr(
        inside: const [],
        frame: [
          ..._card(left.sublist(0, 3)),
          ..._filler(right),
          ..._filler(const [(.90, .75)]),
        ],
      );
      _expectRefusedAndWhole(await _detect(_learned(ocr)));
    });
  });

  group('the limit of a containment fact', () {
    test('print AROUND a correctly framed object is not told apart from the '
        'object\'s own text: the suggestion is dropped, nothing is '
        'cropped', () async {
      // The proposal frames an object whose own text names nothing, lying on
      // printed matter that does. The frame read cannot know which print
      // belongs to which object.
      final ocr = _ScopedOcr(
        inside: _filler(const [(.5, .5)]),
        frame: [
          ..._filler(const [(.5, .5)]),
          ..._card(const [(.1, .1), (.9, .1), (.1, .9)]),
        ],
      );
      final detection = await _detect(_learned(ocr));

      _expectRefusedAndWhole(detection);
      // The cost is a lost suggestion, never a wrong crop.
      expect(detection.boundary, isNot(DetectionBoundary.trustworthy));
    });
  });

  group('what text read inside a classical quad may still decide', () {
    test('number, label and issuer read INSIDE a card-shaped classical quad '
        'corroborate it through the unchanged catalog gate', () async {
      final lines = _card(const [(.5, .4), (.5, .5), (.5, .6)]);
      final ocr = _ScopedOcr(inside: lines, frame: lines);
      final detection = await _detect(_classical(ocr));

      expect(ocr.reads, hasLength(1));
      expect(detection.classification.kind, DocumentKind.unifiedNationalId);
      expect(detection.boundaryDecision!.kind, BoundaryDecisionKind.accepted);
      expect(
        detection.boundaryDecision!.verification.corroboration,
        BoundaryCorroboration.classicalCatalogAspect,
      );
    });

    test('the same three facts read from the FRAME never do', () async {
      final ocr = _ScopedOcr(
        inside: _filler(const [(.5, .5)]),
        frame: _card(const [(.5, .4), (.5, .5), (.5, .6)]),
      );
      final detection = await _detect(_classical(ocr));

      expect(ocr.reads, hasLength(2));
      expect(detection.classification.kind, DocumentKind.unifiedNationalId);
      expect(
        detection.boundaryDecision!.kind,
        BoundaryDecisionKind.needsReview,
      );
      expect(detection.boundaryDecision!.verification.corroboration, isNull);
      expect(detection.cropAuthorization, isNull);
      expect(detection.suggestedCorners, _cardShaped);
    });

    test('below the acceptance score the same quad stays for review', () async {
      final lines = [
        _at('199000000000', 1, .5, .4),
        _at('الاسم', .58, .5, .5),
        _at('وزارة الداخلية', .58, .5, .6),
      ];
      final ocr = _ScopedOcr(inside: lines, frame: lines);
      final detection = await _detect(_classical(ocr));

      expect(
        detection.boundaryDecision!.kind,
        BoundaryDecisionKind.needsReview,
      );
      expect(detection.cropAuthorization, isNull);
    });
  });
}
