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

/// Analysis of one detected document inside an image.
class DetectionAnalysis {
  const DetectionAnalysis({
    required this.detectionId,
    required this.classification,
    required this.orientation,
    this.corners,
    this.detectionConfidence,
    this.geometry,
  });
  final String detectionId;

  /// Normalized source-image corners (CropGeometry order); null when no
  /// trustworthy boundary exists (full-frame fallback).
  final List<Point2>? corners;

  /// Measured segmenter support; absent for the single-document detector
  /// (it exposes no calibrated score) and for full-frame fallbacks.
  final double? detectionConfidence;
  final QuadAssessment? geometry;
  final ClassificationOutcome classification;
  final OrientationEstimate orientation;

  bool get hasUsableQuad =>
      corners != null && (geometry?.acceptable ?? false);
}

/// The complete analysis of one source image.
class ImageAnalysis {
  const ImageAnalysis({
    required this.assetId,
    required this.importIndex,
    required this.detections,
    required this.issues,
    required this.multi,
  });
  final String assetId;
  final int importIndex;
  final List<DetectionAnalysis> detections;
  final List<BatchItemFailure> issues;

  /// Whether this image was treated as a multi-document source.
  final bool multi;
}

/// Default segmentation seam: the real classical segmenter off the UI
/// isolate. Injectable so tests and widget fakes stay deterministic.
Future<SegmentationResult> defaultSegment(Uint8List previewBytes) =>
    Isolate.run(() => segmentDocumentBytes(previewBytes));

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
    if (segmentation.multi) {
      var index = 0;
      for (final candidate in segmentation.candidates) {
        token?.throwIfCancelled();
        if (candidate.corners == null) {
          issues.add(
            const BatchItemFailure(
              category: RecognitionErrorCategory.detectionFailure,
              message:
                  'منطقة مستند بلا حدود موثوقة؛ تحتاج قصاً يدوياً من المحرر.',
            ),
          );
          continue;
        }
        detections.add(
          await _analyzeDetection(
            input,
            detectionId: '${input.assetId}-d$index',
            corners: candidate.corners,
            detectionConfidence: candidate.detectionConfidence,
            issues: issues,
            token: token,
          ),
        );
        index++;
      }
    }
    if (detections.isEmpty) {
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
    );
  }

  Future<DetectionAnalysis> _analyzeDetection(
    PipelineImageInput input, {
    required String detectionId,
    required List<Point2>? corners,
    required double? detectionConfidence,
    required List<BatchItemFailure> issues,
    required CancellationToken? token,
  }) async {
    QuadAssessment? assessment;
    var usableCorners = corners;
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
                'بقيت الصورة كاملة.',
          ),
        );
        usableCorners = null;
        assessment = null;
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

    final boundaryDetected = usableCorners != null && assessment != null;
    final int width;
    final int height;
    if (boundaryDetected) {
      final aspect = assessment!.aspect!;
      // Only the proportion matters for shape classification; the quad is in
      // pixel space so its aspect is the crop's proportion.
      width = aspect >= 1 ? (aspect * 1000).round() : 1000;
      height = aspect >= 1 ? 1000 : (1000 / aspect).round();
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
    );
  }
}
