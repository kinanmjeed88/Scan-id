/// User-override application (ADR-004). Overrides are recognition-level and
/// explicit: they are APPENDED to [DocumentRecord.overrides] and never mutate
/// the stored recognition evidence. Layout stays with [DocumentEdits] /
/// `PageLayout`; nothing here writes page coordinates.
library;

import 'document_edits.dart';
import 'document_kind.dart';
import 'page_layout.dart';
import 'project.dart';
import 'recognition.dart';
import 'recognition_routing.dart';
import 'validation.dart';

/// The kind the user sees: the latest kind override, else the recognition
/// conclusion, else unknown.
DocumentKind effectiveKind(DocumentRecord record) {
  for (final override in record.overrides.reversed) {
    if (override.documentKind != null) return override.documentKind!;
  }
  return record.recognition?.documentKind ?? DocumentKind.unknown;
}

/// The side the user sees for [side]: the latest side override, else the
/// side's own evidence.
SideKind effectiveSide(DocumentRecord record, DocumentSide side) {
  for (final override in record.overrides.reversed) {
    if (override.side != null) return override.side!;
  }
  return side.side;
}

DocumentRecord _record(Project project, String documentId) =>
    project.documents.firstWhere(
      (d) => d.id == documentId,
      orElse: () =>
          throw const ValidationException('المستند المطلوب غير موجود.'),
    );

Project _replaceRecords(Project project, List<DocumentRecord> updated) {
  final byId = {for (final record in updated) record.id: record};
  return project.copyWith(
    documents: [
      for (final record in project.documents) byId[record.id] ?? record,
    ],
  );
}

/// Sets the category of a layout item through the existing editor rules and,
/// when the item is linked to a recognition record, records the divergence as
/// an explicit [UserOverride]. Re-selecting the already-effective kind
/// appends nothing.
Project setKindWithOverride(Project project, String itemId, DocumentKind kind) {
  final before = PageLayout.item(project, itemId);
  var next = DocumentEdits.setKind(project, itemId, kind);
  final documentId = before.documentId;
  if (documentId == null) return next;
  final record = _record(next, documentId);
  if (effectiveKind(record) == kind) return next;
  final variantId = next.catalog.natural(kind) != null
      ? builtinVariantId(kind)
      : null;
  return _replaceRecords(next, [
    record.copyWith(
      overrides: [
        ...record.overrides,
        UserOverride(
          documentKind: kind,
          presetVariantId: variantId,
          fields: const ['documentKind'],
        ),
      ],
    ),
  ]);
}

/// Confirms a reviewed recognition result without changing it. Idempotent.
Project confirmRecognition(Project project, String documentId) {
  final record = _record(project, documentId);
  if (isUserResolved(record)) return project;
  return _replaceRecords(project, [
    record.copyWith(
      overrides: [
        ...record.overrides,
        UserOverride(fields: const [reviewConfirmedField]),
      ],
    ),
  ]);
}

/// Records the user's front/back choice for a document.
Project setSideOverride(Project project, String documentId, SideKind side) {
  final record = _record(project, documentId);
  return _replaceRecords(project, [
    record.copyWith(
      overrides: [
        ...record.overrides,
        UserOverride(side: side, fields: const ['side']),
      ],
    ),
  ]);
}

/// Deterministic id of the keep-together group realizing a confirmed pair.
String pairGroupId(String documentIdA, String documentIdB) {
  final first = documentIdA.compareTo(documentIdB) <= 0
      ? documentIdA
      : documentIdB;
  return 'pair-$first';
}

/// Confirms that [documentIdA] and [documentIdB] are the two sides of one
/// physical document: links the records reciprocally, records the explicit
/// user decision, and keeps their layout items together in a [LayoutGroup].
Project acceptPair(Project project, String documentIdA, String documentIdB) {
  require(documentIdA != documentIdB, 'لا يمكن اقتران المستند بنفسه.');
  final a = _record(project, documentIdA);
  final b = _record(project, documentIdB);
  for (final record in [a, b]) {
    require(
      record.pairing != PairingState.paired ||
          record.pairedDocumentId == a.id ||
          record.pairedDocumentId == b.id,
      'أحد المستندين مقترن مسبقاً بمستند آخر.',
    );
  }
  final override = UserOverride(
    pairing: PairingState.paired,
    fields: const ['pairing'],
  );
  var next = _replaceRecords(project, [
    a.copyWith(
      pairing: PairingState.paired,
      pairedDocumentId: b.id,
      overrides: [...a.overrides, override],
    ),
    b.copyWith(
      pairing: PairingState.paired,
      pairedDocumentId: a.id,
      overrides: [...b.overrides, override],
    ),
  ]);
  // Keep the two sides together on the sheet. Membership lives on the group;
  // placement itself stays with the deterministic layout engine.
  final itemIds = [
    for (final item in next.items)
      if (item.documentId == a.id || item.documentId == b.id) item.id,
  ];
  if (itemIds.length < 2) return next;
  final groupId = pairGroupId(a.id, b.id);
  final group = LayoutGroup(id: groupId, itemIds: itemIds);
  return next.copyWith(
    layoutGroups: [
      for (final existing in next.layoutGroups)
        if (existing.id != groupId) existing,
      group,
    ],
    items: [
      for (final item in next.items)
        itemIds.contains(item.id) ? item.copyWith(groupId: groupId) : item,
    ],
  );
}

/// Rejects a pairing (proposed or confirmed) for [documentId]: both records
/// return to [PairingState.single] and the explicit rejection is recorded.
Project rejectPair(Project project, String documentId) {
  final record = _record(project, documentId);
  final partnerId = record.pairedDocumentId;
  final override = UserOverride(
    pairing: PairingState.single,
    fields: const ['pairing'],
  );
  final updated = <DocumentRecord>[
    record.copyWith(
      pairing: PairingState.single,
      clearPairing: true,
      overrides: [...record.overrides, override],
    ),
  ];
  if (partnerId != null) {
    final partner = _record(project, partnerId);
    updated.add(
      partner.copyWith(
        pairing: PairingState.single,
        clearPairing: true,
        overrides: [...partner.overrides, override],
      ),
    );
  }
  var next = _replaceRecords(project, updated);
  if (partnerId == null) return next;
  final groupId = pairGroupId(documentId, partnerId);
  return next.copyWith(
    layoutGroups: [
      for (final existing in next.layoutGroups)
        if (existing.id != groupId) existing,
    ],
    items: [
      for (final item in next.items)
        item.groupId == groupId ? _withoutGroup(item) : item,
    ],
  );
}

// copyWith cannot null a field; rebuild the item without its group.
DocumentItem _withoutGroup(DocumentItem item) => DocumentItem(
  id: item.id,
  assetId: item.assetId,
  x: item.x,
  y: item.y,
  width: item.width,
  height: item.height,
  rotation: item.rotation,
  pageIndex: item.pageIndex,
  zIndex: item.zIndex,
  locked: item.locked,
  keepAspectRatio: item.keepAspectRatio,
  documentKind: item.documentKind,
  recognitionConfidence: item.recognitionConfidence,
  sizeConfirmed: item.sizeConfirmed,
  documentId: item.documentId,
  sideId: item.sideId,
  presetSnapshot: item.presetSnapshot,
);

/// The records currently needing user review, in stored order.
List<DocumentRecord> recordsNeedingReview(
  Project project, [
  RecognitionThresholds thresholds = defaultThresholds,
]) => List.unmodifiable([
  for (final record in project.documents)
    if (recordNeedsReview(record, thresholds)) record,
]);
