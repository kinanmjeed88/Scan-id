/// Explicit type/side choices for imports that could not be placed automatically.
/// No recognition evidence is invented; the user's choices are persisted as
/// overrides and a pair is created only after the user chooses its other side.
library;

import 'arrangement.dart';
import 'document_kind.dart';
import 'page_layout.dart';
import 'project.dart';
import 'recognition.dart';
import 'recognition_overrides.dart' as rec;
import 'validation.dart';

Project classifyItemManually(
  Project project, {
  required String itemId,
  required DocumentKind kind,
  required SideKind side,
  required String Function() nextId,
}) {
  require(kind != DocumentKind.unknown, 'اختر تصنيف المستمسك أولاً.');
  var item = PageLayout.item(project, itemId);
  require(!item.locked, 'ألغِ تثبيت المستمسك قبل تصنيفه.');
  var next = project;
  if (item.documentId == null) {
    // The fallback/legacy path may have no recognition record at all. Create
    // an honest manual record, not a fake detection, so the side persists even
    // when the user postpones the crop or closes and reopens the project.
    final asset = project.assets.firstWhere((a) => a.id == item.assetId);
    final recordId = nextId();
    final sideId = nextId();
    final sourceId = asset.derivedFrom ?? asset.id;
    final record = DocumentRecord(
      id: recordId,
      sourceImageId: sourceId,
      sides: [
        DocumentSide(
          id: sideId,
          side: SideKind.unknown,
          processedAsset: ProcessedAssetRef(
            workingPath: asset.workingPath,
            thumbnailPath: asset.thumbnailPath,
            width: asset.width,
            height: asset.height,
            orientation: asset.adjustments.quarterTurns,
            processingVersion: 'manual-classification-1',
            corners: asset.hasApprovedCrop ? asset.crop?.corners : null,
          ),
        ),
      ],
      pairing: PairingState.single,
      provenance: Provenance(
        sourceImageId: sourceId,
        detectionIds: const [],
        processedAssetVersion: 'manual-classification-1',
        pipelineVersion: 'manual-classification-1',
        layoutItemIds: [item.id],
      ),
    );
    item = item.copyWith(documentId: recordId, sideId: sideId);
    next = next.copyWith(
      documents: [...next.documents, record],
      items: [
        for (final existing in next.items)
          if (existing.id == itemId) item else existing,
      ],
    );
  }
  var record = next.documents.firstWhere((d) => d.id == item.documentId);
  require(record.sides.length == 1, 'اختر وجهاً واحداً لتصنيفه.');
  // A changed type or face can no longer truthfully share the old pair.
  // Dissolve it symmetrically, leaving both images and their positions intact;
  // the dialog warns about this before the user confirms the change.
  if (record.pairing == PairingState.paired &&
      (rec.effectiveKind(record) != kind ||
          rec.effectiveSide(record, record.sides.single) != side)) {
    next = rec.rejectPair(next, record.id);
    record = next.documents.firstWhere((entry) => entry.id == record.id);
  }
  next = rec.setKindWithOverride(next, itemId, kind);
  final classified = PageLayout.item(next, itemId);
  final asset = next.assets.firstWhere((a) => a.id == classified.assetId);
  final processed = record.sides.single.processedAsset;
  final polygon = record.sides.single.detection?.polygon;
  // Multi-region intake imports already-warped bytes as a derived asset whose
  // `crop` field is empty. Its record is the authorization: both the accepted
  // detector polygon and the processed crop must exist and refer to the exact
  // revision. Do not confuse a saved suggestedPolygon with an approved warp.
  final verifiedDerivedWarp =
      asset.derivedFrom != null &&
      asset.crop == null &&
      polygon?.length == 4 &&
      processed.corners?.length == 4 &&
      processed.workingPath == asset.workingPath &&
      processed.thumbnailPath == asset.thumbnailPath;
  if (!classified.sizeConfirmed &&
      verifiedDerivedWarp &&
      next.catalog.natural(kind) != null &&
      presetStatusFor(kind) == PresetStatus.standard) {
    final approved = classified.copyWith(
      sizeConfirmed: true,
      presetSnapshot: PresetSnapshot(
        variantId: builtinVariantId(kind),
        widthMm: classified.width,
        heightMm: classified.height,
        status: PresetStatus.user,
      ),
    );
    next = next.copyWith(
      items: [
        for (final existing in next.items)
          if (existing.id == itemId) approved else existing,
      ],
    );
  }
  if (rec.effectiveSide(record, record.sides.single) != side ||
      !record.overrides.any((override) => override.side != null)) {
    next = rec.setSideOverride(next, record.id, side);
  }
  return next;
}

/// Already confirmed, ungrouped opposite sides of the SAME type. No face is
/// paired by filename, order, or type alone; the user selects one explicitly.
List<DocumentItem> matchingManualSidePartners(
  Project project, {
  required String itemId,
  required DocumentKind kind,
  required SideKind side,
}) {
  if (kind == DocumentKind.unknown || side == SideKind.unknown) return const [];
  final target = project.items.where((item) => item.id == itemId).firstOrNull;
  if (target == null || target.locked || target.groupId != null) {
    return const [];
  }
  return [
    for (final item in project.items)
      if (item.id != itemId &&
          item.documentId != null &&
          item.documentId != target.documentId &&
          item.documentKind == kind &&
          item.sizeConfirmed &&
          !item.locked &&
          item.groupId == null &&
          _isUnpairedOppositeSide(project, item, side))
        item,
  ];
}

bool _isUnpairedOppositeSide(
  Project project,
  DocumentItem item,
  SideKind side,
) {
  final record = project.documents
      .where((entry) => entry.id == item.documentId)
      .firstOrNull;
  if (record == null ||
      record.sides.length != 1 ||
      record.pairing == PairingState.paired) {
    return false;
  }
  final other = rec.effectiveSide(record, record.sides.single);
  return (side == SideKind.front && other == SideKind.back) ||
      (side == SideKind.back && other == SideKind.front);
}

/// Link two explicitly selected, confirmed opposite sides and place their group
/// side by side. Unrelated hand-placed/locked items remain fixed. If the pair
/// does not fit, the existing arranger keeps it together and explains why.
Project pairManualSides(Project project, String itemId, String partnerItemId) {
  final item = PageLayout.item(project, itemId);
  final partner = PageLayout.item(project, partnerItemId);
  require(item.sizeConfirmed, 'أكّد القص والمقاس قبل ربط الوجهين.');
  require(item.documentId != null, 'صنّف المستمسك قبل ربط وجهه.');
  final record = project.documents.firstWhere((d) => d.id == item.documentId);
  require(
    record.sides.length == 1 && record.pairing != PairingState.paired,
    'الوجه مرتبط بالفعل أو يحتاج إلى مراجعة الاقتران.',
  );
  final side = rec.effectiveSide(record, record.sides.single);
  require(
    matchingManualSidePartners(
      project,
      itemId: itemId,
      kind: item.documentKind,
      side: side,
    ).any((candidate) => candidate.id == partnerItemId),
    'اختر الوجه الآخر المؤكد لنفس نوع المستمسك.',
  );
  var next = project;
  // Existing *proposals* are not a user decision. If the user explicitly
  // chooses a different partner, detach the old proposals first, symmetrically.
  if (record.pairedDocumentId != null) next = rec.rejectPair(next, record.id);
  final partnerRecord = next.documents.firstWhere(
    (entry) => entry.id == partner.documentId,
  );
  if (partnerRecord.pairedDocumentId != null) {
    next = rec.rejectPair(next, partnerRecord.id);
  }
  next = rec.acceptPair(
    next,
    item.documentId!,
    partner.documentId!,
    arrangement: GroupArrangement.sideBySide,
  );
  // Make BOTH members movable even if the first has already been placed. All
  // other documents keep their current positions, including with autoFlow off.
  next = next.copyWith(
    items: [
      for (final entry in next.items)
        if (entry.id == itemId || entry.id == partnerItemId)
          entry.copyWith(unplaced: true)
        else
          entry,
    ],
  );
  return arrangeDocuments(next, keepPlaced: true).result;
}
