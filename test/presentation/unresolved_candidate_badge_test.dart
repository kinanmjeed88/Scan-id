import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';

import 'editor_harness.dart';

/// The editor must distinguish three things that all look like "a document
/// outside the sheet":
///
/// - a normal document that merely lacks a category or a confirmed size;
/// - an UNRESOLVED recognition candidate — a region measured in the source
///   photo and kept on purpose, whose outline was never found, so it was never
///   rectified and no rectangle was invented for it;
/// - a manual item the user placed there.
///
/// Without that distinction a background fragment read as a detected identity
/// document. The marker is a badge, not another text line, so the tray's height
/// and its Arabic right-to-left layout are unchanged.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  const badgeKey = Key('offsheet-unresolved-badge');

  testWidgets('an unresolved candidate is marked, an ordinary one is not', (
    tester,
  ) async {
    await EditorHarness.pump(tester, project: _project());

    // The unresolved candidate carries the badge...
    expect(
      find.descendant(
        of: find.byKey(const Key('offsheet-unresolved')),
        matching: find.byKey(badgeKey),
      ),
      findsOneWidget,
    );
    // ...the document recognition DID outline does not, even though it is also
    // off the sheet for the same stated reason.
    expect(
      find.descendant(
        of: find.byKey(const Key('offsheet-outlined')),
        matching: find.byKey(badgeKey),
      ),
      findsNothing,
    );
    // ...and neither does an item with no recognition record at all.
    expect(
      find.descendant(
        of: find.byKey(const Key('offsheet-manual')),
        matching: find.byKey(badgeKey),
      ),
      findsNothing,
    );
    // Exactly one badge in the whole tray.
    expect(find.byKey(badgeKey), findsOneWidget);

    // The badge ADDS information; it never replaces the existing reason, so
    // both off-sheet documents still say why they are out of the arrangement.
    expect(_statusOf(tester, 'unresolved'), 'sizeUnconfirmed');
    expect(_statusOf(tester, 'outlined'), 'sizeUnconfirmed');
    expect(_statusOf(tester, 'manual'), 'sizeUnconfirmed');

    // Placed documents are not off-sheet tiles and carry no badge.
    expect(find.byKey(const Key('offsheet-card')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the marker explains itself in Arabic, right to left', (
    tester,
  ) async {
    await EditorHarness.pump(tester, project: _project());

    final badge = find.byKey(badgeKey);
    expect(badge, findsOneWidget);
    // The app is Arabic RTL, and the badge lives inside that directionality.
    expect(Directionality.of(tester.element(badge)), TextDirection.rtl);

    // The key sits on the Tooltip itself.
    final message = tester.widget<Tooltip>(badge).message!;
    // Arabic, and it says what to DO: the original is preserved and the region
    // can be cropped by hand from the library.
    expect(message, contains('منطقة مستمسك لم يُتأكّد من حدودها'));
    expect(message, contains('الصورة الأصلية محفوظة'));
    expect(message, contains('قصّ'));
    expect(RegExp(r'[A-Za-z]').hasMatch(message), isFalse);
    // It claims no understanding of the document's text or identity: there is
    // no OCR engine in this app, so the wording must not imply one.
    expect(message, isNot(contains('OCR')));
    expect(message, isNot(contains('رقم')));

    // An icon, not a new text line: the tray's layout is unchanged.
    expect(
      find.descendant(of: badge, matching: find.byIcon(Icons.crop_free)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a legacy record with a synthesized polygon is not unresolved', (
    tester,
  ) async {
    // `synthesizeLegacyRecords` always gives a record a detection polygon (the
    // crop corners, or the truthful full-frame box), so upgrading an old
    // project must never start marking its documents as unresolved candidates.
    final legacy = editorProject(
      items: [
        DocumentItem(
          id: 'legacy',
          assetId: 'asset1',
          x: 0,
          y: 0,
          width: 60,
          height: 40,
          pageIndex: null,
          documentKind: DocumentKind.unifiedNationalId,
          recognitionConfidence: .9,
        ),
      ],
    );
    final synthesized = synthesizeLegacyRecords(
      assets: legacy.assets,
      items: legacy.items,
      catalog: legacy.catalog,
      sourceSchema: 4,
    );
    final project = legacy.copyWith(
      items: synthesized.items,
      documents: synthesized.documents,
    );
    expect(project.documents, hasLength(1));
    final side = project.documents.single.sides.single;
    expect(side.detection, isNotNull);
    expect(
      side.detection!.polygon,
      isNotNull,
      reason: 'a synthesized record always has a boundary',
    );
    expect(project.items.single.documentId, project.documents.single.id);

    await EditorHarness.pump(tester, project: project);
    expect(find.byKey(badgeKey), findsNothing);
    expect(find.byKey(const Key('offsheet-legacy')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// The AutoLayoutStatus name shown on [id]'s off-sheet tile.
String _statusOf(WidgetTester tester, String id) {
  final label = tester.widget<Text>(
    find.descendant(
      of: find.byKey(Key('offsheet-$id')),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Text &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('offsheet-status-'),
      ),
    ),
  );
  return (label.key! as ValueKey<String>).value.substring(
    'offsheet-status-'.length,
  );
}

DocumentRecord _record({
  required String id,
  required String assetId,
  required List<Point2>? polygon,
}) => DocumentRecord(
  id: id,
  sourceImageId: 'asset4',
  sides: [
    DocumentSide(
      id: 'side-$id',
      side: SideKind.front,
      processedAsset: ProcessedAssetRef(
        workingPath: 'projects/project1/assets/$assetId/edits/r1/working.png',
        thumbnailPath: 'projects/project1/assets/$assetId/edits/r1/thumb.jpg',
        width: 400,
        height: 250,
      ),
      // A detection with NO polygon is exactly the unresolved candidate: the
      // region was measured, and no trustworthy outline was found for it.
      detection: DetectionRef(
        detectionId: '$assetId-d0',
        producer: 'document-segmenter',
        version: 'segment-1',
        polygon: polygon,
      ),
    ),
  ],
  pairing: PairingState.single,
  provenance: Provenance(
    sourceImageId: 'asset4',
    detectionIds: ['$assetId-d0'],
    processedAssetVersion: 'smart-1',
    pipelineVersion: 'smart-1',
  ),
);

DocumentItem _offSheet(String id, String assetId, String documentId) =>
    DocumentItem(
      id: id,
      assetId: assetId,
      x: 0,
      y: 0,
      width: 60,
      height: 40,
      pageIndex: null,
      documentKind: DocumentKind.unknown,
      sizeConfirmed: false,
      documentId: documentId,
      sideId: 'side-$documentId',
    );

Project _project() {
  final outlined = [
    Point2(.1, .1),
    Point2(.9, .1),
    Point2(.9, .6),
    Point2(.1, .6),
  ];
  final items = [
    placedDocument('card', 'asset1', DocumentKind.unifiedNationalId),
    _offSheet('unresolved', 'asset2', 'doc-unresolved'),
    _offSheet('outlined', 'asset3', 'doc-outlined'),
    // No documentId: a manual item, or one from before records existed.
    DocumentItem(
      id: 'manual',
      assetId: 'asset4',
      x: 0,
      y: 0,
      width: 60,
      height: 40,
      pageIndex: null,
    ),
  ];
  return editorProject(
    items: items,
    documents: [
      _record(id: 'doc-unresolved', assetId: 'asset2', polygon: null),
      _record(id: 'doc-outlined', assetId: 'asset3', polygon: outlined),
    ],
  );
}
