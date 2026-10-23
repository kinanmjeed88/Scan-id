import 'dart:math' as math;

import 'arrangement.dart';
import 'boundary_decision.dart';
import 'crop_draft.dart';
import 'document_edits.dart';
import 'document_kind.dart';
import 'geometry.dart';
import 'image_adjustments.dart';
import 'image_limits.dart';
import 'project.dart';
import 'recognition.dart';
import 'recognition_overrides.dart';
import 'recognition_routing.dart';
import 'validation.dart';

/// Processing/provenance version recorded when a user confirms a manual crop.
const manualCropProcessingVersion = 'manual-crop-1';

/// Minimum pixel length for every side of a user-confirmed manual quad.
///
/// Matches the 4 px minimum edge floor of [assessQuad] while remaining distinct
/// from automatic detector confidence/truncation gates (`verifyBoundary`).
const double minManualEdgePx = 4.0;

/// Minimum pixel area for a user-confirmed manual quad (`4 × 4 px`).
const double minManualAreaPx = 16.0;

/// Minimum normalized quad area fraction of the oriented source frame (`0.2%`).
///
/// Permits small stamps/cards inside wide camera frames while rejecting
/// degenerate zero-area or sliver selections.
const double minManualAreaFraction = 0.002;

/// Why a proposed manual 4-corner boundary or size confirmation was refused.
enum ManualBoundaryRejection {
  wrongPointCount,
  nonFiniteCoordinates,
  invalidSourceDimensions,
  outOfBounds,
  selfIntersectingOrNonConvex,
  tooSmall,
  singularPerspective,
  unconfirmedDocumentSize,
}

/// Result of [validateManualBoundary].
///
/// Strictly separated from [verifyBoundary]: automatic detector gates
/// (confidence thresholds, frame-touch truncation heuristics, aspect-claim
/// refusal) never block an explicit user-confirmed manual boundary, whereas
/// invalid geometry, non-invertible homographies, and unconfirmed print sizes
/// are always refused.
class ManualBoundaryValidation {
  ManualBoundaryValidation._({
    required this.isValid,
    this.rejection,
    this.message,
    this.recipe,
    this.confirmedKind,
    this.confirmedSizeMm,
  });

  factory ManualBoundaryValidation.accepted({
    required ImageEditRecipe recipe,
    DocumentKind? confirmedKind,
    PhysicalSizeMm? confirmedSizeMm,
  }) => ManualBoundaryValidation._(
    isValid: true,
    recipe: recipe,
    confirmedKind: confirmedKind,
    confirmedSizeMm: confirmedSizeMm,
  );

  factory ManualBoundaryValidation.rejected(
    ManualBoundaryRejection rejection,
    String message,
  ) => ManualBoundaryValidation._(
    isValid: false,
    rejection: rejection,
    message: message,
  );

  final bool isValid;
  final ManualBoundaryRejection? rejection;
  final String? message;
  final ImageEditRecipe? recipe;
  final DocumentKind? confirmedKind;
  final PhysicalSizeMm? confirmedSizeMm;

  /// Explicit boundary producer tag (`BoundaryProducer.manual`), never
  /// conflated with `learnedModel`, `wholeFrameDetector`, or `segmenter`.
  BoundaryProducer get producer => BoundaryProducer.manual;
}

/// Validates a manual 4-corner crop in normalized EXIF-oriented source
/// coordinates mapped onto `[sourceWidth] × [sourceHeight]`.
ManualBoundaryValidation validateManualBoundary({
  required List<Point2> corners,
  required int sourceWidth,
  required int sourceHeight,
  ImageAdjustments? adjustments,
  double? aspectRatio,
  DocumentKind? documentKind,
  PhysicalSizeMm? customSizeMm,
  DocumentSizeCatalog catalog = const DocumentSizeCatalog(),
  bool requireConfirmedSize = false,
}) {
  if (corners.length != 4) {
    return ManualBoundaryValidation.rejected(
      ManualBoundaryRejection.wrongPointCount,
      'زوايا القص يجب أن تتكون من أربع نقاط.',
    );
  }
  if (sourceWidth <= 1 ||
      sourceHeight <= 1 ||
      !withinImageBudget(sourceWidth, sourceHeight)) {
    return ManualBoundaryValidation.rejected(
      ManualBoundaryRejection.invalidSourceDimensions,
      'أبعاد الصورة الأصلية غير صالحة للقص اليدوي.',
    );
  }
  for (final p in corners) {
    if (!p.x.isFinite || !p.y.isFinite) {
      return ManualBoundaryValidation.rejected(
        ManualBoundaryRejection.nonFiniteCoordinates,
        'إحداثيات زوايا القص غير صالحة.',
      );
    }
    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) {
      return ManualBoundaryValidation.rejected(
        ManualBoundaryRejection.outOfBounds,
        'زوايا القص خارج حدود الصورة الأصلية.',
      );
    }
  }

  final maxX = (sourceWidth - 1).toDouble();
  final maxY = (sourceHeight - 1).toDouble();
  final px = <Point2>[
    for (final p in corners) Point2(p.x * maxX, p.y * maxY),
  ];
  for (final p in px) {
    if (!p.x.isFinite ||
        !p.y.isFinite ||
        p.x < -1e-9 ||
        p.x > maxX + 1e-9 ||
        p.y < -1e-9 ||
        p.y > maxY + 1e-9) {
      return ManualBoundaryValidation.rejected(
        ManualBoundaryRejection.outOfBounds,
        'زوايا القص خارج حدود البكسلات الفعلية للصورة.',
      );
    }
  }

  if (_segmentsIntersect(px[0], px[1], px[2], px[3]) ||
      _segmentsIntersect(px[1], px[2], px[3], px[0])) {
    return ManualBoundaryValidation.rejected(
      ManualBoundaryRejection.selfIntersectingOrNonConvex,
      'زوايا القص متقاطعة؛ رتّب المقابض الأربع حول المستمسك دون تقاطع.',
    );
  }

  var twiceNormArea = 0.0;
  var twicePixelArea = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = corners[i];
    final b = corners[(i + 1) % 4];
    final c = corners[(i + 2) % 4];
    final crossNorm = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
    final pa = px[i];
    final pb = px[(i + 1) % 4];
    final pc = px[(i + 2) % 4];
    final crossPx = (pb.x - pa.x) * (pc.y - pb.y) - (pb.y - pa.y) * (pc.x - pb.x);
    if (crossNorm <= 1e-6 || crossPx <= 1e-3) {
      return ManualBoundaryValidation.rejected(
        ManualBoundaryRejection.selfIntersectingOrNonConvex,
        'زوايا القص يجب أن تشكّل شكلاً رباعياً محدباً باتجاه عقارب الساعة.',
      );
    }
    twiceNormArea += a.x * b.y - b.x * a.y;
    twicePixelArea += pa.x * pb.y - pb.x * pa.y;
  }

  for (var i = 0; i < 4; i++) {
    final edgeLen = _distance(px[i], px[(i + 1) % 4]);
    if (!edgeLen.isFinite || edgeLen < minManualEdgePx) {
      return ManualBoundaryValidation.rejected(
        ManualBoundaryRejection.tooSmall,
        'أحد أضلاع القص صغير جداً؛ وسّع زوايا القص حول المستمسك.',
      );
    }
  }
  final normArea = 0.5 * twiceNormArea;
  final pixelArea = 0.5 * twicePixelArea;
  if (normArea < minManualAreaFraction || pixelArea < minManualAreaPx) {
    return ManualBoundaryValidation.rejected(
      ManualBoundaryRejection.tooSmall,
      'مساحة زوايا القص صغيرة جداً؛ حدّد المستمسك بالكامل.',
    );
  }

  if (aspectRatio != null && (!aspectRatio.isFinite || aspectRatio <= 0)) {
    return ManualBoundaryValidation.rejected(
      ManualBoundaryRejection.singularPerspective,
      'نسبة أبعاد القص غير صالحة.',
    );
  }

  final ImageEditRecipe recipe;
  try {
    recipe = CropDraft(
      corners: corners,
      adjustments: adjustments,
      aspectRatio: aspectRatio,
    ).toRecipe(sourceWidth, sourceHeight);
  } on ValidationException catch (e) {
    return ManualBoundaryValidation.rejected(
      ManualBoundaryRejection.singularPerspective,
      e.message,
    );
  }

  if (!_hasStableHomography(recipe.geometry.corners)) {
    return ManualBoundaryValidation.rejected(
      ManualBoundaryRejection.singularPerspective,
      'تحويل المنظور لهذه الزوايا غير مستقر؛ عدّل المقابض قليلاً.',
    );
  }

  final effectiveAdjustments = adjustments ?? ImageAdjustments();
  final turned = effectiveAdjustments.quarterTurns.isOdd;
  final effectiveWidthPx = turned
      ? recipe.geometry.outputHeight
      : recipe.geometry.outputWidth;
  final effectiveHeightPx = turned
      ? recipe.geometry.outputWidth
      : recipe.geometry.outputHeight;
  final landscape = effectiveWidthPx >= effectiveHeightPx;

  DocumentKind? resolvedKind = documentKind;
  PhysicalSizeMm? resolvedSize;
  if (requireConfirmedSize ||
      (documentKind != null && documentKind != DocumentKind.unknown)) {
    if (resolvedKind == null || resolvedKind == DocumentKind.unknown) {
      return ManualBoundaryValidation.rejected(
        ManualBoundaryRejection.unconfirmedDocumentSize,
        'اختر نوع المستمسك أو مقاس الطباعة قبل إضافته إلى ورقة A4.',
      );
    }
    final natural = catalog.natural(resolvedKind);
    if (natural != null && customSizeMm == null) {
      resolvedSize = catalog.sizeFor(resolvedKind, landscape: landscape);
    } else if (customSizeMm != null) {
      try {
        validDocumentSize(customSizeMm);
      } on ValidationException catch (e) {
        return ManualBoundaryValidation.rejected(
          ManualBoundaryRejection.unconfirmedDocumentSize,
          e.message,
        );
      }
      resolvedSize = customSizeMm;
    } else {
      return ManualBoundaryValidation.rejected(
        ManualBoundaryRejection.unconfirmedDocumentSize,
        'أدخل عرض المستمسك وارتفاعه بالمليمتر لتأكيد المقاس المخصص.',
      );
    }
  }

  return ManualBoundaryValidation.accepted(
    recipe: recipe,
    confirmedKind: resolvedKind,
    confirmedSizeMm: resolvedSize,
  );
}

/// Validates and throws [ValidationException] when a manual boundary or size
/// confirmation is invalid.
ManualBoundaryValidation requireValidManualBoundary({
  required List<Point2> corners,
  required int sourceWidth,
  required int sourceHeight,
  ImageAdjustments? adjustments,
  double? aspectRatio,
  DocumentKind? documentKind,
  PhysicalSizeMm? customSizeMm,
  DocumentSizeCatalog catalog = const DocumentSizeCatalog(),
  bool requireConfirmedSize = false,
}) {
  final result = validateManualBoundary(
    corners: corners,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
    adjustments: adjustments,
    aspectRatio: aspectRatio,
    documentKind: documentKind,
    customSizeMm: customSizeMm,
    catalog: catalog,
    requireConfirmedSize: requireConfirmedSize,
  );
  if (!result.isValid) {
    throw ValidationException(result.message ?? 'زوايا القص غير صالحة.');
  }
  return result;
}

/// Reverts a cancelled manual crop on [resetAsset], clearing manual boundary
/// confirmation metadata on affected sides only and re-evaluating document
/// review and A4 placement from the remaining evidence without touching
/// `originalPath` or partner sides.
Project revertManualCropOnProject(
  Project project, {
  required ImageAsset resetAsset,
}) {
  final cleanedAsset = resetAsset
      .clearUserAuthoredCrop()
      .withSuggestedCrop(null);
  var next = project.copyWith(
    assets: [
      for (final a in project.assets)
        a.id == cleanedAsset.id ? cleanedAsset : a,
    ],
  );

  if (next.documents.isNotEmpty) {
    var docsChanged = false;
    final updatedRecords = <DocumentRecord>[];
    for (final record in next.documents) {
      if (isDismissalTombstone(record)) {
        updatedRecords.add(record);
        continue;
      }
      final affectedSideIds = <String>{
        for (final side in record.sides)
          if (_sideBelongsToAsset(next, record, side, cleanedAsset)) side.id,
      };
      if (affectedSideIds.isEmpty) {
        updatedRecords.add(record);
        continue;
      }
      docsChanged = true;

      final updatedSides = <DocumentSide>[
        for (final side in record.sides)
          if (affectedSideIds.contains(side.id))
            DocumentSide(
              id: side.id,
              side: side.side,
              processedAsset: ProcessedAssetRef(
                workingPath: cleanedAsset.workingPath,
                thumbnailPath: cleanedAsset.thumbnailPath,
                width: cleanedAsset.width,
                height: cleanedAsset.height,
                orientation: cleanedAsset.adjustments.quarterTurns,
                processingVersion: side.detection != null
                    ? record.provenance.pipelineVersion
                    : null,
              ),
              detection: side.detection,
            )
          else
            side,
      ];

      final anyAffectedNowUnresolved = updatedSides.any(
        (side) =>
            affectedSideIds.contains(side.id) &&
            side.detection != null &&
            side.detection!.polygon == null,
      );
      final unaffectedSideIds = <String>{
        for (final side in updatedSides)
          if (!affectedSideIds.contains(side.id)) side.id,
      };
      final affectedTokens = <String>{
        for (final sideId in affectedSideIds)
          manualBoundaryConfirmedSideField(sideId),
      };
      final unaffectedTokens = <String>{
        for (final sideId in unaffectedSideIds)
          manualBoundaryConfirmedSideField(sideId),
      };
      final anyUnaffectedManualRemains = record.overrides.any(
        (o) => o.fields.any(unaffectedTokens.contains),
      );

      final cleanedOverrides = <UserOverride>[];
      for (final override in record.overrides) {
        final hasAffectedToken = override.fields.any(affectedTokens.contains);
        final hasAnySideToken = override.fields.any(
          (f) => f.startsWith('$manualBoundaryConfirmedField:'),
        );
        final isUnscopedBoundary =
            !hasAnySideToken &&
            (override.fields.contains(manualBoundaryConfirmedField) ||
                override.corners != null);
        final targetsAffected =
            hasAffectedToken ||
            (isUnscopedBoundary && unaffectedSideIds.isEmpty);
        final keepsUnaffectedSide = override.fields.any(
          unaffectedTokens.contains,
        );

        var nextCorners = override.corners;
        var nextKind = override.documentKind;
        var nextVariant = override.presetVariantId;
        final nextFields = <String>[];

        for (final field in override.fields) {
          if (affectedTokens.contains(field)) continue;
          if (field == 'corners' && targetsAffected && !keepsUnaffectedSide) {
            continue;
          }
          if (field == manualBoundaryConfirmedField &&
              targetsAffected &&
              !keepsUnaffectedSide &&
              !anyUnaffectedManualRemains) {
            continue;
          }
          if (field == reviewConfirmedField && anyAffectedNowUnresolved) {
            continue;
          }
          if (field == 'documentKind' &&
              targetsAffected &&
              !keepsUnaffectedSide &&
              anyAffectedNowUnresolved) {
            continue;
          }
          nextFields.add(field);
        }

        if (targetsAffected && !keepsUnaffectedSide) {
          nextCorners = null;
          if (anyAffectedNowUnresolved &&
              override.fields.contains('documentKind')) {
            nextKind = null;
            nextVariant = null;
          }
        }

        final hasPayload =
            nextFields.isNotEmpty ||
            nextKind != null ||
            nextVariant != null ||
            nextCorners != null ||
            override.side != null ||
            override.pairing != null ||
            override.dismissed != null;
        if (hasPayload) {
          cleanedOverrides.add(
            UserOverride(
              documentKind: nextKind,
              presetVariantId: nextVariant,
              corners: nextCorners,
              side: override.side,
              pairing: override.pairing,
              dismissed: override.dismissed,
              fields: nextFields,
            ),
          );
        }
      }

      final survivingFields = <String>{
        for (final o in cleanedOverrides) ...o.fields,
      }.toList();
      String? survivingVariant;
      for (final o in cleanedOverrides.reversed) {
        if (o.presetVariantId != null) {
          survivingVariant = o.presetVariantId;
          break;
        }
      }
      survivingVariant ??= record.recognition?.preset.variantId;

      final updatedProvenance = Provenance(
        sourceImageId: record.provenance.sourceImageId,
        detectionIds: record.provenance.detectionIds,
        processedAssetVersion: record.provenance.pipelineVersion,
        pipelineVersion: record.provenance.pipelineVersion,
        modelVersions: record.provenance.modelVersions,
        presetVariantId: survivingVariant,
        overrideFields: survivingFields,
        layoutItemIds: record.provenance.layoutItemIds,
        importedFrom: record.provenance.importedFrom,
      );

      updatedRecords.add(
        record.copyWith(
          sides: updatedSides,
          overrides: cleanedOverrides,
          provenance: updatedProvenance,
        ),
      );
    }
    if (docsChanged) {
      next = next.copyWith(documents: updatedRecords);
    }
  }

  final refreshedItems = <DocumentItem>[];
  final catalogRefreshIds = <String>[];
  var itemsChanged = false;
  for (final item in next.items) {
    if (item.assetId != cleanedAsset.id || item.locked) {
      refreshedItems.add(item);
      continue;
    }
    final linkedRecord = item.documentId == null
        ? null
        : next.documents.where((d) => d.id == item.documentId).firstOrNull;
    final linkedSide = linkedRecord == null
        ? null
        : (item.sideId != null
              ? linkedRecord.sides.where((s) => s.id == item.sideId).firstOrNull
              : linkedRecord.sides.firstOrNull);
    final boundaryNowUnresolved = linkedRecord != null
        ? (linkedSide != null
              ? sideHasUnresolvedBoundary(linkedRecord, linkedSide)
              : hasUnresolvedBoundary(linkedRecord))
        : item.presetSnapshot != null;

    if (boundaryNowUnresolved) {
      itemsChanged = true;
      final revertedKind = linkedRecord != null
          ? effectiveKind(linkedRecord)
          : DocumentKind.unknown;
      final prov = provisionalSize(
        width: cleanedAsset.width,
        height: cleanedAsset.height,
      );
      refreshedItems.add(
        DocumentItem(
          id: item.id,
          assetId: item.assetId,
          x: next.paper.margins.left,
          y: next.paper.margins.top,
          width: prov.width,
          height: prov.height,
          rotation: 0,
          pageIndex: null,
          zIndex: item.zIndex,
          locked: item.locked,
          keepAspectRatio: item.keepAspectRatio,
          documentKind: revertedKind,
          recognitionConfidence: item.recognitionConfidence,
          sizeConfirmed: false,
          documentId: item.documentId,
          sideId: item.sideId,
          groupId: item.groupId,
        ),
      );
    } else {
      refreshedItems.add(item);
      if (next.catalog.natural(item.documentKind) != null) {
        catalogRefreshIds.add(item.id);
      }
    }
  }

  if (itemsChanged) {
    next = next.copyWith(items: refreshedItems);
  }
  for (final id in catalogRefreshIds) {
    next = DocumentEdits.setKind(
      next,
      id,
      next.items.firstWhere((e) => e.id == id).documentKind,
    );
  }
  if (itemsChanged || catalogRefreshIds.isNotEmpty) {
    next = _relayoutProject(next);
  }
  return next;
}

/// Applies an explicit user-confirmed manual boundary + print size to [project]
/// in one deterministic transition (**Path B**) and arranges confirmed items
/// onto A4 immediately.
Project applyManualConfirmationToProject(
  Project project, {
  required ImageAsset updatedAsset,
  required ImageEditRecipe recipe,
  required DocumentKind documentKind,
  required PhysicalSizeMm sizeMm,
  required String Function() nextId,
  String? targetItemId,
}) {
  require(
    documentKind != DocumentKind.unknown,
    'اختر نوع المستمسك أو مقاساً مخصصاً قبل التأكيد.',
  );
  validDocumentSize(sizeMm);

  final authored = updatedAsset.markUserAuthoredCrop().withSuggestedCrop(null);
  var next = project.copyWith(
    assets: [
      for (final a in project.assets) a.id == authored.id ? authored : a,
    ],
  );

  final targetItems = <DocumentItem>[
    if (targetItemId != null)
      ...next.items.where((i) => i.id == targetItemId && !i.locked)
    else
      ...next.items.where((i) => i.assetId == authored.id && !i.locked),
  ];

  final snapshot = _manualSnapshot(next.catalog, documentKind, sizeMm);

  if (targetItems.isEmpty) {
    final createdItem = DocumentItem(
      id: nextId(),
      assetId: authored.id,
      x: next.paper.margins.left,
      y: next.paper.margins.top,
      width: sizeMm.width,
      height: sizeMm.height,
      pageIndex: null,
      zIndex: _nextZIndex(next.items),
      documentKind: documentKind,
      recognitionConfidence: 0,
      sizeConfirmed: true,
      presetSnapshot: snapshot,
    );
    next = next.copyWith(items: [...next.items, createdItem]);
  } else {
    final targetIds = targetItems.map((e) => e.id).toSet();
    next = next.copyWith(
      items: [
        for (final item in next.items)
          if (targetIds.contains(item.id))
            item.copyWith(
              documentKind: documentKind,
              width: sizeMm.width,
              height: sizeMm.height,
              sizeConfirmed: true,
              presetSnapshot: snapshot,
            )
          else
            item,
      ],
    );
  }

  next = _updateRecordsForAssetCrop(
    next,
    asset: authored,
    recipe: recipe,
    recordManualCornerOverride: true,
    confirmedKind: documentKind,
    targetItemIds: targetItems.map((e) => e.id).toSet(),
  );

  return _relayoutProject(next);
}

/// Appends an independently cropped manual document extracted from [sourceAsset]
/// as a derived asset + auditable manual [DocumentRecord] + confirmed
/// [DocumentItem] (**Path C**) without modifying [sourceAsset], then arranges
/// confirmed items onto A4 without overlap.
Project appendManualDerivedDocumentToProject(
  Project project, {
  required ImageAsset sourceAsset,
  required ImageAsset derivedAsset,
  required ImageEditRecipe recipe,
  required DocumentKind documentKind,
  required PhysicalSizeMm sizeMm,
  required String Function() nextId,
  bool replaceUnconfirmedSourcePlaceholder = true,
}) {
  require(
    project.assets.any((a) => a.id == sourceAsset.id),
    'الصورة الأصلية غير موجودة في المشروع.',
  );
  require(
    derivedAsset.id != sourceAsset.id,
    'المستمسك المستخرج يجب أن يملك معرّف أصل مشتق مستقل.',
  );
  require(
    documentKind != DocumentKind.unknown,
    'اختر نوع المستمسك أو مقاساً مخصصاً قبل استخراجه إلى ورقة A4.',
  );
  validDocumentSize(sizeMm);

  var next = project;
  if (replaceUnconfirmedSourcePlaceholder) {
    final placeholders = next.items
        .where(
          (i) =>
              i.assetId == sourceAsset.id &&
              !i.sizeConfirmed &&
              i.pageIndex == null &&
              !i.locked,
        )
        .toList();
    for (final placeholder in placeholders) {
      if (placeholder.documentId != null) {
        next = dismissRecognition(next, placeholder.documentId!);
      } else {
        final filteredGroups = <LayoutGroup>[
          for (final g in next.layoutGroups)
            if (g.itemIds.where((id) => id != placeholder.id).isNotEmpty)
              LayoutGroup(
                id: g.id,
                itemIds: g.itemIds.where((id) => id != placeholder.id).toList(),
                arrangement: g.arrangement,
                keepTogether: g.keepTogether,
              ),
        ];
        next = next.copyWith(
          items: next.items.where((i) => i.id != placeholder.id).toList(),
          layoutGroups: filteredGroups,
        );
      }
    }
  }

  final taggedDerived = derivedAsset
      .asDerivedOf(sourceAsset.id)
      .markUserAuthoredCrop()
      .withSuggestedCrop(null);

  final detectionId = nextId();
  final sideId = nextId();
  final recordId = nextId();
  final itemId = nextId();
  final variantId = next.catalog.natural(documentKind) != null
      ? builtinVariantId(documentKind)
      : null;
  final overrideFields = <String>[
    'corners',
    manualBoundaryConfirmedField,
    manualBoundaryConfirmedSideField(sideId),
    'documentKind',
    reviewConfirmedField,
  ];

  final side = DocumentSide(
    id: sideId,
    side: SideKind.unknown,
    processedAsset: ProcessedAssetRef(
      workingPath: taggedDerived.workingPath,
      thumbnailPath: taggedDerived.thumbnailPath,
      width: taggedDerived.width,
      height: taggedDerived.height,
      orientation: 0,
      processingVersion: manualCropProcessingVersion,
      corners: recipe.geometry.corners,
      outputWidth: recipe.geometry.outputWidth,
      outputHeight: recipe.geometry.outputHeight,
    ),
    detection: DetectionRef(
      detectionId: detectionId,
      producer: 'manual-user',
      version: manualCropProcessingVersion,
    ),
  );

  final record = DocumentRecord(
    id: recordId,
    sourceImageId: sourceAsset.id,
    sides: [side],
    pairing: PairingState.single,
    overrides: [
      UserOverride(
        documentKind: documentKind,
        presetVariantId: variantId,
        corners: recipe.geometry.corners,
        fields: overrideFields,
      ),
    ],
    provenance: Provenance(
      sourceImageId: sourceAsset.id,
      detectionIds: [detectionId],
      processedAssetVersion: manualCropProcessingVersion,
      pipelineVersion: manualCropProcessingVersion,
      presetVariantId: variantId,
      overrideFields: overrideFields,
      layoutItemIds: [itemId],
    ),
  );

  final snapshot = _manualSnapshot(next.catalog, documentKind, sizeMm);
  final item = DocumentItem(
    id: itemId,
    assetId: taggedDerived.id,
    x: next.paper.margins.left,
    y: next.paper.margins.top,
    width: sizeMm.width,
    height: sizeMm.height,
    pageIndex: null,
    zIndex: _nextZIndex(next.items),
    documentKind: documentKind,
    recognitionConfidence: 0,
    sizeConfirmed: true,
    documentId: record.id,
    sideId: side.id,
    presetSnapshot: snapshot,
  );

  next = next.copyWith(
    assets: [...next.assets, taggedDerived],
    documents: [...next.documents, record],
    items: [...next.items, item],
  );
  return _relayoutProject(next);
}

PresetSnapshot _manualSnapshot(
  DocumentSizeCatalog catalog,
  DocumentKind kind,
  PhysicalSizeMm size,
) {
  final natural = catalog.natural(kind);
  final matchesCatalog =
      natural != null &&
      (((size.width - natural.width).abs() < 1e-6 &&
              (size.height - natural.height).abs() < 1e-6) ||
          ((size.width - natural.height).abs() < 1e-6 &&
              (size.height - natural.width).abs() < 1e-6));
  return PresetSnapshot(
    variantId: matchesCatalog ? builtinVariantId(kind) : null,
    widthMm: size.width,
    heightMm: size.height,
    status: matchesCatalog ? presetStatusFor(kind) : PresetStatus.user,
  );
}

Project _relayoutProject(Project project) {
  if (project.layout.autoFlow) {
    return arrangeDocuments(project).result;
  }
  return arrangeDocuments(project, keepPlaced: true).result;
}

bool _sideBelongsToAsset(
  Project project,
  DocumentRecord record,
  DocumentSide side,
  ImageAsset asset, {
  Set<String>? targetItemIds,
}) {
  final ownsPath =
      assetOwnsProjectPath(
        project.id,
        asset.id,
        side.processedAsset.workingPath,
      ) ||
      assetOwnsProjectPath(
        project.id,
        asset.id,
        side.processedAsset.thumbnailPath,
      );
  final linkedByItem = project.items.any(
    (item) =>
        item.documentId == record.id &&
        item.assetId == asset.id &&
        (item.sideId == side.id ||
            (item.sideId == null && record.sides.length == 1)) &&
        (targetItemIds == null ||
            targetItemIds.isEmpty ||
            targetItemIds.contains(item.id)),
  );
  if (targetItemIds != null && targetItemIds.isNotEmpty) {
    return linkedByItem ||
        (ownsPath &&
            !project.items.any(
              (item) =>
                  item.documentId == record.id &&
                  item.sideId == side.id &&
                  !targetItemIds.contains(item.id),
            ));
  }
  return ownsPath || linkedByItem;
}

Project _updateRecordsForAssetCrop(
  Project project, {
  required ImageAsset asset,
  required ImageEditRecipe recipe,
  required bool recordManualCornerOverride,
  DocumentKind? confirmedKind,
  Set<String>? targetItemIds,
}) {
  if (project.documents.isEmpty) return project;

  var changed = false;
  final updatedRecords = <DocumentRecord>[];
  for (final record in project.documents) {
    if (isDismissalTombstone(record)) {
      updatedRecords.add(record);
      continue;
    }
    final matchedSideIds = <String>{
      for (final side in record.sides)
        if (_sideBelongsToAsset(
          project,
          record,
          side,
          asset,
          targetItemIds: targetItemIds,
        ))
          side.id,
    };
    if (matchedSideIds.isEmpty) {
      updatedRecords.add(record);
      continue;
    }

    changed = true;
    final updatedSides = <DocumentSide>[
      for (final side in record.sides)
        if (matchedSideIds.contains(side.id))
          DocumentSide(
            id: side.id,
            side: side.side,
            processedAsset: ProcessedAssetRef(
              workingPath: asset.workingPath,
              thumbnailPath: asset.thumbnailPath,
              width: asset.width,
              height: asset.height,
              orientation: asset.adjustments.quarterTurns,
              processingVersion: manualCropProcessingVersion,
              corners: recipe.geometry.corners,
              outputWidth: recipe.geometry.outputWidth,
              outputHeight: recipe.geometry.outputHeight,
            ),
            // Never alter or fabricate automatic detector output.
            detection: side.detection,
          )
        else
          side,
    ];

    var overrides = record.overrides;
    var provenance = record.provenance;
    if (recordManualCornerOverride) {
      final kindOverride =
          confirmedKind != null &&
              confirmedKind != DocumentKind.unknown &&
              effectiveKind(record) != confirmedKind
          ? confirmedKind
          : null;
      final variantId =
          kindOverride != null && project.catalog.natural(kindOverride) != null
          ? builtinVariantId(kindOverride)
          : null;
      final otherSidesUnresolved = updatedSides.any(
        (side) =>
            !matchedSideIds.contains(side.id) &&
            sideHasUnresolvedBoundary(record, side),
      );
      final addedFields = <String>[
        'corners',
        manualBoundaryConfirmedField,
        for (final sideId in matchedSideIds)
          manualBoundaryConfirmedSideField(sideId),
        if (kindOverride != null) 'documentKind',
        if (confirmedKind != null &&
            confirmedKind != DocumentKind.unknown &&
            !otherSidesUnresolved &&
            record.pairing != PairingState.ambiguous)
          reviewConfirmedField,
      ];
      overrides = [
        ...overrides,
        UserOverride(
          documentKind: kindOverride,
          presetVariantId: variantId,
          corners: recipe.geometry.corners,
          fields: addedFields,
        ),
      ];
      final mergedFields = <String>{
        ...provenance.overrideFields,
        ...addedFields,
      }.toList();
      provenance = Provenance(
        sourceImageId: provenance.sourceImageId,
        detectionIds: provenance.detectionIds,
        processedAssetVersion: manualCropProcessingVersion,
        pipelineVersion: provenance.pipelineVersion,
        modelVersions: provenance.modelVersions,
        presetVariantId: variantId ?? provenance.presetVariantId,
        overrideFields: mergedFields,
        layoutItemIds: provenance.layoutItemIds,
        importedFrom: provenance.importedFrom,
      );
    }

    updatedRecords.add(
      record.copyWith(
        sides: updatedSides,
        overrides: overrides,
        provenance: provenance,
      ),
    );
  }
  return changed ? project.copyWith(documents: updatedRecords) : project;
}

int _nextZIndex(List<DocumentItem> items) =>
    items.isEmpty ? 0 : items.map((e) => e.zIndex).reduce(math.max) + 1;

double _distance(Point2 a, Point2 b) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  return math.sqrt(dx * dx + dy * dy);
}

bool _segmentsIntersect(Point2 p1, Point2 p2, Point2 p3, Point2 p4) {
  double orient(Point2 a, Point2 b, Point2 c) =>
      (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);

  bool onSegment(Point2 a, Point2 b, Point2 p) =>
      p.x >= math.min(a.x, b.x) - 1e-9 &&
      p.x <= math.max(a.x, b.x) + 1e-9 &&
      p.y >= math.min(a.y, b.y) - 1e-9 &&
      p.y <= math.max(a.y, b.y) + 1e-9;

  final d1 = orient(p3, p4, p1);
  final d2 = orient(p3, p4, p2);
  final d3 = orient(p1, p2, p3);
  final d4 = orient(p1, p2, p4);

  if (((d1 > 1e-9 && d2 < -1e-9) || (d1 < -1e-9 && d2 > 1e-9)) &&
      ((d3 > 1e-9 && d4 < -1e-9) || (d3 < -1e-9 && d4 > 1e-9))) {
    return true;
  }
  if (d1.abs() <= 1e-9 && onSegment(p3, p4, p1)) return true;
  if (d2.abs() <= 1e-9 && onSegment(p3, p4, p2)) return true;
  if (d3.abs() <= 1e-9 && onSegment(p1, p2, p3)) return true;
  if (d4.abs() <= 1e-9 && onSegment(p1, p2, p4)) return true;
  return false;
}

bool _hasStableHomography(List<Point2> p) {
  if (p.length != 4) return false;
  final dx1 = p[1].x - p[2].x;
  final dx2 = p[3].x - p[2].x;
  final dx3 = p[0].x - p[1].x + p[2].x - p[3].x;
  final dy1 = p[1].y - p[2].y;
  final dy2 = p[3].y - p[2].y;
  final dy3 = p[0].y - p[1].y + p[2].y - p[3].y;
  double g;
  double h;
  if (dx3.abs() + dy3.abs() < 1e-12) {
    g = 0;
    h = 0;
  } else {
    final determinant = dx1 * dy2 - dx2 * dy1;
    if (!determinant.isFinite || determinant.abs() <= 1e-12) return false;
    g = (dx3 * dy2 - dx2 * dy3) / determinant;
    h = (dx1 * dy3 - dx3 * dy1) / determinant;
  }
  final a = p[1].x - p[0].x + g * p[1].x;
  final b = p[3].x - p[0].x + h * p[3].x;
  final c = p[0].x;
  final d = p[1].y - p[0].y + g * p[1].y;
  final e = p[3].y - p[0].y + h * p[3].y;
  final f = p[0].y;
  return [a, b, c, d, e, f, g, h].every((v) => v.isFinite) &&
      [1.0, 1.0 + g, 1.0 + h, 1.0 + g + h].every((v) => v > 1e-9);
}
