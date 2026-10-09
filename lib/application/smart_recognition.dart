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

    final pipeline = RecognitionPipeline(
      suggestSingle: editor.suggest,
      segment: segment,
      ocr: ocr,
      catalog: current.catalog,
      thresholds: thresholds,
    );

    // The analysis order is the import order; results keep it (worker
    // contract), so batch output is deterministic however lanes finish.
    final pending = <ImageAsset>[];
    for (final id in assetIds.toSet()) {
      final index = current.assets.indexWhere((entry) => entry.id == id);
      require(index >= 0, 'الصورة المراد ترتيبها ليست ضمن المشروع.');
      if (current.items.any((item) => item.assetId == id)) continue;
      pending.add(current.assets[index]);
    }

    // Phase A: bounded analysis. Each lane opens one preview, analyzes it
    // and releases it before the next image (memory stays bounded).
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
        final trustworthy = detection.hasUsableQuad;
        final Uint8List derivedBytes;
        List<Point2>? recordedCorners;
        int? outputWidth;
        int? outputHeight;
        if (trustworthy) {
          final estimate = CropDraft(
            corners: detection.corners!,
            adjustments: sourceAsset.adjustments,
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
                  adjustments: sourceAsset.adjustments,
                  aspectRatio: size.width / size.height,
                ).toRecipe(analyzed.sourceWidth, analyzed.sourceHeight);
          derivedBytes = await warp(originalBytes, recipe);
          recordedCorners = detection.corners;
          outputWidth = recipe.geometry.outputWidth;
          outputHeight = recipe.geometry.outputHeight;
        } else {
          // RECOVERY PATH — this region has no trustworthy quadrilateral.
          // Keep it as a plain axis-aligned crop of the ORIGINAL: no guessed
          // rectangle, no perspective warp, no source mutation (ADR-003). The
          // document stays in the review workflow and the user finishes its
          // boundary by hand in the editor — it is never silently discarded.
          derivedBytes = await cropRegion(
            originalBytes,
            detection.region ?? fullFrameRegion,
          );
          onNotDetected();
          warnings.add(
            '${sourceAsset.name} (مستند ${position + 1}): لم تُكتشف حدود '
            'موثوقة لهذه المنطقة؛ حُفظت كما هي لتُقصّ يدوياً من المحرر.',
          );
        }
        final derived = await assets.importImage(
          current.id,
          _derivedName(sourceAsset.name, position + 1),
          derivedBytes,
        );
        current = await projects.save(
          current.copyWith(assets: [...current.assets, derived]),
        );
        if (trustworthy) onCropped();
        // An unresolved region was never rectified, so its size is NOT
        // confirmed: claiming a catalog size here would distort the print.
        final catalogSize = trustworthy
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
            corners: recordedCorners,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
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
    final kind = classification.kind;
    final variantId = current.catalog.natural(kind) != null
        ? builtinVariantId(kind)
        : null;
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
    return DocumentRecord(
      id: 'rec-$itemId',
      sourceImageId: sourceAssetId,
      sides: [
        DocumentSide(
          id: 'side-$itemId',
          side: SideKind.unknown,
          processedAsset: processed,
          detection: DetectionRef(
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
          ),
        ),
      ],
      recognition: RecognitionResult(
        documentKind: kind,
        status: classification.status,
        confidences: classification.confidences,
        preset: preset,
        evidence: classification.evidence,
        pipelineVersion: recognitionPipelineVersion,
        modelVersions: {'ocr': ocr.version},
        validated: false,
      ),
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
