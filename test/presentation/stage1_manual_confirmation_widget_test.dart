import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_routing.dart';
import 'package:scan_id/presentation/app.dart';
import 'package:scan_id/presentation/layout_screen.dart';

import '../fixtures.dart';
import 'editor_harness.dart';

class _InMemoryAssets implements AssetRepository {
  int _seq = 0;

  @override
  Future<ImageAsset> importImage(
    String projectId,
    String name,
    Uint8List bytes,
  ) async {
    final id = 'mem-derived-${++_seq}';
    final prefix = 'projects/$projectId/assets/$id';
    return ImageAsset(
      id: id,
      name: name,
      originalPath: '$prefix/original.png',
      workingPath: '$prefix/working.png',
      thumbnailPath: '$prefix/thumb.jpg',
      width: 64,
      height: 40,
    );
  }

  @override
  Future<ReplacementFiles> replaceImage(
    String projectId,
    String assetId,
    Uint8List bytes,
  ) => Future.error(StateError('Unused in widget test'));

  @override
  Future<Uint8List> previewImage(Uint8List source) async => source;

  @override
  Future<File> resolve(String relativePath) =>
      Future.error(StateError('No disk access in widget test'));
}

class _CropCapableFakeEditor extends FakeImageEditor
    implements CropBytesImageEditor {
  @override
  Future<Uint8List> renderCropBytes(
    ImageAsset asset,
    ImageEditRecipe recipe,
  ) async => bytes;
}

DocumentRecord _unresolvedRecord(String docId, String assetId) =>
    DocumentRecord(
      id: docId,
      sourceImageId: assetId,
      sides: [
        DocumentSide(
          id: 'side-$docId',
          side: SideKind.unknown,
          processedAsset: ProcessedAssetRef(
            workingPath: 'projects/project1/assets/$assetId/working.png',
            thumbnailPath: 'projects/project1/assets/$assetId/thumb.jpg',
            width: 400,
            height: 250,
          ),
          detection: DetectionRef(
            detectionId: 'det-$docId',
            producer: 'scanid-docnet-v1',
            version: '1.0',
            polygon: null,
          ),
        ),
      ],
      pairing: PairingState.single,
      provenance: Provenance(
        sourceImageId: assetId,
        detectionIds: ['det-$docId'],
        processedAssetVersion: 'smart-1',
        pipelineVersion: 'smart-1',
      ),
    );

void main() {
  testWidgets(
    'Path B UI: tapping «ضبط الحدود» on an unconfirmed off-sheet item opens full-image 4-corner CropScreen, confirms kind, places item on A4 immediately, and supports 1-step undo',
    (tester) async {
      final project = editorProject(
        items: [
          DocumentItem(
            id: 'unconfirmed-1',
            assetId: 'asset1',
            x: 0,
            y: 0,
            width: 70,
            height: 45,
            pageIndex: null,
            documentKind: DocumentKind.unknown,
            sizeConfirmed: false,
            documentId: 'doc-1',
            sideId: 'side-doc-1',
          ),
        ],
        documents: [_unresolvedRecord('doc-1', 'asset1')],
      );

      final harness = await EditorHarness.pump(
        tester,
        project: project,
        imageEditor: FakeImageEditor(),
      );

      // Initially off-sheet with unresolved boundary badge.
      expect(find.byKey(const Key('offsheet-unconfirmed-1')), findsOneWidget);
      expect(
        find.byKey(const Key('offsheet-unresolved-badge')),
        findsOneWidget,
      );

      // Tap direct «ضبط الحدود» action on the off-sheet tile.
      await tapKey(tester, const Key('offsheet-crop-unconfirmed-1'));

      // Full image with 4 draggable corner handles is displayed.
      for (var i = 0; i < 4; i++) {
        expect(find.byKey(Key('crop-corner-$i')), findsOneWidget);
      }

      // Select National ID category inside CropScreen.
      await tapKey(tester, const Key('crop-document-kind'));
      await tester.tap(find.text(DocumentKind.unifiedNationalId.label).last);
      await tester.pumpAndSettle();

      // Preview and accept.
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('accept-crop'));

      // Immediately placed onto A4 without re-import; OffSheetTray disappears!
      expect(find.byKey(const Key('offsheet-unconfirmed-1')), findsNothing);
      final confirmedItem = harness.saved.items.single;
      expect(confirmedItem.sizeConfirmed, isTrue);
      expect(confirmedItem.documentKind, DocumentKind.unifiedNationalId);
      expect(confirmedItem.pageIndex, 0);
      expect(hasUnresolvedBoundary(harness.saved.documents.single), isFalse);

      // One-step undo in LayoutScreen restores the pre-confirmation off-sheet state.
      await tapKey(tester, const Key('qa-undo'));
      expect(harness.saved.items.single.sizeConfirmed, isFalse);
      expect(harness.saved.items.single.pageIndex, isNull);
    },
  );

  testWidgets(
    'Path B UI custom mm size + Path C UI «مستمسك إضافي» extracts independent second document onto A4 without overlap',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = MemoryProjects();
      final initial = await repository.create(
        editorProject(
          items: [
            DocumentItem(
              id: 'multi-placeholder',
              assetId: 'asset1',
              x: 0,
              y: 0,
              width: 80,
              height: 50,
              pageIndex: null,
              documentKind: DocumentKind.unknown,
              sizeConfirmed: false,
            ),
          ],
        ),
      );
      final service = ProjectService(
        repository,
        _InMemoryAssets(),
        imageEditor: _CropCapableFakeEditor(),
      );

      await tester.pumpWidget(
        AppShell(
          home: LayoutScreen(
            project: initial,
            service: service,
            pickImages: () async => <ImportSource>[],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Select placeholder item -> 'document' tab opens automatically -> tap «مستمسك إضافي»
      await tapKey(tester, const Key('offsheet-multi-placeholder'));
      await tapKey(tester, const Key('rb-doc-extract'));

      // Extract Document #1 with custom print size 100 x 65 mm
      await tapKey(tester, const Key('crop-document-kind'));
      await tester.tap(find.text('مقاس مخصص (مم)').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('crop-custom-width-mm')),
        '100',
      );
      await tester.enterText(
        find.byKey(const Key('crop-custom-height-mm')),
        '65',
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('accept-crop'));

      // Extract Document #2 (Passport) from the SAME root source photograph
      await tapKey(tester, const Key('rb-doc-extract'));
      await tapKey(tester, const Key('crop-document-kind'));
      await tester.tap(find.text(DocumentKind.passport.label).last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('accept-crop'));

      final saved = repository.values[initial.id]!;
      expect(saved.items, hasLength(2));
      expect(
        saved.items.every((i) => i.pageIndex == 0 && i.sizeConfirmed),
        isTrue,
      );
      expect(saved.items[0].bounds.overlaps(saved.items[1].bounds), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Defect 5B + precision regression: CropScreen internal undo/redo restores DocumentKind, multi-decimal custom mm size, and corners together',
    (tester) async {
      final src = assetFixture(id: 'undo-src');
      final initial = projectFixture(
        assets: [src],
        items: [
          DocumentItem(
            id: 'undo-item',
            assetId: src.id,
            x: 10,
            y: 10,
            width: 72,
            height: 50,
            pageIndex: null,
            documentKind: DocumentKind.unknown,
            sizeConfirmed: false,
          ),
        ],
      );
      final harness = await EditorHarness.pump(
        tester,
        project: initial,
        imageEditor: FakeImageEditor(),
      );

      await tapKey(tester, const Key('offsheet-undo-item'));
      await tapKey(tester, const Key('rb-doc-crop'));

      DropdownButton<DocumentKind> kindDropdown() =>
          tester.widget<DropdownButton<DocumentKind>>(
            find.byKey(const Key('crop-document-kind')),
          );
      IconButton undoIconButton() => tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('تراجع'),
          matching: find.byType(IconButton),
        ),
      );

      // Initial state: DocumentKind.unknown, undo disabled.
      expect(kindDropdown().value, DocumentKind.unknown);
      expect(undoIconButton().onPressed, isNull);

      // Step 1: Select unifiedNationalId.
      await tester.ensureVisible(find.byKey(const Key('crop-document-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('crop-document-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(DocumentKind.unifiedNationalId.label).last);
      await tester.pumpAndSettle();
      expect(kindDropdown().value, DocumentKind.unifiedNationalId);
      expect(find.byKey(const Key('crop-custom-width-mm')), findsNothing);

      // Step 2: Select custom mm (`DocumentKind.other`) -> initial 85.6 x 54.0.
      await tester.tap(find.byKey(const Key('crop-document-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('مقاس مخصص (مم)').last);
      await tester.pumpAndSettle();
      expect(kindDropdown().value, DocumentKind.other);
      expect(find.byKey(const Key('crop-custom-width-mm')), findsOneWidget);

      // Step 3 & Step 4: Enter multi-decimal custom dimensions 118.25 x 76.75 mm.
      await tester.enterText(
        find.byKey(const Key('crop-custom-width-mm')),
        '118.25',
      );
      await tester.enterText(
        find.byKey(const Key('crop-custom-height-mm')),
        '76.75',
      );
      await tester.pumpAndSettle();

      // Step 5: Drag corner 0 (multi-step timedDrag beyond pan slop).
      final cornerFinder = find.byKey(const Key('crop-corner-0'));
      await tester.ensureVisible(cornerFinder);
      await tester.pumpAndSettle();
      final cornerBeforeDrag = tester.getCenter(cornerFinder);
      await tester.timedDrag(
        cornerFinder,
        const Offset(60, 40),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      final cornerAfterDrag = tester.getCenter(cornerFinder);
      expect((cornerAfterDrag - cornerBeforeDrag).distance, greaterThan(5.0));

      // Undo #1 -> reverts corner drag, keeps 118.25 x 76.75 and DocumentKind.other.
      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      expect(
        (tester.getCenter(find.byKey(const Key('crop-corner-0'))) -
                cornerBeforeDrag)
            .distance,
        lessThan(1.0),
      );
      expect(kindDropdown().value, DocumentKind.other);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('crop-custom-width-mm')))
            .controller!
            .text,
        '118.25',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('crop-custom-height-mm')))
            .controller!
            .text,
        '76.75',
      );

      // Undo #2 -> reverts custom height back to '54.0', keeps width '118.25'.
      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('crop-custom-width-mm')))
            .controller!
            .text,
        '118.25',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('crop-custom-height-mm')))
            .controller!
            .text,
        '54.0',
      );

      // Undo #3 -> reverts custom width back to '85.6'.
      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      expect(kindDropdown().value, DocumentKind.other);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('crop-custom-width-mm')))
            .controller!
            .text,
        '85.6',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('crop-custom-height-mm')))
            .controller!
            .text,
        '54.0',
      );

      // Undo #4 -> reverts DocumentKind from `other` back to `unifiedNationalId`.
      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      expect(kindDropdown().value, DocumentKind.unifiedNationalId);
      expect(find.byKey(const Key('crop-custom-width-mm')), findsNothing);

      // Undo #5 -> reverts DocumentKind back to initial `unknown`.
      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      expect(kindDropdown().value, DocumentKind.unknown);
      expect(undoIconButton().onPressed, isNull);

      // Redo 5 times -> restores DocumentKind.other + 118.25 x 76.75 + dragged corner.
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byTooltip('إعادة'));
        await tester.pumpAndSettle();
      }
      expect(kindDropdown().value, DocumentKind.other);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('crop-custom-width-mm')))
            .controller!
            .text,
        '118.25',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('crop-custom-height-mm')))
            .controller!
            .text,
        '76.75',
      );

      // Preview, verify editing custom mm invalidates stale preview, re-preview & accept!
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('accept-crop')))
            .onPressed,
        isNotNull,
      );

      await tester.enterText(
        find.byKey(const Key('crop-custom-width-mm')),
        '119.25',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('accept-crop')))
            .onPressed,
        isNull,
        reason: 'editing custom mm must invalidate stale preview',
      );

      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('accept-crop')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('accept-crop')));
      await tester.pumpAndSettle();

      final savedItem = harness.saved.items.single;
      expect(savedItem.documentKind, DocumentKind.other);
      expect(savedItem.sizeConfirmed, isTrue);
      expect(savedItem.pageIndex, 0);
      expect([savedItem.width, savedItem.height], [118.25, 76.75]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Defect 3 UI regression: ReviewScreen crop action on paired 2-sided record targets the unresolved back side rather than already-confirmed front side',
    (tester) async {
      final frontSrc = assetFixture(id: 'pair-front');
      final backSrc = assetFixture(id: 'pair-back');
      final frontSide = DocumentSide(
        id: 's-front',
        side: SideKind.front,
        processedAsset: ProcessedAssetRef(
          workingPath: frontSrc.workingPath,
          thumbnailPath: frontSrc.thumbnailPath,
          width: frontSrc.width,
          height: frontSrc.height,
        ),
        detection: DetectionRef(
          detectionId: 'd-front',
          producer: 'scanid-docnet-v1',
          version: '1.0',
          polygon: null,
        ),
      );
      final backSide = DocumentSide(
        id: 's-back',
        side: SideKind.back,
        processedAsset: ProcessedAssetRef(
          workingPath: backSrc.workingPath,
          thumbnailPath: backSrc.thumbnailPath,
          width: backSrc.width,
          height: backSrc.height,
        ),
        detection: DetectionRef(
          detectionId: 'd-back',
          producer: 'scanid-docnet-v1',
          version: '1.0',
          polygon: null,
        ),
      );

      final pairedRecord = DocumentRecord(
        id: 'rec-2sides',
        sourceImageId: frontSrc.id,
        sides: [frontSide, backSide],
        pairing: PairingState.paired,
        recognition: RecognitionResult(
          documentKind: DocumentKind.unifiedNationalId,
          status: RecognitionStatus.uncertain,
          confidences: ConfidenceSet(finalConfidence: Confidence(value: 0.44)),
          preset: const PresetSelection.awaiting(),
        ),
        overrides: [
          UserOverride(
            fields: [manualBoundaryConfirmedSideField(frontSide.id)],
          ),
        ],
        provenance: Provenance(
          sourceImageId: frontSrc.id,
          detectionIds: const ['d-front', 'd-back'],
          processedAssetVersion: 'smart-1',
          pipelineVersion: 'smart-1',
        ),
      );

      final initial = projectFixture(
        assets: [frontSrc, backSrc],
        items: [
          DocumentItem(
            id: 'item-front',
            assetId: frontSrc.id,
            x: 10,
            y: 10,
            width: 85.6,
            height: 53.98,
            pageIndex: 0,
            documentKind: DocumentKind.unifiedNationalId,
            sizeConfirmed: true,
            documentId: pairedRecord.id,
            sideId: frontSide.id,
          ),
          DocumentItem(
            id: 'item-back',
            assetId: backSrc.id,
            x: 10,
            y: 70,
            width: 75,
            height: 50,
            pageIndex: null,
            documentKind: DocumentKind.unknown,
            sizeConfirmed: false,
            documentId: pairedRecord.id,
            sideId: backSide.id,
          ),
        ],
        documents: [pairedRecord],
      );

      final harness = await EditorHarness.pump(
        tester,
        project: initial,
        imageEditor: FakeImageEditor(),
      );

      // Open Review queue -> tap `review-crop-rec-2sides` -> targets unresolved back side!
      await tapKey(tester, const Key('rb-review'));
      await tapKey(tester, const Key('review-crop-rec-2sides'));

      // Confirm back side in CropScreen -> BOTH front and back items now sit on A4!
      await tapKey(tester, const Key('crop-document-kind'));
      await tester.tap(find.text(DocumentKind.unifiedNationalId.label).last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('accept-crop'));

      final saved = harness.saved;
      expect(
        saved.items.every((i) => i.sizeConfirmed && i.pageIndex == 0),
        isTrue,
      );
      expect(hasUnresolvedBoundary(saved.documents.single), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
