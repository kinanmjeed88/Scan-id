import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/boundary_suggestion.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/recognition.dart';

import '../fixtures.dart';

final quad = <Point2>[
  Point2(.1, .1),
  Point2(.9, .1),
  Point2(.9, .9),
  Point2(.1, .9),
];

DocumentRecord recordWithSuggestion(List<Point2> corners) => DocumentRecord(
  id: 'doc-a',
  sourceImageId: 'a',
  sides: [
    DocumentSide(
      id: 'side-a',
      side: SideKind.unknown,
      processedAsset: ProcessedAssetRef(
        workingPath: 'projects/project1/assets/a/working.png',
        thumbnailPath: 'projects/project1/assets/a/thumb.jpg',
        width: 400,
        height: 250,
      ),
      detection: DetectionRef(
        detectionId: 'd1',
        producer: 'test',
        version: '1',
        suggestedPolygon: corners,
      ),
    ),
  ],
  pairing: PairingState.single,
  provenance: Provenance(
    sourceImageId: 'a',
    detectionIds: const ['d1'],
    processedAssetVersion: 'v1',
    pipelineVersion: 'v1',
  ),
);

void main() {
  test('no saved suggestion is reported as absent', () {
    final asset = assetFixture(id: 'a');
    final result = inspectSuggestedBoundary(
      projectFixture(assets: [asset]),
      asset,
      sourceWidth: asset.width,
      sourceHeight: asset.height,
    );
    expect(result.isUsable, isFalse);
    expect(result.corners, isNull);
    expect(result.rejection, SuggestionRejection.absent);
  });

  test('an asset-level suggestion is usable and immutable', () {
    final asset = assetFixture(id: 'a').withSuggestedCrop(quad);
    final result = inspectSuggestedBoundary(
      projectFixture(assets: [asset]),
      asset,
      sourceWidth: asset.width,
      sourceHeight: asset.height,
    );
    expect(result.isUsable, isTrue);
    expect(result.corners, quad);
    expect(() => result.corners!.add(Point2(0, 0)), throwsUnsupportedError);
  });

  test('a degenerate suggestion is refused by the shared geometry gate', () {
    final asset = assetFixture(id: 'a').withSuggestedCrop([
      Point2(.5, .5),
      Point2(.5, .5),
      Point2(.5, .5),
      Point2(.5, .5),
    ]);
    final result = inspectSuggestedBoundary(
      projectFixture(assets: [asset]),
      asset,
      sourceWidth: asset.width,
      sourceHeight: asset.height,
    );
    expect(result.isUsable, isFalse);
    expect(result.rejection, SuggestionRejection.geometry);
  });

  test('a DetectionRef suggestion is found through path ownership', () {
    final asset = assetFixture(id: 'a');
    final project = projectFixture(
      assets: [asset],
      documents: [recordWithSuggestion(quad)],
    );
    expect(savedSuggestedBoundary(project, asset), quad);
    final result = inspectSuggestedBoundary(
      project,
      asset,
      sourceWidth: asset.width,
      sourceHeight: asset.height,
    );
    expect(result.isUsable, isTrue);
  });

  test('a record belonging to another asset is never reused', () {
    final asset = assetFixture(id: 'a');
    final other = assetFixture(id: 'b');
    final project = projectFixture(
      assets: [asset, other],
      documents: [
        recordWithSuggestion(quad).copyWithRecordOwnership(
          'projects/project1/assets/b/working.png',
          'b',
        ),
      ],
    );
    expect(savedSuggestedBoundary(project, asset), isNull);
  });
}

extension on DocumentRecord {
  /// Rebuilds the same record with a different processed-asset path, so the
  /// ownership rule (not record order) decides whether a suggestion applies.
  DocumentRecord copyWithRecordOwnership(String path, String sourceId) =>
      DocumentRecord(
        id: id,
        sourceImageId: sourceId,
        sides: [
          DocumentSide(
            id: sides.single.id,
            side: sides.single.side,
            processedAsset: ProcessedAssetRef(
              workingPath: path,
              thumbnailPath: sides.single.processedAsset.thumbnailPath,
              width: sides.single.processedAsset.width,
              height: sides.single.processedAsset.height,
            ),
            detection: sides.single.detection,
          ),
        ],
        pairing: pairing,
        provenance: provenance,
        recognition: recognition,
      );
}
