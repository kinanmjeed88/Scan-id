/// Smart Recognition intake coordinator: applies per-image pipeline analysis
/// to a project — crops (as derived revisions), multi-document derived
/// assets, `DocumentRecord`s, layout items, pairing proposals — then hands
/// placement to the existing deterministic A4 engine (ADR-002).
///
/// Boundaries (locked):
/// - the original image files are never modified (ADR-003);
/// - recognition truth lands in [DocumentRecord]; layout truth stays on
///   [DocumentItem] and is decided by `arrangeDocuments` (ADR-002/004);
/// - one failed image never cancels the batch (failure isolation);
/// - cancellation is cooperative and can only stop BETWEEN safe saves, so
///   persistence stays consistent (ADR-009).
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../domain/acceptance_policy.dart';
import '../domain/arrangement.dart';
import '../domain/boundary_decision.dart';
import '../domain/classification_gap.dart';
import '../domain/crop_draft.dart';
import '../domain/document_kind.dart';
import '../domain/geometry.dart';
import '../domain/image_adjustments.dart';
import '../domain/image_journey.dart';
import '../domain/image_limits.dart';
import '../domain/intake_options.dart';
import '../domain/manual_classification.dart';
import '../domain/processing_record.dart';
import '../domain/project.dart';
import '../domain/recognition.dart';
import '../domain/recognition_classifier.dart';
import '../domain/recognition_routing.dart';
import '../domain/side_pairing.dart';
import '../domain/validation.dart';
import '../imaging/document_segmenter.dart';
import '../imaging/image_header.dart';
import '../imaging/perspective.dart';
import '../imaging/region_crop.dart';
import 'cancellation.dart';
import 'contracts.dart';
import 'full_resolution_jpeg_cropper.dart';
import 'ids.dart';
import 'image_reader.dart';
import 'import_trace.dart';
import 'intake_stage_log.dart';
import 'ocr_engine.dart';
import 'processing_ledger.dart';
import 'project_service.dart';
import 'recognition_pipeline.dart';
import 'recognition_worker.dart';
import 'stage_budget.dart';

int _boundaryReviewCount(Iterable<DocumentRecord> records) => records
    .where(
      (record) =>
          record.sides.any((side) => side.detection?.suggestedPolygon != null),
    )
    .length;

int _notDetectedCount(int count, Iterable<DocumentRecord> records) {
  final remaining = count - _boundaryReviewCount(records);
  return remaining > 0 ? remaining : 0;
}

/// Full-resolution perspective warp for a segmented document, off the UI
/// isolate. Reads from the already-bounded original bytes.
Future<Uint8List> defaultWarp(
  Uint8List originalBytes,
  ImageEditRecipe recipe,
) => Isolate.run(() => renderPerspective(originalBytes, recipe));

/// Axis-aligned crop of one measured region, off the UI isolate.
///
/// This is the RECOVERY path for a segmented region whose quadrilateral could
/// not be trusted: it keeps the measured pixels without guessing a rectangle,
/// and it only ever READS the original bytes (ADR-003).
Future<Uint8List> defaultRegionCrop(
  Uint8List originalBytes,
  List<double> region,
) => Isolate.run(() => cropRegionBytes(originalBytes, region));

class _Analyzed {
  const _Analyzed(
    this.asset,
    this.analysis,
    this.sourceWidth,
    this.sourceHeight,
    this.importIndex,
  );
  final ImageAsset asset;
  final ImageAnalysis analysis;
  final int sourceWidth;
  final int sourceHeight;
  final int importIndex;
}

/// One short Arabic fragment naming why a boundary decision was not accepted.
///
/// The journey's crop/detection stages carry this alongside the machine-readable
/// reason code: the person reading the log should meet a readable cause, not a
/// raw enum, and the reader should not have to decode it first. It is a pure
/// label — never a measurement, never a code to act on.
String boundaryCauseLabel(BoundaryReviewReason reason) => switch (reason) {
  BoundaryReviewReason.noBoundary => 'لم تُقترَح حدود',
  BoundaryReviewReason.notABoundary => 'اقتراح غير صالح شكلاً',
  BoundaryReviewReason.geometryRejected => 'حدود مرفوضة هندسياً',
  BoundaryReviewReason.aspectMismatch => 'شكل الحدود لا يطابق المقاس',
  BoundaryReviewReason.quadOutsideRegion =>
    'الحدود لا تصف المنطقة المقاسة',
  BoundaryReviewReason.lowModelConfidence => 'درجة كشف حدود منخفضة',
  BoundaryReviewReason.touchesFrameEdge => 'تلامس الحدود حافة الإطار',
  BoundaryReviewReason.multiSceneNotCorroborated =>
    'دليل تعدد المشاهد غير مؤيد',
  BoundaryReviewReason.uncalibratedClassicalScore =>
    'اقتراح كلاسيكي غير مُعايَر',
  BoundaryReviewReason.modelDisagreement => 'تعارض داخل نموذج الحدود',
  BoundaryReviewReason.modelNotCorroborated => 'كاشف حدود وحيد غير مؤيد',
  BoundaryReviewReason.excludesDocumentText => 'الحدود جزئية لا تغطي النص',
};

/// Why an automatic crop did not happen, or null when one did.
///
/// The whole decision is read from the analysis the batch just produced — a
/// crop that did not happen says which reason kept the boundary in review, so
/// the person sees the cause instead of the generic «بقيت الصورة كاملة».
String? _cropNotProducedCause(List<String> reasons) {
  if (reasons.isEmpty) {
    return 'لم يُعتمد قصّ تلقائي لهذه الصورة';
  }
  final parsed = <BoundaryReviewReason>[];
  for (final code in reasons) {
    for (final reason in BoundaryReviewReason.values) {
      if (reason.name == code) {
        parsed.add(reason);
        break;
      }
    }
  }
  if (parsed.isEmpty) {
    // An unrecognized reason code still names the failure mode; the code
    // itself travels in the fields, so nothing is lost.
    return 'لم يُعتمد قصّ تلقائي: ${reasons.join('، ')}';
  }
  if (parsed.length == 1) {
    return 'لم يُعتمد قصّ تلقائي: ${boundaryCauseLabel(parsed.first)}';
  }
  return 'لم يُعتمد قصّ تلقائي: ${parsed.map(boundaryCauseLabel).join('، ')}';
}

/// The bounded analysis of a batch of source images, in input order.
/// Records what analysis MEASURED and what applying it PRODUCED.
///
/// Two separate stages, because they fail for different reasons and a reader
/// needs to tell them apart: a photo can be analysed perfectly and still yield
/// no document, and that is not an error. Detection reports the region counts
/// the segmenter actually returned, including the ones it rejected and why it
/// routed to the multi-region path; apply reports the outcome of the crop.
///
/// Only measured numbers and decision facts are recorded — never a path, a
/// name or recognized text. The boundary decision — whether the crop was
/// authorized, which reason kept it in review, and whether a person approved
/// it — travels with the crop record so a refusal can never be read as a
/// silent gap.
void _recordApplyStage(
  IntakeBatchLog? stageLog,
  _Analyzed analyzed, {
  required int cropped,
  required int notDetected,
  required int multi,
  required int applyDurationMs,
  List<DocumentItem> items = const [],
}) {
  final log = stageLog?.forAsset(analyzed.asset.id, name: analyzed.asset.name);
  if (log == null) return;
  final analysis = analyzed.analysis;
  final regions = analysis.allRegions
      .where(
        (r) => r.region != null || r.boundaryDecision?.proposal.corners != null,
      )
      .length;
  // Detection PASSES only when the boundary the crop path would have used
  // was actually accepted. A measured region that the decision rejects is not
  // a pass: it leaves the crop without permission, and a log that says
  // "passed" there is a log that lied about the boundary it measured. The
  // image is still usable — the detail says so and the stage routes to review.
  final measured = regions > 0;
  final rejected = analysis.rejectedRegions.length;
  final measuredDetail = regions > 1
      ? 'قِيست $regions مناطق (متعددة)'
      : 'قِيست $regions منطقة';
  final decisions = [
    for (final region in analysis.allRegions)
      if (region.boundaryDecision case final decision?) decision,
  ];
  final reasons = [
    for (final decision in decisions)
      for (final reason in decision.verification.reasons) reason.name,
  ];
  final userApproved = decisions.any(
    (decision) => decision.verification.userApproved == true,
  );
  final accepted = decisions.any(
    (decision) => decision.kind == BoundaryDecisionKind.accepted,
  );
  log.record(
    IntakeStageRecord(
      stage: JourneyStage.detection,
      outcome: accepted ? JourneyOutcome.passed : JourneyOutcome.review,
      detail: !measured
          ? 'لم تُقَس أي منطقة مستند في هذه الصورة.'
          : accepted
          ? (rejected == 0
                ? measuredDetail
                : '$measuredDetail، ورُفضت $rejected.')
          : '$measuredDetail — ${_cropNotProducedCause(reasons)}.',
      fields: {
        'regions': regions,
        'detections': analysis.detections.length,
        'unresolved': analysis.unresolvedRegions.length,
        'rejected': rejected,
        'multi': multi > 0,
        // The decision, the reasons that kept it in review, and the user
        // approval — read from the same decision the crop path consults, so
        // the record can never claim more than the decision grants.
        if (decisions.isNotEmpty) ...{
          'decision': decisions.first.kind.name,
          if (reasons.isNotEmpty) 'reason': reasons.first,
          if (reasons.length > 1) 'reasonCount': reasons.length,
        },
        'accepted': accepted,
        if (userApproved) 'userApproved': true,
      },
    ),
  );
  // Apply: a crop happened, or the image stayed whole. A whole image is not a
  // failure — it is the documented outcome when no boundary is trusted — so it
  // is reported as needing review, not as blocked.
  log.record(
    IntakeStageRecord(
      stage: JourneyStage.crop,
      outcome: cropped > 0 ? JourneyOutcome.passed : JourneyOutcome.review,
      detail: cropped > 0
          ? 'قُصّت $cropped منطقة وأُنشئت نسخة مشتقة.'
          : !measured
          ? 'لم تُقَس منطقة مستند؛ بقيت الصورة كاملة يمكن قصّها يدوياً.'
          : 'بقيت الصورة كاملة بلا قص؛ '
              '${_cropNotProducedCause(reasons)}.',
      fields: {
        'applyDurationMs': applyDurationMs,
        'cropped': cropped,
        'notDetected': notDetected,
        'userApproved': userApproved,
        'accepted': accepted,
        if (decisions.isNotEmpty) ...{
          'decision': decisions.first.kind.name,
          if (reasons.isNotEmpty) 'reason': reasons.first,
          if (reasons.length > 1) 'reasonCount': reasons.length,
        },
        // The measurement the batch produced, per document: the kind, the
        // size confirmation and the provisional/catalog source and size. A
        // reader should never have to decode the item to learn the outcome.
        if (items.isNotEmpty)
          for (var i = 0; i < items.length; i++)
            ..._measurementFields(items[i], prefix: items.length == 1 ? '' : 'i${i + 1}_'),
      },
    ),
  );
}

/// Per-document recognition facts for the recognition record.
///
/// [prefix] distinguishes documents inside one image in the multi-document
/// report shape (`i1_`, `i2_`, …); it is empty for a single-document result
/// so the keys stay short. Every value below is read from the classification the batch
/// measured — the kind, the status and the classification value — never
/// recomputed, so the record can never claim a recognition the pipeline did
/// not make.
Map<String, Object?> _recognitionFields(DetectionAnalysis region, {String prefix = ''}) {
  final classification = region.classification;
  final confidence = classification.confidences.classification?.value;
  return {
    '${prefix}kind': classification.kind.name,
    '${prefix}status': classification.status.name,
    if (confidence != null) '${prefix}confidence': double.parse(confidence.toStringAsFixed(4)),
  };
}

/// Per-document measurement facts for the crop record.
///
/// [prefix] distinguishes documents inside one image in the multi-document
/// report shape (`i1_`, `i2_`, …); it is empty for a single-document crop
/// so the keys stay short.
Map<String, Object?> _measurementFields(DocumentItem item, {String prefix = ''}) {
  return {
    '${prefix}kind': item.documentKind.name,
    '${prefix}sizeConfirmed': item.sizeConfirmed,
    '${prefix}sizeSource': item.sizeConfirmed ? 'catalog' : 'provisional_image_dimensions',
    '${prefix}widthMm': double.parse(item.width.toStringAsFixed(2)),
    '${prefix}heightMm': double.parse(item.height.toStringAsFixed(2)),
  };
}

class _Analysis {
  const _Analysis(this.pending, this.outcomes);
  final List<ImageAsset> pending;
  final List<BatchOutcome<_Analyzed>> outcomes;
}

/// A stopwatch duration paired with consistent UTC endpoints for one region.
class _MeasuredSpan {
  const _MeasuredSpan({
    required this.durationMs,
    required this.startedAt,
    required this.endedAt,
  });

  final int durationMs;
  final DateTime startedAt;
  final DateTime endedAt;
}

_MeasuredSpan _finishCropSpan(Stopwatch clock, DateTime startedAt) {
  clock.stop();
  final durationMs = clock.elapsedMilliseconds;
  return _MeasuredSpan(
    durationMs: durationMs,
    startedAt: startedAt,
    endedAt: startedAt.add(Duration(milliseconds: durationMs)),
  );
}

/// The rendered image of one detected region, plus the geometry that produced
/// it. Every value here is a measurement; nothing is inferred.
class _RegionOutput {
  const _RegionOutput({
    required this.bytes,
    required this.corners,
    required this.outputWidth,
    required this.outputHeight,
    required this.trustworthy,
    this.suggestedCorners,
    this.recipe,
  });
  final Uint8List bytes;
  final List<Point2>? corners;
  final List<Point2>? suggestedCorners;
  final int? outputWidth;
  final int? outputHeight;

  /// Whether the region had a trustworthy quadrilateral and was rectified. An
  /// unrectified crop must never claim a confirmed size.
  final bool trustworthy;

  /// The rectifying recipe, present only when [trustworthy].
  final ImageEditRecipe? recipe;
}

/// Upper bound for analysing one imported image.
///
/// Generous for a slow phone (boundary models plus OCR on a 1200 px preview)
/// while still finite: the batch must always reach the next image.
const Duration defaultImageAnalysisBudget = Duration(minutes: 2);

/// How much two measured normalized regions must overlap before a reprocess
/// treats them as the same document. Deliberately strict: pairing the wrong
/// record would refresh one card with another card's image, while a missed
/// match only costs a second record the user can dismiss. Two cards in one
/// photograph share no rectangle at all, so 0.6 leaves ample margin.
const double _sameRegionOverlap = 0.6;

class SmartIntake {
  const SmartIntake({
    required this.projects,
    required this.assets,
    required this.editor,
    this.segment = defaultSegment,
    this.ocr = const UnavailableOcrEngine(),
    this.worker = const RecognitionBatchWorker(),
    this.warp = defaultWarp,
    this.cropRegion = defaultRegionCrop,
    this.fullResolutionJpegCropper = const PlatformFullResolutionJpegCropper(),
    this.thresholds = defaultThresholds,
    this.analysisBudget = defaultImageAnalysisBudget,
    this.options,
    this.stageLog,
    this.ledger,
  });

  /// The batch options the person chose, or null when they were not offered.
  final IntakeOptions? options;

  /// The stage-by-stage record of this batch, filled in as it runs.
  final IntakeBatchLog? stageLog;

  /// The detailed processing ledger: every fine-grained stage with its
  /// duration, verified result and the decision that bypassed it. Separate
  /// from [stageLog] (the coarse journey projection) on purpose: the journey
  /// says what the image became, the ledger says how each step actually ended.
  final ProcessingLedger? ledger;

  final ProjectRepository projects;
  final AssetRepository assets;
  final ImageEditor editor;
  final Future<SegmentationResult> Function(Uint8List previewBytes) segment;
  final OcrEngine ocr;
  final RecognitionBatchWorker worker;
  final Future<Uint8List> Function(
    Uint8List originalBytes,
    ImageEditRecipe recipe,
  )
  warp;

  /// Keeps an unresolved region as a plain crop of the original, so a region
  /// without a trustworthy quadrilateral is preserved instead of dropped.
  final Future<Uint8List> Function(Uint8List originalBytes, List<double> region)
  cropRegion;

  /// Native full-density cropper used only for sources that were sampled during
  /// import because their JPEG raster exceeded the Dart image budget.
  final FullResolutionJpegCropper fullResolutionJpegCropper;
  final RecognitionThresholds thresholds;

  /// Hard per-image limit for the analysis lane.
  ///
  /// Each native stage inside the pipeline has its own budget, but a lane must
  /// also be bounded as a whole: this is the guarantee that the batch always
  /// advances to the next image — and that the dialog never sits at `0 / 1`
  /// forever. An expired lane is recorded as a per-image failure, so the batch
  /// keeps the original and offers it for a manual crop (the legacy fallback)
  /// instead of losing the import.
  final Duration analysisBudget;

  Future<AutomaticLayoutReport> run(
    Project project,
    Iterable<String> assetIds, {
    bool keepPlaced = false,
    bool deferArrangement = false,
    CancellationToken? cancellation,
    void Function(BatchProgress progress)? onProgress,
    bool allowMultiDocument = true,
  }) async {
    var current = project;
    var cropped = 0;
    var notDetected = 0;
    var recognized = 0;
    var needsReview = 0;
    var multiImages = 0;
    final refusedRegions = <RejectedRegion>[];
    final warnings = <String>[];
    final newItems = <DocumentItem>[];
    final newDocuments = <DocumentRecord>[];
    final newGroups = <LayoutGroup>[];
    // Derived assets created by this batch, and source assets whose revision
    // changed. Accumulated HERE, beside the records and items they belong to,
    // and committed with them in the single save below.
    final newAssets = <ImageAsset>[];
    final replacedAssets = <String, ImageAsset>{};

    // Phase A: bounded analysis. Each lane opens one preview, analyzes it
    // and releases it before the next image (memory stays bounded).
    final analysis = await _analyzeImages(
      current,
      assetIds,
      skipAssetsWithItems: true,
      cancellation: cancellation,
      onProgress: onProgress,
    );
    final pending = analysis.pending;
    final outcomes = analysis.outcomes;

    // Phase B: apply sequentially in input order. Every image is isolated:
    // its failure leaves a warning and the batch continues.
    for (final outcome in outcomes) {
      final sourceAsset = pending[outcome.index];
      if (cancellation != null && cancellation.isCancelled) {
        warnings.add('أُلغيت العملية؛ لم تُعالج الصور المتبقية.');
        break;
      }
      if (!outcome.succeeded) {
        notDetected++;
        warnings.add('${sourceAsset.name}: ${outcome.failure!.message}');
        // The failed analysis is where the stage record earns its keep: this is
        // the only place the technical category survives. The warning carries a
        // sentence for the person; the record carries the category code, so a
        // reader can tell a decode failure from a detection failure instead of
        // meeting the same «فشل التحليل» for both.
        stageLog
            ?.forAsset(sourceAsset.id, name: sourceAsset.name)
            .block(
              JourneyStage.detection,
              'فشل تحليل الصورة: ${outcome.failure!.message}',
              fields: {'errorType': outcome.failure!.category.name},
            );
        if (outcome.failure!.category != RecognitionErrorCategory.cancelled) {
          // Fallback: the image still becomes a manual item, exactly like
          // the legacy intake when analysis is impossible.
          newItems.add(_fallbackItem(current, sourceAsset, newItems));
        }
        continue;
      }
      final analyzed = outcome.value!;
      // PER-IMAGE STAGING. An image joins the batch only if it completed.
      // `_applyImage` accumulates into the lists it is handed and can throw
      // part-way through (a crop that fails, a cancellation between regions),
      // so handing it the batch lists directly would let a half-processed image
      // contribute a derived asset that no document record explains — the same
      // untraceable asset the per-region save used to create, merely deferred
      // to the end of the batch. Crop files already written are unreferenced
      // until this merge, which is exactly the state
      // `StorageMaintenance.findOrphans` exists to report.
      final imageItems = <DocumentItem>[];
      final imageDocuments = <DocumentRecord>[];
      final imageAssets = <ImageAsset>[];
      final imageReplacements = <String, ImageAsset>{};
      final imageCropSpans = <String, _MeasuredSpan>{};
      var imageCropped = 0;
      var imageNotDetected = 0;
      var imageMulti = 0;
      final imageWarnings = <String>[];
      final imageToken = CancellationToken();
      void cancelImage() => imageToken.cancel();
      cancellation?.addListener(cancelImage);
      // Rejections belong to completed analysis, independently of application.
      refusedRegions.addAll(analyzed.analysis.rejectedRegions);
      final applyClock = Stopwatch()..start();
      try {
        current = await ImportTrace.stage(
          'apply',
          () => requireStageWithin(
            () => _applyImage(
              current,
              analyzed,
              newItems: imageItems,
              newDocuments: imageDocuments,
              newAssets: imageAssets,
              replacedAssets: imageReplacements,
              cropSpans: imageCropSpans,
              warnings: imageWarnings,
              onCropped: () => imageCropped++,
              onNotDetected: () => imageNotDetected++,
              onMulti: () => imageMulti++,
              onRejected: (_) {},
              cancellation: imageToken,
              allowMultiDocument: allowMultiDocument,
            ),
            budget: analysisBudget,
            name: 'image-apply',
            // Writes are cooperative: don't abandon a save just because the
            // user cancelled. The apply code observes imageToken at checkpoints.
          ),
        );
        newItems.addAll(imageItems);
        newDocuments.addAll(imageDocuments);
        newAssets.addAll(imageAssets);
        replacedAssets.addAll(imageReplacements);
        cropped += imageCropped;
        notDetected += imageNotDetected;
        multiImages += imageMulti;
        _recordApplyStage(
          stageLog,
          analyzed,
          cropped: imageCropped,
          notDetected: imageNotDetected,
          multi: imageMulti,
          applyDurationMs: applyClock.elapsedMilliseconds,
          items: imageItems,
        );
        _recordAppliedDocuments(
          current,
          analyzed.asset,
          imageDocuments,
          imageItems,
          cropSpans: imageCropSpans,
        );
      } on RevisionConflict catch (error) {
        _recordUncommittedApply(
          analyzed,
          cropSpans: imageCropSpans,
          reason: 'تعارض حفظ المشروع قبل تثبيت نتيجة قص هذه الصورة.',
          cancelled: false,
          error: error,
        );
        rethrow;
      } on OperationCancelled {
        _recordUncommittedApply(
          analyzed,
          cropSpans: imageCropSpans,
          reason: 'أُلغيت المعالجة قبل تثبيت نتيجة قص هذه الصورة.',
          cancelled: true,
        );
        warnings.add('أُلغيت العملية؛ لم تُعالج الصور المتبقية.');
        break;
      } on StageTimeout catch (error) {
        _recordUncommittedApply(
          analyzed,
          cropSpans: imageCropSpans,
          reason: 'تجاوز تنفيذ قص المستندات المهلة الزمنية.',
          cancelled: false,
          error: error,
        );
        // The native stage never answered within the budget. The original is
        // already saved; keep it as a manual item so nothing is lost and the
        // batch continues with the next image.
        notDetected++;
        stageLog
            ?.forAsset(analyzed.asset.id, name: analyzed.asset.name)
            .block(
              JourneyStage.crop,
              'تجاوزت المعالجة المهلة الزمنية؛ بقيت الصورة الأصلية.',
              fields: {'errorType': 'StageTimeout'},
            );
        newItems.add(_fallbackItem(current, sourceAsset, newItems));
        warnings.add(
          '${analyzed.asset.name}: تجاوزت المعالجة المهلة الزمنية على هذا '
          'الجهاز؛ بقيت الصورة الأصلية ويمكن قصّها يدوياً.',
        );
      } catch (error) {
        _recordUncommittedApply(
          analyzed,
          cropSpans: imageCropSpans,
          reason: 'تعذر تثبيت قص المستندات: ${describeFailure(error)}',
          cancelled: false,
          error: error,
        );
        notDetected++;
        stageLog
            ?.forAsset(analyzed.asset.id, name: analyzed.asset.name)
            .block(
              JourneyStage.crop,
              'تعذرت المعالجة الذكية: ${userError(error)}',
              fields: {'errorType': error.runtimeType.toString()},
            );
        // Do not commit partially staged results or create an item that
        // would cause a subsequent import arrangement retry to skip this asset.
        // The intake UI separately retains the committed source for a manual
        // decision after the batch has finished.
        warnings.add(
          '${analyzed.asset.name}: تعذرت المعالجة الذكية؛ بقي الأصل محفوظاً '
          'ويمكن إعادة معالجة الصورة (${userError(error)}).',
        );
      } finally {
        cancellation?.removeListener(cancelImage);
        imageToken.cancel();
        // Snapshot only; an abandoned operation must not mutate batch state.
        warnings.addAll(imageWarnings);
      }
    }

    // Pairing uses each record's source-image position, not its position among
    // emitted document records (a source can yield several regions, no record,
    // or a failed apply). Keep that input provenance through analysis.
    if (options == null) {
      final sourceImportIndices = {
        for (final outcome in outcomes)
          if (outcome.succeeded)
            outcome.value!.asset.id: outcome.value!.importIndex,
      };
      ImportTrace.syncStage('pairing', () {
        _applyPairing(
          newDocuments,
          newItems,
          newGroups,
          sourceImportIndices: sourceImportIndices,
        );
        return true;
      });
    }

    for (final record in newDocuments) {
      if (recordNeedsReview(record, thresholds)) needsReview++;
      final kind = record.recognition?.documentKind ?? DocumentKind.unknown;
      if (current.catalog.natural(kind) != null) recognized++;
    }
    for (final item in newItems) {
      if (item.documentId == null &&
          current.catalog.natural(item.documentKind) != null) {
        recognized++;
      }
    }

    if (newItems.isEmpty && newAssets.isEmpty && replacedAssets.isEmpty) {
      // Nothing was produced, so nothing is committed and the revision does not
      // move: a no-op run must be indistinguishable from no run at all.
      return AutomaticLayoutReport(
        project: current,
        cropped: cropped,
        notDetected: _notDetectedCount(notDetected, newDocuments),
        recognized: recognized,
        needsReview: needsReview,
        boundaryNeedsReview: _boundaryReviewCount(newDocuments),
        multiDocumentImages: multiImages,
        rejectedRegions: refusedRegions.length,
        rejectedByReason: rejectionTally(refusedRegions),
        warnings: warnings,
      );
    }
    // ONE commit boundary for the whole batch: assets, records, items and
    // groups are written together, so no derived asset can ever be committed
    // without the document that explains it.
    current = current.copyWith(
      assets: _mergedAssets(current.assets, newAssets, replacedAssets),
      items: [...current.items, ...newItems],
      documents: [...current.documents, ...newDocuments],
      layoutGroups: [...current.layoutGroups, ...newGroups],
    );
    if (options case final chosen?) {
      current = attachIntakeChoices(current, newItems, chosen, newId);
    }
    if (deferArrangement) {
      // Multi-only dispatch may stage several sources independently, then
      // arrange every newly produced item together around the pre-existing sheet.
      current = await ImportTrace.stage(
        'persistence',
        () => projects.save(current),
        phase: 'arrangement',
      );
      await _recordCommittedDocuments(current, newDocuments, arranged: false);
    } else {
      final centeredItemIds = <String>{};
      final arrangement = ImportTrace.syncStage(
        'layout',
        () => arrangeDocuments(
          current,
          keepPlaced: keepPlaced,
          onCenteringPass: centeredItemIds.addAll,
        ),
      );
      current = await ImportTrace.stage(
        'persistence',
        () => projects.save(arrangement.result),
        phase: 'arrangement',
      );
      await _recordCommittedDocuments(
        current,
        newDocuments,
        arranged: true,
        centeredItemIds: centeredItemIds,
      );
      _recordPlacementStages(stageLog, current, newDocuments);
      if (arrangement.unplaced.isNotEmpty) {
        warnings.add(
          '${arrangement.unplaced.length} مستمسك بقي خارج الورقة؛ '
          'راجع الأسباب الفردية التالية. لم يُصغّر أو يُقص أي مستمسك لتلائمه.',
        );
        for (final id in arrangement.unplaced) {
          final item = current.items.firstWhere((entry) => entry.id == id);
          warnings.add(unplacedDocumentMessage(current, item));
        }
      }
      for (final id in arrangement.awaitingSize) {
        final item = current.items.firstWhere((entry) => entry.id == id);
        warnings.add(unplacedDocumentMessage(current, item));
      }
    }
    return AutomaticLayoutReport(
      project: current,
      cropped: cropped,
      notDetected: _notDetectedCount(notDetected, newDocuments),
      recognized: recognized,
      needsReview: needsReview,
      boundaryNeedsReview: _boundaryReviewCount(newDocuments),
      multiDocumentImages: multiImages,
      rejectedRegions: refusedRegions.length,
      rejectedByReason: rejectionTally(refusedRegions),
      warnings: warnings,
    );
  }

  /// Records the measured outcomes of analysis for one image: detection,
  /// confidence, automatic and user classification, face verification, the
  /// boundary-review gate, and one independent document record per region.
  ///
  /// Everything here is written from values the pipeline returned — counts,
  /// enum names, measured scores — so the record cannot claim more than was
  /// measured. A region with no quadrilateral is recorded as a FAILED boundary
  /// stage, not as a silent gap.
  void _recordAnalysisStages(ImageAsset asset, ImageAnalysis analysis) {
    final ledger = this.ledger;
    if (ledger == null) return;
    final imageId = asset.id;
    final regions = analysis.allRegions;
    final preprocessingAttempts = regions.fold<int>(
      0,
      (total, region) => total + region.preprocessingAttempts,
    );
    final preprocessingFailures = regions.fold<int>(
      0,
      (total, region) => total + region.preprocessingFailures,
    );
    final preprocessingDurationMs = regions
        .map((region) => region.preprocessingDurationMs)
        .whereType<int>()
        .fold<int>(0, (total, duration) => total + duration);
    if (preprocessingAttempts == 0) {
      if (options?.route == IntakeRoute.singleManualKind) {
        ledger.overridden(
          imageId,
          ProcessingStage.preprocessing,
          reason: 'اختار المستخدم النوع؛ لم تُجهز منطقة OCR.',
          actionTaken: 'استُخدم الاختيار البشري بدلاً من قراءة النص.',
        );
      } else {
        ledger.notApplicable(
          imageId,
          ProcessingStage.preprocessing,
          reason: !ocr.isEnabled
              ? 'محرك OCR غير متاح؛ لم تُجهز منطقة قراءة نص.'
              : 'لم تتوفر منطقة آمنة لتهيئتها من أجل OCR.',
        );
      }
    } else if (preprocessingFailures > 0) {
      ledger.failed(
        imageId,
        ProcessingStage.preprocessing,
        reason:
            'فشلت تهيئة OCR في $preprocessingFailures من '
            '$preprocessingAttempts محاولات.',
        durationMs: preprocessingDurationMs,
        errorType: 'PreprocessingFailure',
        errorCode: 'preprocessing_failed',
        diagnostics: const ['ocr_region_preparation_failed'],
        inputs: {'regions': regions.length},
        results: {
          'attempts': preprocessingAttempts,
          'failed': preprocessingFailures,
        },
        evidence: StageEvidence(
          verified: false,
          checks: [
            EvidenceCheck(name: 'preprocessing_attempted', passed: true),
            EvidenceCheck(name: 'preprocessing_complete', passed: false),
          ],
          counts: {
            'reads': preprocessingAttempts,
            'failed': preprocessingFailures,
          },
        ),
        actionTaken: 'استمر التحليل دون نص للمناطق التي فشلت تهيئتها.',
      );
    } else {
      ledger.succeeded(
        imageId,
        ProcessingStage.preprocessing,
        reason: 'جُهزت مناطق OCR المقاسة قبل قراءة النص.',
        durationMs: preprocessingDurationMs,
        inputs: {'regions': regions.length},
        results: {'attempts': preprocessingAttempts},
        evidence: StageEvidence(
          verified: true,
          checks: [
            EvidenceCheck(name: 'preprocessing_attempted', passed: true),
            EvidenceCheck(name: 'preprocessing_complete', passed: true),
          ],
          counts: {'reads': preprocessingAttempts},
        ),
        actionTaken: 'انتقلت المناطق الجاهزة إلى قراءة النص.',
      );
    }
    final recognitionDurations = regions
        .map((region) => region.recognitionDurationMs)
        .whereType<int>()
        .toList(growable: false);
    final recognitionDurationMs = recognitionDurations.fold<int>(
      0,
      (total, duration) => total + duration,
    );
    final segmentationFailed = analysis.issues.any(
      (issue) => issue.category == RecognitionErrorCategory.segmentationFailure,
    );
    if (segmentationFailed) {
      ledger.failed(
        imageId,
        ProcessingStage.detection,
        reason: 'تعذر تقسيم الصورة؛ عولجت كمستند واحد.',
        errorType: 'SegmentationFailure',
        errorCode: 'segmentation_failed',
        diagnostics: const ['segmentation_exception'],
        durationMs: analysis.detectionDurationMs,
        actionTaken: 'استُخدم مسار المستند الواحد الاحتياطي.',
      );
    } else {
      ledger.succeeded(
        imageId,
        ProcessingStage.detection,
        reason: regions.isEmpty
            ? 'لم تُقَس أي منطقة مستند في هذه الصورة.'
            : regions.length == 1
            ? 'قِيست منطقة مستند واحدة.'
            : 'قِيست ${regions.length} مناطق مستند.',
        evidence: StageEvidence(
          verified: true,
          checks: [
            EvidenceCheck(
              name: 'region_count_measured',
              passed: true,
              detail: '${regions.length}',
            ),
          ],
          counts: {
            'regions': regions.length,
            'detections': analysis.detections.length,
            'unresolved': analysis.unresolvedRegions.length,
            'rejected': analysis.rejectedRegions.length,
          },
        ),
        results: {'multi': analysis.multi},
        durationMs: analysis.detectionDurationMs,
        actionTaken: regions.isEmpty
            ? 'بقيت الصورة كاملة للمعالجة اليدوية.'
            : 'تابع التحليل إلى الحدود والتصنيف.',
      );
    }

    // Confidence: only scores the pipeline actually produced are recorded.
    final scores = <double>[
      for (final detection in regions) ...[
        if (detection.detectionConfidence case final value?) value,
        if (detection.classification.confidences.classification?.value
            case final value?)
          value,
      ],
    ];
    if (scores.isEmpty) {
      ledger.notApplicable(
        imageId,
        ProcessingStage.confidence,
        reason: 'لا يوفر هذا المسار درجة ثقة مقيسة لهذه الصورة.',
      );
    } else {
      ledger.succeeded(
        imageId,
        ProcessingStage.confidence,
        reason: 'جُمعت ${scores.length} درجة ثقة مقيسة.',
        evidence: StageEvidence(
          verified: true,
          checks: [
            EvidenceCheck(name: 'scores_measured', passed: true),
            EvidenceCheck(
              name: 'scores_in_range',
              passed: scores.every((score) => score >= 0 && score <= 1),
            ),
          ],
          counts: {'scores': scores.length},
        ),
        results: {
          'lowest': scores.reduce((a, b) => math.min(a, b)),
          'highest': scores.reduce((a, b) => math.max(a, b)),
        },
        actionTaken: 'استُخدمت الدرجات في بوابات القبول والمراجعة.',
      );
    }

    final chosen = options;
    if (chosen != null && chosen.assertsKind) {
      ledger.overridden(
        imageId,
        ProcessingStage.automaticClassification,
        reason:
            'حدّد المستخدم النوع «${chosen.kind.label}»؛ لم يُستخدم المصنّف الآلي.',
        inputs: {'kind': chosen.kind.name},
        actionTaken: 'حُفظ النوع بوصفه ادّعاءً بشرياً لا استنتاجاً آلياً.',
      );
      ledger.succeeded(
        imageId,
        ProcessingStage.userClassification,
        reason: 'اعتُمد النوع الذي حدده المستخدم على كل مستندات الدفعة.',
        evidence: StageEvidence(
          verified: chosen.kind != DocumentKind.unknown,
          checks: [
            EvidenceCheck(
              name: 'user_kind_present',
              passed: chosen.kind != DocumentKind.unknown,
            ),
          ],
          counts: {'documents': regions.length},
        ),
        inputs: {'kind': chosen.kind.name},
        results: {'source': 'user'},
      );
    } else {
      if (regions.isEmpty) {
        ledger.notApplicable(
          imageId,
          ProcessingStage.automaticClassification,
          reason: 'لا مناطق مستند لتصنيفها.',
        );
      } else {
        final known = regions
            .where(
              (region) =>
                  region.classification.status == RecognitionStatus.recognized,
            )
            .length;
        ledger.succeeded(
          imageId,
          ProcessingStage.automaticClassification,
          reason: known == regions.length
              ? 'صُنفت كل المناطق تلقائياً.'
              : 'صُنفت $known من ${regions.length} مناطق تلقائياً؛ '
                    'الباقي غير محسوم.',
          evidence: StageEvidence(
            verified: true,
            checks: [EvidenceCheck(name: 'classification_ran', passed: true)],
            counts: {'regions': regions.length, 'known': known},
          ),
          results: {'known': known},
          durationMs: recognitionDurations.isEmpty
              ? null
              : recognitionDurationMs,
          actionTaken: known == regions.length
              ? 'استُخدم النوع المقاس.'
              : 'بقيت الأنواع غير المحسومة للمراجعة البشرية.',
        );
      }
      ledger.notApplicable(
        imageId,
        ProcessingStage.userClassification,
        reason: 'لم يحدد المستخدم نوعاً لهذه الدفعة.',
      );
    }

    final side = chosen?.side ?? SideKind.unknown;
    if (side == SideKind.unknown || regions.isEmpty) {
      ledger.notApplicable(
        imageId,
        ProcessingStage.faceVerification,
        reason: side == SideKind.unknown
            ? 'لم يُحدد وجه للدفعة؛ لا اقتران وجهين ليتحقق.'
            : 'لا توجد مستندات مقاسة لتطبيق الوجه الذي اختاره المستخدم.',
      );
    } else {
      ledger.succeeded(
        imageId,
        ProcessingStage.faceVerification,
        reason: 'تحقق الوجه «${side.name}» وطُبّق على المستندات.',
        evidence: StageEvidence(
          verified: true,
          checks: [
            EvidenceCheck(name: 'side_asserted', passed: true),
            EvidenceCheck(
              name: 'documents_carry_side',
              passed: true,
              detail: '${regions.length}',
            ),
          ],
          counts: {'documents': regions.length},
        ),
        inputs: {'side': side.name},
        actionTaken: 'حُفظ الوجه كما حدده المستخدم.',
      );
    }

    for (final detection in regions) {
      final documentId = detection.detectionId;
      final document = ledger.document(
        imageId,
        documentId: documentId,
        index: detection.regionIndex + 1,
        label: 'المستمسك ${detection.regionIndex + 1}',
        kind: detection.classification.kind,
        side: side,
        kindSource: chosen != null && chosen.assertsKind
            ? RecordSource.user
            : detection.classification.kind == DocumentKind.unknown
            ? RecordSource.unknown
            : RecordSource.automatic,
        sideSource: side == SideKind.unknown
            ? RecordSource.unknown
            : RecordSource.user,
      );
      final corners = detection.corners;
      final suggested = detection.suggestedCorners;
      if (corners != null) {
        ledger.documentSucceeded(
          imageId,
          document.id,
          ProcessingStage.boundaryCorners,
          reason: 'اعتُمد رباعي الزوايا المقاس للمنطقة.',
          evidence: StageEvidence(
            verified: corners.length == 4,
            checks: [
              EvidenceCheck(
                name: 'corner_count',
                passed: corners.length == 4,
                detail: '${corners.length}',
              ),
            ],
            counts: {'corners': corners.length},
          ),
          results: {'origin': 'measured_accepted'},
          itemCount: corners.length,
        );
      } else if (suggested != null) {
        ledger.documentSucceeded(
          imageId,
          document.id,
          ProcessingStage.boundaryCorners,
          reason: 'اقتُرح رباعي بانتظار مراجعة المستخدم؛ لم يُعتمد للقص.',
          evidence: StageEvidence(
            verified: suggested.length == 4,
            checks: [
              EvidenceCheck(
                name: 'suggested_corner_count',
                passed: suggested.length == 4,
                detail: '${suggested.length}',
              ),
            ],
          ),
          results: {'origin': 'suggested_review'},
          itemCount: suggested.length,
          actionTaken: 'بقيت الزوايا قابلة للتعديل في شاشة القص.',
        );
      } else if (detection.region != null) {
        ledger.documentFailed(
          imageId,
          document.id,
          ProcessingStage.boundaryCorners,
          reason: 'لم يُعثر على رباعي زوايا لهذه المنطقة المقاسة.',
          errorType: 'NoBoundary',
          errorCode: 'boundary_undetected',
          diagnostics: const ['measured_region_without_quad'],
          results: {'region_crop': true},
          actionTaken: 'حُفظت المنطقة المقاسة لتُقصّ يدوياً.',
        );
      } else {
        ledger.documentOverridden(
          imageId,
          document.id,
          ProcessingStage.boundaryCorners,
          reason: 'لا رباعي مقاس؛ استُخدم إطار الصورة الكامل كمسار احتياطي.',
          actionTaken: 'يمكن رسم الحدود يدوياً.',
        );
      }

      final assessment = detection.geometry;
      if (assessment == null) {
        ledger.documentNotApplicable(
          imageId,
          document.id,
          ProcessingStage.geometryCheck,
          reason: 'لا زوايا مقاسة لتُفحص هندسياً.',
        );
      } else if (assessment.acceptable) {
        ledger.documentSucceeded(
          imageId,
          document.id,
          ProcessingStage.geometryCheck,
          reason: 'اجتاز الرباعي التحقق الهندسي.',
          evidence: StageEvidence(
            verified: true,
            checks: [EvidenceCheck(name: 'quad_acceptable', passed: true)],
          ),
          results: {
            if (assessment.geometryConfidence != null)
              'geometry_confidence': assessment.geometryConfidence,
            if (assessment.aspect != null) 'aspect': assessment.aspect,
            if (assessment.areaFraction != null)
              'area_fraction': assessment.areaFraction,
          },
          actionTaken: 'سُمح بمتابعة بوابة القبول والقص.',
        );
      } else {
        ledger.documentFailed(
          imageId,
          document.id,
          ProcessingStage.geometryCheck,
          reason:
              'رُفض الرباعي هندسياً: '
              '${assessment.rejection?.name ?? 'سبب غير محسوم'}.',
          errorType: 'GeometryRejected',
          errorCode: assessment.rejection?.name ?? 'geometry_rejected',
          diagnostics: const ['quad_assessment_rejected'],
          actionTaken: 'لم يُسمح بالقص الآلي؛ بقي للمراجعة اليدوية.',
          evidence: StageEvidence(
            verified: false,
            checks: [EvidenceCheck(name: 'quad_acceptable', passed: false)],
          ),
        );
      }

      final decision = detection.boundaryDecision;
      if (decision == null) {
        ledger.documentNotApplicable(
          imageId,
          document.id,
          ProcessingStage.boundaryReview,
          reason: 'لا قرار حدود لهذه المنطقة.',
        );
      } else {
        final reasons = decision.verification.reasons.length;
        ledger.documentSucceeded(
          imageId,
          document.id,
          ProcessingStage.boundaryReview,
          reason: decision.cropAuthorization != null
              ? 'اعتُمد القص لهذا المستند.'
              : 'عُرضت الحدود للمراجعة؛ لم يُسمح بالقص الآلي.',
          evidence: StageEvidence(
            verified: true,
            checks: [
              EvidenceCheck(
                name: 'decision_recorded',
                passed: decision.kind.name.isNotEmpty,
              ),
            ],
            counts: {'review_reasons': reasons},
          ),
          results: {
            'decision': decision.kind.name,
            'userApproved': decision.verification.userApproved,
            'cropAuthorized': decision.cropAuthorization != null,
          },
          actionTaken: decision.cropAuthorization != null
              ? 'تابع إلى القص.'
              : 'بقيت الزوايا للمراجعة البشرية.',
        );
      }
    }
  }

  /// Records the crop boundary for per-document results discarded when an
  /// image-level apply was cancelled or failed before its staged output could
  /// be committed. Previously completed analysis/geometry rows remain intact.
  void _recordUncommittedApply(
    _Analyzed analyzed, {
    required String reason,
    required bool cancelled,
    required Map<String, _MeasuredSpan> cropSpans,
    Object? error,
  }) {
    final ledger = this.ledger;
    if (ledger == null) return;
    final imageId = analyzed.asset.id;
    for (final detection in analyzed.analysis.allRegions) {
      final document = ledger.existingDocument(imageId, detection.detectionId);
      if (document == null || document.statusOf(ProcessingStage.crop) != null) {
        continue;
      }
      if (cancelled) {
        ledger.documentCancelled(
          imageId,
          document.id,
          ProcessingStage.crop,
          reason: reason,
          durationMs: cropSpans[detection.detectionId]?.durationMs,
          startedAt: cropSpans[detection.detectionId]?.startedAt,
          endedAt: cropSpans[detection.detectionId]?.endedAt,
          actionTaken: 'لم تُحفظ نتيجة جزئية؛ بقي المصدر الأصلي محفوظاً.',
        );
      } else {
        ledger.documentFailed(
          imageId,
          document.id,
          ProcessingStage.crop,
          error: error,
          reason: reason,
          diagnostics: const ['image_apply_failed'],
          durationMs: cropSpans[detection.detectionId]?.durationMs,
          startedAt: cropSpans[detection.detectionId]?.startedAt,
          endedAt: cropSpans[detection.detectionId]?.endedAt,
          actionTaken: 'لم تُحفظ نتيجة جزئية؛ بقي المصدر الأصلي محفوظاً.',
        );
      }
    }
  }

  /// Records what applying the analysis produced, per document: the crop, the
  /// perspective correction, the output adjustments and the document model.
  ///
  /// A document that was never cropped is recorded as OVERRIDDEN with the
  /// reason, not as a successful crop: the whole frame was kept deliberately,
  /// which is a decision, not a produced crop.
  void _recordAppliedDocuments(
    Project project,
    ImageAsset asset,
    List<DocumentRecord> documents,
    List<DocumentItem> items, {
    required Map<String, _MeasuredSpan> cropSpans,
  }) {
    final ledger = this.ledger;
    if (ledger == null || documents.isEmpty) return;
    final imageId = asset.id;
    for (final record in documents) {
      final side = record.sides.first;
      final detectionId = side.detection?.detectionId;
      var document = detectionId == null
          ? null
          : ledger.existingDocument(imageId, detectionId);
      document ??= ledger.document(
        imageId,
        documentId: record.id,
        kind: record.recognition?.documentKind ?? DocumentKind.unknown,
        side: side.side,
        kindSource: record.recognition == null
            ? RecordSource.unknown
            : RecordSource.automatic,
        sideSource: side.side == SideKind.unknown
            ? RecordSource.unknown
            : RecordSource.user,
      );
      final item = items
          .where((entry) => entry.documentId == record.id)
          .firstOrNull;
      ledger.linkDocument(
        imageId,
        document.id,
        recordId: record.id,
        itemId: item?.id,
      );
      final processed = side.processedAsset;
      final cropped =
          processed.outputWidth != null && processed.outputHeight != null;
      if (cropped) {
        final cropSpan = detectionId == null ? null : cropSpans[detectionId];
        ledger.documentSucceeded(
          imageId,
          document.id,
          ProcessingStage.crop,
          reason: 'قُصّ المستند وأُنتجت صورة بأبعاد صالحة.',
          evidence: StageEvidence(
            verified: processed.outputWidth! > 0 && processed.outputHeight! > 0,
            checks: [
              EvidenceCheck(
                name: 'output_width_positive',
                passed: processed.outputWidth! > 0,
                detail: '${processed.outputWidth}',
              ),
              EvidenceCheck(
                name: 'output_height_positive',
                passed: processed.outputHeight! > 0,
                detail: '${processed.outputHeight}',
              ),
            ],
          ),
          results: {
            'width': processed.outputWidth,
            'height': processed.outputHeight,
          },
          itemCount: 1,
          durationMs: cropSpan?.durationMs,
          startedAt: cropSpan?.startedAt,
          endedAt: cropSpan?.endedAt,
          actionTaken: 'حُفظت الصورة المقصوصة كمشتقة من الأصل.',
        );
        ledger.documentSucceeded(
          imageId,
          document.id,
          ProcessingStage.perspective,
          reason: 'صُحح المنظور من الزوايا الأربع المقبولة.',
          evidence: StageEvidence(
            verified: processed.corners?.length == 4,
            checks: [
              EvidenceCheck(
                name: 'four_corners',
                passed: processed.corners?.length == 4,
                detail: '${processed.corners?.length ?? 0}',
              ),
            ],
            counts: {'corners': processed.corners?.length ?? 0},
            note:
                'تصحيح المنظور مشمول في رسم القص؛ تُسجل مدة الرسم المشتركة '
                'في مرحلة القص.',
          ),
          results: {
            'width': processed.outputWidth,
            'height': processed.outputHeight,
          },
          actionTaken: 'تابع إلى حفظ الصورة المقصوصة.',
        );
        ledger.documentSucceeded(
          imageId,
          document.id,
          ProcessingStage.outputEnhancement,
          reason: 'طُبقت إعدادات الصورة الناتجة وأُنتجت بأبعاد صالحة.',
          evidence: StageEvidence(
            verified: true,
            checks: [
              EvidenceCheck(
                name: 'rendered_output_present',
                passed: processed.workingPath.isNotEmpty,
              ),
            ],
            note:
                'التحقق من وجود المخرج وأبعاده؛ الإعدادات محفوظة في وصف المعالجة. '
                'الرسم والحدة مشتركان مع القص؛ لا تُكرر مدته هنا.',
          ),
          results: {
            'width': processed.outputWidth,
            'height': processed.outputHeight,
          },
        );
      } else {
        ledger.documentOverridden(
          imageId,
          document.id,
          ProcessingStage.crop,
          reason: 'لم يُقص هذا المستند؛ بقي بإطار الصورة الكامل.',
          actionTaken: 'يمكن قصّه يدوياً من شاشة القص.',
        );
        ledger.documentNotApplicable(
          imageId,
          document.id,
          ProcessingStage.perspective,
          reason: 'لا رباعي مقبول لتصحيح منظوره.',
        );
        ledger.documentNotApplicable(
          imageId,
          document.id,
          ProcessingStage.outputEnhancement,
          reason: 'لا صورة مقصوصة لتحسينها.',
        );
      }

      final kind =
          record.recognition?.documentKind ??
          item?.documentKind ??
          DocumentKind.unknown;
      ledger.documentSucceeded(
        imageId,
        document.id,
        ProcessingStage.documentModel,
        reason: 'أُنشئ سجل المستند وربط وجهه بالصورة الأصلية.',
        evidence: StageEvidence(
          verified:
              record.sides.isNotEmpty &&
              record.sourceImageId == asset.id &&
              record.sides.first.id.isNotEmpty,
          checks: [
            EvidenceCheck(
              name: 'side_created',
              passed: record.sides.isNotEmpty,
            ),
            EvidenceCheck(
              name: 'source_linked',
              passed: record.sourceImageId == asset.id,
            ),
          ],
          counts: {'sides': record.sides.length},
        ),
        results: {'kind': kind.name, 'side': side.side.name},
        actionTaken: 'تابع إلى تثبيت النوع والمقاس.',
      );
      if (kind != DocumentKind.unknown && item != null && item.sizeConfirmed) {
        ledger.documentSucceeded(
          imageId,
          document.id,
          ProcessingStage.typeSideSize,
          reason: 'ثُبّت النوع والوجه والمقاس المؤكد على المستند والعنصر.',
          evidence: StageEvidence(
            verified: true,
            checks: [
              EvidenceCheck(name: 'kind_assigned', passed: true),
              EvidenceCheck(name: 'item_present', passed: true),
              EvidenceCheck(name: 'size_confirmed', passed: true),
            ],
            counts: {'kind_known': 1, 'size_confirmed': 1},
          ),
          results: {
            'kind': kind.name,
            'side': side.side.name,
            'sizeConfirmed': true,
          },
          actionTaken: 'تأكد النوع والمقاس قبل متابعة الإضافة.',
        );
      } else if (item == null) {
        ledger.documentFailed(
          imageId,
          document.id,
          ProcessingStage.typeSideSize,
          reason: 'لم يُنشأ عنصر للمستند لتثبيت النوع والمقاس.',
          errorType: 'MissingLayoutItem',
          errorCode: 'layout_item_missing',
          diagnostics: const ['layout_item_missing'],
          actionTaken: 'راجع إنشاء عنصر الصفحة قبل متابعة الإضافة.',
        );
      } else {
        final detection = record.sides
            .map((entry) => entry.detection)
            .whereType<DetectionRef>()
            .firstOrNull;
        final shapeMismatch =
            detection?.detectionTrace.contains('catalogShape=mismatch') ??
            false;
        final recognition = record.recognition;
        final classificationConfidence =
            recognition?.confidences.classification?.value;
        final classificationConfirmed =
            recognition?.status == RecognitionStatus.recognized &&
            (options?.assertsKind == true ||
                (classificationConfidence != null &&
                    classificationConfidence >=
                        thresholds.classificationAcceptance));
        final perspectiveAccepted =
            document.statusOf(ProcessingStage.perspective) ==
                StageStatus.succeeded &&
            document.statusOf(ProcessingStage.crop) == StageStatus.succeeded;
        final (reason, diagnostic) = kind == DocumentKind.unknown
            ? (
                'لم يُحسم نوع المستند؛ اختر النوع أو أدخل قياساً يدوياً.',
                'document_kind_unconfirmed',
              )
            : project.catalog.natural(kind) == null
            ? (
                'لا يوجد مقاس موثق لهذا النوع؛ أدخل قياس النسخة يدوياً قبل وضعها على A4.',
                'size_definition_missing',
              )
            : presetStatusFor(kind) == PresetStatus.estimated
            ? (
                'مقاس الكتالوج لهذا النوع تقديري وغير موثق؛ راجعه وأكّده يدوياً.',
                'estimated_size_requires_confirmation',
              )
            : !classificationConfirmed
            ? (
                'لا يكفي دليل التصنيف لتثبيت مقاس الكتالوج؛ اختر النوع يدوياً أو أكّده.',
                'classification_confidence_below_threshold',
              )
            : !perspectiveAccepted
            ? (
                'لا يتوفر قص منظور معتمد لهذا المستند؛ لم يُثبت مقاس الكتالوج.',
                'approved_perspective_crop_missing',
              )
            : shapeMismatch
            ? (catalogShapeUnconfirmedMessage(), 'catalog_shape_mismatch')
            : (
                'لم تُتحقق شروط تثبيت مقاس الكتالوج؛ بقي القياس المؤقت للمراجعة.',
                'catalog_size_not_confirmed',
              );
        ledger.documentNeedsReview(
          imageId,
          document.id,
          ProcessingStage.typeSideSize,
          reason: reason,
          inputs: {
            'kind': kind.name,
            'side': side.side.name,
            'kindSource': document.kindSource.name,
            'sideSource': document.sideSource.name,
            'sizeProvidedByUser': false,
          },
          results: {
            'kind': kind.name,
            'side': side.side.name,
            'sizeConfirmed': false,
            'sizeSource': 'provisional_image_dimensions',
            'width_mm': item.width,
            'height_mm': item.height,
            if (classificationConfidence != null)
              'classificationConfidence': classificationConfidence,
            if (detection != null) 'detectionId': detection.detectionId,
            if (shapeMismatch) 'catalogShape': 'mismatch',
          },
          diagnostics: [diagnostic, 'user_measurement_missing'],
          actionTaken: 'ثبّت النوع أو أدخل القياس الفعلي قبل ترتيب المستند.',
        );
      }
    }
  }

  /// Records the save, insertion and independent verification of every
  /// document this batch committed.
  ///
  /// Verification reads the project back from the repository — not from the
  /// value this method was handed — because the question is «هل أصبح المستند
  /// جزءاً من المشروع المحفوظ؟», and only a read can answer it.
  ///
  /// Records the placement result of every document this batch committed,
  /// one placement step per image, aggregated over its documents.
  ///
  /// The placement facts the journey report derives from the project, written
  /// as the stage the batch recorded during processing.
  ///
  /// The derived report already states which items sit on the page and where;
  /// for a single-document image it carries nothing machine-readable at all,
  /// and it is silent about whether each item's size was confirmed. This
  /// record fills exactly those gaps — the placed flag, the page number and
  /// the size confirmation per document — read from the item itself, never
  /// recomputed. The detail strings and the per-item key scheme are the same
  /// ones the derived step uses, so the two agree and the overlay merge keeps
  /// them consistent rather than showing two shapes of the same fact.
  void _recordPlacementStages(
    IntakeBatchLog? stageLog,
    Project current,
    List<DocumentRecord> documents,
  ) {
    if (stageLog == null || documents.isEmpty) return;
    final byImage = <String, List<DocumentRecord>>{};
    for (final record in documents) {
      byImage.putIfAbsent(record.sourceImageId, () => []).add(record);
    }
    for (final entry in byImage.entries) {
      final imageId = entry.key;
      final records = entry.value;
      final items = [
        for (final record in records)
          current.items.where((item) => item.documentId == record.id).firstOrNull,
      ];
      final placed = [
        for (final item in items)
          if (item?.pageIndex != null) item!,
      ];
      final log = stageLog.forAsset(imageId);
      if (log == null) continue;
      if (items.every((item) => item == null)) continue;
      final fields = <String, Object?>{
        'items': items.length,
        'placedItems': placed.length,
        for (var i = 0; i < items.length; i++) ...{
          'i${i + 1}_placed': items[i]?.pageIndex != null,
          if (items[i]?.pageIndex != null)
            'i${i + 1}_page': items[i]!.pageIndex! + 1,
          if (items[i] != null) 'i${i + 1}_sizeConfirmed': items[i]!.sizeConfirmed,
          if (items[i] != null)
            'i${i + 1}_sizeSource': items[i]!.sizeConfirmed
                ? 'catalog'
                : 'provisional_image_dimensions',
        },
      };
      final String detail;
      final allPlaced = items.every((item) => item?.pageIndex != null);
      if (allPlaced) {
        final pages = {for (final item in placed) item.pageIndex! + 1}.toList()
          ..sort();
        final pageText = pages.length == 1
            ? 'الصفحة ${pages.single}'
            : 'الصفحات ${pages.join('، ')}';
        final count = items.length > 1 ? ' (${items.length} عناصر)' : '';
        detail = 'وُضع في $pageText داخل حدود الورقة$count.';
      } else if (placed.isNotEmpty) {
        detail =
            'وُضع ${placed.length} من ${items.length} عناصر على الورقة؛ '
            'البقية خارجها وتحتاج مراجعة.';
      } else {
        final firstMissing = items.firstWhere(
          (item) => item?.pageIndex == null,
          orElse: () => items.first,
        );
        detail = firstMissing == null
            ? 'لم يُعثر على عنصر هذا المستند في المشروع.'
            : unplacedDocumentMessage(current, firstMissing);
      }
      log.record(
        IntakeStageRecord(
          stage: JourneyStage.placement,
          outcome: allPlaced ? JourneyOutcome.passed : JourneyOutcome.review,
          detail: detail,
          fields: fields,
        ),
      );
    }
  }

  Future<void> _recordCommittedDocuments(
    Project current,
    List<DocumentRecord> documents, {
    required bool arranged,
    Set<String> centeredItemIds = const <String>{},
  }) async {
    final ledger = this.ledger;
    if (ledger == null || documents.isEmpty) return;
    Project? readBack;
    Object? readError;
    try {
      readBack = await projects.get(current.id);
    } on Object catch (error) {
      readError = error;
    }
    for (final record in documents) {
      final imageId = record.sourceImageId;
      final processed = record.sides.first.processedAsset;
      final detectionId = record.sides.first.detection?.detectionId;
      var document = detectionId == null
          ? null
          : ledger.existingDocument(imageId, detectionId);
      document ??= ledger.existingDocument(imageId, record.id);
      if (document == null) continue;
      final item = current.items
          .where((entry) => entry.documentId == record.id)
          .firstOrNull;
      final asset = current.assets
          .where(
            (entry) =>
                entry.workingPath == processed.workingPath ||
                entry.originalPath == processed.workingPath,
          )
          .firstOrNull;
      ledger.linkDocument(
        imageId,
        document.id,
        recordId: record.id,
        itemId: item?.id,
        assetId: asset?.id,
      );
      final recordSaved = current.documents.any(
        (entry) => entry.id == record.id,
      );
      final assetPresent = asset != null;
      ledger.documentSucceeded(
        imageId,
        document.id,
        ProcessingStage.saveDocument,
        reason: 'حُفظ المشروع وفيه سجل المستند وأصله.',
        evidence: StageEvidence(
          verified: recordSaved && assetPresent,
          checks: [
            EvidenceCheck(name: 'record_persisted', passed: recordSaved),
            EvidenceCheck(name: 'asset_present', passed: assetPresent),
          ],
        ),
        results: {'revision': current.revision},
        actionTaken: 'تابع إلى التحقق من الإضافة.',
      );
      if (item == null) {
        ledger.documentFailed(
          imageId,
          document.id,
          ProcessingStage.addToProject,
          reason: 'لم يُعثر على عنصر المستند في المشروع بعد الحفظ.',
          errorType: 'MissingItem',
          errorCode: 'item_missing',
          diagnostics: const ['document_saved_without_item'],
          actionTaken: 'بقيت الصورة محفوظة، ويحتاج المستند إلى إعادة إضافة.',
        );
      } else {
        ledger.documentSucceeded(
          imageId,
          document.id,
          ProcessingStage.addToProject,
          reason: item.pageIndex == null
              ? 'أُضيف المستند إلى المشروع، وبقي خارج ورقة A4.'
              : 'أُضيف المستند إلى ورقة A4.',
          evidence: StageEvidence(
            verified: true,
            checks: [EvidenceCheck(name: 'item_in_project', passed: true)],
            counts: {'items': current.items.length},
          ),
          results: {'page': item.pageIndex ?? -1},
          actionTaken: item.pageIndex == null
              ? 'بانتظار تأكيد المقاس أو الترتيب.'
              : 'وُضع على الورقة.',
        );
      }
      if (item == null) {
        ledger.documentFailed(
          imageId,
          document.id,
          ProcessingStage.placement,
          reason: 'تعذر التحقق من الوضع لأن عنصر المستند مفقود.',
          errorType: 'MissingItem',
          errorCode: 'item_missing',
          diagnostics: const ['layout_item_missing'],
          actionTaken: 'راجع إضافة العنصر إلى المشروع.',
        );
      } else if (item.pageIndex != null) {
        ledger.documentSucceeded(
          imageId,
          document.id,
          ProcessingStage.placement,
          reason: 'وُضع عنصر هذا المستند على ورقة A4.',
          evidence: StageEvidence(
            verified: true,
            checks: [EvidenceCheck(name: 'item_on_page', passed: true)],
            counts: {'page': item.pageIndex! + 1},
          ),
          results: {
            'itemId': item.id,
            'placed': true,
            'page': item.pageIndex!,
            'sizeConfirmed': item.sizeConfirmed,
          },
          actionTaken: 'أُكد موضع المستند على الورقة.',
        );
      } else if (!arranged) {
        ledger.documentStopped(
          imageId,
          document.id,
          ProcessingStage.placement,
          reason: 'أُجّل ترتيب هذا العنصر؛ لم تُحسم نتيجة وضعه بعد.',
          results: {
            'itemId': item.id,
            'placed': false,
            'page': -1,
            'sizeConfirmed': item.sizeConfirmed,
          },
          diagnostics: const ['arrangement_deferred'],
          actionTaken: 'تُحدّث هذه المرحلة بعد ترتيب الدفعة.',
        );
      } else {
        final placementDiagnostic = switch (autoLayoutStatus(current, item)) {
          AutoLayoutStatus.locked => 'placement_locked',
          AutoLayoutStatus.sizeUnconfirmed => 'placement_size_unconfirmed',
          AutoLayoutStatus.tooLarge => 'placement_too_large',
          AutoLayoutStatus.groupNeedsSpace => 'placement_group_no_space',
          AutoLayoutStatus.eligible => 'placement_no_space',
        };
        ledger.documentNeedsReview(
          imageId,
          document.id,
          ProcessingStage.placement,
          reason: unplacedDocumentMessage(current, item),
          results: {
            'itemId': item.id,
            'placed': false,
            'page': -1,
            'sizeConfirmed': item.sizeConfirmed,
          },
          diagnostics: [placementDiagnostic],
          actionTaken: item.sizeConfirmed
              ? 'أُبقي المستند محفوظاً؛ أعد الترتيب بعد توفير مساحة.'
              : 'أُبقي المستند محفوظاً؛ ثبّت المقاس قبل محاولة الوضع.',
        );
      }
      if (readBack == null) {
        ledger.documentFailed(
          imageId,
          document.id,
          ProcessingStage.verifyAddition,
          reason:
              'تعذرت قراءة المشروع المحفوظ للتحقق: '
              '${describeFailure(readError)}',
          error: readError,
          errorType: 'VerificationReadFailed',
          errorCode: FailureCode.storage,
          diagnostics: const ['read_back_failed'],
          actionTaken: 'بقيت النتيجة غير مؤكدة من التخزين.',
        );
      } else {
        final confirmedRecord = readBack.documents.any(
          (entry) => entry.id == record.id,
        );
        final confirmedItem = readBack.items.any(
          (entry) => entry.documentId == record.id,
        );
        if (confirmedRecord && confirmedItem) {
          ledger.documentSucceeded(
            imageId,
            document.id,
            ProcessingStage.verifyAddition,
            reason: 'أُكد وجود المستند وعنصره في المشروع المحفوظ.',
            evidence: StageEvidence(
              verified: true,
              checks: [
                EvidenceCheck(
                  name: 'record_in_saved_project',
                  passed: confirmedRecord,
                ),
                EvidenceCheck(
                  name: 'item_in_saved_project',
                  passed: confirmedItem,
                ),
              ],
              counts: {'revision': readBack.revision},
            ),
            actionTaken: 'اكتملت إضافة المستند.',
          );
        } else {
          ledger.documentFailed(
            imageId,
            document.id,
            ProcessingStage.verifyAddition,
            reason: confirmedRecord
                ? 'سجل المستند محفوظ لكن عنصره غير موجود في المشروع المحفوظ.'
                : 'سجل المستند غير موجود في المشروع المحفوظ.',
            errorType: 'VerificationFailed',
            errorCode: 'addition_not_confirmed',
            diagnostics: const ['saved_project_missing_document'],
            actionTaken: 'يحتاج المستند إلى إعادة إضافة.',
          );
        }
      }
      if (item != null && current.layout.centerCaptures) {
        if (item.pageIndex == null) {
          ledger.documentNotApplicable(
            imageId,
            document.id,
            ProcessingStage.centering,
            reason: 'لا ينطبق التوسيط؛ لم يُوضع المستند على ورقة A4.',
          );
        } else if (arranged && centeredItemIds.contains(item.id)) {
          ledger.documentSucceeded(
            imageId,
            document.id,
            ProcessingStage.centering,
            reason: 'اجتاز المستند تمرير التوسيط ووُضع على الورقة.',
            evidence: StageEvidence(
              verified: true,
              checks: [
                EvidenceCheck(name: 'center_option_enabled', passed: true),
                EvidenceCheck(name: 'item_placed', passed: true),
                EvidenceCheck(name: 'centering_pass_clear', passed: true),
              ],
              note: 'أدرج محرك الترتيب العنصر في تمرير التوسيط دون تعارض.',
            ),
            actionTaken: 'اكتمل التوسيط مع وضع المستند.',
          );
        } else {
          ledger.documentStopped(
            imageId,
            document.id,
            ProcessingStage.centering,
            reason: !arranged
                ? 'أُجّل التوسيط إلى ترتيب الدفعة؛ لم تُثبت نتيجته بعد.'
                : item.pageIndex == null
                ? 'لم يُوضع المستند على الورقة؛ تعذر تطبيق التوسيط.'
                : 'تعذر إثبات تطبيق التوسيط دون تعارض على هذا المستند.',
            actionTaken: !arranged
                ? 'يُسوّى عند اكتمال الترتيب.'
                : item.pageIndex == null
                ? 'بقي المستند خارج الورقة للمراجعة.'
                : 'بقي المستند في موضعه لتجنب تعارض؛ راجع الترتيب.',
          );
        }
      } else if (item != null) {
        ledger.documentOverridden(
          imageId,
          document.id,
          ProcessingStage.centering,
          reason: 'عطّل المستخدم خيار التوسيط لهذه الدفعة.',
          actionTaken: 'وُضع المستند دون توسيط.',
        );
      }
      final summary = document.failed
          ? 'فشل مستند: ${document.firstFailure?.reason ?? 'سبب غير محسوم'}'
          : document.added
          ? 'حُفظ المستند وأُضيف وتحققت إضافته.'
          : 'حُفظ المستند دون تأكيد الإضافة.';
      ledger.linkDocument(
        imageId,
        document.id,
        recordId: record.id,
        itemId: item?.id,
        assetId: asset?.id,
        outcome: summary,
      );
    }
  }

  /// Phase A: bounded analysis of every requested source image.
  ///
  /// The analysis order is the request order; results keep it (worker
  /// contract), so batch output is deterministic however lanes finish.
  /// [skipAssetsWithItems] reproduces the first-intake rule that an image
  /// already placed on the sheet is left alone; reprocessing deliberately
  /// passes false, because those are exactly the images it must revisit.
  Future<_Analysis> _analyzeImages(
    Project project,
    Iterable<String> assetIds, {
    bool skipAssetsWithItems = false,
    CancellationToken? cancellation,
    void Function(BatchProgress progress)? onProgress,
  }) async {
    final pending = <ImageAsset>[];
    for (final id in assetIds.toSet()) {
      final index = project.assets.indexWhere((entry) => entry.id == id);
      require(index >= 0, 'الصورة المراد ترتيبها ليست ضمن المشروع.');
      if (skipAssetsWithItems &&
          project.items.any((item) => item.assetId == id)) {
        continue;
      }
      pending.add(project.assets[index]);
    }
    final outcomes = await worker.run<ImageAsset, _Analyzed>(
      pending,
      (asset) async {
        // Opening the preview AND analysing it are bounded together: the whole
        // analysis of ONE image must end. Without this a stage that never
        // answers leaves every later image untouched and the dialog open with
        // no result at all.
        final imageToken = CancellationToken();
        void cancelImage() => imageToken.cancel();
        cancellation?.addListener(cancelImage);
        ledger?.image(
          asset.id,
          name: asset.name,
          width: asset.width,
          height: asset.height,
        );
        final pipeline = RecognitionPipeline(
          suggestSingle: editor.suggest,
          suggestProposal: editor is BoundaryProposalImageEditor
              ? (preview) => (editor as BoundaryProposalImageEditor)
                    .suggestProposal(preview, cancellation: imageToken)
              : null,
          segment: segment,
          ocr: ocr,
          catalog: project.catalog,
          thresholds: thresholds,
          options: options,
        );
        try {
          return await ImportTrace.stage(
            'recognition',
            () => requireStageWithin(
              () async {
                final previewClock = Stopwatch()..start();
                final EditorSource source;
                try {
                  source = await ImportTrace.stage(
                    'decode',
                    () => editor.open(asset, cancellation: imageToken),
                    phase: 'preview',
                  );
                } on OperationCancelled {
                  previewClock.stop();
                  ledger?.cancelled(
                    asset.id,
                    ProcessingStage.previewPreparation,
                    reason: 'أُلغيت تهيئة المعاينة عند أول نقطة آمنة.',
                    durationMs: previewClock.elapsedMilliseconds,
                    actionTaken: 'بقيت الصورة الأصلية للمعالجة اليدوية.',
                  );
                  rethrow;
                } catch (error) {
                  previewClock.stop();
                  ledger?.failed(
                    asset.id,
                    ProcessingStage.previewPreparation,
                    error: error,
                    durationMs: previewClock.elapsedMilliseconds,
                    reason:
                        'تعذر تجهيز نسخة المعاينة: ${describeFailure(error)}',
                    actionTaken: 'بقيت الصورة الأصلية للمعالجة اليدوية.',
                  );
                  rethrow;
                }
                previewClock.stop();
                ImportTrace.current?.emit('image_decoded');
                ledger?.image(
                  asset.id,
                  name: asset.name,
                  width: source.width,
                  height: source.height,
                );
                ledger?.succeeded(
                  asset.id,
                  ProcessingStage.previewPreparation,
                  reason: 'أُنتجت نسخة معاينة صالحة للتحليل.',
                  evidence: StageEvidence(
                    verified: true,
                    checks: [
                      EvidenceCheck(
                        name: 'preview_not_empty',
                        passed: source.preview.isNotEmpty,
                        detail: '${source.preview.length}',
                      ),
                      EvidenceCheck(
                        name: 'dimensions_positive',
                        passed: source.width > 0 && source.height > 0,
                      ),
                    ],
                    counts: {'preview_bytes': source.preview.length},
                  ),
                  results: {'width': source.width, 'height': source.height},
                  durationMs: previewClock.elapsedMilliseconds,
                );
                if (ledger
                        ?.existingImage(asset.id)
                        ?.stageOf(ProcessingStage.dimensions) ==
                    null) {
                  ledger?.succeeded(
                    asset.id,
                    ProcessingStage.dimensions,
                    reason: 'قِيست أبعاد المصدر المستخدم في التحليل.',
                    evidence: StageEvidence(
                      verified: true,
                      checks: [
                        EvidenceCheck(
                          name: 'width_positive',
                          passed: source.width > 0,
                          detail: '${source.width}',
                        ),
                        EvidenceCheck(
                          name: 'height_positive',
                          passed: source.height > 0,
                          detail: '${source.height}',
                        ),
                      ],
                    ),
                    results: {'width': source.width, 'height': source.height},
                  );
                }
                final importIndex = pending.indexOf(asset);
                final input = PipelineImageInput(
                  assetId: asset.id,
                  previewBytes: source.preview,
                  sourceWidth: source.width,
                  sourceHeight: source.height,
                  importIndex: importIndex,
                  captureId: asset.captureId,
                );
                final ImageAnalysis analysis;
                if (ledger == null) {
                  analysis = await pipeline.analyze(input, token: imageToken);
                } else {
                  analysis = await ledger!.run(
                    asset.id,
                    ProcessingStage.analysis,
                    () => pipeline.analyze(input, token: imageToken),
                    verify: (value) =>
                        value.assetId == asset.id &&
                        value.detections.length +
                                value.unresolvedRegions.length <=
                            100 &&
                        value.rejectedRegions.length <= 1000,
                    successReason: 'اكتمل تحليل الصورة وأُعيدت نتيجته.',
                    failureReason:
                        'أُعيد تحليل لا يطابق الصورة المطلوبة أو بعدد مناطق غير معقول.',
                    inputs: {
                      'preview_bytes': source.preview.length,
                      'width': source.width,
                      'height': source.height,
                    },
                    results: (value) => {
                      'regions': value.regionCount,
                      'detections': value.detections.length,
                      'unresolved': value.unresolvedRegions.length,
                      'rejected': value.rejectedRegions.length,
                    },
                    checks: (value) => [
                      EvidenceCheck(
                        name: 'asset_matches',
                        passed: value.assetId == asset.id,
                      ),
                      EvidenceCheck(
                        name: 'region_count_valid',
                        passed:
                            value.regionCount >= 0 && value.regionCount <= 100,
                      ),
                    ],
                    failureAction: 'بقيت الصورة الأصلية للمعالجة اليدوية.',
                  );
                }
                _recordAnalysisStages(asset, analysis);
                final stage = stageLog?.forAsset(asset.id, name: asset.name);
                if (stage != null) {
                  final regions = analysis.allRegions;
                  final timed = regions
                      .map((r) => r.recognitionDurationMs)
                      .nonNulls;
                  if (timed.isNotEmpty) {
                    final known = regions
                        .where(
                          (r) =>
                              r.classification.status ==
                              RecognitionStatus.recognized,
                        )
                        .length;
                    stage.record(
                      IntakeStageRecord(
                        stage: JourneyStage.recognition,
                        outcome: known == regions.length
                            ? JourneyOutcome.passed
                            : JourneyOutcome.review,
                        detail:
                            'صُنفت $known من ${regions.length} مناطق تلقائياً.',
                        durationMs: timed.fold<int>(0, (sum, ms) => sum + ms),
                        fields: {
                          'known': known,
                          if (options case final chosen?)
                            'side': chosen.side.name,
                          // Per-document recognition facts: the kind, the
                          // classification status and the value the classifier
                          // emitted for each region, so a reader sees the
                          // measurement rather than only the count.
                          for (var i = 0; i < regions.length; i++)
                            ..._recognitionFields(
                              regions[i],
                              prefix: regions.length == 1 ? '' : 'i${i + 1}_',
                            ),
                        },
                      ),
                    );
                  } else if (options case final chosen?
                      when chosen.assertsKind && regions.isNotEmpty) {
                    stage.skip(
                      JourneyStage.recognition,
                      'استُخدم النوع والوجه المحددان دون قراءة النص أو التصنيف.',
                      fields: {
                        'kind': chosen.kind.name,
                        'side': chosen.side.name,
                      },
                    );
                  }
                }
                return _Analyzed(
                  asset,
                  analysis,
                  source.width,
                  source.height,
                  importIndex,
                );
              },
              budget: analysisBudget,
              name: 'image-analysis',
              cancellation: imageToken,
            ),
          );
        } finally {
          cancellation?.removeListener(cancelImage);
          // Analysis is read-only; terminate cancellable CPU work after a
          // timeout or cancellation. Native calls retain their leases until done.
          imageToken.cancel();
        }
      },
      token: cancellation,
      onProgress: onProgress,
      stage: 'تحليل الصور',
      // `defaultSegment` returns no candidates, so the analysis stage is the
      // only one that can expire here; report it as a resource limit so the
      // user learns the truth (the device was too slow) instead of being told
      // the image was undecodable.
      categorize: (error) => error is StageTimeout
          ? BatchItemFailure(
              category: RecognitionErrorCategory.resourceLimit,
              message:
                  'تجاوز تحليل هذه الصورة المهلة الزمنية على هذا الجهاز؛ '
                  'حُفظ الأصل ويمكن قصّه يدوياً.',
            )
          : BatchItemFailure(
              category: RecognitionErrorCategory.decodeFailure,
              message: userError(error),
            ),
    );
    return _Analysis(pending, outcomes);
  }

  /// Re-runs recognition over source images that are already in the project.
  ///
  /// Explicitly NOT an import: no new source image is added and no source file
  /// is written — the ORIGINAL is only ever read (ADR-003). The fresh analysis
  /// is reconciled with the documents this source already produced by matching
  /// each region to its existing record through the deterministic detection id
  /// (the segmenter is deterministic, so the same original yields the same
  /// regions and the same ids):
  ///
  /// - a matched record keeps its id, its side id and its layout item; only
  ///   its derived image and evidence are regenerated, so no duplicate item
  ///   and no duplicate placement can appear;
  /// - a record carrying any [UserOverride] is left completely alone and
  ///   reported, because reprocessing must never overwrite a user decision
  ///   (ADR-004);
  /// - a region with no existing record becomes a NEW derived document, so a
  ///   document that the first attempt missed is never lost;
  /// - a source-wide manual item without a matchable detector ID is left alone:
  ///   no region can safely be identified as that item without guessing;
  /// - a missing or unreadable original/derived file is reported per image and
  ///   never aborts the batch.
  ///
  /// Only AUTHORITATIVE SOURCE photos are re-analysed (see [_sourceAssetIds]):
  /// a per-region derived crop is a product of its source, not an independent
  /// photograph, and re-analysing it would re-detect the document inside the
  /// crop and append a duplicate of it.
  ///
  /// Layout: reprocessing is a recognition refresh, not an arrangement. A
  /// document already on the sheet is never moved, resized or re-paginated,
  /// and this does not depend on the automatic-flow setting. Placement of a
  /// genuinely new document is still decided solely by `arrangeDocuments`
  /// (ADR-002), called with `keepPlaced: true` so that only off-sheet
  /// documents are placed and everything already positioned acts as an
  /// obstacle.
  Future<AutomaticLayoutReport> reprocess(
    Project project,
    Iterable<String> assetIds, {
    CancellationToken? cancellation,
    void Function(BatchProgress progress)? onProgress,
  }) async {
    var current = project;
    var cropped = 0;
    var notDetected = 0;
    var needsReview = 0;
    var multiImages = 0;
    final refusedRegions = <RejectedRegion>[];
    final warnings = <String>[];
    final newItems = <DocumentItem>[];
    final newDocuments = <DocumentRecord>[];
    final newAssets = <ImageAsset>[];
    final replacementRecords = <String, DocumentRecord>{};
    final replacementItems = <String, DocumentItem>{};
    final replacedAssets = <String, ImageAsset>{};

    // Conservative reconciliation BEFORE selection. A project written before
    // `ImageAsset.derivedFrom` existed proves the relationship through its
    // document records instead; recording it here means the selection below is
    // authoritative for old projects too, and the provenance survives the next
    // save. Nothing is deleted, nothing is guessed and a project with orphaned
    // or ambiguous assets is still perfectly usable when there is nothing to
    // backfill.
    final reconciliation = reconcileDerivedProvenance(current);
    if (reconciliation.brokenChains.isNotEmpty ||
        reconciliation.ambiguousAssetIds.isNotEmpty) {
      warnings.add(_provenanceWarning(current, reconciliation));
    }
    if (reconciliation.changed) {
      current = await projects.save(reconciliation.project);
    }

    final retryIds = <String>[];
    for (final id in _sourceAssetIds(current, assetIds)) {
      if (_hasUnmatchableSourceItem(current, id)) {
        final source = current.assets.firstWhere((asset) => asset.id == id);
        warnings.add(
          '${source.name}: أُبقي العنصر اليدوي دون تغيير ولم تُعَد معالجة '
          'الصورة لتجنب تكراره. يمكنك إكمال تصنيفه وقصّه يدوياً، أو حذف '
          'العنصر قبل إعادة التعرف؛ تبقى الصورة الأصلية محفوظة.',
        );
      } else {
        retryIds.add(id);
      }
    }
    final analysis = await _analyzeImages(
      current,
      retryIds,
      cancellation: cancellation,
      onProgress: onProgress,
    );

    for (final outcome in analysis.outcomes) {
      final sourceAsset = analysis.pending[outcome.index];
      if (cancellation != null && cancellation.isCancelled) {
        warnings.add('أُلغيت العملية؛ لم تُعالج الصور المتبقية.');
        break;
      }
      if (!outcome.succeeded) {
        notDetected++;
        warnings.add('${sourceAsset.name}: ${outcome.failure!.message}');
        continue;
      }
      final analyzed = outcome.value!;
      // PER-IMAGE STAGING, for the reason given in `run`: a reprocess that
      // fails part-way through one image must not leave that image's derived
      // asset, or a replacement half-applied, in the batch that is committed.
      final imageItems = <DocumentItem>[];
      final imageDocuments = <DocumentRecord>[];
      final imageAssets = <ImageAsset>[];
      final imageReplacementRecords = <String, DocumentRecord>{};
      final imageReplacementItems = <String, DocumentItem>{};
      final imageReplacements = <String, ImageAsset>{};
      var imageCropped = 0;
      var imageNotDetected = 0;
      try {
        current = await _reprocessImage(
          current,
          analyzed,
          newItems: imageItems,
          newDocuments: imageDocuments,
          newAssets: imageAssets,
          replacementRecords: imageReplacementRecords,
          replacementItems: imageReplacementItems,
          replacedAssets: imageReplacements,
          warnings: warnings,
          onCropped: () => imageCropped++,
          onNotDetected: () => imageNotDetected++,
          onRejected: refusedRegions.addAll,
          cancellation: cancellation,
        );
        newItems.addAll(imageItems);
        newDocuments.addAll(imageDocuments);
        newAssets.addAll(imageAssets);
        replacementRecords.addAll(imageReplacementRecords);
        replacementItems.addAll(imageReplacementItems);
        replacedAssets.addAll(imageReplacements);
        cropped += imageCropped;
        notDetected += imageNotDetected;
        // Reported honestly: a re-analysed photo can still hold several
        // documents, and the report must not claim otherwise.
        if (analyzed.analysis.multi) multiImages++;
      } on RevisionConflict {
        rethrow;
      } on OperationCancelled {
        warnings.add('أُلغيت العملية؛ لم تُعالج الصور المتبقية.');
        break;
      } catch (error) {
        warnings.add(
          '${analyzed.asset.name}: تعذرت إعادة المعالجة؛ بقي الأصل محفوظاً '
          '(${userError(error)}).',
        );
      }
    }

    final touched = [...replacementRecords.values, ...newDocuments];
    var recognized = 0;
    for (final record in touched) {
      final kind = record.recognition?.documentKind ?? DocumentKind.unknown;
      if (current.catalog.natural(kind) != null) recognized++;
      if (recordNeedsReview(record, thresholds)) needsReview++;
    }

    if (newItems.isEmpty &&
        newAssets.isEmpty &&
        replacementRecords.isEmpty &&
        replacedAssets.isEmpty) {
      return AutomaticLayoutReport(
        project: current,
        cropped: cropped,
        notDetected: _notDetectedCount(notDetected, [
          ...newDocuments,
          ...replacementRecords.values,
        ]),
        recognized: recognized,
        needsReview: needsReview,
        boundaryNeedsReview: _boundaryReviewCount([
          ...newDocuments,
          ...replacementRecords.values,
        ]),
        multiDocumentImages: multiImages,
        rejectedRegions: refusedRegions.length,
        rejectedByReason: rejectionTally(refusedRegions),
        warnings: warnings,
      );
    }
    // ONE commit boundary: regenerated and newly derived assets are written
    // together with the records and items that reference them.
    current = current.copyWith(
      assets: _mergedAssets(current.assets, newAssets, replacedAssets),
      items: [
        for (final item in current.items) replacementItems[item.id] ?? item,
        ...newItems,
      ],
      documents: [
        for (final record in current.documents)
          replacementRecords[record.id] ?? record,
        ...newDocuments,
      ],
    );
    // Only documents that are not on the sheet yet are arranged, by the one
    // existing engine. Everything the user already placed is an obstacle and
    // never a movable item, so reprocessing can place a newly found document
    // without ever rearranging the sheet — in either automatic-flow mode.
    final arrangement = arrangeDocuments(current, keepPlaced: true);
    current = await projects.save(arrangement.result);
    if (arrangement.unplaced.isNotEmpty) {
      warnings.add(
        '${arrangement.unplaced.length} مستمسك بقي خارج الورقة؛ '
        'راجع الأسباب الفردية التالية. لم يُصغّر أو يُقص أي مستمسك لتلائمه.',
      );
      for (final id in arrangement.unplaced) {
        final item = current.items.firstWhere((entry) => entry.id == id);
        warnings.add(unplacedDocumentMessage(current, item));
      }
    }
    for (final id in arrangement.awaitingSize) {
      final item = current.items.firstWhere((entry) => entry.id == id);
      warnings.add(unplacedDocumentMessage(current, item));
    }
    return AutomaticLayoutReport(
      project: current,
      cropped: cropped,
      notDetected: _notDetectedCount(notDetected, [
        ...newDocuments,
        ...replacementRecords.values,
      ]),
      recognized: recognized,
      needsReview: needsReview,
      boundaryNeedsReview: _boundaryReviewCount([
        ...newDocuments,
        ...replacementRecords.values,
      ]),
      multiDocumentImages: multiImages,
      rejectedRegions: refusedRegions.length,
      rejectedByReason: rejectionTally(refusedRegions),
      warnings: warnings,
    );
  }

  /// A source-wide manual item has no detector identity by which a newly
  /// found region can be matched. This includes both an intake recovery item
  /// and an explicit user item; neither is disposable or safe to duplicate.
  /// A manual classification record deliberately has no fabricated detection,
  /// and a `manual-user` detection ID identifies a user decision, not a region
  /// a detector can reproduce. Derived-region items do not block their source.
  bool _hasUnmatchableSourceItem(Project project, String sourceId) {
    for (final item in project.items) {
      if (item.assetId != sourceId) continue;
      final record = project.documents
          .where((document) => document.id == item.documentId)
          .firstOrNull;
      // _reprocessImage can only match single-sided records belonging to this
      // source. Anything else is equally ambiguous, even if it has an ID.
      if (record == null ||
          record.sourceImageId != sourceId ||
          record.sides.length != 1) {
        return true;
      }
      final detection = record.sides.single.detection;
      if (detection == null || detection.producer == 'manual-user') return true;
    }
    return false;
  }

  /// The requested ids that reprocessing may treat as AUTHORITATIVE SOURCE
  /// photos, in request order and without duplicates.
  ///
  /// A derived asset is one a document points at as its PROCESSED image while
  /// naming a DIFFERENT asset as its source photo — the per-region crop of a
  /// multi-document source. Reprocessing such a crop as though it were an
  /// original photograph runs the segmenter inside an already-rectified card,
  /// finds the document again, and appends a second record for the same
  /// physical document: one photo of two cards becomes four documents.
  ///
  /// Matching is by identity, never by dimensions, aspect ratio or approximate
  /// geometry. An imported photo that produced no document yet is still a
  /// source — retrying it is the whole point of reprocessing.
  List<String> _sourceAssetIds(Project project, Iterable<String> requested) {
    final derived = _derivedAssetIds(project);
    final ids = <String>[];
    final seen = <String>{};
    for (final id in requested) {
      if (derived.contains(id)) continue;
      if (!seen.add(id)) continue;
      ids.add(id);
    }
    return ids;
  }

  /// Every asset of [project] that is DERIVED — a product of another asset —
  /// and must therefore never be re-analysed as an original photograph.
  ///
  /// Two authoritative relationships are consulted, in order of strength:
  ///
  /// 1. [ImageAsset.derivedFrom], recorded when the crop was created. It is
  ///    part of the asset itself, so it survives the loss of the document
  ///    record — which is precisely the failure that used to make a derived
  ///    crop look like an imported photograph.
  /// 2. The document records: an asset a side names as its PROCESSED image
  ///    while a DIFFERENT asset is that record's source. This keeps projects
  ///    and backups written before `derivedFrom` existed classifiable, so no
  ///    migration and no schema bump are needed.
  ///
  /// Matching is by identity only — never by dimensions, aspect ratio,
  /// filename or visual similarity, which cannot distinguish a crop of a card
  /// from a photograph of a card. An asset neither relationship marks as
  /// derived is treated as a source: a genuine imported photo that produced no
  /// document yet is still a source, and retrying it is the whole point of
  /// reprocessing. Ambiguity is therefore resolved in the direction that cannot
  /// invent a relationship, and it is reported rather than guessed.
  Set<String> _derivedAssetIds(Project project) {
    final derived = <String>{
      for (final asset in project.assets)
        if (asset.derivedFrom != null) asset.id,
    };
    for (final record in project.documents) {
      for (final side in record.sides) {
        final processed = side.processedAsset;
        for (final asset in project.assets) {
          if (asset.id == record.sourceImageId) continue;
          if (assetOwnsProjectPath(
                project.id,
                asset.id,
                processed.workingPath,
              ) ||
              assetOwnsProjectPath(
                project.id,
                asset.id,
                processed.thumbnailPath,
              )) {
            derived.add(asset.id);
          }
        }
      }
    }
    return derived;
  }

  bool _hasUserAuthoredCrop(Project project, DocumentRecord record) {
    final processed = record.sides.single.processedAsset;
    return project.assets.any(
      (asset) =>
          asset.userAuthoredCrop &&
          (assetOwnsProjectPath(project.id, asset.id, processed.workingPath) ||
              assetOwnsProjectPath(
                project.id,
                asset.id,
                processed.thumbnailPath,
              )),
    );
  }

  /// The committed asset list: replacements applied in place, newly derived
  /// assets appended in creation order.
  ///
  /// A replacement that names an asset no longer in the list would be a silent
  /// loss, so it is asserted instead: every entry of [replaced] is keyed by an
  /// asset id this project already holds.
  List<ImageAsset> _mergedAssets(
    List<ImageAsset> current,
    List<ImageAsset> added,
    Map<String, ImageAsset> replaced,
  ) {
    final known = {for (final asset in current) asset.id};
    assert(
      replaced.keys.every(known.contains),
      'a replaced asset must already belong to the project',
    );
    return [for (final asset in current) replaced[asset.id] ?? asset, ...added];
  }

  /// One aggregated report for broken or ambiguous source/derived chains.
  ///
  /// Nothing is deleted or guessed: missing-source assets remain derived, and
  /// a path shared by different sources is not assigned to either one.
  String _provenanceWarning(
    Project project,
    DerivedProvenanceReport reconciliation,
  ) {
    final brokenNames = [
      for (final id in reconciliation.brokenChains)
        project.assets.where((asset) => asset.id == id).firstOrNull?.name ?? id,
    ];
    final ambiguousNames = [
      for (final id in reconciliation.ambiguousAssetIds)
        project.assets.where((asset) => asset.id == id).firstOrNull?.name ?? id,
    ];
    return [
      if (brokenNames.isNotEmpty)
        '${brokenNames.length} أصل مشتق يشير إلى صورة مصدر لم تعد موجودة '
            '(${brokenNames.join('، ')})؛ حُفظ كما هو ولم يُعامل كصورة أصلية.',
      if (ambiguousNames.isNotEmpty)
        '${ambiguousNames.length} أصل مشتق مستخدم من أكثر من مصدر '
            '(${ambiguousNames.join('، ')})؛ بقيت علاقته كما هي ولم يُنسب '
            'إلى مصدر بالتخمين.',
    ].join('\n');
  }

  /// Reconciles one re-analysed source image with its existing documents.
  Future<Project> _reprocessImage(
    Project current,
    _Analyzed analyzed, {
    required List<DocumentItem> newItems,
    required List<DocumentRecord> newDocuments,
    required List<ImageAsset> newAssets,
    required Map<String, DocumentRecord> replacementRecords,
    required Map<String, DocumentItem> replacementItems,
    required Map<String, ImageAsset> replacedAssets,
    required List<String> warnings,
    required void Function() onCropped,
    required void Function() onNotDetected,
    required void Function(List<RejectedRegion> rejected) onRejected,
    required CancellationToken? cancellation,
  }) async {
    final sourceAsset = analyzed.asset;
    for (final issue in analyzed.analysis.issues) {
      warnings.add('${sourceAsset.name}: ${issue.message}');
    }
    // One aggregated diagnostic per image for the regions candidate-quality
    // validation refused — the same contract the intake reports under.
    final refused = rejectedRegionsMessage(analyzed.analysis.rejectedRegions);
    if (refused != null) {
      warnings.add('${sourceAsset.name}: $refused');
      onRejected(analyzed.analysis.rejectedRegions);
    }
    // Records of THIS source that a region may still claim. Identity is
    // resolved by WHERE the region was measured first and by the positional
    // detection id only as a fallback.
    //
    // The detection id is `asset-dN`, i.e. the region's POSITION in the list,
    // which is stable only while the list itself is. It is not: a later pass
    // can measure the same cards in another order, or one region fewer. Then
    // `d0` names the other card — so matching on the id would either append a
    // second record for a card the project already holds (one photo of two
    // cards becoming four documents) or refresh card A with card B's image.
    // The measured region rectangle is stored with the record and is a property
    // of the photograph, so it answers "which card is this" apart from any
    // ordering. A record whose region is known is therefore matched on geometry
    // and never on its id; the id is used only for records that predate the
    // stored region.
    final claimable = <DocumentRecord>[
      for (final record in current.documents)
        if (record.sourceImageId == sourceAsset.id &&
            record.sides.length == 1 &&
            record.sides.single.detection != null)
          record,
    ];

    Uint8List? originalBytes;
    try {
      originalBytes = await _readRegionSource(sourceAsset);
      var position = 0;
      for (final detection in analyzed.analysis.allRegions) {
        cancellation?.throwIfCancelled();
        position++;
        final existing = _claimRecord(claimable, detection);
        // A face supplied at intake is not a veto on a later explicit
        // recognition refresh. _rebuildRecord preserves sides and overrides.
        if (existing != null &&
            existing.overrides.any(
              (o) =>
                  !(o.fields.length == 1 &&
                      o.fields.single == IntakeOptions.intakeSideField &&
                      o.side != null),
            )) {
          // Preserve the distinct decision: dismissal is not confirmation, and
          // neither may be silently overwritten or reintroduced as a new item.
          final decisionMessage = isDismissed(existing)
              ? 'مستبعد بقرارك؛ لم يُعَد إدراجه.'
              : existing.overrides.any(
                  (override) => override.fields.contains(reviewConfirmedField),
                )
              ? 'تُرِك كما أكّدته.'
              : 'حُفظ قرار المراجعة السابق.';
          warnings.add(
            '${sourceAsset.name} (مستند $position): $decisionMessage '
            'ألغِ قرارك إذا أردت إعادة التعرف عليه.',
          );
          continue;
        }
        if (existing != null && _hasUserAuthoredCrop(current, existing)) {
          // The rejected detector geometry stays untrusted. The accepted crop
          // belongs to the user and is not replaced by this automatic rerun.
          warnings.add(
            '${sourceAsset.name} (مستند $position): حُفظ القص اليدوي كما هو؛ '
            'لم يُستبدل بنتيجة الكشف التلقائي.',
          );
          continue;
        }
        final output = await _renderAnalyzedRegion(
          originalBytes,
          analyzed,
          current.catalog,
          detection,
          cancellation: cancellation,
        );
        // A native full-resolution crop may finish after the user cancels.
        // Never stage its late pixels into the per-image reprocess buffers.
        cancellation?.throwIfCancelled();
        if (existing == null) {
          current = await _appendNewDocument(
            current,
            analyzed,
            detection,
            output,
            position: position,
            newItems: newItems,
            newDocuments: newDocuments,
            newAssets: newAssets,
            warnings: warnings,
            onCropped: onCropped,
            onNotDetected: onNotDetected,
          );
          continue;
        }
        current = await _refreshDocument(
          current,
          analyzed,
          existing,
          detection,
          output,
          position: position,
          replacementRecords: replacementRecords,
          replacementItems: replacementItems,
          replacedAssets: replacedAssets,
          warnings: warnings,
          onNotDetected: onNotDetected,
        );
      }
    } finally {
      originalBytes = null;
    }
    return current;
  }

  /// Takes the record of this source that [detection] continues, or null when
  /// this region is a document the project does not hold yet.
  ///
  /// Preference order is evidence order:
  /// 1. a record whose MEASURED region covers the same part of the photograph;
  /// 2. a record with the same positional detection id, but only when the
  ///    record carries no measured region to check it against (records from
  ///    the region was persisted).
  ///
  /// A claimed record leaves [claimable], so two regions can never resolve to
  /// one document and one record can never be refreshed twice in a pass.
  DocumentRecord? _claimRecord(
    List<DocumentRecord> claimable,
    DetectionAnalysis detection,
  ) {
    final record = _claimByMeasuredGeometry(claimable, detection);
    if (record != null) return record;
    for (final candidate in claimable) {
      final detectionRef = candidate.sides.single.detection!;
      if (detectionRef.detectionId != detection.detectionId) continue;
      // Its geometry is known and did not match, so this is another document.
      if (_regionFromTrace(detectionRef.detectionTrace) != null) continue;
      claimable.remove(candidate);
      return candidate;
    }
    return null;
  }

  /// Takes the claimable record whose MEASURED boundary covers the same part of
  /// the photograph as [detection], and removes it from [claimable] so that one
  /// record can never be claimed twice.
  ///
  /// The comparison uses the normalized region rectangle the segmenter
  /// measured, which is stored with the record. It is a measurement, not
  /// a guess: re-analysing the same bytes reproduces it, while two different
  /// cards in one photo occupy different rectangles. Two regions are the same
  /// when their intersection covers most of both — deliberately strict, because
  /// pairing the wrong record would refresh one card with another card's image.
  /// When nothing matches closely enough, no record is claimed and the region
  /// is correctly treated as a new document.
  DocumentRecord? _claimByMeasuredGeometry(
    List<DocumentRecord> claimable,
    DetectionAnalysis detection,
  ) {
    final region = detection.region;
    if (region == null || region.length != 4) return null;
    DocumentRecord? best;
    var bestScore = 0.0;
    for (final record in claimable) {
      final known = record.sides.single.detection?.detectionTrace;
      final previous = known == null ? null : _regionFromTrace(known);
      if (previous == null) continue;
      final score = _regionOverlap(previous, region);
      if (score > bestScore) {
        bestScore = score;
        best = record;
      }
    }
    if (best == null || bestScore < _sameRegionOverlap) return null;
    claimable.remove(best);
    return best;
  }

  /// The measured region a record was created from, recovered from its
  /// detection trace, or null when the record predates that trace.
  static List<double>? _regionFromTrace(List<String> trace) {
    for (final entry in trace) {
      if (!entry.startsWith('region=')) continue;
      final parts = entry.substring('region='.length).split(',');
      if (parts.length != 4) return null;
      final values = [for (final part in parts) double.tryParse(part)];
      if (values.any((value) => value == null || !value.isFinite)) return null;
      return [for (final value in values) value!];
    }
    return null;
  }

  /// Intersection over union of two normalized `[left, top, right, bottom]`
  /// rectangles.
  static double _regionOverlap(List<double> a, List<double> b) {
    final left = math.max(a[0], b[0]);
    final top = math.max(a[1], b[1]);
    final right = math.min(a[2], b[2]);
    final bottom = math.min(a[3], b[3]);
    if (right <= left || bottom <= top) return 0;
    final intersection = (right - left) * (bottom - top);
    double area(List<double> r) => math.max(0.0, (r[2] - r[0]) * (r[3] - r[1]));
    final union = area(a) + area(b) - intersection;
    return union <= 0 ? 0.0 : intersection / union;
  }

  /// A region that produced no document yet — for example a first attempt that
  /// failed or missed it — becomes a NEW derived document. The source asset is
  /// never mutated, which is what keeps reprocessing distinct from importing a
  /// new source.
  Future<Project> _appendNewDocument(
    Project current,
    _Analyzed analyzed,
    DetectionAnalysis detection,
    _RegionOutput output, {
    required int position,
    required List<DocumentItem> newItems,
    required List<DocumentRecord> newDocuments,
    required List<ImageAsset> newAssets,
    required List<String> warnings,
    required void Function() onCropped,
    required void Function() onNotDetected,
  }) async {
    final sourceAsset = analyzed.asset;
    final kind = detection.classification.kind;
    // Same commit boundary as the intake path: the crop file is written now and
    // the asset is committed together with the record and item built below, so
    // a failure between the two can never leave a derived asset that nothing in
    // the project accounts for.
    final derived = (await assets.importImage(
      current.id,
      _derivedName(sourceAsset.name, position),
      output.bytes,
    )).asDerivedOf(sourceAsset.id);
    newAssets.add(derived);
    if (output.trustworthy) {
      onCropped();
    } else {
      onNotDetected();
      warnings.add(
        '${sourceAsset.name} (مستند $position): لم تُكتشف حدود موثوقة؛ '
        'حُفظت المنطقة كما هي لتُقصّ يدوياً من المحرر.',
      );
    }
    final catalogSize = _confirmedCatalogSize(
      current,
      detection,
      warped: output.trustworthy,
      landscape: derived.width >= derived.height,
    );
    final sizeReason = _sizeConfirmationWarning(
      current,
      detection,
      warped: output.trustworthy,
    );
    if (sizeReason != null) {
      warnings.add('${sourceAsset.name} (مستند $position): $sizeReason');
    }
    final itemSize =
        catalogSize ??
        provisionalSize(width: derived.width, height: derived.height);
    final itemId = newId();
    final record = _buildRecord(
      current,
      itemId: itemId,
      asset: derived,
      sourceAssetId: sourceAsset.id,
      detection: detection,
      processed: ProcessedAssetRef(
        workingPath: derived.workingPath,
        thumbnailPath: derived.thumbnailPath,
        width: derived.width,
        height: derived.height,
        orientation: 0,
        processingVersion: recognitionPipelineVersion,
        corners: output.corners,
        outputWidth: output.outputWidth,
        outputHeight: output.outputHeight,
      ),
      suggestedPolygon: output.suggestedCorners,
      producer: _producerLabelFor(detection, fallback: 'document-segmenter'),
    );
    newDocuments.add(record);
    newItems.add(
      DocumentItem(
        id: itemId,
        assetId: derived.id,
        x: current.paper.margins.left,
        y: current.paper.margins.top,
        width: itemSize.width,
        height: itemSize.height,
        pageIndex: null,
        zIndex: _nextZ(current, newItems),
        documentKind: kind,
        userSelectedKind: options?.assertsKind ?? false,
        recognitionConfidence:
            detection.classification.confidences.classification?.value ?? 0,
        sizeConfirmed: catalogSize != null,
        documentId: record.id,
        sideId: record.sides.single.id,
        presetSnapshot: PresetSnapshot(
          variantId: current.catalog.natural(kind) != null
              ? builtinVariantId(kind)
              : null,
          widthMm: itemSize.width,
          heightMm: itemSize.height,
          status: presetStatusFor(kind),
        ),
      ),
    );
    if (kind == DocumentKind.unknown) {
      final gap = classificationUnknownReason(
        kind: kind,
        status: detection.classification.status,
        confidences: detection.classification.confidences,
        evidence: detection.classification.evidence,
      );
      warnings.add(
        '${sourceAsset.name} (مستند $position): لم يُتعرّف على النوع'
        '${gap == null ? '' : ' — $gap'}؛ '
        'اختر النوع من تبويب «المستمسك».',
      );
    }
    return current;
  }

  /// Refreshes only the parts of an item that FOLLOW from recognition, and
  /// only when the user has not taken charge of it.
  ///
  /// Placement, page, rotation, grouping and locks are never touched, and a
  /// locked item is left alone entirely — so a retry can improve a document's
  /// evidence without disturbing a layout the user arranged by hand.
  ///
  /// Once an item sits on a page, its width and height are LAYOUT properties:
  /// they are the printed footprint the sheet was arranged around. Changing
  /// them here could resize a placed document into its neighbour or off the
  /// paper, so on a placed item only the recognition metadata (kind and
  /// confidence) is refreshed and a differing catalog size is reported through
  /// [onPlacedSizeKept] for the user to review instead of applied silently.
  /// An item that is not on a sheet yet has no footprint to disturb, so its
  /// size is free to follow the recognition.
  DocumentItem _refreshItem(
    Project current,
    DocumentItem item,
    ImageAsset asset,
    DetectionAnalysis detection, {
    required bool trustworthy,
    required void Function(String message) onPlacedSizeKept,
  }) {
    if (item.locked) return item;
    final kind = detection.classification.kind;
    final catalogSize = _confirmedCatalogSize(
      current,
      detection,
      warped: trustworthy,
      landscape: asset.width >= asset.height,
    );
    final confidence =
        detection.classification.confidences.classification?.value ??
        item.recognitionConfidence;
    if (item.hasUserSelectedKind || item.hasUserConfirmedSize) {
      return item.copyWith(recognitionConfidence: confidence);
    }
    if (item.pageIndex != null) {
      if (catalogSize == null) {
        if (kind != DocumentKind.unknown && kind != item.documentKind) {
          onPlacedSizeKept(
            '${asset.name}: النوع المقترح بلا مقاس كتالوج موثق؛ '
            'بقي النوع والمقاس والموضع الحالي للمراجعة اليدوية.',
          );
        }
        return item.copyWith(recognitionConfidence: confidence);
      }
      if (item.width != catalogSize.width ||
          item.height != catalogSize.height) {
        onPlacedSizeKept(
          '${asset.name}: تغيّر الحجم المتعرّف عليه؛ '
          'بقي المستند بموضعه وحجمه الحالي لتفادي إفساد ترتيب الورقة. '
          'راجعه من تبويب «المستمسك».',
        );
      } else if (_shapeUnconfirmed(current, detection)) {
        onPlacedSizeKept(
          '${asset.name}: ${catalogShapeUnconfirmedMessage()} '
          'بقي المستند بموضعه الحالي.',
        );
      }
      return item.copyWith(
        documentKind: kind,
        recognitionConfidence: confidence,
      );
    }
    if (catalogSize == null) {
      if (kind == DocumentKind.unknown &&
          !_shapeUnconfirmed(current, detection)) {
        return item;
      }
      if (_shapeUnconfirmed(current, detection)) {
        final provisional = provisionalSize(
          width: asset.width,
          height: asset.height,
        );
        return item.copyWith(
          width: provisional.width,
          height: provisional.height,
          documentKind: kind,
          sizeConfirmed: false,
          unplaced: true,
          recognitionConfidence: confidence,
          presetSnapshot: PresetSnapshot(
            variantId: null,
            widthMm: provisional.width,
            heightMm: provisional.height,
            status: PresetStatus.unknown,
          ),
        );
      }
      return item.copyWith(
        documentKind: kind,
        sizeConfirmed: false,
        unplaced: true,
        recognitionConfidence: confidence,
        presetSnapshot: PresetSnapshot(
          variantId: null,
          widthMm: item.width,
          heightMm: item.height,
          status: PresetStatus.unknown,
        ),
      );
    }
    return item.copyWith(
      width: catalogSize.width,
      height: catalogSize.height,
      documentKind: kind,
      sizeConfirmed: true,
      recognitionConfidence: confidence,
      presetSnapshot: PresetSnapshot(
        variantId: builtinVariantId(kind),
        widthMm: catalogSize.width,
        heightMm: catalogSize.height,
        status: presetStatusFor(kind),
      ),
    );
  }

  /// Regenerates the derived image of an EXISTING record in place: the record
  /// id, the side id and the layout item all stay the same, so no duplicate
  /// item can appear and the user's placement survives.
  Future<Project> _refreshDocument(
    Project current,
    _Analyzed analyzed,
    DocumentRecord existing,
    DetectionAnalysis detection,
    _RegionOutput output, {
    required int position,
    required Map<String, DocumentRecord> replacementRecords,
    required Map<String, DocumentItem> replacementItems,
    required Map<String, ImageAsset> replacedAssets,
    required List<String> warnings,
    required void Function() onNotDetected,
  }) async {
    final sourceAsset = analyzed.asset;
    final side = existing.sides.single;
    final target = current.assets
        .where(
          (asset) =>
              assetOwnsProjectPath(
                current.id,
                asset.id,
                side.processedAsset.workingPath,
              ) ||
              assetOwnsProjectPath(
                current.id,
                asset.id,
                side.processedAsset.thumbnailPath,
              ),
        )
        .firstOrNull;
    if (target == null) {
      // The derived file is gone: report it instead of inventing pixels or
      // corrupting the record that points at it.
      warnings.add(
        '${sourceAsset.name} (مستند $position): الأصل المعالج مفقود؛ '
        'أعد بناء النسخ المعالجة أو استورد الصورة من جديد.',
      );
      return current;
    }
    final ImageAsset regenerated;
    if (target.id == sourceAsset.id) {
      // The record points at the source photo itself (single-document intake).
      // Only a trustworthy quadrilateral may refine it, and even then it
      // becomes a NEW revision — the original file is never rewritten.
      if (!output.trustworthy) {
        onNotDetected();
        warnings.add(
          '${sourceAsset.name} (مستند $position): لم تُكتشف حدود موثوقة؛ '
          'بقيت الصورة كما هي.',
        );
        return current;
      }
      regenerated = (await editor.createRevision(
        target,
        output.recipe!,
      )).clearUserAuthoredCrop();
    } else {
      final files = await assets.replaceImage(
        current.id,
        target.id,
        output.bytes,
      );
      regenerated = ImageAsset(
        id: target.id,
        captureId: target.captureId,
        revisionId: files.revision,
        parentRevisionId: target.revisionId,
        revisionHistory: target.historyWithCurrent,
        revisionHistoryComplete: target.revisionHistoryComplete,
        originalWidth: files.originalWidth,
        originalHeight: files.originalHeight,
        // Regenerating the crop keeps its recorded source relationship.
        derivedFrom: target.derivedFrom ?? sourceAsset.id,
        name: target.name,
        originalPath: files.originalPath,
        workingPath: files.workingPath,
        thumbnailPath: files.thumbnailPath,
        width: files.width,
        height: files.height,
        transforms: boundedTransformLog([
          ...target.transforms,
          'reprocessed:${files.revision}',
        ]),
      );
    }
    // Deferred to the reprocess commit boundary: the regenerated asset and the
    // record that points at it are written together, so the project can never
    // hold an asset whose paths no record explains.
    replacedAssets[regenerated.id] = regenerated;
    // Refresh what follows from recognition on the linked layout item, while
    // leaving its position, page and grouping exactly as the user left them.
    for (final itemId in existing.provenance.layoutItemIds) {
      final item = current.items.where((item) => item.id == itemId).firstOrNull;
      if (item == null) continue;
      replacementItems[itemId] = _refreshItem(
        current,
        item,
        regenerated,
        detection,
        trustworthy: output.trustworthy,
        onPlacedSizeKept: warnings.add,
      );
    }
    replacementRecords[existing.id] = _rebuildRecord(
      current,
      existing: existing,
      detection: detection,
      processed: ProcessedAssetRef(
        workingPath: regenerated.workingPath,
        thumbnailPath: regenerated.thumbnailPath,
        width: regenerated.width,
        height: regenerated.height,
        orientation: 0,
        processingVersion: recognitionPipelineVersion,
        corners: output.corners,
        outputWidth: output.outputWidth,
        outputHeight: output.outputHeight,
      ),
      suggestedPolygon: output.suggestedCorners,
      producer: _producerLabelFor(detection, fallback: 'document-segmenter'),
    );
    return current;
  }

  Future<Project> _applyImage(
    Project current,
    _Analyzed analyzed, {
    required List<DocumentItem> newItems,
    required List<DocumentRecord> newDocuments,
    required List<ImageAsset> newAssets,
    required Map<String, ImageAsset> replacedAssets,
    required List<String> warnings,
    required void Function() onCropped,
    required void Function() onNotDetected,
    required void Function() onMulti,
    required void Function(List<RejectedRegion> rejected) onRejected,
    required CancellationToken? cancellation,
    required Map<String, _MeasuredSpan> cropSpans,
    bool allowMultiDocument = true,
  }) async {
    var asset = analyzed.asset;
    final analysis = analyzed.analysis;

    // Surface every analysis issue. An unresolved or geometrically rejected
    // region is an explicit, actionable finding — it must never stay hidden
    // inside the analysis object while the report claims success.
    for (final issue in analysis.issues) {
      warnings.add('${analyzed.asset.name}: ${issue.message}');
    }
    // ONE aggregated diagnostic for every refused region, never one per
    // component: a noisy threshold can refuse dozens.
    final refused = rejectedRegionsMessage(analysis.rejectedRegions);
    if (refused != null) {
      warnings.add('${analyzed.asset.name}: $refused');
      onRejected(analysis.rejectedRegions);
    }

    // A photo holding several measured regions NEVER goes through the
    // single-document path: that path crops the SOURCE to the one quad it
    // found, which would make every other region unrecoverable (ADR-003). So
    // this branch is taken whenever the regions exist, whatever the person
    // asked for. What option 5 governs is narrower and honest: whether the batch
    // REPORTS the photo as multi-document, which is what the counts and the
    // review queue describe. Turning the option off must not destroy data, and
    // it does not.
    if (analysis.needsMultiIntake || asset.hasScaledLargeSource) {
      if (analysis.allRegions.length > 1 && !allowMultiDocument) {
        warnings.add(
          '${asset.name}: احتُوت الصورة ${analysis.allRegions.length} مناطق، '
          'ولم يُطلب اكتشاف المستندات المتعددة؛ حُفظت كل المناطق للمراجعة '
          'بدل قصّ واحدة منها فقط.',
        );
      }
      // A source holding more than one measured region NEVER goes through the
      // single-document path: that path crops the SOURCE asset to the one quad
      // it found, which would make every other region of the photo
      // unrecoverable (ADR-003). Every region is preserved instead — resolved
      // ones as rectified crops, unresolved ones as reviewable region crops.
      // A sampled large JPEG takes this same source-preserving path even for a
      // single trusted region: its native full-density crop is a derived asset,
      // not an edit of the 4 MP working proxy. A single unresolved region also
      // needs this preservation path, but is not counted as multi-document.
      if (analysis.allRegions.length > 1) onMulti();
      return _applyMultiDocument(
        current,
        analyzed,
        analysis.allRegions,
        newItems: newItems,
        newDocuments: newDocuments,
        newAssets: newAssets,
        warnings: warnings,
        onCropped: onCropped,
        onNotDetected: onNotDetected,
        cancellation: cancellation,
        cropSpans: cropSpans,
      );
    }

    // Single-document path: byte-compatible with the legacy intake, plus a
    // recognition record that preserves both measurements and their absence.
    final detection = analysis.detections.first;
    final kind = detection.classification.kind;
    final automaticRecipe = _authorizedWarpRecipe(
      detection,
      sourceWidth: analyzed.sourceWidth,
      sourceHeight: analyzed.sourceHeight,
      adjustments: asset.adjustments,
    );
    if (automaticRecipe != null) {
      // The recipe comes only from an accepted authorization and keeps the
      // measured aspect. A refused or missing authorization cannot reach
      // createRevision.
      late final ImageAsset revisedAsset;
      final cropStartedAt = DateTime.now().toUtc();
      final cropClock = Stopwatch()..start();
      try {
        revisedAsset = await editor.createRevision(asset, automaticRecipe);
      } finally {
        cropSpans[detection.detectionId] = _finishCropSpan(
          cropClock,
          cropStartedAt,
        );
      }
      final updated = revisedAsset.clearUserAuthoredCrop();
      // Deferred to the batch commit: a revision saved on its own, whose
      // document record then failed to be created, leaves the source asset
      // pointing at files nothing explains. The revision files themselves are
      // unreferenced until that commit, which is exactly the state
      // `StorageMaintenance.findOrphans` exists to report.
      replacedAssets[asset.id] = updated;
      asset = updated;
      onCropped();
    } else if (detection.boundary == DetectionBoundary.rejected) {
      onNotDetected();
      // The measured refusal is already in analysis.issues, copied above.
      // Do not also claim that no boundary was found.
    } else {
      onNotDetected();
      warnings.add(
        '${asset.name}: لم تُكتشف حدود واضحة؛ بقيت الصورة كاملة ويمكن ضبط '
        'القص يدوياً.',
      );
    }

    // A catalog slot requires both an independent kind claim and a trustworthy
    // accepted warp whose measured shape validates that slot. A filename,
    // missing boundary or OCR kind alone cannot confirm physical dimensions.
    final catalogSize = _confirmedCatalogSize(
      current,
      detection,
      warped: automaticRecipe != null,
      landscape: asset.width >= asset.height,
    );
    final sizeReason = _sizeConfirmationWarning(
      current,
      detection,
      warped: automaticRecipe != null,
    );
    if (sizeReason != null) warnings.add('${asset.name}: $sizeReason');
    final size =
        catalogSize ??
        provisionalSize(width: asset.width, height: asset.height);
    if (catalogSize == null && kind == DocumentKind.unknown) {
      warnings.add(
        '${asset.name}: لم يُتعرّف على نوع المستمسك؛ اختر النوع من تبويب '
        '«المستمسك» ليُطبَّق مقاسه ويوضع على الورقة.',
      );
    }
    final itemId = newId();
    // Preserve even a no-evidence analysis as an explicit unknown record. The
    // review queue is where a person can dismiss a blank/non-document source or
    // manually recover its crop; absence of a classifier result must not make
    // the whole image disappear from review.
    final record = _buildRecord(
      current,
      itemId: itemId,
      asset: asset,
      sourceAssetId: asset.id,
      detection: detection,
      processed: ProcessedAssetRef(
        workingPath: asset.workingPath,
        thumbnailPath: asset.thumbnailPath,
        width: asset.width,
        height: asset.height,
        orientation: asset.adjustments.quarterTurns,
        processingVersion: recognitionPipelineVersion,
        corners: asset.crop?.corners,
        outputWidth: asset.crop?.outputWidth,
        outputHeight: asset.crop?.outputHeight,
      ),
      suggestedPolygon: asset.crop == null ? detection.suggestedCorners : null,
      producer: _producerLabelFor(
        detection,
        fallback: 'manual-only-no-boundary-proposal',
      ),
    );
    newDocuments.add(record);
    newItems.add(
      DocumentItem(
        id: itemId,
        assetId: asset.id,
        x: current.paper.margins.left,
        y: current.paper.margins.top,
        width: size.width,
        height: size.height,
        pageIndex: null,
        zIndex: _nextZ(current, newItems),
        documentKind: kind,
        userSelectedKind: options?.assertsKind ?? false,
        recognitionConfidence:
            detection.classification.confidences.classification?.value ?? 0,
        sizeConfirmed: catalogSize != null,
        documentId: record.id,
        sideId: record.sides.single.id,
        presetSnapshot: PresetSnapshot(
          variantId: current.catalog.natural(kind) != null
              ? builtinVariantId(kind)
              : null,
          widthMm: size.width,
          heightMm: size.height,
          status: presetStatusFor(kind),
        ),
      ),
    );
    return current;
  }

  Future<Project> _applyMultiDocument(
    Project current,
    _Analyzed analyzed,
    List<DetectionAnalysis> detections, {
    required List<DocumentItem> newItems,
    required List<DocumentRecord> newDocuments,
    required List<ImageAsset> newAssets,
    required List<String> warnings,
    required void Function() onCropped,
    required void Function() onNotDetected,
    required CancellationToken? cancellation,
    required Map<String, _MeasuredSpan> cropSpans,
  }) async {
    final sourceAsset = analyzed.asset;
    Uint8List? originalBytes;
    try {
      originalBytes = await _readRegionSource(sourceAsset);
      var position = 0;
      for (final detection in detections) {
        cancellation?.throwIfCancelled();
        final kind = detection.classification.kind;
        late final _RegionOutput output;
        late final ImageAsset importedDerived;
        final cropStartedAt = DateTime.now().toUtc();
        final cropClock = Stopwatch()..start();
        try {
          output = await _renderAnalyzedRegion(
            originalBytes,
            analyzed,
            current.catalog,
            detection,
            cancellation: cancellation,
          );
          // Drop a result that returned after cancellation before creating even
          // an uncommitted derived asset on disk.
          cancellation?.throwIfCancelled();
          if (!output.trustworthy) {
            onNotDetected();
            warnings.add(
              '${sourceAsset.name} (مستند ${position + 1}): لم تُكتشف حدود '
              'موثوقة لهذه المنطقة؛ حُفظت كما هي لتُقصّ يدوياً من المحرر.',
            );
          }
          // The derived file is written here, but the asset is NOT committed
          // here: it joins [newAssets] and is written to the database in the same
          // save as the record and the layout item below. Committing the asset
          // first is what used to leave a derived crop in the project with no
          // document explaining it whenever a later region failed or the run was
          // cancelled — and a derived crop with no record is indistinguishable
          // from an imported photograph, so the next reprocess re-analysed it and
          // appended a second document for the same physical card.
          importedDerived = await assets.importImage(
            current.id,
            _derivedName(sourceAsset.name, position + 1),
            output.bytes,
          );
        } finally {
          cropSpans[detection.detectionId] = _finishCropSpan(
            cropClock,
            cropStartedAt,
          );
        }
        final derived = importedDerived.asDerivedOf(sourceAsset.id);
        newAssets.add(derived);
        if (output.trustworthy) onCropped();
        // An unresolved region was never rectified, so its size is NOT
        // confirmed. A rectified region whose measured shape misses the
        // catalog tolerance is not confirmed either: the catalog slot would
        // claim a physical size the pixels do not match.
        final catalogSize = _confirmedCatalogSize(
          current,
          detection,
          warped: output.trustworthy,
          landscape: derived.width >= derived.height,
        );
        final sizeReason = _sizeConfirmationWarning(
          current,
          detection,
          warped: output.trustworthy,
        );
        if (sizeReason != null) {
          warnings.add(
            '${sourceAsset.name} (مستند ${position + 1}): $sizeReason',
          );
        }
        final itemSize =
            catalogSize ??
            provisionalSize(width: derived.width, height: derived.height);
        final itemId = newId();
        final record = _buildRecord(
          current,
          itemId: itemId,
          asset: derived,
          sourceAssetId: sourceAsset.id,
          detection: detection,
          processed: ProcessedAssetRef(
            workingPath: derived.workingPath,
            thumbnailPath: derived.thumbnailPath,
            width: derived.width,
            height: derived.height,
            orientation: 0,
            processingVersion: recognitionPipelineVersion,
            corners: output.corners,
            outputWidth: output.outputWidth,
            outputHeight: output.outputHeight,
          ),
          suggestedPolygon: output.suggestedCorners,
          producer: _producerLabelFor(
            detection,
            fallback: 'document-segmenter',
          ),
        );
        newDocuments.add(record);
        newItems.add(
          DocumentItem(
            id: itemId,
            assetId: derived.id,
            x: current.paper.margins.left,
            y: current.paper.margins.top,
            width: itemSize.width,
            height: itemSize.height,
            pageIndex: null,
            zIndex: _nextZ(current, newItems),
            documentKind: kind,
            userSelectedKind: options?.assertsKind ?? false,
            recognitionConfidence:
                detection.classification.confidences.classification?.value ?? 0,
            sizeConfirmed: catalogSize != null,
            documentId: record.id,
            sideId: record.sides.single.id,
            presetSnapshot: PresetSnapshot(
              variantId: current.catalog.natural(kind) != null
                  ? builtinVariantId(kind)
                  : null,
              widthMm: itemSize.width,
              heightMm: itemSize.height,
              status: presetStatusFor(kind),
            ),
          ),
        );
        if (kind == DocumentKind.unknown) {
          warnings.add(
            '${sourceAsset.name} (مستند ${position + 1}): لم يُتعرّف على '
            'النوع؛ اختر النوع من تبويب «المستمسك».',
          );
        }
        position++;
      }
    } finally {
      originalBytes = null;
    }
    return current;
  }

  /// Reads the immutable source for a derived region. A normally sized asset
  /// uses its original directly. A large JPEG was deliberately sampled at
  /// import, but its segmented regions must come from the untouched JPEG rather
  /// than the 4 MP working proxy; [fullResolutionJpegCropper] extracts just the
  /// region under a separate native memory budget.
  Future<Uint8List> _readRegionSource(ImageAsset asset) async =>
      readBoundedImage(
        (await assets.resolve(
          asset.hasScaledLargeSource
              ? asset.originalPath
              : asset.processingInputPath,
        )).openRead(),
      );

  Future<_RegionOutput> _renderAnalyzedRegion(
    Uint8List sourceBytes,
    _Analyzed analyzed,
    DocumentSizeCatalog catalog,
    DetectionAnalysis detection, {
    CancellationToken? cancellation,
  }) async {
    final asset = analyzed.asset;
    final region = detection.region;
    if (!asset.hasScaledLargeSource || region == null) {
      return _renderRegion(sourceBytes, analyzed, catalog, detection);
    }
    require(region.length == 4, 'حدود منطقة JPEG غير صالحة.');
    final left = region[0],
        top = region[1],
        right = region[2],
        bottom = region[3];
    require(
      [left, top, right, bottom].every((value) => value.isFinite) &&
          left >= 0 &&
          top >= 0 &&
          right <= 1 &&
          bottom <= 1 &&
          left < right &&
          top < bottom,
      'حدود منطقة JPEG غير صالحة.',
    );
    final header = inspectImageHeader(sourceBytes);
    require(
      header.encoding == ImageEncoding.jpeg &&
          header.width * header.height <= maxScalableJpegSourcePixels,
      'الأصل الكبير ليس JPEG صالحاً للقص كامل الدقة.',
    );
    // A detector's rectangular region and its trusted fitted quad are separate
    // measurements. Include the latter exactly when it extends a rounded
    // component box, rather than clipping a valid corner or inventing a clamp.
    final activeCorners = detection.hasUsableQuad
        ? detection.corners!
        : detection.suggestedCorners;
    final cropBounds = activeCorners != null
        ? _boundsIncludingCorners(left, top, right, bottom, activeCorners)
        : (left: left, top: top, right: right, bottom: bottom);
    final bytes = await fullResolutionJpegCropper.cropJpegRegion(
      source: sourceBytes,
      sourceWidth: header.width,
      sourceHeight: header.height,
      orientation: header.orientation,
      left: cropBounds.left,
      top: cropBounds.top,
      right: cropBounds.right,
      bottom: cropBounds.bottom,
    );
    cancellation?.throwIfCancelled();
    final croppedHeader = inspectImageHeader(bytes);
    require(
      croppedHeader.encoding == ImageEncoding.png &&
          withinImageBudget(croppedHeader.width, croppedHeader.height),
      'منطقة JPEG كاملة الدقة غير صالحة.',
    );
    if (!detection.hasUsableQuad) {
      final localSuggested = detection.suggestedCorners == null
          ? null
          : _remapSuggestedIntoRegion(
              detection.suggestedCorners!,
              cropBounds.left,
              cropBounds.top,
              cropBounds.right,
              cropBounds.bottom,
            );
      // The native rectangle IS the measured region. Keeping its pixels as-is
      // avoids a second decode/re-encode and never invents a quadrilateral.
      return _RegionOutput(
        bytes: bytes,
        corners: null,
        suggestedCorners: localSuggested,
        outputWidth: null,
        outputHeight: null,
        trustworthy: false,
      );
    }
    // The stored corners are the authorized quadrilateral. The values below are
    // that same quadrilateral rewritten into the extracted buffer — not a new
    // boundary and not a different claim.
    final authorizedCorners = detection.cropAuthorization!.corners;
    require(
      detection.corners?.length == authorizedCorners.length,
      'إعادة تعيين JPEG يجب أن تستخدم زوايا القرار المقبول نفسها.',
    );
    for (var i = 0; i < authorizedCorners.length; i++) {
      require(
        detection.corners![i].x == authorizedCorners[i].x &&
            detection.corners![i].y == authorizedCorners[i].y,
        'إعادة تعيين JPEG يجب أن تستخدم زوايا القرار المقبول نفسها.',
      );
    }
    final spanX = cropBounds.right - cropBounds.left;
    final spanY = cropBounds.bottom - cropBounds.top;
    final localCorners = [
      for (final corner in authorizedCorners)
        Point2(
          (corner.x - cropBounds.left) / spanX,
          (corner.y - cropBounds.top) / spanY,
        ),
    ];
    // The request bounds above include every trusted measured corner. Keep this
    // guard so future coordinate changes cannot silently warp geometry that no
    // longer describes the extracted pixels.
    require(
      localCorners.every(
        (corner) =>
            corner.x >= 0 && corner.x <= 1 && corner.y >= 0 && corner.y <= 1,
      ),
      'زوايا المستمسك خارج المنطقة المقاسة.',
    );
    final recipe = _authorizedWarpRecipe(
      detection,
      sourceWidth: croppedHeader.width,
      sourceHeight: croppedHeader.height,
      adjustments: asset.adjustments,
      coordinateFrameCorners: localCorners,
    );
    if (recipe == null) {
      return _RegionOutput(
        bytes: bytes,
        corners: null,
        outputWidth: null,
        outputHeight: null,
        trustworthy: false,
      );
    }
    return _RegionOutput(
      bytes: await warp(bytes, recipe),
      corners: detection.corners,
      outputWidth: recipe.geometry.outputWidth,
      outputHeight: recipe.geometry.outputHeight,
      trustworthy: true,
      recipe: recipe,
    );
  }

  ({double left, double top, double right, double bottom})
  _boundsIncludingCorners(
    double left,
    double top,
    double right,
    double bottom,
    List<Point2> corners,
  ) {
    require(corners.length == 4, 'زوايا المستمسك غير صالحة.');
    require(
      corners.every(
        (corner) =>
            corner.x.isFinite &&
            corner.y.isFinite &&
            corner.x >= 0 &&
            corner.x <= 1 &&
            corner.y >= 0 &&
            corner.y <= 1,
      ),
      'زوايا المستمسك خارج الصورة.',
    );
    var cropLeft = left;
    var cropTop = top;
    var cropRight = right;
    var cropBottom = bottom;
    for (final corner in corners) {
      if (corner.x < cropLeft) cropLeft = corner.x;
      if (corner.y < cropTop) cropTop = corner.y;
      if (corner.x > cropRight) cropRight = corner.x;
      if (corner.y > cropBottom) cropBottom = corner.y;
    }
    return (left: cropLeft, top: cropTop, right: cropRight, bottom: cropBottom);
  }

  /// Renders one detected region into the bytes of its derived image.
  ///
  /// An accepted boundary is perspective-corrected at its measured aspect.
  /// The catalog millimetre slot is a later placement decision, not a warp
  /// ratio. Anything else is an axis-aligned crop of the measured bounds —
  /// no guessed rectangle, no warp. The original bytes are only ever read
  /// (ADR-003).
  Future<_RegionOutput> _renderRegion(
    Uint8List originalBytes,
    _Analyzed analyzed,
    DocumentSizeCatalog _,
    DetectionAnalysis detection,
  ) async {
    if (!detection.hasUsableQuad) {
      // RECOVERY PATH — no trustworthy quadrilateral for this region. Keep the
      // measured pixels so the document stays in the review workflow and can
      // be finished by hand in the editor; it is never silently discarded.
      final rawReg = detection.region ?? fullFrameRegion;
      final bounds = detection.suggestedCorners != null
          ? _boundsIncludingCorners(
              rawReg[0],
              rawReg[1],
              rawReg[2],
              rawReg[3],
              detection.suggestedCorners!,
            )
          : (
              left: rawReg[0],
              top: rawReg[1],
              right: rawReg[2],
              bottom: rawReg[3],
            );
      final localSuggested = detection.suggestedCorners == null
          ? null
          : _remapSuggestedIntoRegion(
              detection.suggestedCorners!,
              bounds.left,
              bounds.top,
              bounds.right,
              bounds.bottom,
            );
      return _RegionOutput(
        bytes: await cropRegion(originalBytes, [
          bounds.left,
          bounds.top,
          bounds.right,
          bounds.bottom,
        ]),
        corners: null,
        suggestedCorners: localSuggested,
        outputWidth: null,
        outputHeight: null,
        trustworthy: false,
      );
    }
    final recipe = _authorizedWarpRecipe(
      detection,
      sourceWidth: analyzed.sourceWidth,
      sourceHeight: analyzed.sourceHeight,
      adjustments: analyzed.asset.adjustments,
    );
    if (recipe == null) {
      return _RegionOutput(
        bytes: await cropRegion(
          originalBytes,
          detection.region ?? fullFrameRegion,
        ),
        corners: null,
        outputWidth: null,
        outputHeight: null,
        trustworthy: false,
      );
    }
    return _RegionOutput(
      bytes: await warp(originalBytes, recipe),
      corners: detection.corners,
      outputWidth: recipe.geometry.outputWidth,
      outputHeight: recipe.geometry.outputHeight,
      trustworthy: true,
      recipe: recipe,
    );
  }

  /// Catalog millimetres only when an independent kind claim exists, the
  /// boundary was warped, and the measured shape independently validates that
  /// size. Shape validates a preset; it never creates the kind or authorizes a
  /// crop. [shapeTolerance] is unchanged at 0.04.
  PhysicalSizeMm? _confirmedCatalogSize(
    Project current,
    DetectionAnalysis detection, {
    required bool warped,
    required bool landscape,
  }) {
    final classification = detection.classification;
    final knownKind =
        options?.assertsKind == true ||
        qualifiesForAutomaticPlacement(classification, thresholds: thresholds);
    if (!knownKind || !warped || detection.cropAuthorization == null) {
      return null;
    }
    return current.catalog.sizeForWarp(
      classification.kind,
      measuredAspect: detection.boundaryDecision?.verification.measuredAspect,
      landscape: landscape,
    );
  }

  bool _catalogShapeMatches(Project current, DetectionAnalysis detection) {
    if (detection.boundaryDecision?.kind != BoundaryDecisionKind.accepted) {
      return false;
    }
    final expected = current.catalog.natural(detection.classification.kind);
    final measured = detection.boundaryDecision?.verification.measuredAspect;
    if (expected == null || measured == null || !measured.isFinite) {
      return false;
    }
    return (measured / expected.aspect - 1).abs() <= shapeTolerance;
  }

  bool _shapeUnconfirmed(Project current, DetectionAnalysis detection) =>
      current.catalog.natural(detection.classification.kind) != null &&
      detection.boundaryDecision?.kind == BoundaryDecisionKind.accepted &&
      !_catalogShapeMatches(current, detection);

  String? _sizeConfirmationWarning(
    Project current,
    DetectionAnalysis detection, {
    required bool warped,
  }) {
    final kind = detection.classification.kind;
    if (kind == DocumentKind.unknown) return null;
    if (current.catalog.natural(kind) == null) {
      return '${kind.label}: لا يوجد مقاس موثق في الكتالوج؛ '
          'أدخل قياس النسخة يدوياً قبل وضعها على A4.';
    }
    if (presetStatusFor(kind) == PresetStatus.estimated) {
      return '${kind.label}: مقاس الكتالوج تقديري وليس قياساً موثقاً؛ '
          'راجعه وأكّده يدوياً قبل وضعه على A4.';
    }
    final classification = detection.classification;
    if (options?.assertsKind != true &&
        !qualifiesForAutomaticPlacement(
          classification,
          thresholds: thresholds,
        )) {
      final typeScore = classification.confidences.classification?.value;
      return '${kind.label}: لا يكفي دليل التصنيف للإضافة التلقائية '
          '(حد التصنيف ${(thresholds.classificationAcceptance * 100).round()}٪؛ '
          'التصنيف ${typeScore == null ? 'غير متاح' : '${(typeScore * 100).toStringAsFixed(1)}٪'})؛ '
          'اختر التصنيف يدوياً قبل اعتماد المقاس.';
    }
    if (warped && !_catalogShapeMatches(current, detection)) {
      return catalogShapeUnconfirmedMessage();
    }
    return null;
  }

  /// Automatic perspective recipe, or null when the shared decision did not
  /// accept the claim. The output keeps the measured aspect. A catalog size
  /// is never an output ratio, including when [BoundaryDecision.catalogShapeMatches].
  ImageEditRecipe? _authorizedWarpRecipe(
    DetectionAnalysis detection, {
    required int sourceWidth,
    required int sourceHeight,
    required ImageAdjustments adjustments,
    List<Point2>? coordinateFrameCorners,
  }) {
    final authorization = detection.cropAuthorization;
    if (authorization == null) return null;
    return recipeFromAcceptedBoundary(
      authorization,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      adjustments: adjustments,
      coordinateFrameCorners: coordinateFrameCorners,
    );
  }

  Map<String, String> get _modelVersions {
    final boundaryId = editor is BoundaryProposalImageEditor
        ? (editor as BoundaryProposalImageEditor).boundaryModelId
        : null;
    return {
      if (options?.assertsKind != true) ...{
        'classifier': classifierVersion,
        'ocr': ocr.version,
      },
      if (boundaryId != null) 'boundary': boundaryId,
    };
  }

  String _producerLabelFor(
    DetectionAnalysis detection, {
    required String fallback,
  }) {
    if (detection.boundaryDecision?.proposal.producer ==
        BoundaryProducer.learnedModel) {
      final boundaryId = editor is BoundaryProposalImageEditor
          ? (editor as BoundaryProposalImageEditor).boundaryModelId
          : null;
      return boundaryId ?? 'unidentified-boundary-proposal-source';
    }
    return fallback;
  }

  List<Point2> _remapSuggestedIntoRegion(
    List<Point2> corners,
    double left,
    double top,
    double right,
    double bottom,
  ) {
    final spanX = math.max(1e-6, right - left);
    final spanY = math.max(1e-6, bottom - top);
    return [
      for (final c in corners)
        Point2(
          ((c.x - left) / spanX).clamp(0.0, 1.0),
          ((c.y - top) / spanY).clamp(0.0, 1.0),
        ),
    ];
  }

  DocumentRecord _buildRecord(
    Project current, {
    required String itemId,
    required ImageAsset asset,
    required String sourceAssetId,
    required DetectionAnalysis detection,
    required ProcessedAssetRef processed,
    required String producer,
    List<Point2>? suggestedPolygon,
  }) {
    final classification = detection.classification;
    final variantId = _variantFor(current, classification);
    return DocumentRecord(
      id: 'rec-$itemId',
      sourceImageId: sourceAssetId,
      sides: [
        DocumentSide(
          id: 'side-$itemId',
          // Option 1: the person said which side this batch shows. When they
          // did not, the side stays unknown — ONE side, which is what «بدون
          // تحديد يُعتبر وجه واحد» means. It is deliberately NOT front: that
          // would assert a facing nobody stated. The override is recorded the
          // same way a manual choice is, so the review screen treats it as a
          // human decision rather than a detector result.
          side: options?.side ?? SideKind.unknown,
          processedAsset: processed,
          detection: _detectionRef(
            detection,
            producer: producer,
            catalog: current.catalog,
            suggestedPolygon: suggestedPolygon,
          ),
        ),
      ],
      overrides: [if (options case final chosen?) chosen.recordOverride],
      recognition: _recognitionFor(current, classification),
      pairing: PairingState.single,
      provenance: Provenance(
        sourceImageId: sourceAssetId,
        // The measured region travels with the record as its detection id too:
        // this is what survives independently of the region ORDER, so a later
        // pass can recognise the same card in a differently numbered list. It
        // carries numbers only — never a path, a sentence or recognized text.
        detectionIds: [detection.detectionId, _regionKeyOf(detection)],
        processedAssetVersion: recognitionPipelineVersion,
        pipelineVersion: recognitionPipelineVersion,
        modelVersions: _modelVersions,
        presetVariantId: variantId,
        layoutItemIds: [itemId],
      ),
    );
  }

  /// Rebuilds an EXISTING record in place: same id, same side id and the same
  /// layout item, with fresh evidence and a freshly rendered derived asset.
  /// User overrides are left untouched (ADR-004).
  DocumentRecord _rebuildRecord(
    Project current, {
    required DocumentRecord existing,
    required DetectionAnalysis detection,
    required ProcessedAssetRef processed,
    String producer = 'document-segmenter',
    List<Point2>? suggestedPolygon,
  }) {
    final classification = detection.classification;
    final variantId = _variantFor(current, classification);
    return existing.copyWith(
      sides: [
        DocumentSide(
          id: existing.sides.single.id,
          side: existing.sides.single.side,
          processedAsset: processed,
          detection: _detectionRef(
            detection,
            producer: producer,
            catalog: current.catalog,
            suggestedPolygon: suggestedPolygon,
          ),
        ),
      ],
      recognition: _recognitionFor(current, classification),
      provenance: Provenance(
        sourceImageId: existing.provenance.sourceImageId,
        detectionIds: [detection.detectionId, _regionKeyOf(detection)],
        processedAssetVersion: recognitionPipelineVersion,
        pipelineVersion: recognitionPipelineVersion,
        modelVersions: _modelVersions,
        presetVariantId: variantId,
        layoutItemIds: existing.provenance.layoutItemIds,
      ),
    );
  }

  static String _fixed(double value) => value.toStringAsFixed(3);

  /// The stable id of the region a detection was measured from.
  ///
  /// Derived from the region rectangle, i.e. from the photograph, so it names
  /// the same document however the regions are ordered in a later pass. Encoded
  /// in the id alphabet `[a-zA-Z0-9_-]` that `validId` enforces — units of
  /// 1/10000 of the frame: `[.1, .1, .9, .6]` -> `r1000_1000_9000_6000`.
  static String _regionKeyOf(DetectionAnalysis detection) {
    final region = detection.region;
    if (region == null || region.length != 4) return detection.detectionId;
    final parts = [
      for (final value in region) (value * 10000).round().clamp(0, 10000),
    ];
    return 'r${parts.join('_')}';
  }

  DetectionRef _detectionRef(
    DetectionAnalysis detection, {
    required String producer,
    required DocumentSizeCatalog catalog,
    List<Point2>? suggestedPolygon,
  }) {
    final isAi =
        detection.boundaryDecision?.proposal.producer ==
        BoundaryProducer.learnedModel;
    final decision = detection.boundaryDecision;
    final disagreement = decision?.proposal.disagreementFraction;
    final measuredShape = decision?.verification.assessment;
    final aspect = measuredShape?.aspect;
    final area = measuredShape?.areaFraction;
    final geometry = measuredShape?.geometryConfidence;
    final rejection = measuredShape?.rejection;
    final catalogAspect = catalog
        .natural(detection.classification.kind)
        ?.aspect;
    final catalogShapeMatches =
        aspect != null &&
        catalogAspect != null &&
        (aspect / catalogAspect - 1).abs() <= shapeTolerance;
    final traces = decision?.proposal.traces ?? const <BoundaryDetectorTrace>[];
    return DetectionRef(
      boundaryDiagnostics: [
        if (decision != null)
          for (final reason in decision.verification.reasons)
            boundaryReviewReasonMessage(
              reason,
              modelConfidence: decision.proposal.modelConfidence,
              minAutoAcceptConfidence:
                  decision.proposal.minAutoAcceptConfidence ??
                  boundaryAcceptanceThreshold,
            ),
      ],
      // Measured facts, in the order the decision used them: what each model
      // returned, how far apart the two quads were, and the measured shape.
      // Codes and numbers only, so the journey report can explain a refusal
      // without ever storing recognized text or a path.
      detectionTrace: [
        for (final entry in traces) entry.encode(),
        // WHERE the segmenter measured this region, as four normalized numbers.
        // Persisted because it is the only measurement that survives with the
        // record and still identifies the region if a later pass numbers the
        // regions differently: without it a reprocess can only trust the
        // positional id, and then a reordered region list duplicates documents.
        if (detection.region != null && detection.region!.length == 4)
          'region=${detection.region!.map(_fixed).join(',')}',
        if (disagreement != null) 'disagreement=${_fixed(disagreement)}',
        if (decision?.verification.userApproved == true) 'userApproved=true',
        if (aspect != null) 'aspect=${_fixed(aspect)}',
        if (catalogAspect != null) 'catalogAspect=${_fixed(catalogAspect)}',
        if (aspect != null && catalogAspect != null)
          'catalogShape=${catalogShapeMatches ? 'match' : 'mismatch'}',
        if (decision?.verification.corroboration != null)
          'corroboration=${decision!.verification.corroboration!.name}',
        if (area != null) 'area=${_fixed(area)}',
        if (geometry != null) 'geometry=${_fixed(geometry)}',
        if (rejection != null) 'rejection=${rejection.name}',
        // Why the decision asked for review, as fixed codes. The sentences in
        // [boundaryDiagnostics] are written for the person and a report may
        // clip them; these codes are for the audit and never are.
        if (decision != null)
          for (final reason in decision.verification.reasons)
            'review=${reason.name}',
      ],
      detectionId: detection.detectionId,
      producer: producer,
      version: isAi ? producer : recognitionPipelineVersion,
      detectionConfidence: detection.detectionConfidence == null
          ? null
          : Confidence(
              value: detection.detectionConfidence!,
              reason: isAi
                  ? 'learned-boundary-score'
                  : 'segment-region-support',
              producer: producer,
              version: isAi ? producer : segmenterVersion,
            ),
      polygon: detection.corners,
      suggestedPolygon: detection.corners == null ? suggestedPolygon : null,
    );
  }

  String? _variantFor(Project current, ClassificationOutcome classification) =>
      current.catalog.natural(classification.kind) != null
      ? builtinVariantId(classification.kind)
      : null;

  RecognitionResult _recognitionFor(
    Project current,
    ClassificationOutcome classification,
  ) {
    final kind = classification.kind;
    final variantId = _variantFor(current, classification);
    final preset = variantId != null
        ? PresetSelection.resolved(variantId)
        : PresetSelection.awaiting(
            candidates: [
              for (final candidate in classification.candidates)
                if (current.catalog.natural(candidate) != null)
                  builtinVariantId(candidate),
            ],
          );
    return RecognitionResult(
      documentKind: kind,
      status: classification.status,
      confidences: classification.confidences,
      preset: preset,
      evidence: classification.evidence,
      pipelineVersion: recognitionPipelineVersion,
      modelVersions: _modelVersions,
      validated: false,
    );
  }

  void _applyPairing(
    List<DocumentRecord> newDocuments,
    List<DocumentItem> newItems,
    List<LayoutGroup> newGroups, {
    required Map<String, int> sourceImportIndices,
  }) {
    final candidates = <PairCandidate>[];
    for (final record in newDocuments) {
      final recognition = record.recognition;
      final importIndex = sourceImportIndices[record.sourceImageId];
      if (recognition == null ||
          recognition.documentKind == DocumentKind.unknown ||
          record.sides.length != 1 ||
          importIndex == null) {
        continue;
      }
      final processed = record.sides.single.processedAsset;
      final long = math.max(processed.width, processed.height).toDouble();
      final short = math.min(processed.width, processed.height).toDouble();
      candidates.add(
        PairCandidate(
          documentId: record.id,
          kind: recognition.documentKind,
          aspect: short == 0 ? 1 : long / short,
          importIndex: importIndex,
          sourceImageId: record.sourceImageId,
        ),
      );
    }
    final proposals = proposePairs(candidates, thresholds: thresholds);
    for (final proposal in proposals) {
      final first = newDocuments.indexWhere(
        (d) => d.id == proposal.firstDocumentId,
      );
      final second = newDocuments.indexWhere(
        (d) => d.id == proposal.secondDocumentId,
      );
      if (first < 0 || second < 0) continue;
      newDocuments[first] = newDocuments[first].copyWith(
        pairing: proposal.resolution,
        pairedDocumentId: proposal.secondDocumentId,
        pairingConfidence: proposal.confidence,
      );
      newDocuments[second] = newDocuments[second].copyWith(
        pairing: proposal.resolution,
        pairedDocumentId: proposal.firstDocumentId,
        pairingConfidence: proposal.confidence,
      );
      if (proposal.resolution == PairingState.paired) {
        final itemIds = [
          for (final item in newItems)
            if (item.documentId == proposal.firstDocumentId ||
                item.documentId == proposal.secondDocumentId)
              item.id,
        ];
        if (itemIds.length >= 2) {
          final groupId =
              'pair-${proposal.firstDocumentId.compareTo(proposal.secondDocumentId) <= 0 ? proposal.firstDocumentId : proposal.secondDocumentId}';
          newGroups.add(LayoutGroup(id: groupId, itemIds: itemIds));
          for (var i = 0; i < newItems.length; i++) {
            if (itemIds.contains(newItems[i].id)) {
              newItems[i] = newItems[i].copyWith(groupId: groupId);
            }
          }
        }
      }
    }
  }

  DocumentItem _fallbackItem(
    Project current,
    ImageAsset asset,
    List<DocumentItem> newItems,
  ) {
    const kind = DocumentKind.unknown;
    final size = provisionalSize(width: asset.width, height: asset.height);
    return DocumentItem(
      id: newId(),
      assetId: asset.id,
      x: current.paper.margins.left,
      y: current.paper.margins.top,
      width: size.width,
      height: size.height,
      pageIndex: null,
      zIndex: _nextZ(current, newItems),
      documentKind: kind,
      recognitionConfidence: 0,
      sizeConfirmed: false,
    );
  }

  int _nextZ(Project current, List<DocumentItem> newItems) {
    var top = 0;
    for (final item in current.items) {
      top = math.max(top, item.zIndex);
    }
    for (final item in newItems) {
      top = math.max(top, item.zIndex);
    }
    return top + 1;
  }

  String _derivedName(String base, int position) {
    final stem = base.length > 120 ? base.substring(0, 120) : base;
    return '$stem - مستند $position';
  }
}
