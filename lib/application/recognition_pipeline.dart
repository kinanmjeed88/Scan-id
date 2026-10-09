/// Per-image Smart Recognition analysis (AUDIT.md §G): segmentation →
/// geometry refinement → orientation → OCR (evidence-only) → hybrid
/// classification → fusion/routing. Produces typed, deterministic results;
/// every stage failure is an explicit issue and the pipeline degrades to the
/// safest remaining path instead of aborting (AUDIT.md §I).
///
/// This stage only ANALYZES: it writes no files and owns no layout. Applying
/// results (crops, derived assets, records, items, A4 arrangement) is the
/// intake coordinator's job.
library;

import 'dart:isolate';
import 'dart:typed_data';

import '../domain/document_kind.dart';
import '../domain/geometry.dart';
import '../domain/ocr_evidence.dart';
import '../domain/quad_assessment.dart';
import '../domain/recognition_classifier.dart';
import '../domain/recognition_routing.dart';
import '../imaging/document_segmenter.dart';
import 'cancellation.dart';
import 'ocr_engine.dart';
import 'recognition_worker.dart';

/// Version of the analysis pipeline, recorded in provenance.
const recognitionPipelineVersion = 'smart-1';

/// Everything the pipeline needs about one imported image.
class PipelineImageInput {
  const PipelineImageInput({
    required this.assetId,
    required this.name,
    required this.previewBytes,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.importIndex,
    this.captureId,
  });
  final String assetId;
  final String name;

  /// Bounded (≤1200 px) preview copy; the original is never decoded here.
  final Uint8List previewBytes;
  final int sourceWidth;
  final int sourceHeight;
  final int importIndex;
  final String? captureId;
}

/// Why a region does (or does not) carry a trustworthy boundary.
///
/// An unresolved region is an explicit, reportable state — never an implicit
/// drop and never a guessed rectangle.
enum DetectionBoundary {
  /// A quadrilateral was found and passed geometry validation.
  trustworthy,

  /// A quadrilateral was found but geometry validation rejected it.
  rejected,

  /// No quadrilateral was found inside the region at all.
  undetected,
}

/// Analysis of one detected document inside an image.
class DetectionAnalysis {
  const DetectionAnalysis({
    required this.detectionId,
    required this.classification,
    required this.orientation,
    this.corners,
    this.detectionConfidence,
    this.geometry,
    this.region,
    this.boundary = DetectionBoundary.undetected,
    this.regionIndex = 0,
  });
  final String detectionId;

  /// Normalized source-image corners (CropGeometry order); null when no
  /// trustworthy boundary exists (full-frame fallback).
  final List<Point2>? corners;

  /// Normalized `[left, top, right, bottom]` bounds of the region this
  /// analysis came from, as MEASURED by the segmenter. Present for every
  /// segmented region — including the ones whose boundary could not be
  /// resolved — so the region can still be recovered by a manual crop.
  /// Null for a full-frame fallback, which has no region measurement.
  final List<double>? region;

  /// Whether [corners] can be trusted. See [DetectionBoundary].
  final DetectionBoundary boundary;

  /// Position of this region in the deterministic region order
  /// (top-to-bottom, left-to-right), used to keep results stable.
  final int regionIndex;

  /// Measured segmenter support; absent for the single-document detector
  /// (it exposes no calibrated score) and for full-frame fallbacks.
  final double? detectionConfidence;
  final QuadAssessment? geometry;
  final ClassificationOutcome classification;
  final OrientationEstimate orientation;

  bool get hasUsableQuad => corners != null && (geometry?.acceptable ?? false);

  /// Whether this region needs a manual boundary before it can be placed
  /// confidently. Its measured [region] is always kept so the document is
  /// never lost from the review workflow.
  bool get needsManualBoundary => !hasUsableQuad;
}

/// The complete analysis of one source image.
class ImageAnalysis {
  const ImageAnalysis({
    required this.assetId,
    required this.importIndex,
    required this.detections,
    required this.issues,
    required this.multi,
    this.unresolvedRegions = const [],
  });
  final String assetId;
  final int importIndex;
  final List<DetectionAnalysis> detections;
  final List<BatchItemFailure> issues;

  /// Whether this image was treated as a multi-document source.
  final bool multi;

  /// Document-like regions the segmenter MEASURED but could not resolve into
  /// a trustworthy quadrilateral.
  ///
  /// These are kept — never dropped — because silently discarding a measured
  /// region is how a photo of several documents loses one of them. Each entry
  /// carries its measured [DetectionAnalysis.region], so the intake can keep
  /// the document as a reviewable region crop the user finishes by hand.
  final List<DetectionAnalysis> unresolvedRegions;

  /// Every region of this image (resolved first, then unresolved), in the
  /// deterministic region order the segmenter produced them in.
  List<DetectionAnalysis> get allRegions =>
      [...detections, ...unresolvedRegions]
        ..sort((a, b) => a.regionIndex.compareTo(b.regionIndex));

  /// How many document-like regions this image holds, resolved or not.
  int get regionCount => detections.length + unresolvedRegions.length;

  /// Whether this source needs the multi-document intake path.
  ///
  /// True as soon as more than one region was measured: routing a
  /// multi-region photo through the single-document path would crop the
  /// SOURCE asset to one quad and make every other region unrecoverable
  /// (ADR-003).
  bool get needsMultiIntake => multi || regionCount > 1;
}

/// Default segmentation seam: the real classical segmenter off the UI
/// isolate. Injectable so tests and widget fakes stay deterministic.
Future<SegmentationResult> defaultSegment(Uint8List previewBytes) =>
    Isolate.run(() => segmentDocumentBytes(previewBytes));

/// The stable identity of one measured region of [assetId].
///
/// It depends on the region's position only — never on whether that region
/// could be resolved into a quadrilateral — so a later retry of the same
/// deterministic analysis recognises the same document again.
String regionDetectionId(String assetId, int regionIndex) =>
    '$assetId-d$regionIndex';

class RecognitionPipeline {
  const RecognitionPipeline({
    required this.suggestSingle,
    this.segment = defaultSegment,
    this.ocr = const UnavailableOcrEngine(),
    this.catalog = const DocumentSizeCatalog(),
    this.thresholds = defaultThresholds,
  });

  /// The existing precise single-document detector seam
  /// (`ImageEditor.suggest`); used when segmentation reports no multi-
  /// document structure.
  final Future<List<Point2>?> Function(Uint8List previewBytes) suggestSingle;
  final Future<SegmentationResult> Function(Uint8List previewBytes) segment;
  final OcrEngine ocr;
  final DocumentSizeCatalog catalog;
  final RecognitionThresholds thresholds;

  Future<ImageAnalysis> analyze(
    PipelineImageInput input, {
    CancellationToken? token,
  }) async {
    token?.throwIfCancelled();
    final issues = <BatchItemFailure>[];

    SegmentationResult segmentation;
    try {
      segmentation = await segment(input.previewBytes);
    } on OperationCancelled {
      rethrow;
    } catch (_) {
      issues.add(
        BatchItemFailure(
          category: RecognitionErrorCategory.segmentationFailure,
          message: 'تعذر تقسيم الصورة؛ عولجت كمستند واحد.',
        ),
      );
      segmentation = const SegmentationResult(candidates: [], multi: false);
    }
    token?.throwIfCancelled();

    final detections = <DetectionAnalysis>[];
    final unresolved = <DetectionAnalysis>[];
    if (segmentation.multi) {
      var index = 0;
      for (final candidate in segmentation.candidates) {
        token?.throwIfCancelled();
        final regionIndex = index;
        index++;
        if (candidate.corners == null) {
          issues.add(
            const BatchItemFailure(
              category: RecognitionErrorCategory.detectionFailure,
              message:
                  'منطقة مستند بلا حدود موثوقة؛ حُفظت كما هي لتُقصّ يدوياً من المحرر.',
            ),
          );
          // KEEP the region instead of dropping it. No rectangle is guessed:
          // the measured bounds are carried through so the intake can preserve
          // the document as a reviewable crop for a manual boundary.
          unresolved.add(
            await _analyzeDetection(
              input,
              // The id depends on the REGION only, never on whether that
              // region could be resolved. Reprocessing the same original is
              // deterministic, so a region keeps its id when a later pass
              // finds the boundary it missed — which is what lets the retry
              // update that document instead of duplicating it.
              detectionId: regionDetectionId(input.assetId, regionIndex),
              corners: null,
              detectionConfidence: candidate.detectionConfidence,
              region: candidate.region,
              regionIndex: regionIndex,
              issues: issues,
              token: token,
            ),
          );
          continue;
        }
        detections.add(
          await _analyzeDetection(
            input,
            detectionId: regionDetectionId(input.assetId, regionIndex),
            corners: candidate.corners,
            detectionConfidence: candidate.detectionConfidence,
            region: candidate.region,
            regionIndex: regionIndex,
            issues: issues,
            token: token,
          ),
        );
      }
    }
    // Only fall back to the whole frame when NOTHING was measured. Once the
    // segmenter has produced regions — even unresolved ones — a full-frame
    // detection would describe a DIFFERENT document spanning those regions,
    // duplicating them instead of recovering them.
    if (detections.isEmpty && unresolved.isEmpty) {
      List<Point2>? corners;
      try {
        corners = await suggestSingle(input.previewBytes);
      } on OperationCancelled {
        rethrow;
      } catch (_) {
        issues.add(
          const BatchItemFailure(
            category: RecognitionErrorCategory.detectionFailure,
            message: 'تعذر كشف حدود المستند؛ بقيت الصورة كاملة.',
          ),
        );
        corners = null;
      }
      token?.throwIfCancelled();
      detections.add(
        await _analyzeDetection(
          input,
          detectionId: '${input.assetId}-d0',
          corners: corners,
          detectionConfidence: null,
          issues: issues,
          token: token,
        ),
      );
    }
    return ImageAnalysis(
      assetId: input.assetId,
      importIndex: input.importIndex,
      detections: detections,
      issues: issues,
      multi: segmentation.multi && detections.length > 1,
      unresolvedRegions: unresolved,
    );
  }

  Future<DetectionAnalysis> _analyzeDetection(
    PipelineImageInput input, {
    required String detectionId,
    required List<Point2>? corners,
    required double? detectionConfidence,
    required List<BatchItemFailure> issues,
    required CancellationToken? token,
    List<double>? region,
    int regionIndex = 0,
  }) async {
    QuadAssessment? assessment;
    var usableCorners = corners;
    var boundary = DetectionBoundary.undetected;
    if (corners != null) {
      assessment = assessQuad(
        corners,
        sourceWidth: input.sourceWidth,
        sourceHeight: input.sourceHeight,
      );
      if (!assessment.acceptable) {
        issues.add(
          BatchItemFailure(
            category: RecognitionErrorCategory.geometryFailure,
            message:
                'حدود مرفوضة هندسياً (${assessment.rejection?.name})؛ '
                'حُفظت المنطقة كما هي لتُقصّ يدوياً من المحرر.',
          ),
        );
        usableCorners = null;
        assessment = null;
        boundary = DetectionBoundary.rejected;
      } else {
        boundary = DetectionBoundary.trustworthy;
      }
    }

    // OCR is optional evidence: unavailability or failure never aborts.
    var ocrResult = OcrTextResult.unavailable(
      unavailableReason: 'skipped',
      engineVersion: ocr.version,
    );
    try {
      ocrResult = await ocr.recognize(input.previewBytes, token: token);
    } on OperationCancelled {
      rethrow;
    } catch (_) {
      issues.add(
        const BatchItemFailure(
          category: RecognitionErrorCategory.ocrFailure,
          message: 'فشل OCR؛ استمر التصنيف بالأدلة المتبقية.',
        ),
      );
    }

    final quadAspect = usableCorners == null ? null : assessment?.aspect;
    final boundaryDetected = quadAspect != null;
    final int width;
    final int height;
    if (quadAspect != null) {
      final aspect = quadAspect;
      // Only the proportion matters for shape classification; the quad is in
      // pixel space so its aspect is the crop's proportion.
      width = _shapeSide(aspect, long: true);
      height = _shapeSide(aspect, long: false);
    } else if (region != null) {
      // No trustworthy quadrilateral, but the segmenter DID measure this
      // region. Classify from the measured region proportion — using the whole
      // frame here would describe a different document.
      final regionWidth = (region[2] - region[0]).abs() * input.sourceWidth;
      final regionHeight = (region[3] - region[1]).abs() * input.sourceHeight;
      final aspect = regionHeight <= 0 ? 1.0 : regionWidth / regionHeight;
      width = _shapeSide(aspect, long: true);
      height = _shapeSide(aspect, long: false);
    } else {
      width = input.sourceWidth;
      height = input.sourceHeight;
    }

    final classification = classifyDocument(
      ClassificationInput(
        name: input.name,
        width: width,
        height: height,
        boundaryDetected: boundaryDetected,
        catalog: catalog,
        detectionConfidence: detectionConfidence,
        geometryConfidence: assessment?.geometryConfidence,
        ocrKeywords: ocrKeywordEvidence(ocrResult),
        ocrConfidence: ocrResult.confidence,
        thresholds: thresholds,
      ),
    );

    final natural = catalog.natural(classification.kind);
    final orientation = estimateOrientation(
      pixelAspect: width / height,
      expectedAspect: natural == null ? null : natural.width / natural.height,
    );

    return DetectionAnalysis(
      detectionId: detectionId,
      corners: usableCorners,
      detectionConfidence: detectionConfidence,
      geometry: assessment,
      classification: classification,
      orientation: orientation,
      region: region,
      boundary: boundary,
      regionIndex: regionIndex,
    );
  }
}

/// One side of the synthetic 1000-px-long-edge shape used for classification.
///
/// Reproduces the historical aspect→pixels mapping exactly, but clamps a
/// degenerate measurement so a zero-area or hostile region can never produce
/// a zero, negative or overflowing dimension.
int _shapeSide(double aspect, {required bool long}) {
  final safe = aspect.isFinite && aspect > 0 ? aspect : 1.0;
  if (safe >= 1) {
    return long ? (safe * 1000).round().clamp(1, 100000).toInt() : 1000;
  }
  return long ? 1000 : (1000 / safe).round().clamp(1, 100000).toInt();
}
