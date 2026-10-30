import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/manual_boundary.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_routing.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/full_resolution_manual_crop.dart';

import '../fixtures.dart';

ImageAsset _sourceAsset({
  String id = 'src1',
  int width = 1200,
  int height = 900,
}) => ImageAsset(
  id: id,
  name: 'photo.jpg',
  originalPath: 'projects/project1/assets/$id/original.jpg',
  workingPath: 'projects/project1/assets/$id/working.png',
  thumbnailPath: 'projects/project1/assets/$id/thumb.jpg',
  width: width,
  height: height,
);

ImageAsset _derivedFixture({
  required String id,
  int width = 856,
  int height = 540,
}) => ImageAsset(
  id: id,
  name: '$id.png',
  originalPath: 'projects/project1/assets/$id/original.png',
  workingPath: 'projects/project1/assets/$id/working.png',
  thumbnailPath: 'projects/project1/assets/$id/thumb.jpg',
  width: width,
  height: height,
);

void main() {
  group('validateManualBoundary — independent from automatic verifyBoundary', () {
    test(
      'accepts valid user-confirmed quad near frame edge or custom aspect that verifyBoundary refuses automatically',
      () {
        // Touches frame edge (x = 0.002 < automatic 0.016 margin) and non-catalog aspect.
        final edgeCorners = <Point2>[
          Point2(0.002, 0.10),
          Point2(0.62, 0.10),
          Point2(0.62, 0.72),
          Point2(0.002, 0.72),
        ];
        final autoDecision = verifyBoundary(
          BoundaryProposal(
            producer: BoundaryProducer.learnedModel,
            corners: edgeCorners,
            modelConfidence: 0.95,
            minAutoAcceptConfidence: 0.55,
            touchesFrameEdge: true,
          ),
          sourceWidth: 1200,
          sourceHeight: 900,
        );
        expect(autoDecision.cropAuthorization, isNull);

        final manual = validateManualBoundary(
          corners: edgeCorners,
          sourceWidth: 1200,
          sourceHeight: 900,
          documentKind: DocumentKind.other,
          customSizeMm: const PhysicalSizeMm(95, 95),
          requireConfirmedSize: true,
        );
        expect(manual.isValid, isTrue);
        expect(manual.producer, BoundaryProducer.manual);
        expect(manual.confirmedKind, DocumentKind.other);
        expect(
          manual.confirmedSizeMm!.sameAs(const PhysicalSizeMm(95, 95)),
          isTrue,
        );
      },
    );

    test(
      'rejects wrong point count, non-finite, out-of-bounds, crossed, concave, tiny, and unconfirmed size',
      () {
        expect(
          validateManualBoundary(
            corners: [Point2(0.1, 0.1), Point2(0.9, 0.1), Point2(0.9, 0.9)],
            sourceWidth: 800,
            sourceHeight: 600,
          ).rejection,
          ManualBoundaryRejection.wrongPointCount,
        );

        expect(
          () => Point2(double.nan, 0.1),
          throwsA(isA<ValidationException>()),
        );

        expect(
          validateManualBoundary(
            corners: [
              Point2(0.1, 0.1),
              Point2(0.9, 0.1),
              Point2(0.9, 0.9),
              Point2(0.1, 0.9),
            ],
            sourceWidth: 0,
            sourceHeight: 600,
          ).rejection,
          ManualBoundaryRejection.invalidSourceDimensions,
        );

        expect(
          validateManualBoundary(
            corners: [
              Point2(-0.01, 0.1),
              Point2(0.9, 0.1),
              Point2(0.9, 0.9),
              Point2(0.1, 0.9),
            ],
            sourceWidth: 800,
            sourceHeight: 600,
          ).rejection,
          ManualBoundaryRejection.outOfBounds,
        );

        // Bowtie / self-intersecting quad
        final crossed = validateManualBoundary(
          corners: [
            Point2(0.1, 0.1),
            Point2(0.9, 0.9),
            Point2(0.9, 0.1),
            Point2(0.1, 0.9),
          ],
          sourceWidth: 800,
          sourceHeight: 600,
        );
        expect(crossed.isValid, isFalse);
        expect(
          crossed.rejection,
          ManualBoundaryRejection.selfIntersectingOrNonConvex,
        );
        expect(crossed.message, contains('زوايا القص'));

        // Concave quad (vertex 2 pulled inside triangle 0-1-3)
        expect(
          validateManualBoundary(
            corners: [
              Point2(0.1, 0.1),
              Point2(0.9, 0.1),
              Point2(0.35, 0.25),
              Point2(0.1, 0.9),
            ],
            sourceWidth: 800,
            sourceHeight: 600,
          ).rejection,
          ManualBoundaryRejection.selfIntersectingOrNonConvex,
        );

        // Too small (< 4 px edge on 800x600)
        expect(
          validateManualBoundary(
            corners: [
              Point2(0.20, 0.20),
              Point2(0.203, 0.20),
              Point2(0.203, 0.50),
              Point2(0.20, 0.50),
            ],
            sourceWidth: 800,
            sourceHeight: 600,
          ).rejection,
          ManualBoundaryRejection.tooSmall,
        );

        // Unconfirmed size when confirming for A4
        expect(
          validateManualBoundary(
            corners: [
              Point2(0.1, 0.1),
              Point2(0.9, 0.1),
              Point2(0.9, 0.8),
              Point2(0.1, 0.8),
            ],
            sourceWidth: 800,
            sourceHeight: 600,
            documentKind: DocumentKind.unknown,
            requireConfirmedSize: true,
          ).rejection,
          ManualBoundaryRejection.unconfirmedDocumentSize,
        );

        expect(
          () => requireValidManualBoundary(
            corners: [
              Point2(0.1, 0.1),
              Point2(0.9, 0.1),
              Point2(0.9, 0.8),
              Point2(0.1, 0.8),
            ],
            sourceWidth: 800,
            sourceHeight: 600,
            documentKind: DocumentKind.other,
            customSizeMm: const PhysicalSizeMm(4, 50),
            requireConfirmedSize: true,
          ),
          throwsA(isA<ValidationException>()),
        );
      },
    );

    test(
      'preview-to-full-resolution normalized corners map consistently across scales and EXIF 6',
      () {
        final previewCorners = <Point2>[
          Point2(0.14, 0.18),
          Point2(0.84, 0.16),
          Point2(0.86, 0.64),
          Point2(0.12, 0.66),
        ];
        // Raw sensor 4000x3000 with EXIF Orientation 6 -> oriented 3000x4000
        final oriented = orientedPixelSize(4000, 3000, 6);
        expect(oriented, (3000, 4000));

        // Preview scaled uniformly to 960x1280
        final previewCheck = validateManualBoundary(
          corners: previewCorners,
          sourceWidth: 960,
          sourceHeight: 1280,
          documentKind: DocumentKind.unifiedNationalId,
          requireConfirmedSize: true,
        );
        final fullCheck = validateManualBoundary(
          corners: previewCorners,
          sourceWidth: oriented.$1,
          sourceHeight: oriented.$2,
          documentKind: DocumentKind.unifiedNationalId,
          requireConfirmedSize: true,
        );
        expect(previewCheck.isValid, isTrue);
        expect(fullCheck.isValid, isTrue);

        final bounds = manualCropBounds(previewCorners);
        final localCorners = remapCornersIntoRegion(
          previewCorners,
          bounds,
          orientedWidth: oriented.$1,
          orientedHeight: oriented.$2,
          regionWidth: 810,
          regionHeight: 1080,
        );
        final spanW = snappedSpanPixels(bounds.left, bounds.right, oriented.$1);
        final spanH = snappedSpanPixels(bounds.top, bounds.bottom, oriented.$2);
        final localCheck = validateManualBoundary(
          corners: localCorners,
          sourceWidth: spanW,
          sourceHeight: spanH,
          documentKind: DocumentKind.unifiedNationalId,
          requireConfirmedSize: true,
        );
        expect(localCheck.isValid, isTrue);
      },
    );
  });

  group('Manual confirmation provenance and multi-document extraction', () {
    test(
      'Path B confirmation resolves hasUnresolvedBoundary via UserOverride without fabricating detector polygon and places item on A4',
      () {
        var seq = 0;
        String nextId() => 'gen-${++seq}';
        final src = _sourceAsset();
        final unresolvedRecord = DocumentRecord(
          id: 'rec-1',
          sourceImageId: src.id,
          sides: [
            DocumentSide(
              id: 'side-1',
              side: SideKind.unknown,
              processedAsset: ProcessedAssetRef(
                workingPath: src.workingPath,
                thumbnailPath: src.thumbnailPath,
                width: src.width,
                height: src.height,
              ),
              detection: DetectionRef(
                detectionId: 'det-1',
                producer: 'historical-boundary-proposer',
                version: '1.0',
                polygon: null,
              ),
            ),
          ],
          pairing: PairingState.single,
          provenance: Provenance(
            sourceImageId: src.id,
            detectionIds: const ['det-1'],
            processedAssetVersion: 'smart-1',
            pipelineVersion: 'smart-1',
          ),
        );
        final unconfirmedItem = DocumentItem(
          id: 'item-1',
          assetId: src.id,
          x: 10,
          y: 10,
          width: 70,
          height: 50,
          pageIndex: null,
          documentKind: DocumentKind.unknown,
          sizeConfirmed: false,
          documentId: unresolvedRecord.id,
          sideId: 'side-1',
        );
        final initial = projectFixture(
          assets: [src],
          items: [unconfirmedItem],
          documents: [unresolvedRecord],
        );
        expect(hasUnresolvedBoundary(initial.documents.single), isTrue);

        final corners = <Point2>[
          Point2(0.12, 0.15),
          Point2(0.88, 0.15),
          Point2(0.88, 0.65),
          Point2(0.12, 0.65),
        ];
        final recipe = CropDraft(
          corners: corners,
        ).toRecipe(src.width, src.height);
        final warped = ImageAsset(
          id: src.id,
          name: src.name,
          originalPath: src.originalPath,
          workingPath:
              'projects/project1/assets/${src.id}/edits/e1/working.png',
          thumbnailPath:
              'projects/project1/assets/${src.id}/edits/e1/thumb.jpg',
          width: recipe.geometry.outputWidth,
          height: recipe.geometry.outputHeight,
          crop: recipe.geometry,
        );

        final confirmed = applyManualConfirmationToProject(
          initial,
          updatedAsset: warped,
          recipe: recipe,
          documentKind: DocumentKind.unifiedNationalId,
          sizeMm: const PhysicalSizeMm(85.6, 53.98),
          nextId: nextId,
          targetItemId: unconfirmedItem.id,
        );

        final item = confirmed.items.single;
        expect(item.sizeConfirmed, isTrue);
        expect(item.documentKind, DocumentKind.unifiedNationalId);
        expect([item.width, item.height], [85.6, 53.98]);
        expect(item.pageIndex, 0);
        expect(confirmed.paper.printable.contains(item.bounds), isTrue);

        final updatedAsset = confirmed.assets.single;
        expect(updatedAsset.userAuthoredCrop, isTrue);
        expect(updatedAsset.originalPath, src.originalPath);

        final updatedRecord = confirmed.documents.single;
        expect(hasUnresolvedBoundary(updatedRecord), isFalse);
        expect(
          updatedRecord.sides.single.detection!.polygon,
          isNull,
          reason:
              'detector evidence is never fabricated on manual confirmation',
        );
        expect(updatedRecord.overrides.single.corners, hasLength(4));
        expect(
          updatedRecord.overrides.single.fields,
          contains(manualBoundaryConfirmedField),
        );
      },
    );

    test(
      'Path C extracts 2 independent derived documents from 1 source image without merging or overlap',
      () {
        var seq = 0;
        String nextId() => 'mc-${++seq}';
        final src = _sourceAsset(id: 'multi-src', width: 1600, height: 1200);
        final placeholder = DocumentItem(
          id: 'placeholder-whole',
          assetId: src.id,
          x: 10,
          y: 10,
          width: 90,
          height: 67.5,
          pageIndex: null,
          documentKind: DocumentKind.unknown,
          sizeConfirmed: false,
        );
        var project = projectFixture(assets: [src], items: [placeholder]);

        final recipe1 = CropDraft(
          corners: [
            Point2(0.06, 0.12),
            Point2(0.46, 0.12),
            Point2(0.46, 0.48),
            Point2(0.06, 0.48),
          ],
        ).toRecipe(src.width, src.height);
        project = appendManualDerivedDocumentToProject(
          project,
          sourceAsset: src,
          derivedAsset: _derivedFixture(
            id: 'derived-1',
            width: 640,
            height: 432,
          ),
          recipe: recipe1,
          documentKind: DocumentKind.unifiedNationalId,
          sizeMm: const PhysicalSizeMm(85.6, 53.98),
          nextId: nextId,
        );

        final recipe2 = CropDraft(
          corners: [
            Point2(0.52, 0.12),
            Point2(0.94, 0.12),
            Point2(0.94, 0.52),
            Point2(0.52, 0.52),
          ],
        ).toRecipe(src.width, src.height);
        project = appendManualDerivedDocumentToProject(
          project,
          sourceAsset: src,
          derivedAsset: _derivedFixture(
            id: 'derived-2',
            width: 672,
            height: 480,
          ),
          recipe: recipe2,
          documentKind: DocumentKind.residenceCard,
          sizeMm: DocumentSizeCatalog.defaultResidenceCard,
          nextId: nextId,
        );

        // Source photo remains intact in assets; placeholder removed; 2 independent items placed on A4.
        expect(project.assets.map((a) => a.id), [
          'multi-src',
          'derived-1',
          'derived-2',
        ]);
        expect(
          project.assets.firstWhere((a) => a.id == 'multi-src').workingPath,
          src.workingPath,
        );
        expect(project.items, hasLength(2));
        expect(project.documents, hasLength(2));
        expect(reconcileDerivedProvenance(project).changed, isFalse);

        final placed = project.items.where((i) => i.pageIndex == 0).toList();
        expect(placed, hasLength(2));
        expect(placed[0].bounds.overlaps(placed[1].bounds), isFalse);
        for (final item in placed) {
          expect(item.sizeConfirmed, isTrue);
          expect(project.paper.printable.contains(item.bounds), isTrue);
        }
      },
    );

    test(
      'PairingState.paired regression: confirming side 1 updates ONLY side 1 and does not overwrite or falsely resolve side 2',
      () {
        var seq = 0;
        String nextId() => 'pair-${++seq}';
        final frontSrc = _sourceAsset(
          id: 'front-asset',
          width: 1200,
          height: 900,
        );
        final backSrc = _sourceAsset(
          id: 'back-asset',
          width: 1000,
          height: 800,
        );

        final frontSide = DocumentSide(
          id: 'side-front',
          side: SideKind.front,
          processedAsset: ProcessedAssetRef(
            workingPath: frontSrc.workingPath,
            thumbnailPath: frontSrc.thumbnailPath,
            width: frontSrc.width,
            height: frontSrc.height,
          ),
          detection: DetectionRef(
            detectionId: 'det-front',
            producer: 'historical-boundary-proposer',
            version: '1.0',
            polygon: null,
          ),
        );
        final backSide = DocumentSide(
          id: 'side-back',
          side: SideKind.back,
          processedAsset: ProcessedAssetRef(
            workingPath: backSrc.workingPath,
            thumbnailPath: backSrc.thumbnailPath,
            width: backSrc.width,
            height: backSrc.height,
          ),
          detection: DetectionRef(
            detectionId: 'det-back',
            producer: 'historical-boundary-proposer',
            version: '1.0',
            polygon: null,
          ),
        );
        final backBeforeJson = backSide.toJson();

        final pairedRecord = DocumentRecord(
          id: 'rec-paired',
          sourceImageId: frontSrc.id,
          sides: [frontSide, backSide],
          pairing: PairingState.paired,
          recognition: RecognitionResult(
            documentKind: DocumentKind.unifiedNationalId,
            status: RecognitionStatus.uncertain,
            confidences: ConfidenceSet(
              finalConfidence: Confidence(value: 0.45),
            ),
            preset: const PresetSelection.awaiting(),
          ),
          provenance: Provenance(
            sourceImageId: frontSrc.id,
            detectionIds: const ['det-front', 'det-back'],
            processedAssetVersion: 'smart-1',
            pipelineVersion: 'smart-1',
          ),
        );

        final itemFront = DocumentItem(
          id: 'item-front',
          assetId: frontSrc.id,
          x: 10,
          y: 10,
          width: 75,
          height: 50,
          pageIndex: null,
          documentKind: DocumentKind.unknown,
          sizeConfirmed: false,
          documentId: pairedRecord.id,
          sideId: frontSide.id,
        );
        final itemBack = DocumentItem(
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
        );

        final initial = projectFixture(
          assets: [frontSrc, backSrc],
          items: [itemFront, itemBack],
          documents: [pairedRecord],
        );

        // Crop and confirm ONLY frontSrc / itemFront
        final frontRecipe = CropDraft(
          corners: [
            Point2(0.10, 0.12),
            Point2(0.90, 0.12),
            Point2(0.90, 0.72),
            Point2(0.10, 0.72),
          ],
        ).toRecipe(frontSrc.width, frontSrc.height);
        final warpedFront = ImageAsset(
          id: frontSrc.id,
          name: frontSrc.name,
          originalPath: frontSrc.originalPath,
          workingPath:
              'projects/project1/assets/${frontSrc.id}/edits/e1/working.png',
          thumbnailPath:
              'projects/project1/assets/${frontSrc.id}/edits/e1/thumb.jpg',
          width: frontRecipe.geometry.outputWidth,
          height: frontRecipe.geometry.outputHeight,
          crop: frontRecipe.geometry,
        );

        final afterFront = applyManualConfirmationToProject(
          initial,
          updatedAsset: warpedFront,
          recipe: frontRecipe,
          documentKind: DocumentKind.unifiedNationalId,
          sizeMm: const PhysicalSizeMm(85.6, 53.98),
          nextId: nextId,
          targetItemId: itemFront.id,
        );

        final recAfterFront = afterFront.documents.single;
        final updatedFrontSide = recAfterFront.sides[0];
        final updatedBackSide = recAfterFront.sides[1];

        // Side 1 updated; Side 2 completely untouched!
        expect(
          updatedFrontSide.processedAsset.workingPath,
          warpedFront.workingPath,
        );
        expect(updatedFrontSide.processedAsset.corners, hasLength(4));
        expect(updatedBackSide.toJson(), backBeforeJson);
        expect(
          sideHasManualBoundaryOverride(recAfterFront, updatedFrontSide),
          isTrue,
        );
        expect(
          sideHasUnresolvedBoundary(recAfterFront, updatedFrontSide),
          isFalse,
        );
        expect(
          sideHasManualBoundaryOverride(recAfterFront, updatedBackSide),
          isFalse,
        );
        expect(
          sideHasUnresolvedBoundary(recAfterFront, updatedBackSide),
          isTrue,
        );

        // Paired record as a whole is NOT falsely boundary-resolved until Side 2 is resolved!
        expect(hasUnresolvedBoundary(recAfterFront), isTrue);
        expect(recordNeedsReview(recAfterFront), isTrue);

        final placedFront = afterFront.items.firstWhere(
          (i) => i.id == 'item-front',
        );
        final pendingBack = afterFront.items.firstWhere(
          (i) => i.id == 'item-back',
        );
        expect(placedFront.sizeConfirmed, isTrue);
        expect(placedFront.pageIndex, 0);
        expect(pendingBack.sizeConfirmed, isFalse);
        expect(pendingBack.pageIndex, isNull);

        // Now confirm Side 2 as well -> record becomes fully resolved!
        final backRecipe = CropDraft(
          corners: [
            Point2(0.08, 0.14),
            Point2(0.92, 0.14),
            Point2(0.92, 0.76),
            Point2(0.08, 0.76),
          ],
        ).toRecipe(backSrc.width, backSrc.height);
        final warpedBack = ImageAsset(
          id: backSrc.id,
          name: backSrc.name,
          originalPath: backSrc.originalPath,
          workingPath:
              'projects/project1/assets/${backSrc.id}/edits/e1/working.png',
          thumbnailPath:
              'projects/project1/assets/${backSrc.id}/edits/e1/thumb.jpg',
          width: backRecipe.geometry.outputWidth,
          height: backRecipe.geometry.outputHeight,
          crop: backRecipe.geometry,
        );

        final afterBoth = applyManualConfirmationToProject(
          afterFront,
          updatedAsset: warpedBack,
          recipe: backRecipe,
          documentKind: DocumentKind.unifiedNationalId,
          sizeMm: const PhysicalSizeMm(85.6, 53.98),
          nextId: nextId,
          targetItemId: itemBack.id,
        );

        final recAfterBoth = afterBoth.documents.single;
        expect(
          recAfterBoth.sides[0].processedAsset.workingPath,
          warpedFront.workingPath,
          reason: 'confirming Side 2 must never overwrite Side 1',
        );
        expect(
          recAfterBoth.sides[1].processedAsset.workingPath,
          warpedBack.workingPath,
        );
        expect(hasUnresolvedBoundary(recAfterBoth), isFalse);
        expect(recordNeedsReview(recAfterBoth), isFalse);
        expect(
          afterBoth.items.every((i) => i.sizeConfirmed && i.pageIndex == 0),
          isTrue,
        );

        // Reverting Side 1 only returns Side 1 to unresolved off-sheet while keeping Side 2 on A4!
        final revertedFront = revertManualCropOnProject(
          afterBoth,
          resetAsset: frontSrc,
        );
        final recAfterRevert = revertedFront.documents.single;
        expect(recAfterRevert.sides[0].processedAsset.corners, isNull);
        expect(
          sideHasManualBoundaryOverride(
            recAfterRevert,
            recAfterRevert.sides[0],
          ),
          isFalse,
        );
        expect(
          sideHasUnresolvedBoundary(recAfterRevert, recAfterRevert.sides[0]),
          isTrue,
        );
        expect(
          sideHasManualBoundaryOverride(
            recAfterRevert,
            recAfterRevert.sides[1],
          ),
          isTrue,
        );
        expect(
          sideHasUnresolvedBoundary(recAfterRevert, recAfterRevert.sides[1]),
          isFalse,
        );
        expect(hasUnresolvedBoundary(recAfterRevert), isTrue);
        expect(recordNeedsReview(recAfterRevert), isTrue);
        expect(
          revertedFront.items.firstWhere((i) => i.id == 'item-front').pageIndex,
          isNull,
        );
        expect(
          revertedFront.items.firstWhere((i) => i.id == 'item-back').pageIndex,
          0,
        );
      },
    );
  });
}
