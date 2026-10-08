import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_overrides.dart';

import 'editor_harness.dart';
import '../fixtures.dart';

DocumentRecord _record(
  String stem,
  String assetId, {
  String? pairedWith,
}) => DocumentRecord(
  id: 'rec-$stem',
  sourceImageId: assetId,
  sides: [
    DocumentSide(
      id: 'side-$stem',
      side: SideKind.unknown,
      processedAsset: ProcessedAssetRef(
        workingPath: 'projects/project1/assets/$assetId/working.png',
        thumbnailPath: 'projects/project1/assets/$assetId/thumb.jpg',
        width: 856,
        height: 540,
      ),
    ),
  ],
  recognition: RecognitionResult(
    documentKind: DocumentKind.unifiedNationalId,
    status: RecognitionStatus.recognized,
    confidences: ConfidenceSet(finalConfidence: Confidence(value: .78)),
    preset: const PresetSelection.resolved('builtin-unifiedNationalId'),
  ),
  pairing: pairedWith == null ? PairingState.single : PairingState.ambiguous,
  pairedDocumentId: pairedWith,
  pairingConfidence: pairedWith == null ? null : .85,
  provenance: Provenance(
    sourceImageId: assetId,
    detectionIds: ['$assetId-d0'],
    processedAssetVersion: 'smart-1',
    pipelineVersion: 'smart-1',
  ),
);

DocumentItem _linkedItem(String stem, String assetId, {double y = 5}) =>
    DocumentItem(
      id: stem,
      assetId: assetId,
      x: 5,
      y: y,
      width: 85.6,
      height: 53.98,
      documentKind: DocumentKind.unifiedNationalId,
      recognitionConfidence: .78,
      sizeConfirmed: true,
      documentId: 'rec-$stem',
      sideId: 'side-$stem',
    );

Project _reviewProject() => Project(
  id: 'project1',
  name: 'مستمسكات العائلة',
  createdAt: DateTime.utc(2026, 10, 7),
  updatedAt: DateTime.utc(2026, 10, 7),
  paper: PaperSettings(margins: Margins.all(5)),
  assets: [assetFixture(id: 'asset1'), assetFixture(id: 'asset2')],
  items: [
    _linkedItem('front', 'asset1'),
    _linkedItem('back', 'asset2', y: 70),
  ],
  documents: [
    _record('front', 'asset1', pairedWith: 'rec-back'),
    _record('back', 'asset2', pairedWith: 'rec-front'),
  ],
);

void main() {
  testWidgets('review button shows the live queue count', (tester) async {
    await EditorHarness.pump(tester, project: _reviewProject());
    expect(find.byKey(const Key('rb-review')), findsOneWidget);
    expect(find.text('مراجعة (2)'), findsOneWidget);
  });

  testWidgets('confirming an entry removes it and persists the override', (
    tester,
  ) async {
    final editor = await EditorHarness.pump(tester, project: _reviewProject());
    await tapKey(tester, const Key('rb-review'));
    expect(find.text('مراجعة التعرف الذكي (تجريبي)'), findsOneWidget);
    await tapKey(tester, const Key('review-confirm-rec-front'));
    final confirmed = editor.saved.documents.firstWhere(
      (d) => d.id == 'rec-front',
    );
    expect(confirmed.overrides, isNotEmpty);
    expect(recordsNeedingReview(editor.saved), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('accepting a proposed pair groups both items', (tester) async {
    final editor = await EditorHarness.pump(tester, project: _reviewProject());
    await tapKey(tester, const Key('rb-review'));
    await tapKey(tester, const Key('review-accept-pair-rec-front'));
    expect(editor.saved.layoutGroups, hasLength(1));
    expect(
      editor.saved.documents.every((d) => d.pairing == PairingState.paired),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejecting a proposed pair returns both to single', (
    tester,
  ) async {
    final editor = await EditorHarness.pump(tester, project: _reviewProject());
    await tapKey(tester, const Key('rb-review'));
    await tapKey(tester, const Key('review-reject-pair-rec-front'));
    expect(editor.saved.layoutGroups, isEmpty);
    expect(
      editor.saved.documents.every((d) => d.pairedDocumentId == null),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirm-all empties the queue and hides the ribbon button', (
    tester,
  ) async {
    final editor = await EditorHarness.pump(tester, project: _reviewProject());
    await tapKey(tester, const Key('rb-review'));
    await tapKey(tester, const Key('review-confirm-all'));
    expect(recordsNeedingReview(editor.saved), isEmpty);
    expect(find.text('لا توجد عناصر بانتظار المراجعة.'), findsOneWidget);
    await tapKey(tester, const Key('review-close'));
    expect(find.byKey(const Key('rb-review')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('kind correction through the dialog resizes the item', (
    tester,
  ) async {
    final editor = await EditorHarness.pump(tester, project: _reviewProject());
    await tapKey(tester, const Key('rb-review'));
    await tapKey(tester, const Key('review-kind-rec-front'));
    await tester.tap(find.text('جواز السفر').last);
    await tester.pumpAndSettle();
    final item = itemIn(editor.saved, 'front');
    expect(item.documentKind, DocumentKind.passport);
    expect([item.width, item.height], [125, 88]);
    final record = editor.saved.documents.firstWhere(
      (d) => d.id == 'rec-front',
    );
    expect(record.overrides.single.documentKind, DocumentKind.passport);
    expect(tester.takeException(), isNull);
  });

  testWidgets('undo reverses a review decision', (tester) async {
    final editor = await EditorHarness.pump(tester, project: _reviewProject());
    await tapKey(tester, const Key('rb-review'));
    await tapKey(tester, const Key('review-confirm-rec-front'));
    await tapKey(tester, const Key('review-close'));
    await tapKey(tester, const Key('qa-undo'));
    expect(recordsNeedingReview(editor.saved), hasLength(2));
    expect(tester.takeException(), isNull);
  });
}
