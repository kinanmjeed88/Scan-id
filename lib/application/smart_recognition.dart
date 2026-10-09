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

import '../domain/arrangement.dart';
import '../domain/crop_draft.dart';
import '../domain/document_kind.dart';
import '../domain/geometry.dart';
import '../domain/project.dart';
import '../domain/recognition.dart';
import '../domain/recognition_classifier.dart';
import '../domain/recognition_routing.dart';
import '../domain/side_pairing.dart';
import '../domain/validation.dart';
import '../imaging/document_segmenter.dart';
import '../imaging/perspective.dart';
import '../imaging/region_crop.dart';
import 'cancellation.dart';
import 'contracts.dart';
import 'ids.dart';
import 'image_reader.dart';
import 'ocr_engine.dart';
import 'project_service.dart';
import 'recognition_pipeline.dart';
import 'recognition_worker.dart';

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
  );
  final ImageAsset asset;
  final ImageAnalysis analysis;
  final int sourceWidth;
  final int sourceHeight;
}

/// The bounded analysis of a batch of source images, in input order.
class _Analysis {
  const _Analysis(this.pending, this.outcomes);
  final List<ImageAsset> pending;
  final List<BatchOutcome<_Analyzed>> outcomes;
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
    this.recipe,
  });
  final Uint8List bytes;
  final List<Point2>? corners;
  final int? outputWidth;
  final int? outputHeight;

  /// Whether the region had a trustworthy quadrilateral and was rectified. An
  /// unrectified crop must never claim a confirmed size.
  final bool trustworthy;

  /// The rectifying recipe, present only when [trustworthy].
  final ImageEditRecipe? recipe;
}

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
    this.thresholds = defaultThresholds,
  });

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
  final RecognitionThresholds thresholds;

  Future<AutomaticLayoutReport> run(
    Project project,
    Iterable<String> assetIds, {
    bool keepPlaced = false,
    CancellationToken? cancellation,
    void Function(BatchProgress progress)? onProgress,
  }) async {
    var current = project;
    var cropped = 0;
    var notDetected = 0;
    var recognized = 0;
    var needsReview = 0;
    var multiImages = 0;
    final warnings = <String>[];
    final newItems = <DocumentItem>[];
    final newDocuments = <DocumentRecord>[];
    final newGroups = <LayoutGroup>[];

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
        if (outcome.failure!.category != RecognitionErrorCategory.cancelled) {
          // Fallback: the image still becomes a manual item, exactly like
          // the legacy intake when analysis is impossible.
          newItems.add(_fallbackItem(current, sourceAsset, newItems));
        }
        continue;
      }
      final analyzed = outcome.value!;
      try {
        current = await _applyImage(
          current,
          analyzed,
          newItems: newItems,
          newDocuments: newDocuments,
          warnings: warnings,
          onCropped: () => cropped++,
          onNotDetected: () => notDetected++,
          onMulti: () => multiImages++,
          cancellation: cancellation,
        );
      } on RevisionConflict {
        rethrow;
      } on OperationCancelled {
        warnings.add('أُلغيت العملية؛ لم تُعالج الصور المتبقية.');
        break;
      } catch (error) {
        notDetected++;
        warnings.add(
          '${analyzed.asset.name}: تعذرت المعالجة الذكية؛ بقي الأصل محفوظاً '
          '(${userError(error)}).',
        );
      }
    }

    // Pairing pass over this batch's single-sided recognized documents.
    _applyPairing(newDocuments, newItems, newGroups);

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

    if (newItems.isEmpty) {
      return AutomaticLayoutReport(
        project: current,
        cropped: cropped,
        notDetected: notDetected,
        recognized: recognized,
        needsReview: needsReview,
        multiDocumentImages: multiImages,
        warnings: warnings,
      );
    }
    current = current.copyWith(
      items: [...current.items, ...newItems],
      documents: [...current.documents, ...newDocuments],
      layoutGroups: [...current.layoutGroups, ...newGroups],
    );
    final arrangement = arrangeDocuments(current, keepPlaced: keepPlaced);
    current = await projects.save(arrangement.result);
    if (arrangement.unplaced.isNotEmpty) {
      warnings.add(
        '${arrangement.unplaced.length} مستمسك أكبر من المساحة القابلة للطباعة؛ '
        'صغّر الهوامش أو غيّر اتجاه الورقة.',
      );
    }
    return AutomaticLayoutReport(
      project: current,
      cropped: cropped,
      notDetected: notDetected,
      recognized: recognized,
      needsReview: needsReview,
      multiDocumentImages: multiImages,
      warnings: warnings,
    );
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
    final pipeline = RecognitionPipeline(
      suggestSingle: editor.suggest,
      segment: segment,
      ocr: ocr,
      catalog: project.catalog,
      thresholds: thresholds,
    );
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
        final source = await editor.open(asset);
        final analysis = await pipeline.analyze(
          PipelineImageInput(
            assetId: asset.id,
            name: asset.name,
            previewBytes: source.preview,
            sourceWidth: source.width,
            sourceHeight: source.height,
            importIndex: pending.indexOf(asset),
            captureId: asset.captureId,
          ),
          token: cancellation,
        );
        return _Analyzed(asset, analysis, source.width, source.height);
      },
      token: cancellation,
      onProgress: onProgress,
      stage: 'تحليل الصور',
      categorize: (error) => BatchItemFailure(
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
    final warnings = <String>[];
    final newItems = <DocumentItem>[];
    final newDocuments = <DocumentRecord>[];
    final replacementRecords = <String, DocumentRecord>{};
    final replacementItems = <String, DocumentItem>{};

    final analysis = await _analyzeImages(
      current,
      _sourceAssetIds(current, assetIds),
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
      try {
        current = await _reprocessImage(
          current,
          analyzed,
          newItems: newItems,
          newDocuments: newDocuments,
          replacementRecords: replacementRecords,
          replacementItems: replacementItems,
          warnings: warnings,
          onCropped: () => cropped++,
          onNotDetected: () => notDetected++,
          cancellation: cancellation,
        );
        // Reported honestly: a re-analysed photo can still hold several
        // documents, and the report must not claim otherwise.
        if (analyzed.analysis.needsMultiIntake) multiImages++;
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

    if (newItems.isEmpty && replacementRecords.isEmpty) {
      return AutomaticLayoutReport(
        project: current,
        cropped: cropped,
        notDetected: notDetected,
        recognized: recognized,
        needsReview: needsReview,
        multiDocumentImages: multiImages,
        warnings: warnings,
      );
    }
    current = current.copyWith(
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
        '${arrangement.unplaced.length} مستمسك أكبر من المساحة القابلة للطباعة؛ '
        'صغّر الهوامش أو غيّر اتجاه الورقة.',
      );
    }
    return AutomaticLayoutReport(
      project: current,
      cropped: cropped,
      notDetected: notDetected,
      recognized: recognized,
      needsReview: needsReview,
      multiDocumentImages: multiImages,
      warnings: warnings,
    );
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
    final derived = <String>{};
    for (final record in project.documents) {
      for (final side in record.sides) {
        final processed = side.processedAsset;
        for (final asset in project.assets) {
          if (asset.id == record.sourceImageId) continue;
          if (asset.workingPath == processed.workingPath ||
              asset.thumbnailPath == processed.thumbnailPath) {
            derived.add(asset.id);
          }
        }
      }
    }
    final ids = <String>[];
    final seen = <String>{};
    for (final id in requested) {
      if (derived.contains(id)) continue;
      if (!seen.add(id)) continue;
      ids.add(id);
    }
    return ids;
  }

  /// Reconciles one re-analysed source image with its existing documents.
  Future<Project> _reprocessImage(
    Project current,
    _Analyzed analyzed, {
    required List<DocumentItem> newItems,
    required List<DocumentRecord> newDocuments,
    required Map<String, DocumentRecord> replacementRecords,
    required Map<String, DocumentItem> replacementItems,
    required List<String> warnings,
    required void Function() onCropped,
    required void Function() onNotDetected,
    required CancellationToken? cancellation,
  }) async {
    final sourceAsset = analyzed.asset;
    for (final issue in analyzed.analysis.issues) {
      warnings.add('${sourceAsset.name}: ${issue.message}');
    }
    // Existing records of THIS source, keyed by the deterministic detection
    // id. The segmenter is deterministic, so re-analysing the same original
    // reproduces the same region ids and matching is exact.
    final byDetectionId = <String, DocumentRecord>{};
    for (final record in current.documents) {
      if (record.sourceImageId != sourceAsset.id) continue;
      if (record.sides.length != 1) continue;
      final detection = record.sides.single.detection;
      if (detection == null) continue;
      byDetectionId.putIfAbsent(detection.detectionId, () => record);
    }

    Uint8List? originalBytes;
    try {
      originalBytes = await readBoundedImage(
        (await assets.resolve(sourceAsset.originalPath)).openRead(),
      );
      var position = 0;
      for (final detection in analyzed.analysis.allRegions) {
        cancellation?.throwIfCancelled();
        position++;
        final existing = byDetectionId[detection.detectionId];
        if (existing != null && existing.overrides.isNotEmpty) {
          // ADR-004: the user already decided about this document, so
          // reprocessing reports it instead of overwriting the decision.
          warnings.add(
            '${sourceAsset.name} (مستند $position): تُرِك كما أكّدته؛ '
            'ألغِ تأكيدك إذا أردت إعادة التعرف عليه.',
          );
          continue;
        }
        final output = await _renderRegion(
          originalBytes,
          analyzed,
          current.catalog,
          detection,
        );
        if (existing == null) {
          current = await _appendNewDocument(
            current,
            analyzed,
            detection,
            output,
            position: position,
            newItems: newItems,
            newDocuments: newDocuments,
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
          warnings: warnings,
          onNotDetected: onNotDetected,
        );
      }
    } finally {
      originalBytes = null;
    }
    return current;
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
    required List<String> warnings,
    required void Function() onCropped,
    required void Function() onNotDetected,
  }) async {
    final sourceAsset = analyzed.asset;
    final kind = detection.classification.kind;
    final derived = await assets.importImage(
      current.id,
      _derivedName(sourceAsset.name, position),
      output.bytes,
    );
    current = await projects.save(
      current.copyWith(assets: [...current.assets, derived]),
    );
    if (output.trustworthy) {
      onCropped();
    } else {
      onNotDetected();
      warnings.add(
        '${sourceAsset.name} (مستند $position): لم تُكتشف حدود موثوقة؛ '
        'حُفظت المنطقة كما هي لتُقصّ يدوياً من المحرر.',
      );
    }
    final catalogSize = output.trustworthy
        ? current.catalog.sizeFor(
            kind,
            landscape: derived.width >= derived.height,
          )
        : null;
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
      producer: 'document-segmenter',
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
        recognitionConfidence:
            detection.classification.confidences.finalConfidence?.value ?? 0,
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
        '${sourceAsset.name} (مستند $position): لم يُتعرّف على النوع؛ '
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
    final catalogSize = trustworthy
        ? current.catalog.sizeFor(kind, landscape: asset.width >= asset.height)
        : null;
    final confidence =
        detection.classification.confidences.finalConfidence?.value ??
        item.recognitionConfidence;
    if (item.pageIndex != null) {
      if (catalogSize != null &&
          (item.width != catalogSize.width ||
              item.height != catalogSize.height)) {
        onPlacedSizeKept(
          '${asset.name}: تغيّر الحجم المتعرّف عليه؛ '
          'بقي المستند بموضعه وحجمه الحالي لتفادي إفساد ترتيب الورقة. '
          'راجعه من تبويب «المستمسك».',
        );
      }
      return item.copyWith(
        documentKind: kind,
        recognitionConfidence: confidence,
      );
    }
    if (catalogSize == null) return item;
    return item.copyWith(
      width: catalogSize.width,
      height: catalogSize.height,
      documentKind: kind,
      sizeConfirmed: true,
      recognitionConfidence: confidence,
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
    required List<String> warnings,
    required void Function() onNotDetected,
  }) async {
    final sourceAsset = analyzed.asset;
    final side = existing.sides.single;
    final target = current.assets
        .where((asset) => asset.workingPath == side.processedAsset.workingPath)
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
      regenerated = await editor.createRevision(target, output.recipe!);
    } else {
      final files = await assets.replaceImage(
        current.id,
        target.id,
        output.bytes,
      );
      regenerated = ImageAsset(
        id: target.id,
        captureId: target.captureId,
        name: target.name,
        originalPath: files.originalPath,
        workingPath: files.workingPath,
        thumbnailPath: files.thumbnailPath,
        width: files.width,
        height: files.height,
        transforms: [...target.transforms, 'reprocessed:${files.revision}'],
      );
    }
    current = await projects.save(
      current.copyWith(
        assets: [
          for (final asset in current.assets)
            asset.id == regenerated.id ? regenerated : asset,
        ],
      ),
    );
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
    );
    return current;
  }

  Future<Project> _applyImage(
    Project current,
    _Analyzed analyzed, {
    required List<DocumentItem> newItems,
    required List<DocumentRecord> newDocuments,
    required List<String> warnings,
    required void Function() onCropped,
    required void Function() onNotDetected,
    required void Function() onMulti,
    required CancellationToken? cancellation,
  }) async {
    var asset = analyzed.asset;
    final analysis = analyzed.analysis;

    // Surface every analysis issue. An unresolved or geometrically rejected
    // region is an explicit, actionable finding — it must never stay hidden
    // inside the analysis object while the report claims success.
    for (final issue in analysis.issues) {
      warnings.add('${analyzed.asset.name}: ${issue.message}');
    }

    if (analysis.needsMultiIntake) {
      // A source holding more than one measured region NEVER goes through the
      // single-document path: that path crops the SOURCE asset to the one quad
      // it found, which would make every other region of the photo
      // unrecoverable (ADR-003). Every region is preserved instead — resolved
      // ones as rectified crops, unresolved ones as reviewable region crops.
      onMulti();
      return _applyMultiDocument(
        current,
        analyzed,
        analysis.allRegions,
        newItems: newItems,
        newDocuments: newDocuments,
        warnings: warnings,
        onCropped: onCropped,
        onNotDetected: onNotDetected,
        cancellation: cancellation,
      );
    }

    // Single-document path: byte-compatible with the legacy intake, plus a
    // recognition record carrying the measured evidence.
    final detection = analysis.detections.first;
    final kind = detection.classification.kind;
    if (detection.hasUsableQuad) {
      // The exact legacy sequence: estimate the free crop, orient the
      // catalog size to it, then rectify to the catalog aspect ratio.
      final estimate = CropDraft(
        corners: detection.corners!,
        adjustments: asset.adjustments,
      ).toRecipe(analyzed.sourceWidth, analyzed.sourceHeight);
      final size = current.catalog.sizeFor(
        kind,
        landscape:
            estimate.geometry.outputWidth >= estimate.geometry.outputHeight,
      );
      final recipe = size == null
          ? estimate
          : CropDraft(
              corners: detection.corners!,
              adjustments: asset.adjustments,
              aspectRatio: size.width / size.height,
            ).toRecipe(analyzed.sourceWidth, analyzed.sourceHeight);
      final updated = await editor.createRevision(asset, recipe);
      current = await projects.save(
        current.copyWith(
          assets: [
            for (final entry in current.assets)
              entry.id == asset.id ? updated : entry,
          ],
        ),
      );
      asset = updated;
      onCropped();
    } else {
      onNotDetected();
      warnings.add(
        '${asset.name}: لم تُكتشف حدود واضحة؛ بقيت الصورة كاملة ويمكن ضبط '
        'القص يدوياً.',
      );
    }

    final catalogSize = current.catalog.sizeFor(
      kind,
      landscape: asset.width >= asset.height,
    );
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
    final hasEvidence =
        detection.classification.evidence.isNotEmpty || detection.hasUsableQuad;
    final record = hasEvidence
        ? _buildRecord(
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
            producer: 'suggestDocumentCorners',
          )
        : null;
    if (record != null) newDocuments.add(record);
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
        recognitionConfidence:
            detection.classification.confidences.finalConfidence?.value ?? 0,
        sizeConfirmed: catalogSize != null,
        documentId: record?.id,
        sideId: record?.sides.single.id,
        presetSnapshot: record == null
            ? null
            : PresetSnapshot(
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
    required List<String> warnings,
    required void Function() onCropped,
    required void Function() onNotDetected,
    required CancellationToken? cancellation,
  }) async {
    final sourceAsset = analyzed.asset;
    Uint8List? originalBytes;
    try {
      originalBytes = await readBoundedImage(
        (await assets.resolve(sourceAsset.originalPath)).openRead(),
      );
      var position = 0;
      for (final detection in detections) {
        cancellation?.throwIfCancelled();
        final kind = detection.classification.kind;
        final output = await _renderRegion(
          originalBytes,
          analyzed,
          current.catalog,
          detection,
        );
        if (!output.trustworthy) {
          onNotDetected();
          warnings.add(
            '${sourceAsset.name} (مستند ${position + 1}): لم تُكتشف حدود '
            'موثوقة لهذه المنطقة؛ حُفظت كما هي لتُقصّ يدوياً من المحرر.',
          );
        }
        final derived = await assets.importImage(
          current.id,
          _derivedName(sourceAsset.name, position + 1),
          output.bytes,
        );
        current = await projects.save(
          current.copyWith(assets: [...current.assets, derived]),
        );
        if (output.trustworthy) onCropped();
        // An unresolved region was never rectified, so its size is NOT
        // confirmed: claiming a catalog size here would distort the print.
        final catalogSize = output.trustworthy
            ? current.catalog.sizeFor(
                kind,
                landscape: derived.width >= derived.height,
              )
            : null;
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
          producer: 'document-segmenter',
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
            recognitionConfidence:
                detection.classification.confidences.finalConfidence?.value ??
                0,
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

  /// Renders one detected region into the bytes of its derived image.
  ///
  /// A trustworthy quadrilateral is rectified to the catalog aspect ratio; an
  /// unresolved region is kept as a plain axis-aligned crop of the measured
  /// bounds — no guessed rectangle, no warp. Either way the ORIGINAL source
  /// bytes are only ever READ (ADR-003).
  Future<_RegionOutput> _renderRegion(
    Uint8List originalBytes,
    _Analyzed analyzed,
    DocumentSizeCatalog catalog,
    DetectionAnalysis detection,
  ) async {
    if (!detection.hasUsableQuad) {
      // RECOVERY PATH — no trustworthy quadrilateral for this region. Keep the
      // measured pixels so the document stays in the review workflow and can
      // be finished by hand in the editor; it is never silently discarded.
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
    final kind = detection.classification.kind;
    final estimate = CropDraft(
      corners: detection.corners!,
      adjustments: analyzed.asset.adjustments,
    ).toRecipe(analyzed.sourceWidth, analyzed.sourceHeight);
    final size = catalog.sizeFor(
      kind,
      landscape:
          estimate.geometry.outputWidth >= estimate.geometry.outputHeight,
    );
    final recipe = size == null
        ? estimate
        : CropDraft(
            corners: detection.corners!,
            adjustments: analyzed.asset.adjustments,
            aspectRatio: size.width / size.height,
          ).toRecipe(analyzed.sourceWidth, analyzed.sourceHeight);
    return _RegionOutput(
      bytes: await warp(originalBytes, recipe),
      corners: detection.corners,
      outputWidth: recipe.geometry.outputWidth,
      outputHeight: recipe.geometry.outputHeight,
      trustworthy: true,
      recipe: recipe,
    );
  }

  DocumentRecord _buildRecord(
    Project current, {
    required String itemId,
    required ImageAsset asset,
    required String sourceAssetId,
    required DetectionAnalysis detection,
    required ProcessedAssetRef processed,
    required String producer,
  }) {
    final classification = detection.classification;
    final variantId = _variantFor(current, classification);
    return DocumentRecord(
      id: 'rec-$itemId',
      sourceImageId: sourceAssetId,
      sides: [
        DocumentSide(
          id: 'side-$itemId',
          side: SideKind.unknown,
          processedAsset: processed,
          detection: _detectionRef(detection, producer: producer),
        ),
      ],
      recognition: _recognitionFor(current, classification),
      pairing: PairingState.single,
      provenance: Provenance(
        sourceImageId: sourceAssetId,
        detectionIds: [detection.detectionId],
        processedAssetVersion: recognitionPipelineVersion,
        pipelineVersion: recognitionPipelineVersion,
        modelVersions: {'ocr': ocr.version},
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
  }) {
    final classification = detection.classification;
    final variantId = _variantFor(current, classification);
    return existing.copyWith(
      sides: [
        DocumentSide(
          id: existing.sides.single.id,
          side: existing.sides.single.side,
          processedAsset: processed,
          detection: _detectionRef(detection, producer: producer),
        ),
      ],
      recognition: _recognitionFor(current, classification),
      provenance: Provenance(
        sourceImageId: existing.provenance.sourceImageId,
        detectionIds: [detection.detectionId],
        processedAssetVersion: recognitionPipelineVersion,
        pipelineVersion: recognitionPipelineVersion,
        modelVersions: {'ocr': ocr.version},
        presetVariantId: variantId,
        layoutItemIds: existing.provenance.layoutItemIds,
      ),
    );
  }

  DetectionRef _detectionRef(
    DetectionAnalysis detection, {
    required String producer,
  }) => DetectionRef(
    detectionId: detection.detectionId,
    producer: producer,
    version: recognitionPipelineVersion,
    detectionConfidence: detection.detectionConfidence == null
        ? null
        : Confidence(
            value: detection.detectionConfidence!,
            reason: 'segment-region-support',
            producer: producer,
            version: segmenterVersion,
          ),
    polygon: detection.corners,
  );

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
        ? PresetSelection.resolved(
            variantId,
            presetConfidence: _aspectFit(classification),
          )
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
      modelVersions: {'ocr': ocr.version},
      validated: false,
    );
  }

  void _applyPairing(
    List<DocumentRecord> newDocuments,
    List<DocumentItem> newItems,
    List<LayoutGroup> newGroups,
  ) {
    final candidates = <PairCandidate>[];
    for (var index = 0; index < newDocuments.length; index++) {
      final record = newDocuments[index];
      final recognition = record.recognition;
      if (recognition == null ||
          recognition.documentKind == DocumentKind.unknown ||
          record.sides.length != 1) {
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
          importIndex: index,
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
    final suggestion = suggestDocumentType(
      name: asset.name,
      width: asset.width,
      height: asset.height,
      catalog: current.catalog,
      fullFrame: true,
    );
    final catalogSize = current.catalog.sizeFor(
      suggestion.kind,
      landscape: asset.width >= asset.height,
    );
    final size =
        catalogSize ??
        provisionalSize(width: asset.width, height: asset.height);
    return DocumentItem(
      id: newId(),
      assetId: asset.id,
      x: current.paper.margins.left,
      y: current.paper.margins.top,
      width: size.width,
      height: size.height,
      pageIndex: null,
      zIndex: _nextZ(current, newItems),
      documentKind: suggestion.kind,
      recognitionConfidence: suggestion.confidence,
      sizeConfirmed: catalogSize != null,
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

  double? _aspectFit(ClassificationOutcome classification) {
    for (final evidence in classification.evidence) {
      if (evidence.kind == 'aspect-match' &&
          evidence.reason == classification.kind.name) {
        return evidence.score;
      }
    }
    return null;
  }
}
