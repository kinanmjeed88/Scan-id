/// Per-image Smart Recognition analysis (AUDIT.md §G): segmentation →
/// geometry refinement → orientation → OCR (evidence-only) → explicit-evidence
/// classification → fusion/routing. Produces structured, deterministic results;
/// every stage failure is an explicit issue and the pipeline degrades to the
/// safest remaining path instead of aborting (AUDIT.md §I).
///
/// This stage only ANALYZES: it writes no files and owns no layout. Applying
/// results (crops, derived assets, records, items, A4 arrangement) is the
/// intake coordinator's job.
library;

import 'dart:typed_data';

import '../domain/boundary_decision.dart';
import '../domain/document_kind.dart';
import '../domain/geometry.dart';
import '../domain/intake_options.dart';
import '../domain/ocr_evidence.dart';
import '../domain/quad_assessment.dart';
import '../domain/recognition.dart';
import '../domain/recognition_classifier.dart';
import '../domain/recognition_routing.dart';
import '../imaging/document_segmenter.dart';
import '../imaging/ocr_region.dart';
import 'cancellation.dart';
import 'import_trace.dart';
import 'ocr_engine.dart';
import 'stage_budget.dart';
import 'recognition_worker.dart';

/// Version of the analysis pipeline, recorded in provenance.
const recognitionPipelineVersion = 'smart-5';

/// Everything the pipeline needs about one imported image.
class PipelineImageInput {
  const PipelineImageInput({
    required this.assetId,
    required this.previewBytes,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.importIndex,
    this.captureId,
  });
  final String assetId;

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
    this.suggestedCorners,
    this.detectionConfidence,
    this.geometry,
    this.region,
    this.boundary = DetectionBoundary.undetected,
    this.regionIndex = 0,
    this.recognitionDurationMs,
    this.preprocessingDurationMs,
    this.preprocessingAttempts = 0,
    this.preprocessingFailures = 0,
    this.boundaryDecision,
  });
  final String detectionId;

  /// Normalized source-image corners (CropGeometry order); null when no
  /// trustworthy boundary exists (full-frame fallback).
  final List<Point2>? corners;

  /// Geometrically valid 4-corner proposal held back for user review when
  /// `verifyBoundary` returned `BoundaryDecisionKind.needsReview`. Never used
  /// for automatic warping; offered as editable handles in `CropScreen`.
  final List<Point2>? suggestedCorners;

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

  /// OCR/evidence and type classification time, excluding the separately
  /// measured preprocessing duration. Null when bypassed by user choice.
  final int? recognitionDurationMs;

  /// Sum of the measured OCR-region preparation calls for this document.
  /// Null means preprocessing was not attempted, not a zero-millisecond run.
  final int? preprocessingDurationMs;
  final int preprocessingAttempts;
  final int preprocessingFailures;

  /// The shared Proposal → Verification → Decision result for this region.
  /// Automatic crops may proceed only when it grants [cropAuthorization].
  /// It checks measured geometry and region consistency; only the narrow
  /// classical/catalog corroboration gate may also consult a qualified kind.
  final BoundaryDecision? boundaryDecision;

  /// Measured segmenter support; absent for the single-document detector
  /// (it exposes no calibrated score) and for full-frame fallbacks.
  final double? detectionConfidence;
  final QuadAssessment? geometry;
  final ClassificationOutcome classification;
  final OrientationEstimate orientation;

  /// True only when the shared boundary decision accepted the measured
  /// proposal. Passing [assessQuad] alone is not enough: the decision also
  /// checks measured-region agreement, detector confidence and frame contact.
  /// Catalog-size confirmation is separate and never authorizes a warp.
  /// Callers that warp must also use [cropAuthorization]; this getter is the
  /// same fact, so a path cannot treat "corners present" as permission.
  bool get hasUsableQuad => cropAuthorization != null;

  /// Present only for an accepted decision. Automatic warps take their
  /// measured corners from this authorization, not from a separately rebuilt
  /// classification- or catalog-dependent recipe.
  AutomaticCropAuthorization? get cropAuthorization =>
      boundaryDecision?.cropAuthorization;

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
    this.rejectedRegions = const [],
    this.detectionDurationMs,
  });
  final String assetId;
  final int importIndex;
  final List<DetectionAnalysis> detections;
  final List<BatchItemFailure> issues;

  /// Whether this image was treated as a multi-document source.
  final bool multi;

  /// Measured regions the segmenter REFUSED as document candidates, with the
  /// measurements that decided each one.
  ///
  /// These never become a crop, a derived file, a `DocumentRecord` or a layout
  /// item, so they are deliberately NOT part of [allRegions] and not part of
  /// [regionCount]: counting them would make the intake preserve a background
  /// fragment as though it were a document. They are kept here so the decision
  /// stays explainable, and so the user is told once per image instead of once
  /// per component.
  ///
  /// Refusing a candidate never touches the original image (ADR-003): the whole
  /// photo stays in the library and any part of it can still be cropped by
  /// hand, which is the recovery route for a region refused by mistake.
  final List<RejectedRegion> rejectedRegions;

  /// Measured time spent in segmentation and the single-frame boundary detector.
  /// It excludes OCR, classification and geometry evaluation.
  final int? detectionDurationMs;

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
  /// True when multiple regions were measured, regardless of the segmenter's
  /// `multi` hint, or when one measured candidate has no usable boundary and
  /// must be retained as a measured crop for manual recovery. A full-frame
  /// fallback with no measured region remains on the single-image path.
  bool get needsMultiIntake =>
      multi ||
      regionCount > 1 ||
      unresolvedRegions.isNotEmpty ||
      allRegions.any(
        (region) => region.region != null && region.needsManualBoundary,
      );
}

/// Safe default when no qualified automatic region detector is installed.
///
/// Deliberately returns no candidates rather than falling back to the legacy
/// classical segmenter. Keep [segmentDocumentBytes] available only for its
/// isolated algorithm tests/research; production intake must use manual review
/// until a detector is qualified and explicitly wired in.
Future<SegmentationResult> defaultSegment(Uint8List _) async =>
    const SegmentationResult(candidates: [], multi: false);

/// The stable identity of one measured region of [assetId].
///
/// It depends on the region's position only — never on whether that region
/// could be resolved into a quadrilateral — so a later retry of the same
/// deterministic analysis recognises the same document again.
String regionDetectionId(String assetId, int regionIndex) =>
    '$assetId-d$regionIndex';

/// Hard limit on one document's OCR stage.
///
/// The engine has its own budget; this is the pipeline's guarantee that an
/// engine — any engine — cannot hold the import open. Expiry is reported as an
/// issue and the analysis continues without text, which keeps the kind `unknown`
/// instead of stalling the batch.
const Duration defaultPipelineOcrBudget = Duration(seconds: 40);

typedef OcrRegionPreparer =
    Future<Uint8List> Function(
      Uint8List previewBytes, {
      List<Point2>? corners,
      List<double>? region,
      CancellationToken? cancellation,
    });

class RecognitionPipeline {
  const RecognitionPipeline({
    required this.suggestSingle,
    this.suggestProposal,
    this.segment = defaultSegment,
    this.ocr = const UnavailableOcrEngine(),
    this.catalog = const DocumentSizeCatalog(),
    this.thresholds = defaultThresholds,
    this.ocrBudget = defaultPipelineOcrBudget,
    this.classifier = classifyDocument,
    this.options,
    this.prepareOcrRegion = prepareOcrRegionIsolated,
  });

  /// The batch options the person chose, or null when they were not offered.
  ///
  /// Geometry remains independent. A manual kind replaces the entire evidence
  /// collection/classification stage, not just its result.
  final IntakeOptions? options;
  final ClassificationOutcome Function(ClassificationInput) classifier;

  /// The existing precise single-document detector seam
  /// (`ImageEditor.suggest`); used when segmentation reports no multi-
  /// document structure and [suggestProposal] is not provided.
  final Future<List<Point2>?> Function(Uint8List previewBytes) suggestSingle;

  /// Optional learned-model proposal seam carrying calibrated confidence and
  /// frame-touch flags for `verifyBoundary`.
  final Future<BoundaryProposal?> Function(Uint8List previewBytes)?
  suggestProposal;
  final Future<SegmentationResult> Function(Uint8List previewBytes) segment;
  final OcrEngine ocr;
  final DocumentSizeCatalog catalog;
  final RecognitionThresholds thresholds;

  /// Builds the bounded OCR input. Production uses the cancellable isolate
  /// implementation; tests may supply a controlled preparer to verify timing
  /// and cancellation without depending on image-decoder speed.
  final OcrRegionPreparer prepareOcrRegion;

  /// Upper bound on the OCR stage of one document (see
  /// [defaultPipelineOcrBudget]).
  final Duration ocrBudget;

  Future<ImageAnalysis> analyze(
    PipelineImageInput input, {
    CancellationToken? token,
  }) async {
    token?.throwIfCancelled();
    if (options?.route == IntakeRoute.manualSelections) {
      throw StateError('Manual selections do not enter recognition');
    }
    final issues = <BatchItemFailure>[];
    var detectionDurationMs = 0;

    SegmentationResult segmentation;
    final segmentationClock = Stopwatch();
    if (options == null) segmentationClock.start();
    try {
      segmentation = options != null
          ? const SegmentationResult(candidates: [], multi: false)
          : await ImportTrace.stage(
              'detection',
              () => segment(input.previewBytes),
              phase: 'segmentation',
            );
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
    } finally {
      if (segmentationClock.isRunning) {
        segmentationClock.stop();
        detectionDurationMs += segmentationClock.elapsedMilliseconds;
      }
    }
    token?.throwIfCancelled();

    final detections = <DetectionAnalysis>[];
    final unresolved = <DetectionAnalysis>[];
    // `multi` is only a hint; candidates are measured evidence in their own
    // right. In particular, all-unresolved multi-region results legitimately
    // carry `multi: false` because none has a trustworthy quadrilateral.
    if (segmentation.candidates.isNotEmpty) {
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
              producer: candidate.producer,
              minAutoAcceptConfidence: candidate.minAutoAcceptConfidence,
              touchesFrameEdge: candidate.touchesFrameEdge,
              forceReview: candidate.requiresReview,
              region: candidate.region,
              regionIndex: regionIndex,
              isolatedRegion: true,
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
            producer: candidate.producer,
            minAutoAcceptConfidence: candidate.minAutoAcceptConfidence,
            touchesFrameEdge: candidate.touchesFrameEdge,
            forceReview: candidate.requiresReview,
            region: candidate.region,
            regionIndex: regionIndex,
            isolatedRegion: true,
            issues: issues,
            token: token,
          ),
        );
      }
    }
    // The production segmenter returns no candidates when none is plausible,
    // or when one measured region already has a trustworthy quad and should use
    // the established precise whole-frame detector. A measured unresolved
    // singleton and every multi-region result stay in `candidates`, so this
    // fallback can never replace bounds needed for recovery or duplicate them.
    if (detections.isEmpty && unresolved.isEmpty) {
      List<Point2>? corners;
      double? detConf;
      double? minAutoConf;
      var touchesEdge = false;
      var forceReview = false;
      BoundaryReviewReason? forceReviewReason;
      var producer = BoundaryProducer.wholeFrameDetector;
      BoundaryProposal? prop;
      final boundaryClock = Stopwatch()..start();
      try {
        if (suggestProposal != null) {
          prop = await ImportTrace.stage(
            'detection',
            () => suggestProposal!(input.previewBytes),
            phase: 'boundary',
          );
          corners = prop?.corners;
          detConf = prop?.modelConfidence;
          minAutoConf = prop?.minAutoAcceptConfidence;
          touchesEdge = prop?.touchesFrameEdge ?? false;
          forceReview = prop?.forceReview ?? false;
          forceReviewReason = prop?.forceReviewReason;
          if (prop != null) producer = prop.producer;
        } else {
          corners = await ImportTrace.stage(
            'detection',
            () => suggestSingle(input.previewBytes),
            phase: 'boundary',
          );
        }
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
      } finally {
        boundaryClock.stop();
        detectionDurationMs += boundaryClock.elapsedMilliseconds;
      }
      token?.throwIfCancelled();
      detections.add(
        await _analyzeDetection(
          input,
          detectionId: '${input.assetId}-d0',
          corners: corners,
          detectionConfidence: detConf,
          producer: producer,
          minAutoAcceptConfidence: minAutoConf,
          touchesFrameEdge: touchesEdge,
          forceReview: forceReview,
          forceReviewReason: forceReviewReason,
          traces: prop?.traces ?? const [],
          disagreementFraction: prop?.disagreementFraction,
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
      // Report the measured region count, not the segmenter's hint: the hint
      // can be false when every candidate is unresolved.
      multi: detections.length + unresolved.length > 1,
      unresolvedRegions: unresolved,
      rejectedRegions: segmentation.rejected,
      detectionDurationMs: detectionDurationMs,
    );
  }

  /// Centres of the located lines of [result] in source-normalized
  /// coordinates. [region] is the measured area the read was cropped to, or
  /// null when the whole preview was read. A line the engine did not locate is
  /// skipped: it says nothing about where the text is.
  static List<Point2> _lineCentres(OcrTextResult result, List<double>? region) {
    final left = region == null ? 0.0 : region[0];
    final top = region == null ? 0.0 : region[1];
    final width = region == null ? 1.0 : region[2] - region[0];
    final height = region == null ? 1.0 : region[3] - region[1];
    final centres = <Point2>[];
    for (final line in result.lines) {
      final bounds = line.bounds;
      if (bounds == null || bounds.isEmpty) continue;
      var x = 0.0;
      var y = 0.0;
      for (final point in bounds) {
        x += point.x;
        y += point.y;
      }
      final cx = left + width * x / bounds.length;
      final cy = top + height * y / bounds.length;
      if (!cx.isFinite || !cy.isFinite) continue;
      centres.add(Point2(cx.clamp(0.0, 1.0), cy.clamp(0.0, 1.0)));
    }
    return centres;
  }

  /// One bounded OCR read of [corners], of [region], or of the whole preview.
  ///
  /// Returns null when the read failed, so the caller keeps what it already
  /// had. A read that outlives [budget] returns an explicit unavailable result.
  /// [issues], when given, receives the person-facing reason; a second,
  /// widening read passes null because its failure changes nothing the person
  /// has to act on.
  Future<OcrTextResult?> _readText(
    PipelineImageInput input, {
    required List<Point2>? corners,
    required List<double>? region,
    required Duration budget,
    required List<BatchItemFailure>? issues,
    void Function(int durationMs, bool succeeded)? onPreprocessing,
    required CancellationToken? token,
  }) async {
    final trace = ImportTrace.current;
    final ocrOperation = trace?.nextOperation();
    trace?.emit('ocr_started', operationId: ocrOperation);
    try {
      final preprocessingClock = Stopwatch()..start();
      Uint8List ocrBytes;
      var preprocessingSucceeded = false;
      try {
        ocrBytes = await ImportTrace.stage(
          'preprocessing',
          () => prepareOcrRegion(
            input.previewBytes,
            corners: corners,
            region: region,
            cancellation: token,
          ),
          phase: 'ocr-region',
        );
        preprocessingSucceeded = ocrBytes.isNotEmpty;
        require(ocrBytes.isNotEmpty, 'لم تُنتج المعالجة المسبقة صورة OCR صالحة.');
      } finally {
        preprocessingClock.stop();
        onPreprocessing?.call(
          preprocessingClock.elapsedMilliseconds,
          preprocessingSucceeded,
        );
      }
      final ocrOutcome = await runStageWithin(
        () => ocr.recognize(ocrBytes, token: token),
        budget: budget,
        name: 'pipeline-ocr',
        cancellation: token,
      );
      if (ocrOutcome.didTimeOut) {
        trace?.emit('ocr_timeout', operationId: ocrOperation);
        issues?.add(
          const BatchItemFailure(
            category: RecognitionErrorCategory.ocrFailure,
            message:
                'تجاوزت قراءة النص المهلة على هذا الجهاز؛ استمر تحليل '
                'الحدود وبقي النوع غير محدد.',
          ),
        );
        return OcrTextResult.unavailable(
          unavailableReason: 'time-budget-exceeded',
          engineVersion: ocr.version,
        );
      }
      final ocrError = ocrOutcome.error;
      if (ocrError != null) {
        Error.throwWithStackTrace(ocrError, ocrOutcome.stackTrace!);
      }
      final result = ocrOutcome.value!;
      trace?.emit(
        result.isAvailable ? 'ocr_completed' : 'ocr_unavailable',
        operationId: ocrOperation,
      );
      return result;
    } on OperationCancelled catch (error) {
      trace?.emit('ocr_cancelled', error: error, operationId: ocrOperation);
      rethrow;
    } catch (error) {
      trace?.emit('ocr_failed', error: error, operationId: ocrOperation);
      issues?.add(
        const BatchItemFailure(
          category: RecognitionErrorCategory.ocrFailure,
          message: 'فشل OCR؛ استمر تحليل الحدود وبقي النوع غير محدد.',
        ),
      );
      return null;
    }
  }

  Future<DetectionAnalysis> _analyzeDetection(
    PipelineImageInput input, {
    required String detectionId,
    required List<Point2>? corners,
    required double? detectionConfidence,
    required List<BatchItemFailure> issues,
    required CancellationToken? token,
    BoundaryProducer? producer,
    double? minAutoAcceptConfidence,
    bool touchesFrameEdge = false,
    bool forceReview = false,
    BoundaryReviewReason? forceReviewReason,
    List<double>? region,
    int regionIndex = 0,
    bool isolatedRegion = false,
    List<BoundaryDetectorTrace> traces = const [],
    double? disagreementFraction,
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

    final quadAspect = usableCorners == null ? null : assessment?.aspect;
    // Keep the crop's measured orientation for the separate orientation stage.
    // Aspect is not a document-kind vote or a catalog-size claim.
    final double heldAspect;
    if (quadAspect != null) {
      heldAspect = cropHeldAspect(
        usableCorners!,
        sourceWidth: input.sourceWidth,
        sourceHeight: input.sourceHeight,
      );
    } else if (region != null) {
      // An unresolved region keeps its measured orientation; the whole-frame
      // dimensions describe a different object and are not substituted.
      final regionWidth = (region[2] - region[0]).abs() * input.sourceWidth;
      final regionHeight = (region[3] - region[1]).abs() * input.sourceHeight;
      heldAspect = regionHeight <= 0 ? 1.0 : regionWidth / regionHeight;
    } else {
      heldAspect = input.sourceHeight <= 0
          ? 1.0
          : input.sourceWidth / input.sourceHeight;
    }

    // First apply the source-independent geometry and detector review gate.
    // After OCR classification, only a sole classical-score refusal may be
    // corroborated by a qualified kind's matching catalog aspect; learned and
    // explicitly disputed proposals never use that exception.
    final effectiveProducer =
        producer ??
        (region == null
            ? BoundaryProducer.wholeFrameDetector
            : BoundaryProducer.segmenter);
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: effectiveProducer,
        corners: corners,
        region: region,
        modelConfidence:
            effectiveProducer == BoundaryProducer.learnedModel ||
                minAutoAcceptConfidence != null
            ? detectionConfidence
            : null,
        minAutoAcceptConfidence: minAutoAcceptConfidence,
        touchesFrameEdge: touchesFrameEdge,
        forceReview: forceReview,
        forceReviewReason: forceReviewReason,
        traces: traces,
        disagreementFraction: disagreementFraction,
      ),
      sourceWidth: input.sourceWidth,
      sourceHeight: input.sourceHeight,
    );
    List<Point2>? reviewSuggestedCorners;
    if (corners != null && decision.kind != BoundaryDecisionKind.accepted) {
      if (decision.kind == BoundaryDecisionKind.needsReview &&
          decision.verification.hasUsableGeometry) {
        reviewSuggestedCorners = corners;
      }
      usableCorners = null;
      boundary = DetectionBoundary.rejected;
    }

    // OCR is optional evidence: it only sees this document's authorized quad or
    // its measured segmentation region. A segment without either measurement
    // is skipped rather than leaking text from sibling documents in the frame.
    var ocrResult = OcrTextResult.unavailable(
      unavailableReason: 'skipped',
      engineVersion: ocr.version,
    );
    // Set only when the evidence was read from the wider measured area rather
    // than from inside the proposal itself.
    var evidenceFromWiderRead = false;
    var widerLineCentres = const <Point2>[];
    var preprocessingDurationMs = 0;
    var preprocessingAttempts = 0;
    var preprocessingFailures = 0;
    void recordPreprocessing(int durationMs, bool succeeded) {
      preprocessingDurationMs += durationMs;
      preprocessingAttempts++;
      if (!succeeded) preprocessingFailures++;
    }
    final manualKind = options?.route == IntakeRoute.singleManualKind;
    final recognitionClock = manualKind ? null : (Stopwatch()..start());
    if (!manualKind && ocr.isEnabled) {
      final authorizedCorners = decision.cropAuthorization?.corners;
      final List<Point2>? ocrCorners;
      if (authorizedCorners != null) {
        ocrCorners = authorizedCorners;
      } else if (assessment?.acceptable == true && corners != null) {
        // A geometrically valid proposal may provide OCR evidence even when
        // boundary policy still requires review. It never authorizes a crop or
        // a physical-size confirmation by itself.
        ocrCorners = corners;
      } else {
        ocrCorners = null;
      }
      if (isolatedRegion && ocrCorners == null && region == null) {
        ocrResult = OcrTextResult.unavailable(
          unavailableReason: 'no-safe-region-for-ocr',
          engineVersion: ocr.version,
        );
      } else {
        final ocrClock = Stopwatch()..start();
        ocrResult =
            await _readText(
              input,
              corners: ocrCorners,
              region: ocrCorners == null ? region : null,
              budget: ocrBudget,
              issues: issues,
              onPreprocessing: recordPreprocessing,
              token: token,
            ) ??
            ocrResult;
        // An unauthorized proposal may ADD text evidence; it must never
        // SUPPRESS it. When policy has not accepted the quad and the text
        // inside it evidences no document kind, the quad may simply be wrong
        // (a sliver of a card that fills the frame), so the same measured
        // area the document was found in — its segmentation region, or the
        // whole frame of a single-document photo — is read once more. The
        // wider read replaces the first only when it produces evidence, shares
        // the one OCR budget, and never crosses into a sibling document: an
        // isolated region without its own measured area is not widened.
        final confinedToProposal =
            authorizedCorners == null && ocrCorners != null;
        final mayWiden = !isolatedRegion || region != null;
        if (confinedToProposal &&
            mayWiden &&
            ocrResult.isAvailable &&
            ocrKeywordEvidence(ocrResult).isEmpty) {
          final remaining = ocrBudget - ocrClock.elapsed;
          if (remaining > Duration.zero) {
            final wider = await _readText(
              input,
              corners: null,
              region: region,
              budget: remaining,
              issues: null,
              onPreprocessing: recordPreprocessing,
              token: token,
            );
            if (wider != null &&
                wider.isAvailable &&
                ocrKeywordEvidence(wider).isNotEmpty) {
              ocrResult = wider;
              evidenceFromWiderRead = true;
              widerLineCentres = _lineCentres(wider, region);
            }
          }
        }
      }
    }

    final classification = manualKind
        ? ClassificationOutcome(
            kind: options!.kind,
            status: RecognitionStatus.uncertain,
            confidences: ConfidenceSet(
              detection: detectionConfidence == null
                  ? null
                  : Confidence(
                      value: detectionConfidence,
                      reason: 'detector support',
                      producer: effectiveProducer.name,
                      version: recognitionPipelineVersion,
                    ),
              geometry: assessment == null
                  ? null
                  : Confidence(
                      value: assessment.geometryConfidence!,
                      reason: 'quad assessment',
                      producer: 'quad-assessment',
                      version: recognitionPipelineVersion,
                    ),
            ),
            evidence: const [],
            routing: const RoutingDecision(
              band: RecognitionBand.unresolved,
              reasons: ['user-selected-kind'],
            ),
          )
        : classifier(
            ClassificationInput(
              detectionConfidence: detectionConfidence,
              geometryConfidence: assessment?.geometryConfidence,
              ocrKeywords: ocrKeywordEvidence(ocrResult),
              ocrConfidence: ocrResult.confidence,
              thresholds: thresholds,
            ),
          );
    recognitionClock?.stop();
    // Evidence read from the wider area describes the document in the frame,
    // not the content of the proposal, so it never corroborates that proposal
    // into an automatic crop: the catalog gate only ever sees text read from
    // inside the quadrilateral it is asked to accept.
    var resolvedDecision = manualKind || evidenceFromWiderRead
        ? decision
        : corroborateClassicalBoundaryWithCatalog(
            decision: decision,
            classification: classification,
            catalog: catalog,
            thresholds: thresholds,
          );
    // And when most of that text lies outside the proposal, the proposal is a
    // fragment of the document (a card that fills or exceeds the frame leaves
    // a detector nothing but slivers). It is refused rather than preserved as
    // suggested corners, and the whole image stays for the person.
    if (evidenceFromWiderRead &&
        corners != null &&
        quadExcludesText(corners, widerLineCentres)) {
      resolvedDecision = refuseProposalExcludingText(decision);
      reviewSuggestedCorners = null;
    }
    // Option 3: the person approved the proposed boundary. Applied AFTER the
    // geometry gate and only to geometry it measured as usable, so it cannot
    // turn an unusable quad, a missing quad or a frame artifact into a crop. It
    // is recorded as a user approval rather than an automatic acceptance.
    if (options?.acceptSuggestedBoundary ?? false) {
      final approved = resolvedDecision.approvedByUser();
      if (approved.kind == BoundaryDecisionKind.accepted &&
          resolvedDecision.kind != BoundaryDecisionKind.accepted) {
        resolvedDecision = approved;
      }
    }
    if (resolvedDecision.kind == BoundaryDecisionKind.accepted &&
        decision.kind != BoundaryDecisionKind.accepted) {
      usableCorners = resolvedDecision.acceptedCorners;
      reviewSuggestedCorners = null;
      boundary = DetectionBoundary.trustworthy;
    } else if (corners != null &&
        resolvedDecision.kind != BoundaryDecisionKind.accepted &&
        !resolvedDecision.verification.reasons.contains(
          BoundaryReviewReason.geometryRejected,
        )) {
      for (final reason in resolvedDecision.verification.reasons) {
        issues.add(
          BatchItemFailure(
            category: RecognitionErrorCategory.geometryFailure,
            message: boundaryReviewReasonMessage(
              reason,
              modelConfidence: resolvedDecision.proposal.modelConfidence,
              minAutoAcceptConfidence:
                  resolvedDecision.proposal.minAutoAcceptConfidence,
            ),
          ),
        );
      }
    }
    final natural = catalog.natural(classification.kind);
    final orientation = estimateOrientation(
      pixelAspect: heldAspect,
      expectedAspect: natural == null ? null : natural.width / natural.height,
    );

    final recognitionElapsedMs = recognitionClock?.elapsedMilliseconds;
    final recognitionDurationMs = recognitionElapsedMs == null
        ? null
        : recognitionElapsedMs > preprocessingDurationMs
        ? recognitionElapsedMs - preprocessingDurationMs
        : 0;

    return DetectionAnalysis(
      detectionId: detectionId,
      corners: resolvedDecision.cropAuthorization?.corners ?? usableCorners,
      suggestedCorners: reviewSuggestedCorners,
      detectionConfidence: detectionConfidence,
      geometry: assessment,
      classification: classification,
      orientation: orientation,
      region: region,
      boundary: boundary,
      regionIndex: regionIndex,
      recognitionDurationMs: recognitionDurationMs,
      preprocessingDurationMs: preprocessingAttempts == 0
          ? null
          : preprocessingDurationMs,
      preprocessingAttempts: preprocessingAttempts,
      preprocessingFailures: preprocessingFailures,
      boundaryDecision: resolvedDecision,
    );
  }
}

/// Arabic label of one rejection reason, for the single aggregated diagnostic.
String regionRejectionLabel(RegionRejection rejection) => switch (rejection) {
  RegionRejection.frameArtifact => 'حافة الإطار أو صورة مبتورة',
  RegionRejection.implausibleAspect => 'شريط ضيق',
  RegionRejection.unusableCrop => 'منطقة أصغر من أن تُقصّ',
  RegionRejection.candidateCap => 'تجاوزت حدّ المناطق في صورة واحدة',
};

/// Per-reason tally of [rejected], in [RegionRejection] declaration order.
///
/// The batch report and the per-image warning are built from this SAME tally so
/// the two surfaces can never disagree about what was refused or why.
Map<RegionRejection, int> rejectionTally(List<RejectedRegion> rejected) {
  final counts = <RegionRejection, int>{};
  for (final region in rejected) {
    counts[region.rejection] = (counts[region.rejection] ?? 0) + 1;
  }
  return counts;
}

/// The `2 شريط ضيق، 1 حافة الإطار` breakdown shared by both diagnostics.
///
/// Only reasons actually measured are named, in a stable order, so the text is
/// reproducible and never invents a category the pipeline did not decide.
String _rejectionBreakdown(Map<RegionRejection, int> byReason) {
  final parts = <String>[
    for (final reason in RegionRejection.values)
      if ((byReason[reason] ?? 0) > 0)
        '${byReason[reason]} ${regionRejectionLabel(reason)}',
  ];
  return parts.join('، ');
}

/// What every rejection diagnostic promises: refusing a region costs the user
/// nothing irrecoverable, because the original is untouched (ADR-003) and any
/// part of it stays croppable by hand.
const rejectedRegionsRecoveryHint =
    'الصورة الأصلية محفوظة كما هي، ويمكن قصّ أي جزء منها يدوياً من المكتبة';

/// ONE concise diagnostic for every region a photo had refused.
///
/// Deliberately a single message with per-reason counts: a noisy threshold can
/// produce dozens of refused components, and one warning each would bury the
/// messages that actually need the user. Returns null when nothing was refused.
String? rejectedRegionsMessage(List<RejectedRegion> rejected) {
  if (rejected.isEmpty) return null;
  final breakdown = _rejectionBreakdown(rejectionTally(rejected));
  return 'تجاهل التقسيم ${rejected.length} منطقة لا يمكن أن تكون مستمسكاً '
      '($breakdown)؛ لم تُضف إلى المشروع. $rejectedRegionsRecoveryHint.';
}

/// The short form: how many regions were refused and by which measured
/// categories, in one clause. For surfaces that already carry the per-image
/// warnings and only need the tally to be unmissable.
String? rejectedRegionsHeadline(int count, Map<RegionRejection, int> byReason) {
  if (count <= 0) return null;
  final breakdown = _rejectionBreakdown(byReason);
  return 'استُبعدت $count منطقة لا يمكن أن تكون مستمسكاً'
      '${breakdown.isEmpty ? '' : ' ($breakdown)'}';
}

/// ONE concise batch-level summary of every region this batch refused.
///
/// This is the surface the status-line entry points have: the editor imports
/// and reprocesses through a single message, so without it the refusals a
/// per-image warning already explains would be invisible there — the same
/// feedback must not depend on which door the user came through.
///
/// Count first, then the measured categories, then the recovery promise. It
/// aggregates deliberately: one photo can refuse a dozen noise components, and
/// the user needs to know how many and what kind, not each one separately.
/// Returns null when nothing was refused, so callers can append it
/// unconditionally.
String? rejectedRegionsSummary(int count, Map<RegionRejection, int> byReason) {
  final headline = rejectedRegionsHeadline(count, byReason);
  if (headline == null) return null;
  return '$headline؛ لم تُضف إلى المشروع. $rejectedRegionsRecoveryHint.';
}
