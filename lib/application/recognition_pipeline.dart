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

import '../domain/boundary_decision.dart';
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
    this.suggestedCorners,
    this.detectionConfidence,
    this.geometry,
    this.region,
    this.boundary = DetectionBoundary.undetected,
    this.regionIndex = 0,
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

  /// The shared Proposal → Verification → Decision result for this region.
  /// Automatic crops may proceed only when it grants [cropAuthorization].
  /// A consistency gate over geometry and the imposed catalog claim — not
  /// an independent measurement of the physical edge.
  final BoundaryDecision? boundaryDecision;

  /// Measured segmenter support; absent for the single-document detector
  /// (it exposes no calibrated score) and for full-frame fallbacks.
  final double? detectionConfidence;
  final QuadAssessment? geometry;
  final ClassificationOutcome classification;
  final OrientationEstimate orientation;

  /// True only when the shared boundary decision accepted this claim.
  ///
  /// Geometry that merely passed [assessQuad] is not enough: a filename can
  /// still impose a catalog size the measured shape cannot claim, and a quad
  /// can fail to describe its measured region. Those are review outcomes.
  /// Callers that warp must also use [cropAuthorization]; this getter is the
  /// same fact, so a path cannot treat "corners present" as permission.
  bool get hasUsableQuad => cropAuthorization != null;

  /// Present only for an accepted decision. Automatic warps take their
  /// corners and their catalog-aspect permission from this, not from a
  /// separately rebuilt recipe.
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
    this.suggestProposal,
    this.segment = defaultSegment,
    this.ocr = const UnavailableOcrEngine(),
    this.catalog = const DocumentSizeCatalog(),
    this.thresholds = defaultThresholds,
  });

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
            producer: candidate.producer,
            minAutoAcceptConfidence: candidate.minAutoAcceptConfidence,
            touchesFrameEdge: candidate.touchesFrameEdge,
            region: candidate.region,
            regionIndex: regionIndex,
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
      var producer = BoundaryProducer.wholeFrameDetector;
      try {
        if (suggestProposal != null) {
          final prop = await suggestProposal!(input.previewBytes);
          corners = prop?.corners;
          detConf = prop?.modelConfidence;
          minAutoConf = prop?.minAutoAcceptConfidence;
          touchesEdge = prop?.touchesFrameEdge ?? false;
          if (prop != null) producer = prop.producer;
        } else {
          corners = await suggestSingle(input.previewBytes);
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
    );
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
    // Which way the document is HELD, orientation preserved. [_shapeSide]
    // normalizes the pair below to long/short — right for the catalog shape
    // comparison, wrong for [estimateOrientation], which would otherwise be
    // told every crop is landscape. See `cropHeldAspect`.
    final double heldAspect;
    if (quadAspect != null) {
      final aspect = quadAspect;
      // Only the proportion matters for shape classification; the quad is in
      // pixel space so its aspect is the crop's proportion.
      width = _shapeSide(aspect, long: true);
      height = _shapeSide(aspect, long: false);
      heldAspect = cropHeldAspect(
        usableCorners!,
        sourceWidth: input.sourceWidth,
        sourceHeight: input.sourceHeight,
      );
    } else if (region != null) {
      // No trustworthy quadrilateral, but the segmenter DID measure this
      // region. Classify from the measured region proportion — using the whole
      // frame here would describe a different document.
      final regionWidth = (region[2] - region[0]).abs() * input.sourceWidth;
      final regionHeight = (region[3] - region[1]).abs() * input.sourceHeight;
      final aspect = regionHeight <= 0 ? 1.0 : regionWidth / regionHeight;
      width = _shapeSide(aspect, long: true);
      height = _shapeSide(aspect, long: false);
      // A measured region keeps its own orientation; nothing normalized it.
      heldAspect = aspect;
    } else {
      width = input.sourceWidth;
      height = input.sourceHeight;
      heldAspect = input.sourceHeight <= 0
          ? 1.0
          : input.sourceWidth / input.sourceHeight;
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

    // Shared boundary contract. The duplicated claim-ratio check used to live
    // here and could drift from the legacy path. verifyBoundary is a
    // consistency gate (shape, region agreement, imposed catalog claim) —
    // not an independent edge measurement. A non-accepted claim cannot keep
    // corners that an intake path might warp.
    final claimedNatural = catalog.natural(classification.kind);
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
        imposedAspect: claimedNatural?.aspect,
        imposedKindLabel: classification.kind.label,
        modelConfidence: minAutoAcceptConfidence == null
            ? null
            : detectionConfidence,
        minAutoAcceptConfidence: minAutoAcceptConfidence,
        touchesFrameEdge: touchesFrameEdge,
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
      // Geometry rejection was already reported above. Aspect and region
      // disagreements are new reasons and must be visible to the user.
      if (!decision.verification.reasons.contains(
        BoundaryReviewReason.geometryRejected,
      )) {
        for (final reason in decision.verification.reasons) {
          issues.add(
            BatchItemFailure(
              category: RecognitionErrorCategory.geometryFailure,
              message: boundaryReviewReasonMessage(reason),
            ),
          );
        }
      }
    }

    final natural = catalog.natural(classification.kind);
    final orientation = estimateOrientation(
      pixelAspect: heldAspect,
      expectedAspect: natural == null ? null : natural.width / natural.height,
    );

    return DetectionAnalysis(
      detectionId: detectionId,
      corners: decision.cropAuthorization?.corners ?? usableCorners,
      suggestedCorners: reviewSuggestedCorners,
      detectionConfidence: detectionConfidence,
      geometry: assessment,
      classification: classification,
      orientation: orientation,
      region: region,
      boundary: boundary,
      regionIndex: regionIndex,
      boundaryDecision: decision,
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
